-- =====================================================================
-- 010  Batch photos + purchase-order details
-- Run in the Supabase SQL editor (after 009). Safe to run twice.
-- =====================================================================

-- 1. Buyers could not see batch photos (or the size/colour options when joining)
--    because the public batch view did not say which product a batch is for.
create or replace view public.open_pools as
 select p.id as pool_id, p.pool_no, p.title, p.spec_snapshot, p.moq_qty, p.target_qty, p.paid_qty,
    greatest((p.moq_qty - p.paid_qty), 0) as remaining_to_moq,
    greatest(((p.target_qty - p.paid_qty) - p.reserved_qty), 0) as remaining_capacity,
    p.min_commit_qty, p.max_commit_qty, p.deadline_at, p.status,
    mo.verification_level as supplier_level,
    coalesce(mo.trade_name, mo.legal_name) as supplier_name,
    p.product_id
   from public.moq_pools p
   join public.organizations mo on mo.id = p.manufacturer_org_id
  where p.status = any (array['open','moq_reached'])
    and p.deadline_at > now() and p.opens_at <= now()
    and (p.restricted_buyer_org_id is null or public.is_org_member(p.restricted_buyer_org_id));

-- 2. Photos for any pool the caller may see (including batches that already went to the factory)
create or replace view public.pool_images as
 select p.id as pool_id, i.product_id, i."position", i.alt_text, f.bucket, f.object_key
   from public.moq_pools p
   join public.product_images i on i.product_id = p.product_id
   join public.files f on f.id = i.file_id
  where f.visibility = 'public' and f.status = 'uploaded'
    and (public.is_admin() or public.is_org_member(p.manufacturer_org_id)
         or (p.status in ('open','moq_reached') and p.opens_at <= now()
             and (p.restricted_buyer_org_id is null or public.is_org_member(p.restricted_buyer_org_id)))
         or exists (select 1 from public.pool_commitments c
                    where c.pool_id = p.id and public.is_org_member(c.buyer_org_id)));
grant select on public.pool_images to authenticated;
