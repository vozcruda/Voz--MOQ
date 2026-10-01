-- 007: product images (Supabase Storage) + admin can create products.
-- Run once in the Supabase SQL editor. Safe to re-run.

-- ---------------------------------------------------------------------
-- 1. Public storage bucket for product images (5 MB, jpeg/png/webp)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('vc-public', 'vc-public', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = true, file_size_limit = 5242880,
      allowed_mime_types = array['image/jpeg','image/png','image/webp'];

-- Upload path rule: products/<organization_id>/<anything>.<ext>
-- Allowed for members of that organization, or admins with the catalogue permission.
create or replace function public.can_write_public_object(p_name text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_org uuid;
begin
  if p_name !~ '^products/[0-9a-f-]{36}/[^/]+$' then return false; end if;
  v_org := split_part(p_name, '/', 2)::uuid;
  return public.is_org_member(v_org) or public.has_perm('catalogue');
end $$;
grant execute on function public.can_write_public_object(text) to authenticated;

drop policy if exists vc_public_insert on storage.objects;
create policy vc_public_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'vc-public' and public.can_write_public_object(name));
drop policy if exists vc_public_delete on storage.objects;
create policy vc_public_delete on storage.objects for delete to authenticated
  using (bucket_id = 'vc-public' and public.can_write_public_object(name));
-- Reading is public because the bucket is public (no select policy needed for public URLs).

-- ---------------------------------------------------------------------
-- 2. Register / remove a product image
-- ---------------------------------------------------------------------
create or replace function public.register_product_image(
  p_product uuid, p_object_key text, p_mime text, p_size bigint, p_alt text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_file uuid; v_img uuid; v_pos int;
begin
  select organization_id into v_org from public.products where id = p_product and deleted_at is null;
  if v_org is null then raise exception 'product not found'; end if;
  if not (public.owns_product(p_product) or public.has_perm('catalogue')) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_object_key not like 'products/' || v_org::text || '/%' then
    raise exception 'image path does not belong to this product''s organization';
  end if;
  if not exists (select 1 from storage.objects where bucket_id = 'vc-public' and name = p_object_key) then
    raise exception 'file was not uploaded';
  end if;
  select count(*) into v_pos from public.product_images where product_id = p_product;
  if v_pos >= 8 then raise exception 'a product can have at most 8 images'; end if;

  insert into public.files (owner_org_id, uploaded_by, bucket, object_key, mime_type, size_bytes,
                            purpose, visibility, status, uploaded_at)
  values (v_org, auth.uid(), 'vc-public', p_object_key, p_mime, greatest(p_size, 1),
          'product_image', 'public', 'uploaded', now())
  returning id into v_file;
  insert into public.product_images (product_id, file_id, position, alt_text)
  values (p_product, v_file, v_pos, nullif(p_alt, '')) returning id into v_img;
  return v_img;
end $$;

-- Returns the storage key so the browser can delete the file itself.
create or replace function public.remove_product_image(p_image uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_prod uuid; v_file uuid; v_key text;
begin
  select i.product_id, i.file_id, f.object_key into v_prod, v_file, v_key
  from public.product_images i join public.files f on f.id = i.file_id where i.id = p_image;
  if v_prod is null then raise exception 'image not found'; end if;
  if not (public.owns_product(v_prod) or public.has_perm('catalogue')) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  delete from public.product_images where id = p_image;
  delete from public.files where id = v_file;
  -- keep positions contiguous
  update public.product_images pi set position = r.rn
  from (select id, row_number() over (order by position, id) - 1 as rn
        from public.product_images where product_id = v_prod) r
  where pi.id = r.id;
  return v_key;
end $$;

grant execute on function public.register_product_image(uuid, text, text, bigint, text),
                          public.remove_product_image(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Admin can create a product for any manufacturer
-- ---------------------------------------------------------------------
create or replace function public.admin_create_product(
  p_org uuid, p_title text, p_category uuid default null, p_description text default null,
  p_gsm int default null, p_moq int default null, p_lead_days int default null,
  p_sample boolean default false, p_price_paise bigint default null, p_publish boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_slug text;
begin
  if not public.has_perm('catalogue') then raise exception 'admin only' using errcode = '42501'; end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'title is required'; end if;
  if not exists (select 1 from public.organizations where id = p_org and type = 'manufacturer' and deleted_at is null) then
    raise exception 'select a supplier organization';
  end if;
  v_slug := trim(both '-' from regexp_replace(lower(p_title), '[^a-z0-9]+', '-', 'g'))
            || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 4);
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then v_slug := 'product-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8); end if;

  insert into public.products (organization_id, category_id, title, slug, description, gsm, min_moq,
                               lead_time_days, sample_available, status)
  values (p_org, p_category, trim(p_title), v_slug, nullif(p_description, ''), p_gsm, p_moq,
          p_lead_days, coalesce(p_sample, false), case when p_publish then 'approved' else 'draft' end)
  returning id into v_id;

  if p_price_paise is not null and p_moq is not null then
    insert into public.price_tiers (product_id, min_qty, unit_price_paise) values (v_id, p_moq, p_price_paise);
  end if;
  insert into public.audit_logs (actor_profile_id, action, entity_type, entity_id, after)
  values (auth.uid(), 'admin_create_product', 'product', v_id, jsonb_build_object('organization_id', p_org, 'published', p_publish));
  return v_id;
end $$;
grant execute on function public.admin_create_product(uuid, text, uuid, text, int, int, int, boolean, bigint, boolean) to authenticated;
