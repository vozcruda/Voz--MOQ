-- 008: one admin function to create OR edit a full product listing
-- (details + sizes/colours + price tiers). Replaces admin_create_product from 007.
-- Run once in the Supabase SQL editor. Safe to re-run.

drop function if exists public.admin_create_product(uuid, text, uuid, text, int, int, int, boolean, bigint, boolean);

create or replace function public.admin_save_product(
  p_product uuid, p_org uuid, p_title text, p_category uuid, p_material uuid, p_description text,
  p_gsm int, p_fit text, p_moq int, p_lead_days int, p_sample boolean,
  p_variants jsonb default '[]', p_tiers jsonb default '[]', p_publish boolean default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_org uuid; v_slug text; v_new boolean := (p_product is null);
begin
  if not public.has_perm('catalogue') then raise exception 'admin only' using errcode = '42501'; end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'title is required'; end if;
  p_variants := coalesce(p_variants, '[]'::jsonb);
  p_tiers    := coalesce(p_tiers, '[]'::jsonb);

  if v_new then
    if not exists (select 1 from public.organizations where id = p_org and type = 'manufacturer' and deleted_at is null) then
      raise exception 'select a supplier organization';
    end if;
    v_slug := trim(both '-' from regexp_replace(lower(p_title), '[^a-z0-9]+', '-', 'g'))
              || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 4);
    if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then v_slug := 'product-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8); end if;
    insert into public.products (organization_id, category_id, material_id, title, slug, description, gsm, fit,
                                 min_moq, lead_time_days, sample_available, status)
    values (p_org, p_category, p_material, trim(p_title), v_slug, nullif(p_description, ''), p_gsm, nullif(trim(p_fit), ''),
            p_moq, p_lead_days, coalesce(p_sample, false), case when coalesce(p_publish, false) then 'approved' else 'draft' end)
    returning id into v_id;
  else
    select organization_id into v_org from public.products where id = p_product and deleted_at is null;
    if v_org is null then raise exception 'product not found'; end if;
    update public.products
       set title = trim(p_title), category_id = p_category, material_id = p_material,
           description = nullif(p_description, ''), gsm = p_gsm, fit = nullif(trim(p_fit), ''),
           min_moq = p_moq, lead_time_days = p_lead_days, sample_available = coalesce(p_sample, false),
           status = case when p_publish is true and status in ('draft','pending','rejected') then 'approved' else status end
     where id = p_product;
    v_id := p_product;
  end if;

  -- sizes / colours: keep exactly the list sent
  delete from public.product_variants pv where pv.product_id = v_id
    and not exists (select 1 from jsonb_array_elements(p_variants) e
                    where trim(e->>'size') = pv.size and trim(e->>'color') = pv.color);
  insert into public.product_variants (product_id, size, color)
  select v_id, trim(e->>'size'), trim(e->>'color') from jsonb_array_elements(p_variants) e
  where coalesce(trim(e->>'size'), '') <> '' and coalesce(trim(e->>'color'), '') <> ''
  on conflict (product_id, size, color) do update set is_active = true;

  -- price tiers: replace
  delete from public.price_tiers where product_id = v_id;
  insert into public.price_tiers (product_id, min_qty, max_qty, unit_price_paise)
  select v_id, (e->>'min_qty')::int, nullif(e->>'max_qty', '')::int, (e->>'unit_price_paise')::bigint
  from jsonb_array_elements(p_tiers) e;

  insert into public.audit_logs (actor_profile_id, action, entity_type, entity_id, after)
  values (auth.uid(), case when v_new then 'admin_create_product' else 'admin_update_product' end, 'product', v_id,
          jsonb_build_object('title', trim(p_title)));
  return v_id;
end $$;

grant execute on function public.admin_save_product(uuid, uuid, text, uuid, uuid, text, int, text, int, int, boolean, jsonb, jsonb, boolean) to authenticated;
