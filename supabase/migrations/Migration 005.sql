-- =====================================================================
-- Voz Cruda | Migration 005: Saved listings, KPI functions, buyer pool requests
-- Requires 001-004b. STATUS: UNTESTED DRAFT. Run on a scratch project first.
--
-- GAPS ADDRESSED:
--  1. saved_products: Allows users to save/bookmark favorite listings.
--  2. Dashboard KPI functions: Aggregation helpers for admin, buyer, and manufacturer stats.
--  3. Buyer pool requests: Allows buyers to request a pool from an RFQ/inquiry.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. SAVED PRODUCTS (Favorites / Bookmarks)
-- ---------------------------------------------------------------------
create table public.saved_products (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references public.profiles(id) on delete cascade,
  product_id  uuid not null references public.products(id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (profile_id, product_id)
);
create index saved_products_profile_idx on public.saved_products (profile_id);

-- ---------------------------------------------------------------------
-- 2. BUYER POOL REQUESTS
-- ---------------------------------------------------------------------
create table public.buyer_pool_requests (
  id           uuid primary key default gen_random_uuid(),
  buyer_org_id uuid not null references public.organizations(id) on delete cascade,
  rfq_id       uuid references public.rfqs(id) on delete set null,
  inquiry_id   uuid references public.inquiries(id) on delete set null,
  status       text not null default 'pending' check (status in ('pending','approved','rejected')),
  admin_notes  text,
  created_by   uuid references public.profiles(id) default auth.uid(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check ((rfq_id is not null)::int + (inquiry_id is not null)::int = 1)
);
create index buyer_pool_requests_org_idx on public.buyer_pool_requests (buyer_org_id, status);

create trigger trg_buyer_pool_req_updated before update on public.buyer_pool_requests
  for each row execute function public.set_updated_at();

create or replace function public.request_pool_creation(p_rfq uuid default null, p_inquiry uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_buyer uuid; v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if not public.email_confirmed() then raise exception 'email not verified' using errcode = '42501'; end if;
  if (p_rfq is null) = (p_inquiry is null) then
    raise exception 'provide exactly one of rfq or inquiry';
  end if;

  if p_rfq is not null then
    select buyer_org_id into v_buyer from public.rfqs where id = p_rfq and deleted_at is null;
  else
    select buyer_org_id into v_buyer from public.inquiries where id = p_inquiry;
  end if;

  if v_buyer is null or not public.is_org_member(v_buyer) then
    raise exception 'request not found or not allowed' using errcode = '42501';
  end if;

  insert into public.buyer_pool_requests (buyer_org_id, rfq_id, inquiry_id)
  values (v_buyer, p_rfq, p_inquiry) returning id into v_id;

  perform public.notify_admins('pool_request_new', 'New Pool Request',
    'A buyer requested to open a pool for request ' || coalesce(p_rfq::text, p_inquiry::text),
    'buyer_pool_request', v_id, 'pool_req:' || v_id::text);

  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- 3. DASHBOARD KPI AGREGATION FUNCTIONS / RPCs
-- ---------------------------------------------------------------------

-- Admin KPI Summary
create or replace function public.admin_get_kpis()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'pending_manufacturers', (select count(*) from public.organizations where type = 'manufacturer' and verification_status = 'pending' and deleted_at is null),
    'pending_products', (select count(*) from public.products where status = 'pending' and deleted_at is null),
    'open_disputes', (select count(*) from public.disputes where status = 'open'),
    'active_pools', (select count(*) from public.moq_pools where status in ('open','moq_reached')),
    'orders_in_production', (select count(*) from public.orders where status = 'in_production')
  );
$$;

-- Manufacturer KPI Summary (for the calling user's active manufacturer org)
create or replace function public.manufacturer_get_kpis(p_org uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'incoming_rfqs', (select count(*) from public.manufacturer_rfqs),
    'active_pools', (select count(*) from public.manufacturer_pools where status = 'open' and manufacturer_org_id = p_org),
    'pending_quotes', (select count(*) from public.quotes where manufacturer_org_id = p_org and status in ('draft','submitted')),
    'orders_in_production', (select count(*) from public.purchase_orders where manufacturer_org_id = p_org and status in ('accepted','in_production'))
  );
$$;

-- ---------------------------------------------------------------------
-- 4. RLS AND PRIVILEGES
-- ---------------------------------------------------------------------
alter table public.saved_products       enable row level security;
alter table public.buyer_pool_requests  enable row level security;

create policy saved_products_all on public.saved_products for all to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());

create policy buyer_pool_req_select on public.buyer_pool_requests for select to authenticated
  using (public.is_org_member(buyer_org_id) or public.is_admin());
create policy buyer_pool_req_insert on public.buyer_pool_requests for insert to authenticated
  with check (public.is_org_member(buyer_org_id) and public.email_confirmed());

revoke all on public.saved_products, public.buyer_pool_requests from anon, authenticated;

revoke execute on function public.request_pool_creation(uuid, uuid),
                          public.admin_get_kpis(),
                          public.manufacturer_get_kpis(uuid)
  from public, anon, authenticated;

grant select, insert, delete on public.saved_products to authenticated;
grant select on public.buyer_pool_requests to authenticated;

grant execute on function public.request_pool_creation(uuid, uuid) to authenticated;
grant execute on function public.admin_get_kpis() to authenticated;
grant execute on function public.manufacturer_get_kpis(uuid) to authenticated;