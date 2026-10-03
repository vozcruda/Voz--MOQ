-- =====================================================================
-- 015  Remove batches and products from the listings
-- Run in the Supabase SQL editor (after 014). Safe to run twice.
--
-- Nothing is ever destroyed: a removed batch / product is hidden from every list,
-- its history (orders, payments, POs, audit trail) stays, and an admin can restore it.
--
--  * Batch   - admin_remove_pool / admin_restore_pool
--              A live batch is cancelled first (buyers who paid are queued for refund,
--              exactly like "Cancel batch"), then hidden. Batches that already have a
--              purchase order cannot be removed - they are real orders in production.
--  * Product - remove_product / admin_restore_product
--              Admin or the owning supplier. Blocked while the product has a live batch
--              (an admin can tick "also cancel its live batches").
-- =====================================================================

alter table public.moq_pools
  add column if not exists removed_at timestamptz,
  add column if not exists removed_by uuid references auth.users(id);

-- ---------- batch ----------
create or replace function public.admin_remove_pool(p_pool uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v public.moq_pools;
begin
  if not public.has_perm('pools') then raise exception 'admin only' using errcode = '42501'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'a reason is required'; end if;
  select * into v from public.moq_pools where id = p_pool for update;
  if not found then raise exception 'batch not found'; end if;
  if v.removed_at is not null then return; end if;
  if v.status = 'po_placed' then
    raise exception 'this batch already has a purchase order, so it cannot be removed. Manage it from Purchase Orders / Orders.';
  end if;

  if v.status in ('draft', 'open', 'moq_reached') then
    perform public.admin_cancel_pool(p_pool, p_reason);     -- refunds / notifies buyers as usual
  end if;

  update public.moq_pools set removed_at = now(), removed_by = auth.uid() where id = p_pool;
  perform public.log_transition('pool', p_pool, 'listed', 'removed', p_reason);
end $$;

create or replace function public.admin_restore_pool(p_pool uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_perm('pools') then raise exception 'admin only' using errcode = '42501'; end if;
  update public.moq_pools set removed_at = null, removed_by = null where id = p_pool and removed_at is not null;
  if not found then raise exception 'batch is not removed'; end if;
  perform public.log_transition('pool', p_pool, 'removed', 'listed', 'restored');
end $$;

-- ---------- product ----------
create or replace function public.remove_product(p_product uuid, p_reason text default null, p_cascade boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  v public.products; v_admin boolean := public.has_perm('catalogue'); v_live integer; r record;
begin
  select * into v from public.products where id = p_product and deleted_at is null for update;
  if not found then raise exception 'product not found'; end if;
  if not (v_admin or (public.my_manufacturer_org() is not null and public.my_manufacturer_org() = v.organization_id)) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_admin and nullif(trim(p_reason), '') is null then raise exception 'a reason is required'; end if;

  select count(*) into v_live from public.moq_pools
   where product_id = p_product and removed_at is null and status in ('draft', 'open', 'moq_reached');
  if v_live > 0 then
    if p_cascade and public.has_perm('pools') then
      for r in select id from public.moq_pools
                where product_id = p_product and removed_at is null and status in ('draft', 'open', 'moq_reached') loop
        perform public.admin_remove_pool(r.id, 'Product removed: ' || coalesce(nullif(trim(p_reason), ''), 'no reason given'));
      end loop;
    else
      raise exception 'This product has % live batch(es). Cancel or remove them first%.', v_live,
        case when v_admin then ' (or tick "also cancel its live batches")' else ', or ask the Smallotz team' end;
    end if;
  end if;

  update public.products set deleted_at = now() where id = p_product;
  perform public.log_transition('product', p_product, v.status, 'removed', p_reason);

  if not v_admin then
    perform public.notify_admins('product_removed', 'A supplier removed a product', v.title,
                                 'product', p_product, 'product_removed:' || p_product::text);
  end if;
end $$;

create or replace function public.admin_restore_product(p_product uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_perm('catalogue') then raise exception 'admin only' using errcode = '42501'; end if;
  update public.products set deleted_at = null where id = p_product and deleted_at is not null;
  if not found then raise exception 'product is not removed'; end if;
  perform public.log_transition('product', p_product, 'removed', 'restored', 'restored');
end $$;

revoke all on function public.admin_remove_pool(uuid, text), public.admin_restore_pool(uuid),
  public.remove_product(uuid, text, boolean), public.admin_restore_product(uuid) from public, anon;
grant execute on function public.admin_remove_pool(uuid, text), public.admin_restore_pool(uuid),
  public.remove_product(uuid, text, boolean), public.admin_restore_product(uuid) to authenticated;
