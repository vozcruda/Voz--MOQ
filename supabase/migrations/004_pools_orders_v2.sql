-- =====================================================================
-- Voz Cruda | Migration 004: MOQ pools, commitments, orders
-- Requires 001_foundation_v2, 002_catalogue_v2, 003 v2. STATUS: UNTESTED DRAFT
-- (v2: suspension-aware helpers; duplicate payments handled explicitly).
--
-- HOW MONEY FITS: this migration has no payments table yet (that is 005).
-- The webhook handler (service role) calls mark_commitment_paid() after it
-- has verified a Razorpay signature. Nothing here trusts the browser.
--
-- DECISIONS BUILT IN (placeholders unless you confirm them):
-- D1. A buyer pays the price at the pool's MOQ tier. If the pool ends up in
--     a cheaper tier, the difference is stored as rebate_paise per
--     commitment for 005 to refund.
-- D2. Reaching the MOQ does NOT auto-create the manufacturer order. An
--     admin places it (admin_place_purchase_order), so the pool can keep
--     filling until its capacity or deadline.
-- D3. Reservation window 30 minutes, one deadline extension per pool.
-- D4. Buyers can cancel only UNPAID reservations. Withdrawing a paid
--     commitment is admin-only until cancellation rules are decided.
-- D5. Late or duplicate payments never overfill a pool; they become
--     'refund_pending'.
-- =====================================================================

create sequence public.pool_no_seq  start 1001;
create sequence public.order_no_seq start 1001;
create sequence public.po_no_seq    start 1001;

-- ---------------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------------

create table public.moq_pools (
  id                   uuid primary key default gen_random_uuid(),
  pool_no              text not null unique
                         default ('POOL-' || lpad(nextval('public.pool_no_seq')::text, 6, '0')),
  manufacturer_org_id  uuid not null references public.organizations(id),
  product_id           uuid references public.products(id),
  quote_id             uuid references public.quotes(id),
  title                text not null check (length(trim(title)) > 0),
  spec_snapshot        jsonb not null default '{}'::jsonb,   -- public: never put supplier names here
  moq_qty              integer not null check (moq_qty > 0),
  target_qty           integer not null,                     -- capacity cap
  min_commit_qty       integer not null default 1 check (min_commit_qty > 0),
  max_commit_qty       integer not null,
  opens_at             timestamptz not null default now(),
  deadline_at          timestamptz not null,
  max_extensions       integer not null default 1 check (max_extensions >= 0),
  extension_count      integer not null default 0,
  payment_window_minutes integer not null default 30 check (payment_window_minutes between 5 and 1440),
  status               text not null default 'draft' check (status in
                         ('draft','open','moq_reached','po_placed','cancelled','expired')),
  paid_qty             integer not null default 0 check (paid_qty >= 0),
  reserved_qty         integer not null default 0 check (reserved_qty >= 0),
  version              integer not null default 1,
  created_by           uuid references public.profiles(id) default auth.uid(),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  check (target_qty >= moq_qty),
  check (max_commit_qty >= min_commit_qty),
  check (deadline_at > opens_at),
  check (extension_count <= max_extensions),
  check (paid_qty + reserved_qty <= target_qty)
);
create index moq_pools_status_idx on public.moq_pools (status, deadline_at);

-- What buyers pay (thresholds by total pool quantity).
create table public.pool_price_tiers (
  pool_id          uuid not null references public.moq_pools(id) on delete cascade,
  min_total_qty    integer not null check (min_total_qty > 0),
  unit_price_paise bigint not null check (unit_price_paise > 0),
  primary key (pool_id, min_total_qty)
);

-- What Voz Cruda pays the manufacturer. Admin only.
create table public.pool_cost_tiers (
  pool_id          uuid not null references public.moq_pools(id) on delete cascade,
  min_total_qty    integer not null check (min_total_qty > 0),
  unit_price_paise bigint not null check (unit_price_paise > 0),
  primary key (pool_id, min_total_qty)
);

create table public.purchase_orders (
  id                  uuid primary key default gen_random_uuid(),
  po_no               text not null unique
                        default ('PO-' || lpad(nextval('public.po_no_seq')::text, 6, '0')),
  pool_id             uuid not null unique references public.moq_pools(id),   -- one PO per pool
  manufacturer_org_id uuid not null references public.organizations(id),
  status              text not null default 'sent' check (status in
                        ('draft','sent','accepted','rejected','in_production','ready',
                         'shipped_to_voz','received','closed','cancelled','claim_open')),
  spec_snapshot       jsonb not null default '{}'::jsonb,
  total_qty           integer not null check (total_qty > 0),
  unit_cost_paise     bigint not null check (unit_cost_paise > 0),
  total_cost_paise    bigint not null check (total_cost_paise > 0),
  expected_ready_date date,
  version             integer not null default 1,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index purchase_orders_mfr_idx on public.purchase_orders (manufacturer_org_id, status);

create table public.purchase_order_items (
  id                uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  size              text not null,
  color             text not null,
  qty               integer not null check (qty > 0),
  unit_cost_paise   bigint not null check (unit_cost_paise > 0),
  unique (purchase_order_id, size, color)
);

create table public.orders (
  id                 uuid primary key default gen_random_uuid(),
  order_no           text not null unique
                       default ('ORD-' || lpad(nextval('public.order_no_seq')::text, 6, '0')),
  pool_id            uuid not null references public.moq_pools(id),
  commitment_id      uuid not null unique,      -- FK added below
  buyer_org_id       uuid not null references public.organizations(id),
  purchase_order_id  uuid not null references public.purchase_orders(id),
  status             text not null default 'confirmed' check (status in
                       ('confirmed','in_production','qc_passed','ready_to_ship','shipped',
                        'delivered','completed','cancelled','refund_pending','refunded','disputed')),
  billing_address    jsonb not null,
  shipping_address   jsonb not null,
  subtotal_paise     bigint not null check (subtotal_paise >= 0),
  tax_total_paise    bigint not null default 0,   -- GST arrives in 005
  platform_fee_paise bigint not null default 0,
  total_paise        bigint not null check (total_paise >= 0),
  expected_ship_date date,
  version            integer not null default 1,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index orders_buyer_idx on public.orders (buyer_org_id, status);
create index orders_pool_idx  on public.orders (pool_id);

create table public.order_items (
  id                   uuid primary key default gen_random_uuid(),
  order_id             uuid not null references public.orders(id) on delete cascade,
  description_snapshot text not null,
  size                 text not null,
  color                text not null,
  qty                  integer not null check (qty > 0),
  unit_price_paise     bigint not null check (unit_price_paise > 0),
  hsn_code             text,
  tax_rate_bp          integer,
  tax_paise            bigint not null default 0
);
create index order_items_order_idx on public.order_items (order_id);

create table public.pool_commitments (
  id                    uuid primary key default gen_random_uuid(),
  pool_id               uuid not null references public.moq_pools(id),
  buyer_org_id          uuid not null references public.organizations(id),
  created_by            uuid references public.profiles(id) default auth.uid(),
  qty                   integer not null check (qty > 0),
  unit_price_locked_paise bigint not null check (unit_price_locked_paise > 0),
  amount_due_paise      bigint not null check (amount_due_paise > 0),
  status                text not null default 'reserved' check (status in
                          ('reserved','paid','fulfilled','cancelled','expired','refund_pending','refunded')),
  reserved_until        timestamptz not null,
  paid_at               timestamptz,
  payment_ref           text,     -- provider payment id; 005 replaces this with a payments FK
  shipping_address      jsonb not null,
  billing_address       jsonb not null,
  final_unit_price_paise bigint,
  rebate_paise          bigint check (rebate_paise is null or rebate_paise >= 0),
  order_id              uuid references public.orders(id),
  idempotency_key       text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create unique index pool_commitments_active_uq on public.pool_commitments (pool_id, buyer_org_id)
  where status in ('reserved','paid','fulfilled');
create unique index pool_commitments_idem_uq on public.pool_commitments (buyer_org_id, idempotency_key)
  where idempotency_key is not null;
create unique index pool_commitments_payref_uq on public.pool_commitments (payment_ref)
  where payment_ref is not null;
create index pool_commitments_pool_idx  on public.pool_commitments (pool_id, status);
create index pool_commitments_buyer_idx on public.pool_commitments (buyer_org_id);
create index pool_commitments_expiry_idx on public.pool_commitments (reserved_until) where status = 'reserved';

alter table public.orders
  add constraint orders_commitment_fk foreign key (commitment_id)
  references public.pool_commitments(id) deferrable initially deferred;

create table public.pool_commitment_items (
  id            uuid primary key default gen_random_uuid(),
  commitment_id uuid not null references public.pool_commitments(id) on delete cascade,
  size          text not null,
  color         text not null,
  qty           integer not null check (qty > 0),
  unique (commitment_id, size, color)
);

-- ---------------------------------------------------------------------
-- 2. HELPERS
-- ---------------------------------------------------------------------

create or replace function public.pool_price_at(p_pool uuid, p_qty integer)
returns bigint language sql stable security definer set search_path = public as $$
  select unit_price_paise from public.pool_price_tiers
  where pool_id = p_pool and min_total_qty <= p_qty
  order by min_total_qty desc limit 1;
$$;

create or replace function public.pool_cost_at(p_pool uuid, p_qty integer)
returns bigint language sql stable security definer set search_path = public as $$
  select unit_price_paise from public.pool_cost_tiers
  where pool_id = p_pool and min_total_qty <= p_qty
  order by min_total_qty desc limit 1;
$$;

create or replace function public.owns_commitment(p_commitment uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_active_user() and exists (select 1 from public.pool_commitments c
    join public.organization_members m on m.organization_id = c.buyer_org_id
    where c.id = p_commitment and m.profile_id = auth.uid());
$$;

create or replace function public.owns_order(p_order uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_active_user() and exists (select 1 from public.orders o
    join public.organization_members m on m.organization_id = o.buyer_org_id
    where o.id = p_order and m.profile_id = auth.uid());
$$;

create or replace function public.owns_po(p_po uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_active_user() and exists (select 1 from public.purchase_orders p
    join public.organization_members m on m.organization_id = p.manufacturer_org_id
    where p.id = p_po and m.profile_id = auth.uid());
$$;

-- ---------------------------------------------------------------------
-- 3. TRIGGERS
-- ---------------------------------------------------------------------

create trigger trg_pools_updated       before update on public.moq_pools
  for each row execute function public.set_updated_at();
create trigger trg_commitments_updated before update on public.pool_commitments
  for each row execute function public.set_updated_at();
create trigger trg_orders_updated      before update on public.orders
  for each row execute function public.set_updated_at();
create trigger trg_po_updated          before update on public.purchase_orders
  for each row execute function public.set_updated_at();

create trigger trg_audit_pools         after insert or update or delete on public.moq_pools
  for each row execute function public.audit_row_change();
create trigger trg_audit_commitments   after insert or update or delete on public.pool_commitments
  for each row execute function public.audit_row_change();
create trigger trg_audit_orders        after insert or update or delete on public.orders
  for each row execute function public.audit_row_change();
create trigger trg_audit_po            after insert or update or delete on public.purchase_orders
  for each row execute function public.audit_row_change();

-- Direct client writes to these tables are impossible (no grants); this is
-- a second lock in case a grant is added by mistake later.
create or replace function public.block_client_writes()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated','anon') then
    raise exception 'use the provided functions to change %', tg_table_name using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;

create trigger trg_lock_pools       before insert or update or delete on public.moq_pools
  for each row execute function public.block_client_writes();
create trigger trg_lock_commitments before insert or update or delete on public.pool_commitments
  for each row execute function public.block_client_writes();
create trigger trg_lock_orders      before insert or update or delete on public.orders
  for each row execute function public.block_client_writes();
create trigger trg_lock_po          before insert or update or delete on public.purchase_orders
  for each row execute function public.block_client_writes();

-- ---------------------------------------------------------------------
-- 4. PUBLIC / BUYER VIEWS (supplier identity hidden, per A1 in 003)
-- ---------------------------------------------------------------------

create or replace view public.open_pools as
select p.id as pool_id, p.pool_no, p.title, p.spec_snapshot,
       p.moq_qty, p.target_qty, p.paid_qty,
       greatest(p.moq_qty - p.paid_qty, 0) as remaining_to_moq,
       greatest(p.target_qty - p.paid_qty - p.reserved_qty, 0) as remaining_capacity,
       p.min_commit_qty, p.max_commit_qty, p.deadline_at, p.status,
       mo.verification_level as supplier_level
from public.moq_pools p
join public.organizations mo on mo.id = p.manufacturer_org_id
where p.status in ('open','moq_reached') and p.deadline_at > now() and p.opens_at <= now();

create or replace view public.open_pool_price_tiers as
select t.pool_id, t.min_total_qty, t.unit_price_paise
from public.pool_price_tiers t
join public.open_pools op on op.pool_id = t.pool_id;

-- ---------------------------------------------------------------------
-- 5. ADMIN: CREATE, OPEN, EXTEND, CANCEL A POOL
-- ---------------------------------------------------------------------
-- Tier JSON format: [{"min_total_qty":250,"unit_price_paise":31000}, ...]
-- If p_quote is given and tiers are omitted, tiers are copied from that
-- accepted quote (offer prices become buyer prices; quote prices become cost).

create or replace function public.admin_create_pool(
  p_title text, p_spec jsonb, p_moq integer, p_target integer,
  p_min_commit integer, p_max_commit integer, p_deadline timestamptz,
  p_quote uuid default null, p_product uuid default null,
  p_price_tiers jsonb default null, p_cost_tiers jsonb default null,
  p_opens_at timestamptz default null,
  p_payment_window_minutes integer default 30, p_max_extensions integer default 1)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_pool uuid; v_mfr uuid; v_rev uuid; v_q public.quotes; v_prod_id uuid;
  v_price jsonb := p_price_tiers; v_cost jsonb := p_cost_tiers; v_bad boolean; r record;
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  if (p_quote is null) = (p_product is null) then
    raise exception 'provide exactly one of quote or product';
  end if;

  if p_quote is not null then
    select * into v_q from public.quotes where id = p_quote;
    if not found or v_q.status <> 'accepted' then
      raise exception 'the quote must be accepted first';
    end if;
    v_mfr := v_q.manufacturer_org_id; v_rev := v_q.current_revision_id;
    if v_price is null then
      select jsonb_agg(jsonb_build_object('min_total_qty', min_qty, 'unit_price_paise', unit_price_paise))
        into v_price from public.offer_price_tiers where revision_id = v_rev;
    end if;
    if v_cost is null then
      select jsonb_agg(jsonb_build_object('min_total_qty', min_qty, 'unit_price_paise', unit_price_paise))
        into v_cost from public.quote_price_tiers where revision_id = v_rev;
    end if;
  else
    select organization_id into v_mfr from public.products where id = p_product and deleted_at is null;
    if v_mfr is null then raise exception 'product not found'; end if;
    v_prod_id := p_product;
  end if;

  if v_price is null or v_cost is null then raise exception 'price and cost tiers are required'; end if;

  insert into public.moq_pools (manufacturer_org_id, product_id, quote_id, title, spec_snapshot,
    moq_qty, target_qty, min_commit_qty, max_commit_qty, opens_at, deadline_at,
    payment_window_minutes, max_extensions)
  values (v_mfr, v_prod_id, p_quote, p_title, coalesce(p_spec, '{}'::jsonb), p_moq, p_target,
    p_min_commit, p_max_commit, coalesce(p_opens_at, now()), p_deadline,
    p_payment_window_minutes, p_max_extensions)
  returning id into v_pool;

  insert into public.pool_price_tiers (pool_id, min_total_qty, unit_price_paise)
  select v_pool, t.min_total_qty, t.unit_price_paise
  from jsonb_to_recordset(v_price) as t(min_total_qty int, unit_price_paise bigint);
  insert into public.pool_cost_tiers (pool_id, min_total_qty, unit_price_paise)
  select v_pool, t.min_total_qty, t.unit_price_paise
  from jsonb_to_recordset(v_cost) as t(min_total_qty int, unit_price_paise bigint);

  -- prices must not rise as the pool grows
  select exists (select 1 from public.pool_price_tiers a join public.pool_price_tiers b
                 on b.pool_id = a.pool_id and b.min_total_qty > a.min_total_qty
                 and b.unit_price_paise > a.unit_price_paise where a.pool_id = v_pool) into v_bad;
  if v_bad then raise exception 'buyer prices must not increase with quantity'; end if;

  -- from the MOQ upward, the buyer price must exist and cover the cost
  for r in
    select distinct q from (
      select p_moq as q
      union select min_total_qty from public.pool_price_tiers where pool_id = v_pool and min_total_qty >= p_moq
      union select min_total_qty from public.pool_cost_tiers  where pool_id = v_pool and min_total_qty >= p_moq
    ) s order by q
  loop
    if public.pool_price_at(v_pool, r.q) is null or public.pool_cost_at(v_pool, r.q) is null
       or public.pool_price_at(v_pool, r.q) < public.pool_cost_at(v_pool, r.q) then
      raise exception 'at quantity % the price is missing or below cost', r.q;
    end if;
  end loop;

  perform public.log_transition('pool', v_pool, null, 'draft');
  return v_pool;
end $$;

create or replace function public.admin_open_pool(p_pool uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v public.moq_pools;
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  select * into v from public.moq_pools where id = p_pool for update;
  if not found then raise exception 'pool not found'; end if;
  if v.status <> 'draft' then raise exception 'only draft pools can be opened'; end if;
  if v.deadline_at <= now() then raise exception 'deadline is in the past'; end if;
  update public.moq_pools set status = 'open', version = version + 1 where id = p_pool;
  perform public.log_transition('pool', p_pool, 'draft', 'open');
end $$;

create or replace function public.admin_extend_pool(p_pool uuid, p_new_deadline timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare v public.moq_pools;
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  select * into v from public.moq_pools where id = p_pool for update;
  if not found then raise exception 'pool not found'; end if;
  if v.status <> 'open' then raise exception 'only open pools can be extended'; end if;
  if v.extension_count >= v.max_extensions then raise exception 'no extensions left'; end if;
  if p_new_deadline <= v.deadline_at then raise exception 'new deadline must be later'; end if;
  update public.moq_pools set deadline_at = p_new_deadline,
    extension_count = extension_count + 1, version = version + 1 where id = p_pool;
  perform public.log_transition('pool', p_pool, 'open', 'open', 'deadline extended');
end $$;

create or replace function public.admin_cancel_pool(p_pool uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v public.moq_pools;
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'a reason is required'; end if;
  select * into v from public.moq_pools where id = p_pool for update;
  if not found then raise exception 'pool not found'; end if;
  if v.status not in ('draft','open','moq_reached') then
    raise exception 'this pool can no longer be cancelled (current: %)', v.status;
  end if;

  update public.pool_commitments set status = 'refund_pending'
    where pool_id = p_pool and status = 'paid';
  update public.pool_commitments set status = 'cancelled'
    where pool_id = p_pool and status = 'reserved';
  update public.moq_pools set status = 'cancelled', reserved_qty = 0, version = version + 1
    where id = p_pool;
  perform public.log_transition('pool', p_pool, v.status, 'cancelled', p_reason);

  insert into public.notifications (profile_id, type, title, body, entity_type, entity_id, dedupe_key)
  select m.profile_id, 'pool_cancelled', 'A pool you joined was cancelled',
         'Any payment made will be refunded.', 'pool', p_pool, 'pool_cancelled:' || p_pool::text || ':' || m.profile_id::text
  from public.pool_commitments c join public.organization_members m on m.organization_id = c.buyer_org_id
  where c.pool_id = p_pool and c.status in ('refund_pending','cancelled')
  on conflict (dedupe_key) do nothing;
end $$;

-- ---------------------------------------------------------------------
-- 6. BUYER: RESERVE AND CANCEL (the concurrency-critical part)
-- ---------------------------------------------------------------------
-- Every capacity change locks the pool row first. Lock order everywhere:
-- pool row, then commitment row. This prevents deadlocks and overfilling.
-- p_items example: [{"size":"M","color":"Black","qty":60},{"size":"L","color":"Black","qty":40}]

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
    where buyer_org_id = p_buyer_org and idempotency_key = p_idempotency_key;
    if found then return v_id; end if;
  end if;

  select * into v_pool from public.moq_pools where id = p_pool for update;
  if not found then raise exception 'pool not found'; end if;
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
  select v_id, t.size, t.color, t.qty
  from jsonb_to_recordset(p_items) as t(size text, color text, qty int);

  update public.moq_pools set reserved_qty = reserved_qty + p_qty, version = version + 1 where id = p_pool;
  perform public.log_transition('commitment', v_id, null, 'reserved');
  return v_id;
end $$;

create or replace function public.cancel_reservation(p_commitment uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_pool uuid; v_c public.pool_commitments;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  select pool_id into v_pool from public.pool_commitments where id = p_commitment;
  if v_pool is null then raise exception 'commitment not found'; end if;
  perform 1 from public.moq_pools where id = v_pool for update;               -- pool first
  select * into v_c from public.pool_commitments where id = p_commitment for update;
  if not public.is_org_member(v_c.buyer_org_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  if v_c.status <> 'reserved' then
    raise exception 'only unpaid reservations can be cancelled here';
  end if;
  update public.pool_commitments set status = 'cancelled' where id = p_commitment;
  update public.moq_pools set reserved_qty = reserved_qty - v_c.qty, version = version + 1 where id = v_pool;
  perform public.log_transition('commitment', p_commitment, 'reserved', 'cancelled');
end $$;

-- ---------------------------------------------------------------------
-- 7. PAYMENT HOOK (service role only; call after webhook verification)
-- ---------------------------------------------------------------------
-- Idempotent: the same payment reference can be applied any number of times.
-- Returns 'paid', 'already_paid', 'refund_pending' (late payment) or
-- 'duplicate_payment' (a second, different payment on a settled commitment).

create or replace function public.mark_commitment_paid(
  p_commitment uuid, p_payment_ref text, p_amount_paise bigint)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_pool_id uuid; v_pool public.moq_pools; v_c public.pool_commitments;
begin
  if nullif(trim(p_payment_ref), '') is null then raise exception 'payment reference required'; end if;
  select pool_id into v_pool_id from public.pool_commitments where id = p_commitment;
  if v_pool_id is null then raise exception 'commitment not found'; end if;

  select * into v_pool from public.moq_pools where id = v_pool_id for update;          -- pool first
  select * into v_c from public.pool_commitments where id = p_commitment for update;

  if v_c.status in ('paid','fulfilled') and v_c.payment_ref = p_payment_ref then
    return 'already_paid';
  end if;
  if p_amount_paise is distinct from v_c.amount_due_paise then
    raise exception 'amount mismatch: expected %, got %', v_c.amount_due_paise, p_amount_paise;
  end if;

  if v_c.status = 'reserved' and v_pool.status in ('open','moq_reached') then
    update public.pool_commitments
      set status = 'paid', paid_at = now(), payment_ref = p_payment_ref where id = p_commitment;
    update public.moq_pools
      set reserved_qty = reserved_qty - v_c.qty, paid_qty = paid_qty + v_c.qty, version = version + 1
      where id = v_pool_id;
    perform public.log_transition('commitment', p_commitment, 'reserved', 'paid');

    if v_pool.status = 'open' and v_pool.paid_qty + v_c.qty >= v_pool.moq_qty then
      update public.moq_pools set status = 'moq_reached' where id = v_pool_id;
      perform public.log_transition('pool', v_pool_id, 'open', 'moq_reached');
      perform public.notify_admins('pool_moq_reached', 'MOQ reached',
        v_pool.pool_no || ' has reached its MOQ', 'pool', v_pool_id, 'moq_reached:' || v_pool_id::text);
    end if;
    return 'paid';
  end if;

  -- Late payment (reservation expired or cancelled, or pool closed): never
  -- count it. Keep the reference so 005 can refund it.
  if v_c.status in ('reserved','expired','cancelled') then
    update public.pool_commitments
      set status = 'refund_pending', payment_ref = p_payment_ref, paid_at = now()
      where id = p_commitment;
    perform public.log_transition('commitment', p_commitment, v_c.status, 'refund_pending', 'late or invalid payment');
    return 'refund_pending';
  end if;

  -- A different payment on a commitment that is already settled (paid,
  -- refund_pending, refunded ...). Leave the commitment untouched; 005 tracks
  -- and refunds the extra payment under its own reference.
  perform public.log_transition('commitment', p_commitment, v_c.status, v_c.status,
    'extra payment received: ' || p_payment_ref);
  return 'duplicate_payment';
end $$;

-- Admin removes a commitment (paid ones go to refund_pending).
create or replace function public.admin_cancel_commitment(p_commitment uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_pool_id uuid; v_pool public.moq_pools; v_c public.pool_commitments;
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'a reason is required'; end if;
  select pool_id into v_pool_id from public.pool_commitments where id = p_commitment;
  if v_pool_id is null then raise exception 'commitment not found'; end if;
  select * into v_pool from public.moq_pools where id = v_pool_id for update;
  select * into v_c from public.pool_commitments where id = p_commitment for update;

  if v_c.status = 'reserved' then
    update public.pool_commitments set status = 'cancelled' where id = p_commitment;
    update public.moq_pools set reserved_qty = reserved_qty - v_c.qty, version = version + 1 where id = v_pool_id;
    perform public.log_transition('commitment', p_commitment, 'reserved', 'cancelled', p_reason);
  elsif v_c.status = 'paid' and v_pool.status in ('open','moq_reached') then
    update public.pool_commitments set status = 'refund_pending' where id = p_commitment;
    update public.moq_pools set paid_qty = paid_qty - v_c.qty, version = version + 1 where id = v_pool_id;
    if v_pool.status = 'moq_reached' and v_pool.paid_qty - v_c.qty < v_pool.moq_qty then
      update public.moq_pools set status = 'open' where id = v_pool_id;
      perform public.log_transition('pool', v_pool_id, 'moq_reached', 'open', 'MOQ lost after cancellation');
    end if;
    perform public.log_transition('commitment', p_commitment, 'paid', 'refund_pending', p_reason);
  else
    raise exception 'this commitment cannot be cancelled (status %, pool %)', v_c.status, v_pool.status;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 8. PLACE THE SINGLE MANUFACTURER ORDER
-- ---------------------------------------------------------------------

create or replace function public.admin_place_purchase_order(
  p_pool uuid, p_expected_ready date default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_pool public.moq_pools; v_qty integer; v_cost bigint; v_final bigint;
  v_po uuid; v_order uuid; r public.pool_commitments;
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  select * into v_pool from public.moq_pools where id = p_pool for update;
  if not found then raise exception 'pool not found'; end if;
  if v_pool.status <> 'moq_reached' then
    raise exception 'the pool must have reached its MOQ (current: %)', v_pool.status;
  end if;

  -- unpaid reservations are dropped so nothing can pay after this point
  update public.pool_commitments set status = 'expired'
    where pool_id = p_pool and status = 'reserved';

  v_qty   := v_pool.paid_qty;
  v_cost  := public.pool_cost_at(p_pool, v_qty);
  v_final := public.pool_price_at(p_pool, v_qty);
  if v_cost is null or v_final is null then raise exception 'pool pricing is incomplete'; end if;

  insert into public.purchase_orders (pool_id, manufacturer_org_id, spec_snapshot, total_qty,
    unit_cost_paise, total_cost_paise, expected_ready_date)
  values (p_pool, v_pool.manufacturer_org_id, v_pool.spec_snapshot, v_qty, v_cost, v_cost * v_qty,
    p_expected_ready)
  returning id into v_po;

  insert into public.purchase_order_items (purchase_order_id, size, color, qty, unit_cost_paise)
  select v_po, i.size, i.color, sum(i.qty), v_cost
  from public.pool_commitment_items i
  join public.pool_commitments c on c.id = i.commitment_id
  where c.pool_id = p_pool and c.status = 'paid'
  group by i.size, i.color;

  for r in select * from public.pool_commitments
           where pool_id = p_pool and status = 'paid' order by created_at loop
    insert into public.orders (pool_id, commitment_id, buyer_org_id, purchase_order_id,
      billing_address, shipping_address, subtotal_paise, total_paise)
    values (p_pool, r.id, r.buyer_org_id, v_po, r.billing_address, r.shipping_address,
      v_final * r.qty, v_final * r.qty)
    returning id into v_order;

    insert into public.order_items (order_id, description_snapshot, size, color, qty, unit_price_paise)
    select v_order, v_pool.title, i.size, i.color, i.qty, v_final
    from public.pool_commitment_items i where i.commitment_id = r.id;

    update public.pool_commitments
      set order_id = v_order, final_unit_price_paise = v_final,
          rebate_paise = greatest(r.unit_price_locked_paise - v_final, 0) * r.qty
      where id = r.id;

    perform public.log_transition('order', v_order, null, 'confirmed');
    perform public.notify_org(r.buyer_org_id, 'order_confirmed', 'Your order is confirmed',
      'The pool reached its target and your order has been placed.', 'order', v_order,
      'order_confirmed:' || v_order::text);
  end loop;

  update public.moq_pools set status = 'po_placed', reserved_qty = 0, version = version + 1
    where id = p_pool;
  perform public.log_transition('pool', p_pool, 'moq_reached', 'po_placed');
  perform public.log_transition('purchase_order', v_po, null, 'sent');
  perform public.notify_org(v_pool.manufacturer_org_id, 'po_received', 'New purchase order',
    'You have received a new purchase order.', 'purchase_order', v_po, 'po_received:' || v_po::text);
  return v_po;
end $$;

-- ---------------------------------------------------------------------
-- 9. PURCHASE ORDER AND ORDER STATUS
-- ---------------------------------------------------------------------

create or replace function public.update_po_status(p_po uuid, p_to text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v public.purchase_orders; v_admin boolean := public.is_admin(); v_mfr boolean; v_ok boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  select * into v from public.purchase_orders where id = p_po for update;
  if not found then raise exception 'purchase order not found'; end if;
  v_mfr := public.is_org_member(v.manufacturer_org_id);
  if not (v_admin or v_mfr) then raise exception 'not allowed' using errcode = '42501'; end if;

  v_ok := (v_mfr or v_admin) and (
       (v.status = 'sent'          and p_to in ('accepted','rejected'))
    or (v.status = 'accepted'      and p_to = 'in_production')
    or (v.status = 'in_production' and p_to = 'ready'));
  if not v_ok and v_admin then
    v_ok := (v.status = 'ready'          and p_to = 'shipped_to_voz')
         or (v.status = 'shipped_to_voz' and p_to = 'received')
         or (v.status = 'received'       and p_to in ('closed','claim_open'))
         or (v.status = 'claim_open'     and p_to = 'closed');
  end if;
  if not v_ok then raise exception 'purchase order cannot move from % to %', v.status, p_to; end if;

  update public.purchase_orders set status = p_to, version = version + 1 where id = p_po;
  perform public.log_transition('purchase_order', p_po, v.status, p_to, p_note);

  if p_to = 'in_production' then
    update public.orders set status = 'in_production', version = version + 1
      where purchase_order_id = p_po and status = 'confirmed';
  end if;
  if p_to = 'rejected' then
    perform public.notify_admins('po_rejected', 'Purchase order rejected',
      v.po_no || ' was rejected by the manufacturer', 'purchase_order', p_po, 'po_rejected:' || p_po::text);
  elsif v_mfr and not v_admin then
    perform public.notify_admins('po_update', 'Purchase order update',
      v.po_no || ' is now ' || p_to, 'purchase_order', p_po, 'po_update:' || p_po::text || ':' || p_to);
  end if;
end $$;

create or replace function public.admin_set_order_status(p_order uuid, p_to text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v public.orders; v_ok boolean;
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  select * into v from public.orders where id = p_order for update;
  if not found then raise exception 'order not found'; end if;
  v_ok := (v.status = 'confirmed'     and p_to = 'in_production')
       or (v.status = 'in_production' and p_to = 'qc_passed')
       or (v.status = 'qc_passed'     and p_to = 'ready_to_ship')
       or (v.status = 'ready_to_ship' and p_to = 'shipped')
       or (v.status = 'shipped'       and p_to = 'delivered')
       or (v.status = 'delivered'     and p_to = 'completed')
       or (v.status in ('shipped','delivered','completed') and p_to = 'disputed');
  if not v_ok then raise exception 'order cannot move from % to %', v.status, p_to; end if;
  update public.orders set status = p_to, version = version + 1 where id = p_order;
  perform public.log_transition('order', p_order, v.status, p_to, p_note);
  if p_to in ('shipped','delivered') then
    perform public.notify_org(v.buyer_org_id, 'order_' || p_to, 'Order ' || p_to,
      v.order_no || ' is ' || p_to, 'order', p_order, 'order_' || p_to || ':' || p_order::text);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 10. SCHEDULED JOBS (service role; safe to run repeatedly)
-- ---------------------------------------------------------------------

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
      returning id, qty)
    update public.moq_pools p
      set reserved_qty = p.reserved_qty - coalesce((select sum(qty) from e), 0), version = version + 1
      where p.id = r.pool_id and exists (select 1 from e);
    get diagnostics v_rows = row_count;
    v_n := v_n + v_rows;
  end loop;
  return v_n;
end $$;

create or replace function public.close_due_pools()
returns integer language plpgsql security definer set search_path = public as $$
declare
  r record; v public.moq_pools; v_n integer := 0;
begin
  for r in select id from public.moq_pools
           where deadline_at < now() and status in ('open','moq_reached') order by id loop
    select * into v from public.moq_pools where id = r.id for update;
    if v.status = 'open' then                       -- MOQ missed: unwind everything
      update public.pool_commitments set status = 'refund_pending'
        where pool_id = v.id and status = 'paid';
      update public.pool_commitments set status = 'expired'
        where pool_id = v.id and status = 'reserved';
      update public.moq_pools set status = 'expired', reserved_qty = 0, version = version + 1
        where id = v.id;
      perform public.log_transition('pool', v.id, 'open', 'expired', 'MOQ not reached by deadline');
      insert into public.notifications (profile_id, type, title, body, entity_type, entity_id, dedupe_key)
      select m.profile_id, 'pool_expired', 'A pool did not reach its target',
             'Any payment made will be refunded.', 'pool', v.id,
             'pool_expired:' || v.id::text || ':' || m.profile_id::text
      from public.pool_commitments c join public.organization_members m on m.organization_id = c.buyer_org_id
      where c.pool_id = v.id and c.status = 'refund_pending'
      on conflict (dedupe_key) do nothing;
      v_n := v_n + 1;
    elsif v.status = 'moq_reached' then             -- ready for a human to place the PO
      perform public.notify_admins('pool_ready_for_po', 'Pool ready for purchase order',
        v.pool_no || ' passed its deadline with the MOQ met', 'pool', v.id, 'pool_ready:' || v.id::text);
    end if;
  end loop;
  return v_n;
end $$;

-- ---------------------------------------------------------------------
-- 11. ROW-LEVEL SECURITY
-- ---------------------------------------------------------------------

alter table public.moq_pools             enable row level security;
alter table public.pool_price_tiers      enable row level security;
alter table public.pool_cost_tiers       enable row level security;
alter table public.pool_commitments      enable row level security;
alter table public.pool_commitment_items enable row level security;
alter table public.purchase_orders       enable row level security;
alter table public.purchase_order_items  enable row level security;
alter table public.orders                enable row level security;
alter table public.order_items           enable row level security;

create policy pools_admin      on public.moq_pools        for select to authenticated using (public.is_admin());
create policy price_tiers_admin on public.pool_price_tiers for select to authenticated using (public.is_admin());
create policy cost_tiers_admin  on public.pool_cost_tiers  for select to authenticated using (public.is_admin());

create policy commitments_select on public.pool_commitments for select to authenticated
  using (public.is_org_member(buyer_org_id) or public.is_admin());
create policy commit_items_select on public.pool_commitment_items for select to authenticated
  using (public.owns_commitment(commitment_id) or public.is_admin());

create policy orders_select on public.orders for select to authenticated
  using (public.is_org_member(buyer_org_id) or public.is_admin());
create policy order_items_select on public.order_items for select to authenticated
  using (public.owns_order(order_id) or public.is_admin());

create policy po_select on public.purchase_orders for select to authenticated
  using (public.is_org_member(manufacturer_org_id) or public.is_admin());
create policy po_items_select on public.purchase_order_items for select to authenticated
  using (public.owns_po(purchase_order_id) or public.is_admin());

-- ---------------------------------------------------------------------
-- 12. PRIVILEGES
-- ---------------------------------------------------------------------

revoke all on public.moq_pools, public.pool_price_tiers, public.pool_cost_tiers,
  public.pool_commitments, public.pool_commitment_items, public.purchase_orders,
  public.purchase_order_items, public.orders, public.order_items,
  public.open_pools, public.open_pool_price_tiers from anon, authenticated;
revoke all on sequence public.pool_no_seq, public.order_no_seq, public.po_no_seq
  from anon, authenticated;

revoke execute on function
  public.pool_price_at(uuid, integer), public.pool_cost_at(uuid, integer),
  public.owns_commitment(uuid), public.owns_order(uuid), public.owns_po(uuid),
  public.admin_create_pool(text, jsonb, integer, integer, integer, integer, timestamptz,
    uuid, uuid, jsonb, jsonb, timestamptz, integer, integer),
  public.admin_open_pool(uuid), public.admin_extend_pool(uuid, timestamptz),
  public.admin_cancel_pool(uuid, text),
  public.reserve_commitment(uuid, uuid, integer, jsonb, uuid, uuid, text),
  public.cancel_reservation(uuid),
  public.mark_commitment_paid(uuid, text, bigint),
  public.admin_cancel_commitment(uuid, text),
  public.admin_place_purchase_order(uuid, date),
  public.update_po_status(uuid, text, text),
  public.admin_set_order_status(uuid, text, text),
  public.release_expired_reservations(), public.close_due_pools()
  from public, anon, authenticated;

grant select on public.pool_price_tiers, public.pool_cost_tiers, public.moq_pools,
  public.pool_commitments, public.pool_commitment_items, public.purchase_orders,
  public.purchase_order_items, public.orders, public.order_items to authenticated;
grant select on public.open_pools, public.open_pool_price_tiers to anon, authenticated;

grant execute on function
  public.pool_price_at(uuid, integer), public.owns_commitment(uuid), public.owns_order(uuid),
  public.owns_po(uuid), public.reserve_commitment(uuid, uuid, integer, jsonb, uuid, uuid, text),
  public.cancel_reservation(uuid), public.update_po_status(uuid, text, text),
  public.admin_create_pool(text, jsonb, integer, integer, integer, integer, timestamptz,
    uuid, uuid, jsonb, jsonb, timestamptz, integer, integer),
  public.admin_open_pool(uuid), public.admin_extend_pool(uuid, timestamptz),
  public.admin_cancel_pool(uuid, text), public.admin_cancel_commitment(uuid, text),
  public.admin_place_purchase_order(uuid, date), public.admin_set_order_status(uuid, text, text)
  to authenticated;
grant execute on function
  public.mark_commitment_paid(uuid, text, bigint), public.release_expired_reservations(),
  public.close_due_pools(), public.pool_cost_at(uuid, integer) to service_role;

-- ---------------------------------------------------------------------
-- SMOKE TESTS TO RUN BEFORE MOVING ON
-- 1. Anonymous: open_pools and open_pool_price_tiers work; nothing shows
--    the manufacturer's name, cost tiers or other buyers.
-- 2. admin_create_pool from an accepted quote copies tiers; it rejects
--    prices that rise with quantity or fall below cost from the MOQ up.
-- 3. RACE TEST: two sessions call reserve_commitment for the last 100 units
--    at the same moment. Exactly one succeeds; paid+reserved never exceeds
--    target_qty.
-- 4. Same buyer twice on one pool: rejected. Same idempotency key twice:
--    returns the same commitment.
-- 5. release_expired_reservations frees reserved_qty; running it twice in
--    a row changes nothing the second time.
-- 6. mark_commitment_paid: same payment ref twice = 'already_paid'; wrong
--    amount raises; a payment after expiry returns 'refund_pending' and
--    never increases paid_qty; a different payment ref on an already-paid
--    commitment returns 'duplicate_payment' and changes nothing. Reaching the MOQ flips the pool to
--    moq_reached and notifies admins.
-- 7. admin_place_purchase_order: one PO per pool (second call fails); one
--    order per paid commitment; PO items equal the summed size/colour split;
--    rebate_paise is correct when the final tier is cheaper than the locked
--    price.
-- 8. close_due_pools on an unmet pool: paid commitments become
--    refund_pending, the pool becomes expired; running it twice is safe.
-- 9. Buyers cannot read other buyers' commitments or orders; manufacturers
--    can read only their own purchase orders (no buyer identity).
-- 10. Direct INSERT/UPDATE on pools, commitments, orders and purchase
--     orders from an authenticated session fails.
-- 11. A suspended user cannot reserve, cancel reservations, read their
--     orders through the helpers, or update purchase orders.
-- =====================================================================
