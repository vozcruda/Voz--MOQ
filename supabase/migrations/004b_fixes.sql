-- =====================================================================
-- Voz Cruda | Migration 004b: fixes from review + functions the mockups need
-- Requires 001-004 (v2). STATUS: UNTESTED DRAFT. Run on a scratch project first.
--
-- DECISIONS MADE HERE (change before running if you disagree)
--  * Mockups win over assumption A1: buyers now see the manufacturer NAME on
--    offers and pools, and manufacturers see the RFQ target price and city.
--    Buyer identity stays hidden from manufacturers.
--  * Offer floor assumes customization_cost_paise and packaging_cost_paise
--    are PER UNIT; shipping_estimate_paise is ignored (order-level).
--  * Staff can still accept offers and commit money (not changed).
--  * Product photos stay in the public bucket (update the infra plan).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. OFFER FLOOR: check cost per quantity band, plus per-unit extras
-- ---------------------------------------------------------------------
create or replace function public.admin_publish_offer(
  p_quote uuid, p_valid_until timestamptz, p_tiers jsonb, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_q public.quotes; v_rev public.quote_revisions; t record;
  v_cost bigint; v_extra bigint; v_hi integer;
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  select * into v_q from public.quotes where id = p_quote for update;
  if not found then raise exception 'quote not found'; end if;
  if v_q.status not in ('submitted','offered') then
    raise exception 'quote must be submitted before pricing (current: %)', v_q.status;
  end if;
  if p_valid_until is null or p_valid_until <= now() then
    raise exception 'valid_until must be in the future';
  end if;
  if p_tiers is null or jsonb_typeof(p_tiers) <> 'array' or jsonb_array_length(p_tiers) = 0 then
    raise exception 'provide at least one price tier';
  end if;

  select * into v_rev from public.quote_revisions where id = v_q.current_revision_id;
  v_extra := v_rev.customization_cost_paise + v_rev.packaging_cost_paise;

  for t in select * from jsonb_to_recordset(p_tiers)
             as x(min_qty int, max_qty int, unit_price_paise bigint) loop
    if t.min_qty is null or t.min_qty <= 0 or t.unit_price_paise is null or t.unit_price_paise <= 0 then
      raise exception 'every tier needs min_qty and unit_price_paise';
    end if;
    v_hi := coalesce(t.max_qty, 1000000000);
    -- worst (highest) manufacturer price anywhere inside this band
    select max(c.unit_price_paise) into v_cost
    from public.quote_price_tiers c
    where c.revision_id = v_q.current_revision_id
      and int4range(c.min_qty, coalesce(c.max_qty, 1000000000), '[]')
          && int4range(t.min_qty, v_hi, '[]');
    if v_cost is null then   -- band sits outside every cost band: be conservative
      select max(unit_price_paise) into v_cost
      from public.quote_price_tiers where revision_id = v_q.current_revision_id;
    end if;
    if v_cost is null then raise exception 'the quote has no cost tiers'; end if;
    if t.unit_price_paise < v_cost + v_extra then
      raise exception 'offer price % for quantity % is below cost % (incl. extras %)',
        t.unit_price_paise, t.min_qty, v_cost + v_extra, v_extra;
    end if;
  end loop;

  delete from public.offer_price_tiers where revision_id = v_q.current_revision_id;
  insert into public.offer_price_tiers (revision_id, min_qty, max_qty, unit_price_paise)
  select v_q.current_revision_id, x.min_qty, x.max_qty, x.unit_price_paise
  from jsonb_to_recordset(p_tiers) as x(min_qty int, max_qty int, unit_price_paise bigint);

  update public.quotes set status = 'offered', valid_until = p_valid_until, version = version + 1
  where id = p_quote;
  if v_q.inquiry_id is not null then
    update public.inquiries set status = 'quoted' where id = v_q.inquiry_id and status = 'open';
  end if;

  perform public.log_transition('quote', p_quote, v_q.status, 'offered', p_note);
  perform public.notify_org(v_q.buyer_org_id, 'offer_ready', 'You have a new offer',
    'An offer for your request is ready to review.', 'quote', p_quote,
    'offer:' || p_quote::text || ':' || (v_q.version + 1)::text);
end $$;

-- ---------------------------------------------------------------------
-- 2. DIRECT (PRIVATE) ORDER PATH: an accepted quote becomes a one-buyer pool
-- ---------------------------------------------------------------------
alter table public.moq_pools
  add column if not exists restricted_buyer_org_id uuid references public.organizations(id);

-- pools may only be created for approved, unsuspended manufacturers / approved products
create or replace function public.pools_check_manufacturer()
returns trigger language plpgsql as $$
begin
  if not exists (select 1 from public.organizations o
                 where o.id = new.manufacturer_org_id and o.type = 'manufacturer'
                   and o.verification_status = 'approved'
                   and o.deleted_at is null and o.suspended_at is null) then
    raise exception 'the manufacturer is not approved or is suspended';
  end if;
  if new.product_id is not null and not exists (
       select 1 from public.products p where p.id = new.product_id and p.status = 'approved'
         and p.deleted_at is null) then
    raise exception 'the product is not approved';
  end if;
  return new;
end $$;
drop trigger if exists trg_pools_check_mfr on public.moq_pools;
create trigger trg_pools_check_mfr before insert on public.moq_pools
  for each row execute function public.pools_check_manufacturer();

create or replace function public.admin_create_direct_pool(
  p_quote uuid, p_deadline timestamptz, p_payment_window_minutes integer default 1440)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_q public.quotes; v_qty integer; v_title text; v_pool uuid;
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  select * into v_q from public.quotes where id = p_quote;
  if not found or v_q.status <> 'accepted' then raise exception 'the quote must be accepted first'; end if;
  if v_q.rfq_id is not null then
    select quantity, title into v_qty, v_title from public.rfqs where id = v_q.rfq_id;
  else
    select i.quantity, p.title into v_qty, v_title
    from public.inquiries i join public.products p on p.id = i.product_id where i.id = v_q.inquiry_id;
  end if;
  if v_qty is null then raise exception 'request not found'; end if;

  v_pool := public.admin_create_pool(v_title, jsonb_build_object('title', v_title, 'quantity', v_qty),
    v_qty, v_qty, v_qty, v_qty, p_deadline, p_quote, null, null, null, null,
    p_payment_window_minutes, 0);
  update public.moq_pools set restricted_buyer_org_id = v_q.buyer_org_id where id = v_pool;
  perform public.admin_open_pool(v_pool);
  return v_pool;
end $$;

-- ---------------------------------------------------------------------
-- 3. reserve_commitment: restriction check, inline release of expired
--    reservations, idempotency key scoped to the pool
-- ---------------------------------------------------------------------
create or replace function public.reserve_commitment(
  p_pool uuid, p_buyer_org uuid, p_qty integer, p_items jsonb,
  p_shipping_address uuid, p_billing_address uuid, p_idempotency_key text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_pool public.moq_pools; v_id uuid; v_price bigint;
  v_ship jsonb; v_bill jsonb; v_sum integer;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if not public.email_confirmed() then raise exception 'email not verified' using errcode = '42501'; end if;
  if not public.is_org_member(p_buyer_org) then raise exception 'not allowed' using errcode = '42501'; end if;
  if not exists (select 1 from public.organizations
                 where id = p_buyer_org and type = 'buyer' and deleted_at is null and suspended_at is null) then
    raise exception 'an active buyer account is required';
  end if;

  if p_idempotency_key is not null then
    select id into v_id from public.pool_commitments
    where buyer_org_id = p_buyer_org and idempotency_key = p_idempotency_key and pool_id = p_pool;
    if found then return v_id; end if;
  end if;

  select * into v_pool from public.moq_pools where id = p_pool for update;
  if not found then raise exception 'pool not found'; end if;
  if v_pool.restricted_buyer_org_id is not null and v_pool.restricted_buyer_org_id <> p_buyer_org then
    raise exception 'pool not found';   -- do not reveal private pools
  end if;

  -- free capacity held by lapsed reservations before checking it
  with e as (
    update public.pool_commitments set status = 'expired'
    where pool_id = p_pool and status = 'reserved' and reserved_until < now()
    returning qty)
  update public.moq_pools
    set reserved_qty = reserved_qty - coalesce((select sum(qty) from e), 0)
    where id = p_pool and exists (select 1 from e);
  select * into v_pool from public.moq_pools where id = p_pool;

  if v_pool.status not in ('open','moq_reached') or now() < v_pool.opens_at or now() >= v_pool.deadline_at then
    raise exception 'this pool is not accepting commitments';
  end if;
  if p_qty is null or p_qty < v_pool.min_commit_qty or p_qty > v_pool.max_commit_qty then
    raise exception 'quantity must be between % and %', v_pool.min_commit_qty, v_pool.max_commit_qty;
  end if;
  if v_pool.paid_qty + v_pool.reserved_qty + p_qty > v_pool.target_qty then
    raise exception 'not enough capacity left (remaining %)',
      greatest(v_pool.target_qty - v_pool.paid_qty - v_pool.reserved_qty, 0);
  end if;
  if exists (select 1 from public.pool_commitments
             where pool_id = p_pool and buyer_org_id = p_buyer_org
               and status in ('reserved','paid','fulfilled')) then
    raise exception 'you already have a commitment in this pool';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'provide the size and colour split';
  end if;
  select coalesce(sum(t.qty), 0) into v_sum
    from jsonb_to_recordset(p_items) as t(size text, color text, qty int);
  if v_sum <> p_qty or exists (select 1 from jsonb_to_recordset(p_items) as t(size text, color text, qty int)
       where t.size is null or t.color is null or t.qty is null or t.qty <= 0) then
    raise exception 'the size and colour split must add up to the quantity';
  end if;

  select to_jsonb(a) - 'created_at' - 'updated_at' - 'deleted_at' into v_ship
    from public.addresses a where a.id = p_shipping_address and a.organization_id = p_buyer_org and a.deleted_at is null;
  select to_jsonb(a) - 'created_at' - 'updated_at' - 'deleted_at' into v_bill
    from public.addresses a where a.id = p_billing_address and a.organization_id = p_buyer_org and a.deleted_at is null;
  if v_ship is null or v_bill is null then raise exception 'choose valid shipping and billing addresses'; end if;

  v_price := public.pool_price_at(p_pool, v_pool.moq_qty);
  if v_price is null then raise exception 'pool pricing is not configured'; end if;

  insert into public.pool_commitments (pool_id, buyer_org_id, qty, unit_price_locked_paise,
    amount_due_paise, reserved_until, shipping_address, billing_address, idempotency_key)
  values (p_pool, p_buyer_org, p_qty, v_price, v_price * p_qty,
    least(now() + make_interval(mins => v_pool.payment_window_minutes), v_pool.deadline_at),
    v_ship, v_bill, p_idempotency_key)
  returning id into v_id;

  insert into public.pool_commitment_items (commitment_id, size, color, qty)
  select v_id, t.size, t.color, t.qty from jsonb_to_recordset(p_items) as t(size text, color text, qty int);

  update public.moq_pools set reserved_qty = reserved_qty + p_qty, version = version + 1 where id = p_pool;
  perform public.log_transition('commitment', v_id, null, 'reserved');
  return v_id;
end $$;

-- the job now returns the number of commitments released (was: pools touched)
create or replace function public.release_expired_reservations()
returns integer language plpgsql security definer set search_path = public as $$
declare
  r record; v_n integer := 0; v_rows integer;
begin
  for r in select distinct pool_id from public.pool_commitments
           where status = 'reserved' and reserved_until < now() order by pool_id loop
    perform 1 from public.moq_pools where id = r.pool_id for update;
    with e as (
      update public.pool_commitments set status = 'expired'
      where pool_id = r.pool_id and status = 'reserved' and reserved_until < now()
      returning id, qty),
    p as (
      update public.moq_pools set reserved_qty = reserved_qty - (select sum(qty) from e), version = version + 1
      where id = r.pool_id and exists (select 1 from e) returning 1)
    select count(*) into v_rows from e;
    v_n := v_n + v_rows;
  end loop;
  return v_n;
end $$;

-- ---------------------------------------------------------------------
-- 4. PRIVATE POOLS HIDDEN; NAMES SHOWN (per mockups); NEW VIEW COLUMNS LAST
-- ---------------------------------------------------------------------
create or replace view public.open_pools as
select p.id as pool_id, p.pool_no, p.title, p.spec_snapshot,
       p.moq_qty, p.target_qty, p.paid_qty,
       greatest(p.moq_qty - p.paid_qty, 0) as remaining_to_moq,
       greatest(p.target_qty - p.paid_qty - p.reserved_qty, 0) as remaining_capacity,
       p.min_commit_qty, p.max_commit_qty, p.deadline_at, p.status,
       mo.verification_level as supplier_level,
       coalesce(mo.trade_name, mo.legal_name) as supplier_name
from public.moq_pools p
join public.organizations mo on mo.id = p.manufacturer_org_id
where p.status in ('open','moq_reached') and p.deadline_at > now() and p.opens_at <= now()
  and (p.restricted_buyer_org_id is null or public.is_org_member(p.restricted_buyer_org_id));

create or replace view public.buyer_offers as
select q.id as quote_id, q.quote_no, q.rfq_id, q.inquiry_id, q.status, q.valid_until,
       r.revision_no, r.lead_time_days, r.sample_available,
       mo.verification_level as supplier_level,
       (select jsonb_agg(jsonb_build_object('min_qty', t.min_qty, 'max_qty', t.max_qty,
                'unit_price_paise', t.unit_price_paise) order by t.min_qty)
          from public.offer_price_tiers t where t.revision_id = q.current_revision_id) as price_tiers,
       q.created_at,
       coalesce(mo.trade_name, mo.legal_name) as supplier_name
from public.quotes q
join public.quote_revisions r on r.id = q.current_revision_id
join public.organizations mo on mo.id = q.manufacturer_org_id
where public.is_org_member(q.buyer_org_id)
  and q.status in ('offered','accepted','declined','expired');

-- ---------------------------------------------------------------------
-- 5. MANUFACTURER SIDE: RFQ target/city, decline RFQ, see own pools, ask to extend
-- ---------------------------------------------------------------------
alter table public.rfqs add column if not exists delivery_city text;
grant insert (delivery_city), update (delivery_city) on public.rfqs to authenticated;

create table public.rfq_declines (
  rfq_id              uuid not null references public.rfqs(id) on delete cascade,
  manufacturer_org_id uuid not null references public.organizations(id) on delete cascade,
  reason              text,
  created_at          timestamptz not null default now(),
  primary key (rfq_id, manufacturer_org_id)
);

create or replace function public.my_manufacturer_org()
returns uuid language sql stable security definer set search_path = public as $$
  select m.organization_id
  from public.organization_members m join public.organizations o on o.id = m.organization_id
  where m.profile_id = auth.uid() and public.is_active_user()
    and o.type = 'manufacturer' and o.verification_status = 'approved'
    and o.deleted_at is null and o.suspended_at is null
  order by (m.member_role = 'owner') desc, m.created_at limit 1;
$$;

create or replace view public.manufacturer_rfqs as
select r.id as rfq_id, r.rfq_no, r.title, r.category_id, r.material_id, r.quantity,
       r.gsm_min, r.colors, r.customization_type_ids, r.private_label,
       left(r.delivery_pincode, 3) as region_prefix,
       r.needed_by, r.notes, r.expires_at, r.created_at,
       r.target_unit_price_paise, r.delivery_city
from public.rfqs r
where public.is_approved_manufacturer()
  and r.status = 'open' and r.deleted_at is null and r.expires_at > now()
  and not exists (select 1 from public.rfq_declines d
                  where d.rfq_id = r.id and d.manufacturer_org_id = public.my_manufacturer_org());

create or replace function public.decline_rfq(p_rfq uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_mfr uuid;
begin
  v_mfr := public.my_manufacturer_org();
  if v_mfr is null or not public.email_confirmed() then
    raise exception 'approved manufacturer account required' using errcode = '42501';
  end if;
  if not exists (select 1 from public.rfqs where id = p_rfq and status = 'open' and deleted_at is null) then
    raise exception 'rfq not found';
  end if;
  insert into public.rfq_declines (rfq_id, manufacturer_org_id, reason)
  values (p_rfq, v_mfr, p_reason) on conflict do nothing;
end $$;

create or replace view public.manufacturer_pools as
select p.id as pool_id, p.pool_no, p.title, p.moq_qty, p.target_qty, p.paid_qty, p.reserved_qty,
       p.deadline_at, p.status, p.extension_count, p.max_extensions
from public.moq_pools p
where public.is_org_member(p.manufacturer_org_id) and p.status <> 'draft';

create or replace function public.request_pool_extension(p_pool uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v public.moq_pools;
begin
  select * into v from public.moq_pools where id = p_pool;
  if not found or not public.is_org_member(v.manufacturer_org_id) then
    raise exception 'pool not found' using errcode = '42501';
  end if;
  if v.status <> 'open' then raise exception 'only open pools can be extended'; end if;
  if v.extension_count >= v.max_extensions then raise exception 'no extensions left'; end if;
  perform public.notify_admins('pool_extension_requested', 'Extension requested',
    v.pool_no || ': ' || coalesce(left(p_reason, 200), ''), 'pool', p_pool,
    'pool_ext:' || p_pool::text || ':' || v.extension_count::text);
end $$;

-- ---------------------------------------------------------------------
-- 6. REJECTED / CANCELLED PURCHASE ORDERS: refund path for paid buyers
-- ---------------------------------------------------------------------
create or replace function public.admin_cancel_po(p_po uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v public.purchase_orders;
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'a reason is required'; end if;
  select * into v from public.purchase_orders where id = p_po for update;
  if not found then raise exception 'purchase order not found'; end if;
  if v.status not in ('sent','accepted','rejected') then
    raise exception 'production has started; cancel through a dispute instead (status %)', v.status;
  end if;
  perform 1 from public.moq_pools where id = v.pool_id for update;      -- pool first

  update public.purchase_orders set status = 'cancelled', version = version + 1 where id = p_po;
  update public.orders set status = 'refund_pending', version = version + 1
    where purchase_order_id = p_po and status = 'confirmed';
  update public.pool_commitments set status = 'refund_pending'
    where pool_id = v.pool_id and status = 'paid';
  update public.moq_pools set status = 'cancelled', version = version + 1 where id = v.pool_id;

  perform public.log_transition('purchase_order', p_po, v.status, 'cancelled', p_reason);
  perform public.log_transition('pool', v.pool_id, 'po_placed', 'cancelled', p_reason);

  insert into public.notifications (profile_id, type, title, body, entity_type, entity_id, dedupe_key)
  select m.profile_id, 'order_cancelled', 'Your order was cancelled',
         'Your payment will be refunded.', 'order', o.id,
         'order_cancelled:' || o.id::text || ':' || m.profile_id::text
  from public.orders o join public.organization_members m on m.organization_id = o.buyer_org_id
  where o.purchase_order_id = p_po and o.status = 'refund_pending'
  on conflict (dedupe_key) do nothing;
end $$;

-- ---------------------------------------------------------------------
-- 7. TEAM MEMBERS: invitations instead of silent inserts; owners protected
-- ---------------------------------------------------------------------
create table public.organization_invites (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  email           text not null check (email = lower(trim(email)) and position('@' in email) > 1),
  invited_by      uuid references public.profiles(id) default auth.uid(),
  status          text not null default 'pending' check (status in ('pending','accepted','revoked','expired')),
  expires_at      timestamptz not null default now() + interval '7 days',
  created_at      timestamptz not null default now()
);
create unique index organization_invites_pending_uq
  on public.organization_invites (organization_id, email) where status = 'pending';

drop policy if exists members_insert on public.organization_members;
revoke insert on public.organization_members from authenticated;
drop policy if exists members_delete on public.organization_members;
create policy members_delete on public.organization_members for delete to authenticated
  using (public.is_org_owner(organization_id) and profile_id <> auth.uid() and member_role <> 'owner');

create or replace function public.invite_member(p_org uuid, p_email text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not (public.is_org_owner(p_org) and public.email_confirmed()) then
    raise exception 'owners only' using errcode = '42501';
  end if;
  insert into public.organization_invites (organization_id, email)
  values (p_org, lower(trim(p_email))) returning id into v_id;
  return v_id;
end $$;

create or replace function public.accept_invite(p_invite uuid)
returns void language plpgsql security definer set search_path = public, auth as $$
declare i public.organization_invites; v_email text;
begin
  if auth.uid() is null or not public.email_confirmed() then
    raise exception 'email not verified' using errcode = '42501';
  end if;
  select lower(email) into v_email from auth.users where id = auth.uid();
  select * into i from public.organization_invites where id = p_invite for update;
  if not found or i.status <> 'pending' or i.expires_at < now() or i.email <> v_email then
    raise exception 'invitation not valid' using errcode = '42501';
  end if;
  insert into public.organization_members (organization_id, profile_id, member_role, invited_by)
  values (i.organization_id, auth.uid(), 'staff', i.invited_by) on conflict do nothing;
  update public.organization_invites set status = 'accepted' where id = p_invite;
end $$;

create or replace function public.set_member_role(p_org uuid, p_profile uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_org_owner(p_org) then raise exception 'owners only' using errcode = '42501'; end if;
  if p_role not in ('owner','staff') then raise exception 'invalid role'; end if;
  if p_profile = auth.uid() and p_role <> 'owner' then
    raise exception 'ask another owner to change your role';
  end if;
  update public.organization_members set member_role = p_role
    where organization_id = p_org and profile_id = p_profile;
end $$;

-- ---------------------------------------------------------------------
-- 8. ADMIN DEAD ENDS: slug, suspension, resubmission; trade_name re-verification
-- ---------------------------------------------------------------------
create or replace function public.admin_set_manufacturer_slug(p_org uuid, p_slug text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  if p_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then raise exception 'invalid slug'; end if;
  update public.manufacturer_profiles set slug = p_slug where organization_id = p_org;
  if not found then raise exception 'manufacturer not found'; end if;
end $$;

create or replace function public.admin_set_org_suspension(p_org uuid, p_suspend boolean, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'a reason is required'; end if;
  update public.organizations
    set suspended_at = case when p_suspend then now() end where id = p_org and deleted_at is null;
  if not found then raise exception 'organization not found'; end if;
  perform public.log_transition('organization', p_org,
    case when p_suspend then 'active' else 'suspended' end,
    case when p_suspend then 'suspended' else 'active' end, p_reason);
end $$;

create or replace function public.resubmit_verification(p_org uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_org_owner(p_org) and public.email_confirmed()) then
    raise exception 'owners only' using errcode = '42501';
  end if;
  update public.organizations set verification_status = 'pending'
    where id = p_org and verification_status = 'rejected' and deleted_at is null;
  if not found then raise exception 'only rejected organizations can be resubmitted'; end if;
  perform public.log_transition('organization', p_org, 'rejected', 'pending', 'resubmitted by owner');
end $$;

create or replace function public.organizations_guard()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated','anon') and not public.is_admin()
     and old.verification_status = 'approved'
     and (new.legal_name, new.trade_name, new.gstin, new.pan)
         is distinct from (old.legal_name, old.trade_name, old.gstin, old.pan)
  then
    new.verification_status := 'pending';
    new.verification_level  := 'unverified';
    new.verified_at := null;
    new.verified_by := null;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 9. APPROVED CONTENT: child-table edits reopen review; text edits alert admins
-- ---------------------------------------------------------------------
create or replace function public.product_child_reopen_review()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_pid uuid;
begin
  if auth.uid() is not null and not public.is_admin() then
    v_pid := case when tg_op = 'DELETE' then old.product_id else new.product_id end;
    update public.products set status = 'pending' where id = v_pid and status = 'approved';
    if found then
      perform public.log_transition('product', v_pid, 'approved', 'pending', 'listing details changed');
    end if;
  end if;
  return null;
end $$;

create trigger trg_images_reopen after insert or update or delete on public.product_images
  for each row execute function public.product_child_reopen_review();
create trigger trg_variants_reopen after insert or update or delete on public.product_variants
  for each row execute function public.product_child_reopen_review();
create trigger trg_custom_reopen after insert or update or delete on public.product_customizations
  for each row execute function public.product_child_reopen_review();

create or replace function public.mfr_profile_text_alert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin()
     and (new.about, new.seo_title, new.seo_description)
         is distinct from (old.about, old.seo_title, old.seo_description) then
    perform public.notify_admins('profile_text_changed', 'Manufacturer profile text changed',
      'Review the public profile text.', 'organization', new.organization_id,
      'profile_text:' || new.organization_id::text || ':' || extract(epoch from now())::bigint::text);
  end if;
  return null;
end $$;
create trigger trg_mfr_profile_text after update on public.manufacturer_profiles
  for each row execute function public.mfr_profile_text_alert();

-- ---------------------------------------------------------------------
-- 10. RATE LIMITS (the browser writes RFQs and inquiries directly)
-- ---------------------------------------------------------------------
create or replace function public.rate_limit_guard()
returns trigger language plpgsql as $$
declare v_limit integer := tg_argv[0]::integer; v_n integer;
begin
  if current_user in ('authenticated','anon') then
    execute format('select count(*) from public.%I where created_by = $1 and created_at > now() - interval ''1 day''',
                   tg_table_name) into v_n using auth.uid();
    if v_n >= v_limit then
      raise exception 'daily limit reached (% per day)', v_limit using errcode = '54000';
    end if;
  end if;
  return new;
end $$;
create trigger trg_c_rfqs_ratelimit before insert on public.rfqs
  for each row execute function public.rate_limit_guard('10');
create trigger trg_c_inquiries_ratelimit before insert on public.inquiries
  for each row execute function public.rate_limit_guard('30');

-- ---------------------------------------------------------------------
-- 11. DISPUTES, COUNTER-OFFERS, ADMIN ACTIVITY FEED
-- ---------------------------------------------------------------------
create sequence public.dispute_no_seq start 1001;

create table public.disputes (
  id           uuid primary key default gen_random_uuid(),
  dispute_no   text not null unique
                 default ('DSP-' || lpad(nextval('public.dispute_no_seq')::text, 6, '0')),
  order_id     uuid not null references public.orders(id),
  buyer_org_id uuid not null references public.organizations(id),
  raised_by    uuid references public.profiles(id) default auth.uid(),
  reason       text not null check (length(trim(reason)) between 5 and 2000),
  status       text not null default 'open' check (status in ('open','resolved','rejected')),
  resolution   text,
  resolved_by  uuid references public.profiles(id),
  resolved_at  timestamptz,
  created_at   timestamptz not null default now()
);
create unique index disputes_open_uq on public.disputes (order_id) where status = 'open';

create or replace function public.open_dispute(p_order uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare o public.orders; v_id uuid;
begin
  if auth.uid() is null or not public.email_confirmed() then
    raise exception 'email not verified' using errcode = '42501';
  end if;
  select * into o from public.orders where id = p_order for update;
  if not found or not public.is_org_member(o.buyer_org_id) then
    raise exception 'order not found' using errcode = '42501';
  end if;
  if o.status not in ('shipped','delivered','completed') then
    raise exception 'a dispute can only be raised after shipping';
  end if;
  insert into public.disputes (order_id, buyer_org_id, reason)
  values (p_order, o.buyer_org_id, trim(p_reason)) returning id into v_id;
  update public.orders set status = 'disputed', version = version + 1 where id = p_order;
  perform public.log_transition('order', p_order, o.status, 'disputed', p_reason);
  perform public.notify_admins('dispute_opened', 'Dispute opened', o.order_no, 'order', p_order,
    'dispute:' || v_id::text);
  return v_id;
end $$;

create or replace function public.admin_resolve_dispute(
  p_dispute uuid, p_refund boolean, p_resolution text)
returns void language plpgsql security definer set search_path = public as $$
declare d public.disputes;
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  if nullif(trim(p_resolution), '') is null then raise exception 'a resolution note is required'; end if;
  select * into d from public.disputes where id = p_dispute for update;
  if not found or d.status <> 'open' then raise exception 'dispute is not open'; end if;
  update public.disputes set status = case when p_refund then 'resolved' else 'rejected' end,
    resolution = p_resolution, resolved_by = auth.uid(), resolved_at = now() where id = p_dispute;
  if p_refund then
    update public.orders set status = 'refund_pending', version = version + 1 where id = d.order_id;
    update public.pool_commitments set status = 'refund_pending'
      where order_id = d.order_id and status in ('paid','fulfilled');
    perform public.log_transition('order', d.order_id, 'disputed', 'refund_pending', p_resolution);
  else
    update public.orders set status = 'delivered', version = version + 1 where id = d.order_id;
    perform public.log_transition('order', d.order_id, 'disputed', 'delivered', p_resolution);
  end if;
  perform public.notify_org(d.buyer_org_id, 'dispute_resolved', 'Your dispute was reviewed',
    left(p_resolution, 200), 'order', d.order_id, 'dispute_resolved:' || p_dispute::text);
end $$;

create table public.offer_counters (
  id                      uuid primary key default gen_random_uuid(),
  quote_id                uuid not null references public.quotes(id) on delete cascade,
  buyer_org_id            uuid not null references public.organizations(id),
  target_unit_price_paise bigint check (target_unit_price_paise is null or target_unit_price_paise > 0),
  note                    text check (note is null or length(note) <= 2000),
  created_by              uuid references public.profiles(id) default auth.uid(),
  created_at              timestamptz not null default now()
);

create or replace function public.counter_offer(p_quote uuid, p_target_paise bigint, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare v_q public.quotes; v_id uuid;
begin
  if auth.uid() is null or not public.email_confirmed() then
    raise exception 'email not verified' using errcode = '42501';
  end if;
  select * into v_q from public.quotes where id = p_quote;
  if not found or not public.is_org_member(v_q.buyer_org_id) or v_q.status <> 'offered' then
    raise exception 'offer not found' using errcode = '42501';
  end if;
  insert into public.offer_counters (quote_id, buyer_org_id, target_unit_price_paise, note)
  values (p_quote, v_q.buyer_org_id, p_target_paise, p_note) returning id into v_id;
  perform public.notify_admins('offer_countered', 'Buyer wants to negotiate', v_q.quote_no,
    'quote', p_quote, 'counter:' || v_id::text);
end $$;

create or replace view public.admin_activity as
select st.created_at,
       case when st.actor is null then 'system'
            when exists (select 1 from public.admin_users a where a.profile_id = st.actor) then 'admin'
            else 'user' end as actor_label,
       st.entity_type, st.entity_id, st.from_status, st.to_status, st.reason,
       coalesce(o.trade_name, o.legal_name, p.pool_no, pr.title) as label
from public.state_transitions st
left join public.organizations o on st.entity_type = 'organization' and o.id = st.entity_id
left join public.moq_pools p     on st.entity_type = 'pool'         and p.id = st.entity_id
left join public.products pr     on st.entity_type = 'product'      and pr.id = st.entity_id
where public.is_admin();

-- ---------------------------------------------------------------------
-- 12. RLS AND PRIVILEGES FOR EVERYTHING NEW
-- ---------------------------------------------------------------------
alter table public.rfq_declines         enable row level security;
alter table public.organization_invites enable row level security;
alter table public.disputes             enable row level security;
alter table public.offer_counters       enable row level security;

create policy declines_select on public.rfq_declines for select to authenticated
  using (manufacturer_org_id = public.my_manufacturer_org() or public.is_admin());
create policy invites_select on public.organization_invites for select to authenticated
  using (public.is_org_owner(organization_id) or public.is_admin()
         or email = lower(coalesce(auth.jwt() ->> 'email', '')));
create policy disputes_select on public.disputes for select to authenticated
  using (public.is_org_member(buyer_org_id) or public.is_admin());
create policy counters_select on public.offer_counters for select to authenticated
  using (public.is_org_member(buyer_org_id) or public.is_admin());

revoke all on public.rfq_declines, public.organization_invites, public.disputes,
  public.offer_counters, public.manufacturer_pools, public.admin_activity
  from anon, authenticated;
revoke all on sequence public.dispute_no_seq from anon, authenticated;

grant select on public.rfq_declines, public.organization_invites, public.disputes,
  public.offer_counters, public.manufacturer_pools, public.admin_activity to authenticated;

-- price lookups are internal; clients read prices through views
revoke execute on function public.pool_price_at(uuid, integer) from public, anon, authenticated;

revoke execute on function
  public.pools_check_manufacturer(), public.product_child_reopen_review(),
  public.mfr_profile_text_alert(), public.rate_limit_guard(),
  public.my_manufacturer_org(), public.decline_rfq(uuid, text),
  public.request_pool_extension(uuid, text), public.admin_cancel_po(uuid, text),
  public.admin_create_direct_pool(uuid, timestamptz, integer),
  public.invite_member(uuid, text), public.accept_invite(uuid),
  public.set_member_role(uuid, uuid, text),
  public.admin_set_manufacturer_slug(uuid, text),
  public.admin_set_org_suspension(uuid, boolean, text),
  public.resubmit_verification(uuid),
  public.open_dispute(uuid, text), public.admin_resolve_dispute(uuid, boolean, text),
  public.counter_offer(uuid, bigint, text)
  from public, anon, authenticated;

grant execute on function
  public.my_manufacturer_org(), public.decline_rfq(uuid, text),
  public.request_pool_extension(uuid, text), public.admin_cancel_po(uuid, text),
  public.admin_create_direct_pool(uuid, timestamptz, integer),
  public.invite_member(uuid, text), public.accept_invite(uuid),
  public.set_member_role(uuid, uuid, text),
  public.admin_set_manufacturer_slug(uuid, text),
  public.admin_set_org_suspension(uuid, boolean, text),
  public.resubmit_verification(uuid),
  public.open_dispute(uuid, text), public.admin_resolve_dispute(uuid, boolean, text),
  public.counter_offer(uuid, bigint, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- SMOKE TESTS FOR THIS PATCH
-- 1. admin_publish_offer: cost 340 @100-249, 310 @250+; offering 320 for the
--    100-249 band now fails; customization+packaging extras are added.
-- 2. Accepted RFQ quote -> admin_create_direct_pool: pool shows only for that
--    buyer in open_pools; another buyer's reserve_commitment says "not found".
-- 3. A lapsed reservation no longer blocks the same buyer re-reserving.
-- 4. decline_rfq hides the RFQ from that manufacturer only.
-- 5. Owner cannot delete another owner; invite_member + accept_invite adds
--    'staff' only when the invitee's confirmed email matches.
-- 6. Editing an approved product's images sends it back to pending.
-- 7. admin_cancel_po on a 'rejected' PO puts orders/commitments into
--    refund_pending and cancels the pool.
-- 8. 11th RFQ in 24 hours from one user fails with a limit error.
-- 9. open_dispute only after shipped; admin_resolve_dispute(refund=true)
--    moves the order to refund_pending.
-- =====================================================================
