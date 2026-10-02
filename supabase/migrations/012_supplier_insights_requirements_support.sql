-- =====================================================================
-- 012  Supplier market insights, requirements board, support chat
-- Run in the Supabase SQL editor (after 011). Safe to run twice.
--
--  A. Market insights   supplier_market_insights(), supplier_price_benchmark()
--                       Anonymous aggregates only: a group is shown only when it
--                       has >= 3 batches from >= 2 different manufacturers.
--  B. Requirements      suppliers post needs -> admin reviews & publishes ->
--                       every approved manufacturer is notified and can respond.
--                       Posters are never shown to other suppliers.
--  C. Support chat      any supplier / buyer <-> any admin (shared inbox).
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. MARKET INSIGHTS
-- ---------------------------------------------------------------------
-- One row per live/finished batch in the window, with its "spec bucket".
-- Buyer-paid prices are deliberately NOT exposed here: suppliers only ever see catalogue listing prices.
drop function if exists public._market_pools(integer);
create or replace function public._market_pools(p_days integer)
returns table (pool_id uuid, org_id uuid, category_id uuid, material_id uuid, cat text, mat text,
               fit text, gsm integer, opens_at timestamptz, status text, paid_qty integer,
               filled boolean, fill_hours numeric)
language sql stable security definer set search_path = public as $$
  select p.id, p.manufacturer_org_id, pr.category_id, pr.material_id, c.name, m.name,
         nullif(lower(trim(pr.fit)), ''),
         case when pr.gsm is null then null else (round(pr.gsm / 10.0) * 10)::integer end,
         p.opens_at, p.status, p.paid_qty,
         (t.at is not null or p.status in ('moq_reached', 'po_placed')),
         case when t.at is null then null else greatest(0, extract(epoch from (t.at - p.opens_at)) / 3600.0)::numeric end
  from public.moq_pools p
  join public.products pr on pr.id = p.product_id
  left join public.categories c on c.id = pr.category_id
  left join public.materials m on m.id = pr.material_id
  left join lateral (select min(s.created_at) as at from public.state_transitions s
                     where s.entity_type = 'pool' and s.entity_id = p.id and s.to_status = 'moq_reached') t on true
  where p.status in ('open', 'moq_reached', 'po_placed', 'expired')
    and p.opens_at >= now() - make_interval(days => greatest(7, least(coalesce(p_days, 90), 730)));
$$;

-- Listed (catalogue) price per product = first quantity tier of approved products.
create or replace function public._market_listings()
returns table (product_id uuid, org_id uuid, category_id uuid, material_id uuid, fit text, gsm integer, price bigint)
language sql stable security definer set search_path = public as $$
  select pr.id, pr.organization_id, pr.category_id, pr.material_id, nullif(lower(trim(pr.fit)), ''),
         case when pr.gsm is null then null else (round(pr.gsm / 10.0) * 10)::integer end,
         (select t.unit_price_paise from public.price_tiers t where t.product_id = pr.id order by t.min_qty limit 1)
  from public.products pr join public.organizations o on o.id = pr.organization_id
  where pr.status = 'approved' and pr.deleted_at is null and o.type = 'manufacturer'
    and o.suspended_at is null and o.deleted_at is null;
$$;
revoke all on function public._market_pools(integer), public._market_listings() from public, anon, authenticated;

create or replace function public._assert_supplier()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v uuid := public.my_manufacturer_org();
begin
  if v is null and not public.is_admin() then raise exception 'Only verified suppliers can view market insights'; end if;
  return v;
end $$;
revoke all on function public._assert_supplier() from public, anon, authenticated;

create or replace function public.supplier_market_insights(p_days integer default 90)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_org uuid; v_days integer := greatest(7, least(coalesce(p_days, 90), 730)); v_out jsonb;
begin
  v_org := public._assert_supplier();
  with mp as (select * from public._market_pools(v_days)),
  lst as (select * from public._market_listings()),
  b as (
    select category_id, material_id, gsm, fit, max(cat) cat, max(mat) mat,
           count(*) batches, count(distinct org_id) makers,
           count(*) filter (where filled) filled,
           count(*) filter (where status in ('moq_reached','po_placed','expired')) closed,
           sum(paid_qty) units,
           sum(paid_qty) filter (where opens_at >= now() - make_interval(days => v_days / 2)) units_recent,
           sum(paid_qty) filter (where opens_at <  now() - make_interval(days => v_days / 2)) units_prev,
           percentile_cont(0.5) within group (order by fill_hours) filter (where fill_hours is not null) med_hours,
           count(*) filter (where org_id = v_org) my_batches,
           percentile_cont(0.5) within group (order by fill_hours) filter (where org_id = v_org and fill_hours is not null) my_med_hours
    from mp group by category_id, material_id, gsm, fit
  ),
  l as (
    select category_id, material_id, gsm, fit, count(*) products, count(distinct org_id) makers,
           avg(price) avg_price, percentile_cont(0.25) within group (order by price) p25,
           percentile_cont(0.5) within group (order by price) p50, percentile_cont(0.75) within group (order by price) p75,
           avg(price) filter (where org_id = v_org) my_price, bool_or(org_id = v_org) i_list_it
    from lst where price is not null group by category_id, material_id, gsm, fit
  ),
  shown as (
    select b.*, l.products, l.makers l_makers, l.avg_price l_avg, l.p25 l_p25, l.p50 l_p50, l.p75 l_p75, l.my_price, coalesce(l.i_list_it, false) i_list_it,
           (l.products >= 3 and l.makers >= 2) l_ok
    from b left join l on l.category_id is not distinct from b.category_id and l.material_id is not distinct from b.material_id
                      and l.gsm is not distinct from b.gsm and l.fit is not distinct from b.fit
    where b.batches >= 3 and b.makers >= 2
  )
  select jsonb_build_object(
    'days', v_days, 'generated_at', now(),
    'totals', (select jsonb_build_object('batches', coalesce(sum(batches), 0), 'units', coalesce(sum(units), 0),
                 'filled', coalesce(sum(filled), 0), 'groups', count(*),
                 'median_fill_hours', (select percentile_cont(0.5) within group (order by fill_hours) from mp where fill_hours is not null))
               from shown),
    'buckets', coalesce((select jsonb_agg(x order by (x->>'units')::numeric desc) from (
        select jsonb_build_object(
          'key', concat_ws('|', category_id, material_id, gsm, fit),
          'category_id', category_id, 'material_id', material_id,
          'category', cat, 'material', mat, 'gsm', gsm, 'fit', fit,
          'batches', batches, 'makers', makers, 'filled', filled,
          'fill_rate', case when closed > 0 then round(filled::numeric / closed * 100) end,
          'units', units,
          'trend_pct', case when coalesce(units_prev, 0) > 0 then round((coalesce(units_recent, 0) - units_prev)::numeric / units_prev * 100) end,
          'median_fill_hours', round(med_hours::numeric, 1),
          'listed', case when l_ok then jsonb_build_object('avg', round(l_avg), 'p25', round(l_p25), 'median', round(l_p50), 'p75', round(l_p75), 'products', products) end,
          'mine', jsonb_build_object('batches', my_batches, 'median_fill_hours', round(my_med_hours::numeric, 1),
                                     'listed_price', round(my_price), 'lists_product', i_list_it)
        ) x from shown order by units desc nulls last limit 40) s), '[]'::jsonb)
  ) into v_out;
  return v_out;
end $$;

-- Benchmark for one spec. Any combination: category required, others optional.
create or replace function public.supplier_price_benchmark(
  p_category uuid, p_material uuid default null, p_gsm integer default null, p_fit text default null, p_days integer default 180)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_org uuid; v_fit text := nullif(lower(trim(coalesce(p_fit, ''))), '');
        v_days integer := greatest(7, least(coalesce(p_days, 180), 730)); r record; l record; v_li jsonb;
begin
  v_org := public._assert_supplier();
  if p_category is null then raise exception 'Choose a category'; end if;
  select count(*) batches, count(distinct org_id) makers, count(*) filter (where filled) filled,
         count(*) filter (where status in ('moq_reached','po_placed','expired')) closed,
         sum(paid_qty) units,
         percentile_cont(0.5) within group (order by fill_hours) filter (where fill_hours is not null) med_hours
    into r from public._market_pools(v_days) m
   where m.category_id = p_category and (p_material is null or m.material_id = p_material)
     and (p_gsm is null or abs(m.gsm - p_gsm) <= 15) and (v_fit is null or m.fit = v_fit);
  select count(*) products, count(distinct org_id) makers, avg(price) avg_p,
         percentile_cont(0.25) within group (order by price) p25,
         percentile_cont(0.5)  within group (order by price) p50,
         percentile_cont(0.75) within group (order by price) p75
    into l from public._market_listings() x
   where x.price is not null and x.category_id = p_category and (p_material is null or x.material_id = p_material)
     and (p_gsm is null or abs(x.gsm - p_gsm) <= 15) and (v_fit is null or x.fit = v_fit);
  if l.products >= 3 and l.makers >= 2 then
    v_li := jsonb_build_object('avg', round(l.avg_p), 'p25', round(l.p25), 'median', round(l.p50), 'p75', round(l.p75), 'products', l.products); end if;
  return jsonb_build_object(
    'enough', (v_li is not null or (r.batches >= 3 and r.makers >= 2)),
    'batches', case when r.batches >= 3 and r.makers >= 2 then r.batches end,
    'units', case when r.batches >= 3 and r.makers >= 2 then r.units end,
    'fill_rate', case when r.batches >= 3 and r.makers >= 2 and r.closed > 0 then round(r.filled::numeric / r.closed * 100) end,
    'median_fill_hours', case when r.batches >= 3 and r.makers >= 2 then round(r.med_hours::numeric, 1) end,
    'listed_price', v_li);
end $$;

revoke all on function public.supplier_market_insights(integer), public.supplier_price_benchmark(uuid, uuid, integer, text, integer) from public, anon;
grant execute on function public.supplier_market_insights(integer), public.supplier_price_benchmark(uuid, uuid, integer, text, integer) to authenticated;

-- ---------------------------------------------------------------------
-- B. REQUIREMENTS BOARD
-- ---------------------------------------------------------------------
create sequence if not exists public.requirement_no_seq;

create table if not exists public.requirements (
  id uuid primary key default gen_random_uuid(),
  req_no text not null unique default 'REQ-' || lpad(nextval('public.requirement_no_seq')::text, 5, '0'),
  posted_by_org uuid references public.organizations(id) on delete set null,  -- null = posted by admin
  posted_by uuid references public.profiles(id),
  source text not null default 'supplier' check (source in ('supplier', 'admin')),
  kind text not null check (kind in ('product', 'raw_material')),
  title text not null check (length(trim(title)) between 3 and 140),
  description text check (description is null or length(description) <= 4000),
  category_id uuid references public.categories(id),
  qty integer check (qty is null or qty > 0),
  unit text check (unit is null or length(unit) <= 20),
  target_price_paise bigint check (target_price_paise is null or target_price_paise > 0),
  needed_by date,
  response_by date,
  status text not null default 'pending_review'
    check (status in ('pending_review', 'published', 'closed', 'rejected', 'fulfilled')),
  admin_note text,
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists requirements_status_idx on public.requirements (status, published_at desc);
create index if not exists requirements_org_idx on public.requirements (posted_by_org);

create table if not exists public.requirement_responses (
  id uuid primary key default gen_random_uuid(),
  requirement_id uuid not null references public.requirements(id) on delete cascade,
  org_id uuid not null references public.organizations(id) on delete cascade,
  responded_by uuid references public.profiles(id),
  unit_price_paise bigint check (unit_price_paise is null or unit_price_paise > 0),
  lead_time_days integer check (lead_time_days is null or lead_time_days > 0),
  min_qty integer check (min_qty is null or min_qty > 0),
  note text check (note is null or length(note) <= 2000),
  status text not null default 'submitted' check (status in ('submitted', 'shortlisted', 'selected', 'declined', 'withdrawn')),
  shared_with_poster boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (requirement_id, org_id)
);
create index if not exists req_resp_req_idx on public.requirement_responses (requirement_id);

drop trigger if exists trg_requirements_updated on public.requirements;
create trigger trg_requirements_updated before update on public.requirements for each row execute function public.set_updated_at();
drop trigger if exists trg_req_resp_updated on public.requirement_responses;
create trigger trg_req_resp_updated before update on public.requirement_responses for each row execute function public.set_updated_at();
drop trigger if exists trg_audit_requirements on public.requirements;
create trigger trg_audit_requirements after insert or update or delete on public.requirements for each row execute function public.audit_row_change();
drop trigger if exists trg_audit_req_resp on public.requirement_responses;
create trigger trg_audit_req_resp after insert or update or delete on public.requirement_responses for each row execute function public.audit_row_change();

alter table public.requirements enable row level security;
alter table public.requirement_responses enable row level security;
-- Poster sees their own requests; admins see everything. Other suppliers only via the view below.
drop policy if exists req_select on public.requirements;
create policy req_select on public.requirements for select to authenticated
  using (public.is_admin() or (posted_by_org is not null and public.is_org_member(posted_by_org)));
-- A response is visible to its own organisation and to admins. NOT to the poster.
drop policy if exists req_resp_select on public.requirement_responses;
create policy req_resp_select on public.requirement_responses for select to authenticated
  using (public.is_admin() or public.is_org_member(org_id));
revoke all on public.requirements, public.requirement_responses from anon;
revoke insert, update, delete on public.requirements, public.requirement_responses from authenticated;
grant select on public.requirements, public.requirement_responses to authenticated;

-- What suppliers see: no poster identity. Includes closed ones the caller responded to.
create or replace view public.requirement_board as
  select r.id, r.req_no, r.kind, r.title, r.description, r.category_id, r.qty, r.unit, r.target_price_paise,
         r.needed_by, r.response_by, r.status, r.published_at,
         (r.posted_by_org is not distinct from public.my_manufacturer_org()) as mine,
         (r.response_by is not null and r.response_by < current_date) as past_deadline
  from public.requirements r
  where public.my_manufacturer_org() is not null
    and (r.status = 'published'
         or exists (select 1 from public.requirement_responses x
                    where x.requirement_id = r.id and public.is_org_member(x.org_id)));
-- What the poster sees: only responses admin chose to share, with no supplier identity.
create or replace view public.requirement_shared_responses as
  select x.id, x.requirement_id, x.unit_price_paise, x.lead_time_days, x.min_qty, x.note, x.status, x.created_at
  from public.requirement_responses x join public.requirements r on r.id = x.requirement_id
  where x.shared_with_poster and x.status <> 'withdrawn'
    and r.posted_by_org is not null and public.is_org_member(r.posted_by_org);
revoke all on public.requirement_board, public.requirement_shared_responses from anon;
grant select on public.requirement_board, public.requirement_shared_responses to authenticated;

-- ---- RPCs ------------------------------------------------------------
create or replace function public._notify_all_suppliers(p_except uuid, p_type text, p_title text, p_body text, p_entity uuid, p_dedupe text)
returns void language plpgsql security definer set search_path = public as $$
declare o record;
begin
  for o in select id from public.organizations
           where type = 'manufacturer' and verification_status = 'approved' and deleted_at is null
             and suspended_at is null and id is distinct from p_except loop
    perform public.notify_org(o.id, p_type, p_title, p_body, 'requirement', p_entity, p_dedupe || ':' || o.id::text);
  end loop;
end $$;
revoke all on function public._notify_all_suppliers(uuid, text, text, text, uuid, text) from public, anon, authenticated;

create or replace function public.submit_requirement(
  p_kind text, p_title text, p_description text default null, p_category uuid default null,
  p_qty integer default null, p_unit text default null, p_target_price_paise bigint default null, p_needed_by date default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_org uuid := public.my_manufacturer_org(); v_id uuid; v_no text;
begin
  if v_org is null then raise exception 'Only verified suppliers can post requirements'; end if;
  if not public.email_confirmed() then raise exception 'Confirm your email first'; end if;
  if (select count(*) from public.requirements where posted_by_org = v_org and status = 'pending_review') >= 10 then
    raise exception 'You already have 10 requests waiting for review'; end if;
  if p_needed_by is not null and p_needed_by < current_date then raise exception 'Needed-by date is in the past'; end if;
  insert into public.requirements (posted_by_org, posted_by, source, kind, title, description, category_id, qty, unit, target_price_paise, needed_by)
  values (v_org, auth.uid(), 'supplier', p_kind, trim(p_title), nullif(trim(coalesce(p_description, '')), ''), p_category, p_qty,
          nullif(trim(coalesce(p_unit, '')), ''), p_target_price_paise, p_needed_by)
  returning id, req_no into v_id, v_no;
  perform public.log_transition('requirement', v_id, null, 'pending_review', 'posted by supplier');
  perform public.notify_admins('requirement_submitted', 'New requirement to review', v_no || ' · ' || trim(p_title), 'requirement', v_id, 'req_sub:' || v_id);
  return v_id;
end $$;

create or replace function public.admin_create_requirement(
  p_kind text, p_title text, p_description text default null, p_category uuid default null,
  p_qty integer default null, p_unit text default null, p_target_price_paise bigint default null,
  p_needed_by date default null, p_response_by date default null, p_publish boolean default true)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_no text;
begin
  if not public.has_perm('suppliers') then raise exception 'You do not have permission to post requirements'; end if;
  insert into public.requirements (posted_by_org, posted_by, source, kind, title, description, category_id, qty, unit,
                                   target_price_paise, needed_by, response_by, status, reviewed_by, reviewed_at, published_at)
  values (null, auth.uid(), 'admin', p_kind, trim(p_title), nullif(trim(coalesce(p_description, '')), ''), p_category, p_qty,
          nullif(trim(coalesce(p_unit, '')), ''), p_target_price_paise, p_needed_by, p_response_by,
          case when p_publish then 'published' else 'pending_review' end, auth.uid(), now(), case when p_publish then now() end)
  returning id, req_no into v_id, v_no;
  perform public.log_transition('requirement', v_id, null, case when p_publish then 'published' else 'pending_review' end, 'posted by admin');
  if p_publish then
    perform public._notify_all_suppliers(null, 'requirement_published', 'New requirement: ' || trim(p_title),
      case when p_kind = 'raw_material' then 'Raw material' else 'Product' end || ' requirement ' || v_no || ' is open for responses.', v_id, 'req_pub:' || v_id);
  end if;
  return v_id;
end $$;

-- action: publish | reject | close | fulfil | reopen.  p_edits may adjust fields while publishing.
create or replace function public.admin_review_requirement(p_id uuid, p_action text, p_note text default null, p_edits jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare r public.requirements; v_to text; e jsonb := coalesce(p_edits, '{}'::jsonb);
begin
  if not public.has_perm('suppliers') then raise exception 'You do not have permission to manage requirements'; end if;
  select * into r from public.requirements where id = p_id for update;
  if not found then raise exception 'Requirement not found'; end if;
  v_to := case p_action when 'publish' then 'published' when 'reject' then 'rejected' when 'close' then 'closed'
                        when 'fulfil' then 'fulfilled' when 'reopen' then 'published' end;
  if v_to is null then raise exception 'Unknown action'; end if;
  if not ((p_action in ('publish', 'reject') and r.status = 'pending_review')
       or (p_action in ('close', 'fulfil') and r.status = 'published')
       or (p_action = 'reopen' and r.status in ('closed', 'fulfilled'))) then
    raise exception 'Cannot % a requirement that is %', p_action, r.status; end if;
  if p_action = 'reject' and length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Give the supplier a reason'; end if;
  update public.requirements set status = v_to, admin_note = coalesce(nullif(trim(coalesce(p_note, '')), ''), admin_note),
      reviewed_by = auth.uid(), reviewed_at = now(),
      published_at = case when v_to = 'published' then coalesce(published_at, now()) else published_at end,
      title = coalesce(nullif(trim(e->>'title'), ''), title),
      description = case when e ? 'description' then nullif(trim(e->>'description'), '') else description end,
      category_id = case when e ? 'category_id' then nullif(e->>'category_id', '')::uuid else category_id end,
      qty = case when e ? 'qty' then nullif(e->>'qty', '')::integer else qty end,
      unit = case when e ? 'unit' then nullif(trim(e->>'unit'), '') else unit end,
      target_price_paise = case when e ? 'target_price_paise' then nullif(e->>'target_price_paise', '')::bigint else target_price_paise end,
      needed_by = case when e ? 'needed_by' then nullif(e->>'needed_by', '')::date else needed_by end,
      response_by = case when e ? 'response_by' then nullif(e->>'response_by', '')::date else response_by end
    where id = p_id;
  perform public.log_transition('requirement', p_id, r.status, v_to, p_note);
  if p_action in ('publish', 'reopen') then
    perform public._notify_all_suppliers(r.posted_by_org, 'requirement_published', 'New requirement: ' || r.title,
      r.req_no || ' is open for responses.', p_id, 'req_pub:' || p_id || ':' || extract(epoch from now())::bigint);
  end if;
  if r.posted_by_org is not null then
    perform public.notify_org(r.posted_by_org, 'requirement_' || v_to,
      case p_action when 'publish' then 'Your requirement is live' when 'reject' then 'Requirement not published'
                    when 'fulfil' then 'Requirement marked fulfilled' else 'Requirement ' || v_to end,
      r.req_no || ' · ' || r.title || coalesce(' — ' || nullif(trim(coalesce(p_note, '')), ''), ''), 'requirement', p_id,
      'req_st:' || p_id || ':' || v_to || ':' || extract(epoch from now())::bigint);
  end if;
end $$;

-- the poster can cancel their own request while it is pending or live
create or replace function public.withdraw_requirement(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r public.requirements;
begin
  select * into r from public.requirements where id = p_id for update;
  if not found or r.posted_by_org is null or not public.is_org_member(r.posted_by_org) then raise exception 'Requirement not found'; end if;
  if r.status not in ('pending_review', 'published') then raise exception 'This request is already %', r.status; end if;
  update public.requirements set status = 'closed', admin_note = coalesce(admin_note, 'Withdrawn by poster') where id = p_id;
  perform public.log_transition('requirement', p_id, r.status, 'closed', 'withdrawn by poster');
  perform public.notify_admins('requirement_withdrawn', 'Requirement withdrawn', r.req_no || ' · ' || r.title, 'requirement', p_id, 'req_wd:' || p_id);
end $$;

create or replace function public.respond_to_requirement(
  p_req uuid, p_unit_price_paise bigint default null, p_lead_time_days integer default null,
  p_min_qty integer default null, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_org uuid := public.my_manufacturer_org(); r public.requirements; v_id uuid; v_new boolean;
begin
  if v_org is null then raise exception 'Only verified suppliers can respond'; end if;
  if not public.email_confirmed() then raise exception 'Confirm your email first'; end if;
  select * into r from public.requirements where id = p_req;
  if not found or r.status <> 'published' then raise exception 'This requirement is not open'; end if;
  if r.posted_by_org is not distinct from v_org then raise exception 'You cannot respond to your own requirement'; end if;
  if r.response_by is not null and r.response_by < current_date then raise exception 'The response deadline has passed'; end if;
  if p_unit_price_paise is null and length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Add a price or a note'; end if;
  select id into v_id from public.requirement_responses where requirement_id = p_req and org_id = v_org;
  v_new := v_id is null;
  if v_new then
    insert into public.requirement_responses (requirement_id, org_id, responded_by, unit_price_paise, lead_time_days, min_qty, note)
    values (p_req, v_org, auth.uid(), p_unit_price_paise, p_lead_time_days, p_min_qty, nullif(trim(coalesce(p_note, '')), '')) returning id into v_id;
  else
    update public.requirement_responses set unit_price_paise = p_unit_price_paise, lead_time_days = p_lead_time_days, min_qty = p_min_qty,
      note = nullif(trim(coalesce(p_note, '')), ''), responded_by = auth.uid(), status = 'submitted', shared_with_poster = false
    where id = v_id;
  end if;
  perform public.notify_admins('requirement_response', case when v_new then 'New response to ' else 'Updated response to ' end || r.req_no,
    r.title, 'requirement', p_req, 'req_resp:' || v_id || ':' || extract(epoch from now())::bigint);
  return v_id;
end $$;

create or replace function public.withdraw_response(p_req uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_org uuid := public.my_manufacturer_org();
begin
  update public.requirement_responses set status = 'withdrawn', shared_with_poster = false
   where requirement_id = p_req and org_id = v_org and status <> 'selected';
  if not found then raise exception 'No response to withdraw'; end if;
end $$;

-- admin: shortlist / select / decline, and decide what the poster may see (anonymised)
create or replace function public.admin_set_response(p_id uuid, p_status text default null, p_share boolean default null)
returns void language plpgsql security definer set search_path = public as $$
declare x public.requirement_responses; r public.requirements;
begin
  if not public.has_perm('suppliers') then raise exception 'You do not have permission to manage requirements'; end if;
  select * into x from public.requirement_responses where id = p_id for update;
  if not found then raise exception 'Response not found'; end if;
  select * into r from public.requirements where id = x.requirement_id;
  if p_status is not null and p_status not in ('submitted', 'shortlisted', 'selected', 'declined') then raise exception 'Bad status'; end if;
  if x.status = 'withdrawn' then raise exception 'The supplier withdrew this response'; end if;
  update public.requirement_responses set status = coalesce(p_status, status), shared_with_poster = coalesce(p_share, shared_with_poster) where id = p_id;
  if p_share is true and not x.shared_with_poster and r.posted_by_org is not null then
    perform public.notify_org(r.posted_by_org, 'requirement_response', 'A supplier can fulfil ' || r.req_no,
      'Admin shared a response to "' || r.title || '". Open Requirements to view it.', 'requirement', r.id, 'req_share:' || p_id);
  end if;
  if p_status is not null and p_status is distinct from x.status and p_status in ('selected', 'shortlisted') then
    perform public.notify_org(x.org_id, 'requirement_response', 'Your response was ' || p_status, r.req_no || ' · ' || r.title,
      'requirement', r.id, 'req_rs:' || p_id || ':' || p_status);
  end if;
end $$;

revoke all on function public.submit_requirement(text, text, text, uuid, integer, text, bigint, date),
  public.admin_create_requirement(text, text, text, uuid, integer, text, bigint, date, date, boolean),
  public.admin_review_requirement(uuid, text, text, jsonb), public.withdraw_requirement(uuid),
  public.respond_to_requirement(uuid, bigint, integer, integer, text), public.withdraw_response(uuid),
  public.admin_set_response(uuid, text, boolean) from public, anon;
grant execute on function public.submit_requirement(text, text, text, uuid, integer, text, bigint, date),
  public.admin_create_requirement(text, text, text, uuid, integer, text, bigint, date, date, boolean),
  public.admin_review_requirement(uuid, text, text, jsonb), public.withdraw_requirement(uuid),
  public.respond_to_requirement(uuid, bigint, integer, integer, text), public.withdraw_response(uuid),
  public.admin_set_response(uuid, text, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- C. SUPPORT CHAT (supplier / buyer  <->  any admin)
-- ---------------------------------------------------------------------
create sequence if not exists public.support_no_seq;
create table if not exists public.support_threads (
  id uuid primary key default gen_random_uuid(),
  thread_no text not null unique default 'SUP-' || lpad(nextval('public.support_no_seq')::text, 5, '0'),
  org_id uuid not null references public.organizations(id) on delete cascade,
  opened_by uuid references public.profiles(id),
  subject text not null check (length(trim(subject)) between 3 and 140),
  topic text not null default 'general' check (topic in ('general', 'account', 'batch', 'order', 'payment', 'product', 'requirement', 'other')),
  status text not null default 'open' check (status in ('open', 'closed')),
  assigned_to uuid references public.profiles(id),
  last_message_at timestamptz not null default now(),
  last_sender_side text not null default 'org' check (last_sender_side in ('org', 'admin')),
  org_read_at timestamptz,
  admin_read_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists support_threads_org_idx on public.support_threads (org_id, last_message_at desc);
create index if not exists support_threads_inbox_idx on public.support_threads (status, last_message_at desc);

create table if not exists public.support_messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.support_threads(id) on delete cascade,
  sender_id uuid references public.profiles(id),
  sender_side text not null check (sender_side in ('org', 'admin')),
  sender_name text,
  body text not null check (length(trim(body)) between 1 and 4000),
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists support_messages_thread_idx on public.support_messages (thread_id, created_at);

drop trigger if exists trg_support_threads_updated on public.support_threads;
create trigger trg_support_threads_updated before update on public.support_threads for each row execute function public.set_updated_at();

alter table public.support_threads enable row level security;
alter table public.support_messages enable row level security;
drop policy if exists sup_thread_select on public.support_threads;
create policy sup_thread_select on public.support_threads for select to authenticated
  using (public.is_admin() or public.is_org_member(org_id));
drop policy if exists sup_msg_select on public.support_messages;
create policy sup_msg_select on public.support_messages for select to authenticated
  using (exists (select 1 from public.support_threads t where t.id = thread_id and (public.is_admin() or public.is_org_member(t.org_id))));
revoke all on public.support_threads, public.support_messages from anon;
revoke insert, update, delete on public.support_threads, public.support_messages from authenticated;
grant select on public.support_threads, public.support_messages to authenticated;

create or replace function public._support_org()
returns uuid language sql stable security definer set search_path = public as $$
  select m.organization_id from public.organization_members m join public.organizations o on o.id = m.organization_id
  where m.profile_id = auth.uid() and public.is_active_user() and o.deleted_at is null
  order by (m.member_role = 'owner') desc, m.created_at limit 1;
$$;
revoke all on function public._support_org() from public, anon, authenticated;

create or replace function public.start_support_thread(p_subject text, p_body text, p_topic text default 'general')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_org uuid := public._support_org(); v_id uuid; v_no text; v_name text; v_org_name text;
begin
  if v_org is null then raise exception 'No organisation found for your account'; end if;
  if public.is_admin() then raise exception 'Admins reply from the Support Inbox'; end if;
  if not public.email_confirmed() then raise exception 'Confirm your email first'; end if;
  if (select count(*) from public.support_threads where org_id = v_org and status = 'open') >= 10 then
    raise exception 'You have 10 open conversations. Please continue in one of them.'; end if;
  select coalesce(full_name, 'Member') into v_name from public.profiles where id = auth.uid();
  select coalesce(trade_name, legal_name) into v_org_name from public.organizations where id = v_org;
  insert into public.support_threads (org_id, opened_by, subject, topic) values (v_org, auth.uid(), trim(p_subject), coalesce(p_topic, 'general'))
  returning id, thread_no into v_id, v_no;
  insert into public.support_messages (thread_id, sender_id, sender_side, sender_name, body) values (v_id, auth.uid(), 'org', v_name, p_body);
  update public.support_threads set org_read_at = now() where id = v_id;
  perform public.notify_admins('support_message', 'Support: ' || trim(p_subject), coalesce(v_org_name, 'A member') || ': ' || left(p_body, 120), 'support_thread', v_id, 'sup:' || v_id || ':first');
  return v_id;
end $$;

create or replace function public.send_support_message(p_thread uuid, p_body text)
returns uuid language plpgsql security definer set search_path = public as $$
declare t public.support_threads; v_admin boolean := public.is_admin(); v_id uuid; v_name text; v_side text;
begin
  select * into t from public.support_threads where id = p_thread for update;
  if not found or not (v_admin or public.is_org_member(t.org_id)) then raise exception 'Conversation not found'; end if;
  if not public.email_confirmed() then raise exception 'Confirm your email first'; end if;
  v_side := case when v_admin then 'admin' else 'org' end;
  select coalesce(full_name, case when v_admin then 'Support' else 'Member' end) into v_name from public.profiles where id = auth.uid();
  insert into public.support_messages (thread_id, sender_id, sender_side, sender_name, body) values (p_thread, auth.uid(), v_side, v_name, p_body)
  returning id into v_id;
  update public.support_threads set last_message_at = now(), last_sender_side = v_side, status = 'open',
      org_read_at = case when v_admin then org_read_at else now() end,
      admin_read_at = case when v_admin then now() else admin_read_at end,
      assigned_to = case when v_admin then coalesce(assigned_to, auth.uid()) else assigned_to end
    where id = p_thread;
  if v_admin then
    perform public.notify_org(t.org_id, 'support_message', 'Reply from MoqLess support', t.subject || ': ' || left(p_body, 120), 'support_thread', p_thread, 'sup:' || v_id);
  else
    perform public.notify_admins('support_message', 'Support: ' || t.subject, left(p_body, 140), 'support_thread', p_thread, 'sup:' || v_id);
  end if;
  return v_id;
end $$;

create or replace function public.mark_support_read(p_thread uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.support_threads;
begin
  select * into t from public.support_threads where id = p_thread;
  if not found then return; end if;
  if public.is_admin() then update public.support_threads set admin_read_at = now() where id = p_thread;
  elsif public.is_org_member(t.org_id) then update public.support_threads set org_read_at = now() where id = p_thread; end if;
end $$;

-- admin: close / reopen, and take or release a conversation
create or replace function public.admin_set_support_thread(p_thread uuid, p_status text default null, p_assign_me boolean default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  if p_status is not null and p_status not in ('open', 'closed') then raise exception 'Bad status'; end if;
  update public.support_threads set status = coalesce(p_status, status),
      assigned_to = case when p_assign_me is true then auth.uid() when p_assign_me is false then null else assigned_to end
    where id = p_thread;
  if not found then raise exception 'Conversation not found'; end if;
end $$;

-- badge count: admin = customers waiting for a reply; others = replies you have not read
create or replace function public.support_unread_count()
returns integer language sql stable security definer set search_path = public as $$
  select count(*)::integer from public.support_threads t
  where case when public.is_admin()
          then t.status = 'open' and t.last_sender_side = 'org' and (t.admin_read_at is null or t.admin_read_at < t.last_message_at)
          else public.is_org_member(t.org_id) and t.last_sender_side = 'admin' and (t.org_read_at is null or t.org_read_at < t.last_message_at) end;
$$;

revoke all on function public.start_support_thread(text, text, text), public.send_support_message(uuid, text),
  public.mark_support_read(uuid), public.admin_set_support_thread(uuid, text, boolean), public.support_unread_count() from public, anon;
grant execute on function public.start_support_thread(text, text, text), public.send_support_message(uuid, text),
  public.mark_support_read(uuid), public.admin_set_support_thread(uuid, text, boolean), public.support_unread_count() to authenticated;
