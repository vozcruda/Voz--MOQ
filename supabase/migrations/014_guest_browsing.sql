-- =====================================================================
-- 014  Guest browsing (no login needed to look around)
-- Run in the Supabase SQL editor (after 013). Safe to run twice.
--
-- Visitors who are not signed in can see open batches (with prices), batch photos
-- and the product catalogue. They never see supplier names or ids.
-- Everything that writes (join, reserve, pay, ask) still needs a signed-in user.
-- =====================================================================

-- 1. The old public views also exposed the supplier's trade name / organisation id to
--    anyone holding the public API key. Signed-in users keep them; anonymous visitors do not.
revoke select on public.open_pools, public.public_products from anon;

-- 2. Guest-safe versions. They do not call any membership function (an anonymous caller may not run
--    those), so they simply show open, public (not buyer-restricted) batches, without supplier identity.
create or replace view public.guest_pools as
  select p.id as pool_id, p.pool_no, p.title, p.spec_snapshot, p.moq_qty, p.target_qty, p.paid_qty,
         greatest(p.moq_qty - p.paid_qty, 0) as remaining_to_moq,
         greatest(p.target_qty - p.paid_qty - p.reserved_qty, 0) as remaining_capacity,
         p.min_commit_qty, p.max_commit_qty, p.deadline_at, p.status,
         mo.verification_level as supplier_level, p.product_id
  from public.moq_pools p join public.organizations mo on mo.id = p.manufacturer_org_id
  where p.status in ('open', 'moq_reached') and p.deadline_at > now() and p.opens_at <= now()
    and p.restricted_buyer_org_id is null and mo.deleted_at is null and mo.suspended_at is null;

create or replace view public.guest_pool_price_tiers as
  select t.pool_id, t.min_total_qty, t.unit_price_paise
  from public.pool_price_tiers t join public.guest_pools g on g.pool_id = t.pool_id;

create or replace view public.guest_pool_images as
  select g.pool_id, i."position", i.alt_text, f.bucket, f.object_key
  from public.guest_pools g
  join public.product_images i on i.product_id = g.product_id
  join public.files f on f.id = i.file_id
  where f.visibility = 'public' and f.status = 'uploaded';

create or replace view public.guest_products as
  select id, verification_level, category_id, category_slug, category_name, material_name, composition, title, slug,
         description, gsm, fit, min_moq, lead_time_days, sample_available, created_at
  from public.public_products;

grant select on public.guest_pools, public.guest_pool_price_tiers, public.guest_pool_images, public.guest_products to anon, authenticated;
-- public_product_images / public_product_variants / categories / materials are unchanged (already public)
