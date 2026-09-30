-- =====================================================================
-- 005_admin_roles.sql
-- Super admin + permissioned admins, delegated "grant" right, admin-created
-- accounts, and an admin wrapper for marking payments.
--
-- Model
--   * is_super   : full access; the ONLY role that can give an admin the
--                  right to grant permissions (can_grant), create/remove
--                  super admins, or remove admins.
--   * can_grant  : a normal admin who may grant permissions to other
--                  admins, limited to permissions they hold themselves.
--                  Cannot create grantors or touch super admins.
--   * permissions: text[] of feature keys (see admin_permission_keys()).
-- Every admin can READ everything (existing RLS); WRITES are gated by the
-- permission checks below.
-- Run AFTER 004b_fixes.sql. Existing admins become super admins.
-- =====================================================================

do $$
begin
  -- First run only: every existing admin keeps full power as a super admin.
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'admin_users' and column_name = 'is_super') then
    alter table public.admin_users add column is_super boolean not null default false;
    update public.admin_users set is_super = true;
  end if;
end $$;

alter table public.admin_users
  add column if not exists can_grant   boolean not null default false,
  add column if not exists permissions text[]  not null default '{}',
  add column if not exists created_by  uuid references public.profiles(id),
  add column if not exists updated_at  timestamptz not null default now();

alter table public.admin_users drop constraint if exists admin_permissions_valid;
alter table public.admin_users add constraint admin_permissions_valid check (
  permissions <@ array['catalogue','quotes','pools','payments','orders','disputes','suppliers','users','settings']::text[]);

create or replace function public.admin_permission_keys()
returns text[] language sql immutable as $$
  select array['catalogue','quotes','pools','payments','orders','disputes','suppliers','users','settings']::text[]
$$;

create or replace function public.has_perm(p text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admin_users a
                 where a.profile_id = auth.uid() and (a.is_super or p = any(a.permissions)));
$$;

create or replace function public.is_super_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admin_users a where a.profile_id = auth.uid() and a.is_super);
$$;

create or replace function public.can_grant_permissions()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admin_users a where a.profile_id = auth.uid() and (a.is_super or a.can_grant));
$$;

-- What the UI needs to know about the signed-in admin (null if not an admin).
create or replace function public.my_admin_access()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('is_super', a.is_super, 'can_grant', a.is_super or a.can_grant,
           'permissions', case when a.is_super then to_jsonb(public.admin_permission_keys()) else to_jsonb(a.permissions) end)
  from public.admin_users a where a.profile_id = auth.uid();
$$;

create or replace function public.can_create_accounts()
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_perm('users') or public.can_grant_permissions();
$$;

-- ---------------------------------------------------------------------
-- Settings: only admins with the 'settings' permission may edit.
-- ---------------------------------------------------------------------
drop policy if exists settings_admin_update on public.app_settings;
create policy settings_admin_update on public.app_settings for update to authenticated
  using (public.has_perm('settings')) with check (public.has_perm('settings'));

-- ---------------------------------------------------------------------
-- Existing admin functions, re-issued with permission checks
-- (bodies unchanged except the guard line).
-- ---------------------------------------------------------------------
create or replace function public.admin_review_product(
  p_product uuid, p_status text, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_old text;
begin
  if not public.has_perm('catalogue') then
    raise exception 'admin only' using errcode = '42501';
  end if;
  if p_status not in ('approved','rejected') then
    raise exception 'status must be approved or rejected';
  end if;
  if p_status = 'rejected' and nullif(trim(p_reason), '') is null then
    raise exception 'a reason is required when rejecting';
  end if;

  select status into v_old from public.products
  where id = p_product and deleted_at is null for update;
  if not found then raise exception 'product not found'; end if;
  if v_old <> 'pending' then
    raise exception 'only pending products can be reviewed (current: %)', v_old;
  end if;

  update public.products
  set status = p_status,
      rejected_reason = case when p_status = 'rejected' then p_reason end
  where id = p_product;

  insert into public.state_transitions (entity_type, entity_id, from_status, to_status, actor, reason)
  values ('product', p_product, v_old, p_status, auth.uid(), p_reason);
end $$;

create or replace function public.admin_publish_offer(
  p_quote uuid, p_valid_until timestamptz, p_tiers jsonb, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_q public.quotes; v_rev public.quote_revisions; t record;
  v_cost bigint; v_extra bigint; v_hi integer;
begin
  if not public.has_perm('quotes') then raise exception 'admin only' using errcode = '42501'; end if;
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
  if not public.has_perm('pools') then raise exception 'admin only' using errcode = '42501'; end if;
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
  if not public.has_perm('pools') then raise exception 'admin only' using errcode = '42501'; end if;
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
  if not public.has_perm('pools') then raise exception 'admin only' using errcode = '42501'; end if;
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
  if not public.has_perm('pools') then raise exception 'admin only' using errcode = '42501'; end if;
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

create or replace function public.admin_create_direct_pool(
  p_quote uuid, p_deadline timestamptz, p_payment_window_minutes integer default 1440)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_q public.quotes; v_qty integer; v_title text; v_pool uuid;
begin
  if not public.has_perm('pools') then raise exception 'admin only' using errcode = '42501'; end if;
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

create or replace function public.admin_place_purchase_order(
  p_pool uuid, p_expected_ready date default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_pool public.moq_pools; v_qty integer; v_cost bigint; v_final bigint;
  v_po uuid; v_order uuid; r public.pool_commitments;
begin
  if not public.has_perm('pools') then raise exception 'admin only' using errcode = '42501'; end if;
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

create or replace function public.admin_cancel_commitment(p_commitment uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_pool_id uuid; v_pool public.moq_pools; v_c public.pool_commitments;
begin
  if not public.has_perm('payments') then raise exception 'admin only' using errcode = '42501'; end if;
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

create or replace function public.admin_set_order_status(p_order uuid, p_to text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v public.orders; v_ok boolean;
begin
  if not public.has_perm('orders') then raise exception 'admin only' using errcode = '42501'; end if;
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

create or replace function public.admin_cancel_po(p_po uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v public.purchase_orders;
begin
  if not public.has_perm('orders') then raise exception 'admin only' using errcode = '42501'; end if;
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

create or replace function public.update_po_status(p_po uuid, p_to text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v public.purchase_orders; v_admin boolean := public.has_perm('orders'); v_mfr boolean; v_ok boolean;
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

create or replace function public.admin_resolve_dispute(
  p_dispute uuid, p_refund boolean, p_resolution text)
returns void language plpgsql security definer set search_path = public as $$
declare d public.disputes;
begin
  if not public.has_perm('disputes') then raise exception 'admin only' using errcode = '42501'; end if;
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

create or replace function public.admin_set_verification(
  p_org uuid, p_status text, p_level text, p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_old text; v_type text; v_gstin text; v_pan text;
begin
  if not public.has_perm('suppliers') then raise exception 'admin only' using errcode = '42501'; end if;
  if p_status not in ('pending','approved','rejected') then raise exception 'invalid status'; end if;
  if p_level not in ('unverified','document_verified','business_verified','factory_verified') then
    raise exception 'invalid level';
  end if;
  if p_status = 'approved' and p_level = 'unverified' then
    raise exception 'approved organizations need a verification level';
  end if;

  select verification_status, type, gstin, pan into v_old, v_type, v_gstin, v_pan
  from public.organizations where id = p_org and deleted_at is null for update;
  if not found then raise exception 'organization not found'; end if;

  if p_status = 'approved' and exists (
       select 1 from public.organizations o
       where o.id <> p_org and o.type = v_type and o.verification_status = 'approved'
         and o.deleted_at is null
         and ((v_gstin is not null and o.gstin = v_gstin) or (v_pan is not null and o.pan = v_pan))) then
    raise exception 'another approved organization already uses this GSTIN or PAN';
  end if;

  update public.organizations
  set verification_status = p_status,
      verification_level  = p_level,
      verified_at = case when p_status = 'approved' then now() end,
      verified_by = case when p_status = 'approved' then auth.uid() end
  where id = p_org;

  insert into public.manufacturer_verifications (organization_id, level, status, decided_by, admin_notes)
  values (p_org, p_level, p_status, auth.uid(), p_notes);
  insert into public.state_transitions (entity_type, entity_id, from_status, to_status, actor, reason)
  values ('organization', p_org, v_old, p_status, auth.uid(), p_notes);
end $$;

create or replace function public.admin_set_manufacturer_slug(p_org uuid, p_slug text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_perm('suppliers') then raise exception 'admin only' using errcode = '42501'; end if;
  if p_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then raise exception 'invalid slug'; end if;
  update public.manufacturer_profiles set slug = p_slug where organization_id = p_org;
  if not found then raise exception 'manufacturer not found'; end if;
end $$;

create or replace function public.admin_set_profile_status(
  p_profile uuid, p_status text, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_old text;
begin
  if not public.has_perm('users') then raise exception 'admin only' using errcode = '42501'; end if;
  if p_status not in ('active','suspended','deactivated') then raise exception 'invalid status'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'a reason is required'; end if;
  if p_profile = auth.uid() then raise exception 'you cannot change your own status'; end if;
  select status into v_old from public.profiles where id = p_profile for update;
  if not found then raise exception 'profile not found'; end if;
  update public.profiles set status = p_status where id = p_profile;
  insert into public.state_transitions (entity_type, entity_id, from_status, to_status, actor, reason)
  values ('profile', p_profile, v_old, p_status, auth.uid(), p_reason);
end $$;

create or replace function public.admin_set_org_suspension(p_org uuid, p_suspend boolean, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (public.has_perm('suppliers') or public.has_perm('users')) then raise exception 'admin only' using errcode = '42501'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'a reason is required'; end if;
  update public.organizations
    set suspended_at = case when p_suspend then now() end where id = p_org and deleted_at is null;
  if not found then raise exception 'organization not found'; end if;
  perform public.log_transition('organization', p_org,
    case when p_suspend then 'active' else 'suspended' end,
    case when p_suspend then 'suspended' else 'active' end, p_reason);
end $$;


-- Payments: mark_commitment_paid is service-role only (payment webhook), so
-- admins need a wrapper. Amount is taken from the commitment itself.
create or replace function public.admin_mark_paid(p_commitment uuid, p_payment_ref text)
returns text language plpgsql security definer set search_path = public as $$
declare v_amount bigint;
begin
  if not public.has_perm('payments') then raise exception 'not allowed: payments permission required' using errcode = '42501'; end if;
  select amount_due_paise into v_amount from public.pool_commitments where id = p_commitment;
  if v_amount is null then raise exception 'commitment not found'; end if;
  return public.mark_commitment_paid(p_commitment, p_payment_ref, v_amount);
end $$;

-- ---------------------------------------------------------------------
-- Audit helper
-- ---------------------------------------------------------------------
create or replace function public._audit_admin(p_action text, p_profile uuid, p_before jsonb, p_after jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.audit_logs (actor_profile_id, action, entity_type, entity_id, before, after)
  values (auth.uid(), p_action, 'admin_user', p_profile, p_before, p_after);
$$;
revoke all on function public._audit_admin(text, uuid, jsonb, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Admin team management
-- ---------------------------------------------------------------------
create or replace function public.admin_list_admins()
returns table (profile_id uuid, email text, full_name text, is_super boolean, can_grant boolean,
               permissions text[], created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_grant_permissions() then raise exception 'not allowed' using errcode = '42501'; end if;
  return query
    select a.profile_id, u.email::text, p.full_name, a.is_super, a.can_grant, a.permissions, a.created_at
    from public.admin_users a
    join auth.users u on u.id = a.profile_id
    left join public.profiles p on p.id = a.profile_id
    order by a.is_super desc, a.created_at;
end $$;

create or replace function public.admin_find_user(p_email text)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  if not public.can_create_accounts() then raise exception 'not allowed' using errcode = '42501'; end if;
  select id into v from auth.users where lower(email) = lower(trim(p_email));
  return v;
end $$;

-- Make an existing account an admin (or update an existing admin's permissions).
create or replace function public.admin_grant_admin(p_email text, p_permissions text[], p_can_grant boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me public.admin_users; v_target uuid; v_old public.admin_users; v_perms text[];
begin
  select * into v_me from public.admin_users where profile_id = auth.uid();
  if not found or not (v_me.is_super or v_me.can_grant) then
    raise exception 'only a super admin or an admin with grant rights can add admins' using errcode = '42501';
  end if;
  select id into v_target from auth.users where lower(email) = lower(trim(p_email));
  if v_target is null then raise exception 'no account with that email - create it first'; end if;
  if v_target = auth.uid() then raise exception 'you cannot change your own access'; end if;
  v_perms := coalesce(p_permissions, '{}');
  if not (v_perms <@ public.admin_permission_keys()) then raise exception 'unknown permission'; end if;

  select * into v_old from public.admin_users where profile_id = v_target;
  if not v_me.is_super then
    if p_can_grant then raise exception 'only a super admin can give grant rights' using errcode = '42501'; end if;
    if not (v_perms <@ v_me.permissions) then raise exception 'you can only grant permissions you hold yourself' using errcode = '42501'; end if;
    if found and (v_old.is_super or v_old.can_grant) then raise exception 'you cannot modify a super admin or grantor' using errcode = '42501'; end if;
    if found then v_perms := (select coalesce(array_agg(x), '{}') from unnest(v_old.permissions) x where not (x = any(v_me.permissions))) || v_perms; end if;
  end if;

  insert into public.admin_users (profile_id, permissions, can_grant, created_by)
  values (v_target, v_perms, case when v_me.is_super then p_can_grant else false end, auth.uid())
  on conflict (profile_id) do update
    set permissions = excluded.permissions,
        can_grant = case when v_me.is_super then excluded.can_grant else public.admin_users.can_grant end,
        updated_at = now();
  perform public._audit_admin('admin_granted', v_target, to_jsonb(v_old),
    jsonb_build_object('permissions', v_perms, 'can_grant', p_can_grant and v_me.is_super));
  return v_target;
end $$;

-- Change an admin's permissions.
create or replace function public.admin_set_permissions(p_profile uuid, p_permissions text[])
returns void language plpgsql security definer set search_path = public as $$
declare v_me public.admin_users; v_old public.admin_users; v_perms text[];
begin
  select * into v_me from public.admin_users where profile_id = auth.uid();
  if not found or not (v_me.is_super or v_me.can_grant) then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into v_old from public.admin_users where profile_id = p_profile;
  if not found then raise exception 'admin not found'; end if;
  v_perms := coalesce(p_permissions, '{}');
  if not (v_perms <@ public.admin_permission_keys()) then raise exception 'unknown permission'; end if;
  if not v_me.is_super then
    if p_profile = auth.uid() then raise exception 'you cannot change your own access' using errcode = '42501'; end if;
    if v_old.is_super or v_old.can_grant then raise exception 'you cannot modify a super admin or grantor' using errcode = '42501'; end if;
    if not (v_perms <@ v_me.permissions) then raise exception 'you can only grant permissions you hold yourself' using errcode = '42501'; end if;
    -- keep permissions the grantor does not hold; only touch the ones they do
    v_perms := (select coalesce(array_agg(x), '{}') from unnest(v_old.permissions) x where not (x = any(v_me.permissions))) || v_perms;
  end if;
  update public.admin_users set permissions = v_perms, updated_at = now() where profile_id = p_profile;
  perform public._audit_admin('admin_permissions_changed', p_profile, jsonb_build_object('permissions', v_old.permissions), jsonb_build_object('permissions', v_perms));
end $$;

-- SUPER ADMIN ONLY: decide who may grant permissions to others.
create or replace function public.admin_set_grant_right(p_profile uuid, p_can_grant boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'only a super admin can do this' using errcode = '42501'; end if;
  update public.admin_users set can_grant = p_can_grant, updated_at = now() where profile_id = p_profile and not is_super;
  if not found then raise exception 'admin not found (or is a super admin, who always can grant)'; end if;
  perform public._audit_admin('admin_grant_right_changed', p_profile, null, jsonb_build_object('can_grant', p_can_grant));
end $$;

create or replace function public.admin_set_super(p_profile uuid, p_super boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'only a super admin can do this' using errcode = '42501'; end if;
  if not p_super and (select count(*) from public.admin_users where is_super and profile_id <> p_profile) = 0 then
    raise exception 'there must be at least one super admin';
  end if;
  update public.admin_users set is_super = p_super, updated_at = now() where profile_id = p_profile;
  if not found then raise exception 'admin not found'; end if;
  perform public._audit_admin('admin_super_changed', p_profile, null, jsonb_build_object('is_super', p_super));
end $$;

create or replace function public.admin_remove_admin(p_profile uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v public.admin_users;
begin
  if not public.is_super_admin() then raise exception 'only a super admin can do this' using errcode = '42501'; end if;
  if p_profile = auth.uid() then raise exception 'you cannot remove yourself'; end if;
  select * into v from public.admin_users where profile_id = p_profile;
  if not found then raise exception 'admin not found'; end if;
  if v.is_super and (select count(*) from public.admin_users where is_super and profile_id <> p_profile) = 0 then
    raise exception 'there must be at least one super admin';
  end if;
  delete from public.admin_users where profile_id = p_profile;
  perform public._audit_admin('admin_removed', p_profile, to_jsonb(v), null);
end $$;

-- ---------------------------------------------------------------------
-- Admin-created buyer / supplier account (the auth user itself is created
-- by the admin-create-user edge function; this attaches the business).
-- Consents are NOT recorded: the account holder has not accepted terms.
-- ---------------------------------------------------------------------
create or replace function public.admin_create_org_for(
  p_profile uuid, p_type text, p_legal_name text,
  p_trade_name text default null, p_gstin text default null, p_pan text default null,
  p_phone text default null, p_approve boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  if not public.has_perm('users') then raise exception 'not allowed: users permission required' using errcode = '42501'; end if;
  if p_type not in ('buyer','manufacturer') then raise exception 'invalid organization type'; end if;
  if nullif(trim(p_legal_name), '') is null then raise exception 'legal name is required'; end if;
  if not exists (select 1 from public.profiles where id = p_profile) then raise exception 'profile not found'; end if;
  if exists (select 1 from public.organization_members where profile_id = p_profile) then
    raise exception 'this user already belongs to a business';
  end if;
  insert into public.organizations (type, legal_name, trade_name, gstin, pan, created_by)
  values (p_type, trim(p_legal_name), nullif(trim(p_trade_name), ''), nullif(trim(p_gstin), ''), nullif(trim(p_pan), ''), p_profile)
  returning id into v_org;
  insert into public.organization_members (organization_id, profile_id, member_role) values (v_org, p_profile, 'owner');
  if p_type = 'buyer' then insert into public.buyer_profiles (organization_id) values (v_org);
  else insert into public.manufacturer_profiles (organization_id) values (v_org); end if;
  if nullif(trim(p_phone), '') is not null then update public.profiles set phone = trim(p_phone) where id = p_profile; end if;
  if p_approve then perform public.admin_set_verification(v_org, 'approved', 'business_verified', 'Created by admin'); end if;
  insert into public.audit_logs (actor_profile_id, action, entity_type, entity_id, after)
  values (auth.uid(), 'account_created_by_admin', 'organization', v_org, jsonb_build_object('profile', p_profile, 'type', p_type));
  return v_org;
end $$;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
revoke all on function
  public.has_perm(text), public.is_super_admin(), public.can_grant_permissions(), public.my_admin_access(), public.can_create_accounts(),
  public.admin_mark_paid(uuid, text), public.admin_list_admins(), public.admin_find_user(text),
  public.admin_grant_admin(text, text[], boolean), public.admin_set_permissions(uuid, text[]),
  public.admin_set_grant_right(uuid, boolean), public.admin_set_super(uuid, boolean), public.admin_remove_admin(uuid),
  public.admin_create_org_for(uuid, text, text, text, text, text, text, boolean)
  from public, anon;
grant execute on function
  public.has_perm(text), public.is_super_admin(), public.can_grant_permissions(), public.my_admin_access(), public.can_create_accounts(),
  public.admin_mark_paid(uuid, text), public.admin_list_admins(), public.admin_find_user(text),
  public.admin_grant_admin(text, text[], boolean), public.admin_set_permissions(uuid, text[]),
  public.admin_set_grant_right(uuid, boolean), public.admin_set_super(uuid, boolean), public.admin_remove_admin(uuid),
  public.admin_create_org_for(uuid, text, text, text, text, text, text, boolean)
  to authenticated;
