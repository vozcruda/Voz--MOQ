-- =====================================================================
-- Voz Cruda | Migration 003: RFQs, inquiries, quotes, messaging
-- Requires 001_foundation_v2 and 002_catalogue_v2. STATUS: UNTESTED DRAFT
-- (v2: suspension-aware helpers, suspended organizations blocked).
--
-- ASSUMPTIONS BUILT IN (change them here before building the UI):
-- A1. Voz Cruda sits between buyer and manufacturer. Manufacturers see
--     RFQs and inquiries WITHOUT the buyer's identity. Buyers see offers
--     WITHOUT the manufacturer's identity. Conversations are always
--     between one organization and Voz Cruda, never buyer-to-manufacturer.
-- A2. A manufacturer's quote is Voz Cruda's COST (private). An admin sets
--     the buyer-facing offer prices by hand (admin_publish_offer). Automated
--     margin rules can replace this later.
-- A3. RFQs expire after 30 days (placeholder, not a decision).
-- =====================================================================

create sequence public.rfq_no_seq     start 1001;
create sequence public.inquiry_no_seq start 1001;
create sequence public.quote_no_seq   start 1001;

-- ---------------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------------

create table public.rfqs (
  id                      uuid primary key default gen_random_uuid(),
  rfq_no                  text not null unique
                            default ('RFQ-' || lpad(nextval('public.rfq_no_seq')::text, 6, '0')),
  buyer_org_id            uuid not null references public.organizations(id) on delete cascade,
  created_by              uuid references public.profiles(id) default auth.uid(),
  title                   text not null check (length(trim(title)) > 0),
  category_id             uuid references public.categories(id),
  material_id             uuid references public.materials(id),
  quantity                integer not null check (quantity > 0),
  gsm_min                 integer check (gsm_min is null or gsm_min between 60 and 800),
  colors                  text[] not null default '{}',
  customization_type_ids  uuid[] not null default '{}',
  private_label           boolean not null default false,
  target_unit_price_paise bigint check (target_unit_price_paise is null or target_unit_price_paise > 0),
  delivery_pincode        text check (delivery_pincode is null or delivery_pincode ~ '^[0-9]{6}$'),
  needed_by               date,
  notes                   text check (notes is null or length(notes) <= 4000),
  status                  text not null default 'open'
                            check (status in ('open','closed','awarded','expired','cancelled')),
  expires_at              timestamptz not null default (now() + interval '30 days'),
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  deleted_at              timestamptz
);
create index rfqs_buyer_idx  on public.rfqs (buyer_org_id);
create index rfqs_status_idx on public.rfqs (status, expires_at);

create table public.rfq_attachments (
  id      uuid primary key default gen_random_uuid(),
  rfq_id  uuid not null references public.rfqs(id) on delete cascade,
  file_id uuid not null references public.files(id),
  unique (rfq_id, file_id)
);

create table public.inquiries (
  id           uuid primary key default gen_random_uuid(),
  inquiry_no   text not null unique
                 default ('INQ-' || lpad(nextval('public.inquiry_no_seq')::text, 6, '0')),
  buyer_org_id uuid not null references public.organizations(id) on delete cascade,
  created_by   uuid references public.profiles(id) default auth.uid(),
  product_id   uuid not null references public.products(id),
  quantity     integer not null check (quantity > 0),
  message      text check (message is null or length(message) <= 2000),
  status       text not null default 'open' check (status in ('open','quoted','closed','declined')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index inquiries_buyer_idx   on public.inquiries (buyer_org_id);
create index inquiries_product_idx on public.inquiries (product_id);

create table public.inquiry_attachments (
  id         uuid primary key default gen_random_uuid(),
  inquiry_id uuid not null references public.inquiries(id) on delete cascade,
  file_id    uuid not null references public.files(id),
  unique (inquiry_id, file_id)
);

create table public.quotes (
  id                  uuid primary key default gen_random_uuid(),
  quote_no            text not null unique
                        default ('QUO-' || lpad(nextval('public.quote_no_seq')::text, 6, '0')),
  rfq_id              uuid references public.rfqs(id),
  inquiry_id          uuid references public.inquiries(id),
  buyer_org_id        uuid not null references public.organizations(id),
  manufacturer_org_id uuid not null references public.organizations(id),
  status              text not null default 'draft' check (status in
                        ('draft','submitted','offered','accepted','declined',
                         'not_selected','expired','withdrawn')),
  valid_until         timestamptz,
  current_revision_id uuid,
  version             integer not null default 1,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check ((rfq_id is not null)::int + (inquiry_id is not null)::int = 1)
);
create unique index quotes_rfq_mfr_uq on public.quotes (rfq_id, manufacturer_org_id) where rfq_id is not null;
create unique index quotes_inq_mfr_uq on public.quotes (inquiry_id, manufacturer_org_id) where inquiry_id is not null;
create index quotes_mfr_idx   on public.quotes (manufacturer_org_id, status);
create index quotes_buyer_idx on public.quotes (buyer_org_id, status);

create table public.quote_revisions (
  id                       uuid primary key default gen_random_uuid(),
  quote_id                 uuid not null references public.quotes(id) on delete cascade,
  revision_no              integer not null,
  created_by               uuid references public.profiles(id),
  moq_qty                  integer check (moq_qty is null or moq_qty > 0),
  lead_time_days           integer check (lead_time_days is null or lead_time_days > 0),
  sample_available         boolean not null default false,
  customization_cost_paise bigint not null default 0 check (customization_cost_paise >= 0),
  packaging_cost_paise     bigint not null default 0 check (packaging_cost_paise >= 0),
  shipping_estimate_paise  bigint not null default 0 check (shipping_estimate_paise >= 0),
  terms                    text,
  notes                    text,
  created_at               timestamptz not null default now(),
  unique (quote_id, revision_no)
);

alter table public.quotes
  add constraint quotes_current_revision_fk
  foreign key (current_revision_id) references public.quote_revisions(id)
  deferrable initially deferred;

-- Manufacturer prices per quantity band (Voz Cruda's cost). Private.
create table public.quote_price_tiers (
  id               uuid primary key default gen_random_uuid(),
  revision_id      uuid not null references public.quote_revisions(id) on delete cascade,
  min_qty          integer not null check (min_qty > 0),
  max_qty          integer,
  unit_price_paise bigint not null check (unit_price_paise > 0),
  check (max_qty is null or max_qty >= min_qty),
  exclude using gist (revision_id with =,
    int4range(min_qty, coalesce(max_qty, 1000000000), '[]') with &&)
);

-- Buyer-facing prices set by an admin. Buyers read them through buyer_offers only.
create table public.offer_price_tiers (
  id               uuid primary key default gen_random_uuid(),
  revision_id      uuid not null references public.quote_revisions(id) on delete cascade,
  min_qty          integer not null check (min_qty > 0),
  max_qty          integer,
  unit_price_paise bigint not null check (unit_price_paise > 0),
  check (max_qty is null or max_qty >= min_qty),
  exclude using gist (revision_id with =,
    int4range(min_qty, coalesce(max_qty, 1000000000), '[]') with &&)
);

-- Messaging: each conversation is one organization talking to Voz Cruda.
create table public.conversations (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  kind            text not null check (kind in ('buyer_support','manufacturer_support')),
  context_type    text not null default 'general'
                    check (context_type in ('general','inquiry','rfq','quote','order','dispute')),
  context_id      uuid,
  subject         text,
  status          text not null default 'open' check (status in ('open','closed')),
  created_by      uuid default auth.uid(),
  last_message_at timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index conversations_ctx_uq on public.conversations (organization_id, context_type, context_id)
  where status = 'open' and context_id is not null;

create table public.conversation_participants (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  profile_id      uuid not null references public.profiles(id) on delete cascade,
  last_read_at    timestamptz,
  muted           boolean not null default false,
  primary key (conversation_id, profile_id)
);

create table public.messages (
  id                uuid primary key default gen_random_uuid(),
  conversation_id   uuid not null references public.conversations(id) on delete cascade,
  sender_profile_id uuid references public.profiles(id),
  sender_side       text not null check (sender_side in ('organization','voz','system')),
  kind              text not null default 'user' check (kind in ('user','system')),
  body              text not null check (length(trim(body)) between 1 and 5000),
  ref_type          text check (ref_type is null or ref_type in ('product','rfq','inquiry','quote','order')),
  ref_id            uuid,   -- a hint only; the UI must re-check access before linking
  created_at        timestamptz not null default now()
);
create index messages_conv_idx on public.messages (conversation_id, created_at);

create table public.message_attachments (
  id         uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.messages(id) on delete cascade,
  file_id    uuid not null references public.files(id),
  unique (message_id, file_id)
);

create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references public.profiles(id) on delete cascade,
  type        text not null,
  title       text not null,
  body        text,
  entity_type text,
  entity_id   uuid,
  dedupe_key  text not null unique,
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index notifications_profile_idx on public.notifications (profile_id, read_at, created_at desc);

create table public.notification_preferences (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  type       text not null,
  channel    text not null check (channel in ('in_app','email','whatsapp')),
  enabled    boolean not null default true,
  primary key (profile_id, type, channel)
);

-- ---------------------------------------------------------------------
-- 2. HELPER FUNCTIONS
-- ---------------------------------------------------------------------

create or replace function public.owns_rfq(p_rfq uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_active_user() and exists (select 1 from public.rfqs r
    join public.organization_members m on m.organization_id = r.buyer_org_id
    where r.id = p_rfq and m.profile_id = auth.uid());
$$;

create or replace function public.owns_inquiry(p_inquiry uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_active_user() and exists (select 1 from public.inquiries i
    join public.organization_members m on m.organization_id = i.buyer_org_id
    where i.id = p_inquiry and m.profile_id = auth.uid());
$$;

create or replace function public.owns_revision(p_revision uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_active_user() and exists (select 1 from public.quote_revisions r
    join public.quotes q on q.id = r.quote_id
    join public.organization_members m on m.organization_id = q.manufacturer_org_id
    where r.id = p_revision and m.profile_id = auth.uid());
$$;

-- True only while the quote is a draft AND this is its current revision.
create or replace function public.quote_draft_editable(p_revision uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_active_user() and exists (select 1 from public.quote_revisions r
    join public.quotes q on q.id = r.quote_id and q.current_revision_id = r.id
    join public.organization_members m on m.organization_id = q.manufacturer_org_id
    where r.id = p_revision and q.status = 'draft' and m.profile_id = auth.uid());
$$;

create or replace function public.is_approved_manufacturer()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_active_user() and exists (select 1 from public.organization_members m
    join public.organizations o on o.id = m.organization_id
    where m.profile_id = auth.uid() and o.type = 'manufacturer'
      and o.verification_status = 'approved' and o.deleted_at is null and o.suspended_at is null);
$$;

create or replace function public.is_public_product(p_product uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.public_products where id = p_product);
$$;

create or replace function public.can_access_conversation(p_conv uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.conversations c
    where c.id = p_conv and (public.is_admin() or public.is_org_member(c.organization_id)));
$$;

create or replace function public.can_access_message(p_message uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.messages m
    where m.id = p_message and public.can_access_conversation(m.conversation_id));
$$;

-- Internal helpers, called only from other functions ----------------

create or replace function public.log_transition(
  p_type text, p_id uuid, p_from text, p_to text, p_reason text default null)
returns void language sql security definer set search_path = public as $$
  insert into public.state_transitions (entity_type, entity_id, from_status, to_status, actor, reason)
  values (p_type, p_id, p_from, p_to, auth.uid(), p_reason);
$$;

create or replace function public.notify_admins(
  p_type text, p_title text, p_body text, p_entity_type text, p_entity_id uuid, p_dedupe text)
returns void language sql security definer set search_path = public as $$
  insert into public.notifications (profile_id, type, title, body, entity_type, entity_id, dedupe_key)
  select a.profile_id, p_type, p_title, p_body, p_entity_type, p_entity_id, p_dedupe || ':' || a.profile_id::text
  from public.admin_users a
  where a.profile_id is distinct from auth.uid()
  on conflict (dedupe_key) do nothing;
$$;

create or replace function public.notify_org(
  p_org uuid, p_type text, p_title text, p_body text, p_entity_type text, p_entity_id uuid, p_dedupe text)
returns void language sql security definer set search_path = public as $$
  insert into public.notifications (profile_id, type, title, body, entity_type, entity_id, dedupe_key)
  select m.profile_id, p_type, p_title, p_body, p_entity_type, p_entity_id, p_dedupe || ':' || m.profile_id::text
  from public.organization_members m
  where m.organization_id = p_org and m.profile_id is distinct from auth.uid()
  on conflict (dedupe_key) do nothing;
$$;

-- ---------------------------------------------------------------------
-- 3. TRIGGERS
-- ---------------------------------------------------------------------
-- "current_user in (authenticated, anon)" means a direct client write.
-- Our SECURITY DEFINER functions run as the owner, so they pass through.

create or replace function public.rfqs_guard()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.status := 'open';
    return new;
  end if;
  if current_user in ('authenticated','anon') and not public.is_admin() then
    if old.status <> 'open' then
      raise exception 'only open requests can be changed' using errcode = '42501';
    end if;
    if new.status is distinct from old.status and new.status not in ('closed','cancelled') then
      raise exception 'status change % to % is not allowed', old.status, new.status
        using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

create or replace function public.inquiries_guard()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.status := 'open';
    return new;
  end if;
  if current_user in ('authenticated','anon') and not public.is_admin() then
    if not (old.status = 'open' and new.status = 'closed') then
      raise exception 'inquiries can only be closed by the buyer' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

create or replace function public.messages_guard()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated','anon') then
    new.sender_profile_id := auth.uid();
    new.sender_side := case when public.is_admin() then 'voz' else 'organization' end;
    new.kind := 'user';
  end if;
  return new;
end $$;

create or replace function public.messages_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_org uuid;
begin
  select organization_id into v_org from public.conversations where id = new.conversation_id;
  update public.conversations set last_message_at = new.created_at where id = new.conversation_id;

  if new.sender_side = 'voz' then
    perform public.notify_org(v_org, 'message', 'New message from Voz Cruda',
      left(new.body, 140), 'conversation', new.conversation_id, 'msg:' || new.id::text);
  elsif new.sender_side = 'organization' then
    perform public.notify_admins('message', 'New customer message',
      left(new.body, 140), 'conversation', new.conversation_id, 'msg:' || new.id::text);
  end if;
  return null;
end $$;

create or replace function public.notify_new_rfq()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.notify_admins('rfq_new', 'New RFQ', new.rfq_no || ': ' || new.title,
    'rfq', new.id, 'rfq_new:' || new.id::text);
  return null;
end $$;

create or replace function public.notify_new_inquiry()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.notify_admins('inquiry_new', 'New inquiry', new.inquiry_no,
    'inquiry', new.id, 'inquiry_new:' || new.id::text);
  return null;
end $$;

create trigger trg_a_rfqs_guard      before insert or update on public.rfqs
  for each row execute function public.rfqs_guard();
create trigger trg_b_rfqs_updated    before update on public.rfqs
  for each row execute function public.set_updated_at();
create trigger trg_rfqs_notify       after insert on public.rfqs
  for each row execute function public.notify_new_rfq();

create trigger trg_a_inquiries_guard before insert or update on public.inquiries
  for each row execute function public.inquiries_guard();
create trigger trg_b_inquiries_updated before update on public.inquiries
  for each row execute function public.set_updated_at();
create trigger trg_inquiries_notify  after insert on public.inquiries
  for each row execute function public.notify_new_inquiry();

create trigger trg_quotes_updated    before update on public.quotes
  for each row execute function public.set_updated_at();
create trigger trg_conversations_updated before update on public.conversations
  for each row execute function public.set_updated_at();
create trigger trg_messages_guard    before insert on public.messages
  for each row execute function public.messages_guard();
create trigger trg_messages_after    after insert on public.messages
  for each row execute function public.messages_after_insert();

create trigger trg_audit_rfqs        after insert or update or delete on public.rfqs
  for each row execute function public.audit_row_change();
create trigger trg_audit_inquiries   after insert or update or delete on public.inquiries
  for each row execute function public.audit_row_change();
create trigger trg_audit_quotes      after insert or update or delete on public.quotes
  for each row execute function public.audit_row_change();
create trigger trg_audit_cost_tiers  after insert or update or delete on public.quote_price_tiers
  for each row execute function public.audit_row_change();
create trigger trg_audit_offer_tiers after insert or update or delete on public.offer_price_tiers
  for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------
-- 4. PRIVACY VIEWS (identity-hiding, per assumption A1)
-- ---------------------------------------------------------------------
-- These run with the owner's rights and filter with auth.uid()-based helpers.

create or replace view public.manufacturer_rfqs as
select r.id as rfq_id, r.rfq_no, r.title, r.category_id, r.material_id, r.quantity,
       r.gsm_min, r.colors, r.customization_type_ids, r.private_label,
       left(r.delivery_pincode, 3) as region_prefix,
       r.needed_by, r.notes, r.expires_at, r.created_at
from public.rfqs r
where public.is_approved_manufacturer()
  and r.status = 'open' and r.deleted_at is null and r.expires_at > now();

create or replace view public.manufacturer_rfq_attachments as
select a.rfq_id, a.file_id
from public.rfq_attachments a
join public.manufacturer_rfqs mr on mr.rfq_id = a.rfq_id;
-- The signed-download function must confirm a row exists here before
-- issuing a URL for a buyer's file.

create or replace view public.manufacturer_inquiries as
select i.id as inquiry_id, i.inquiry_no, i.product_id, i.quantity, i.message,
       i.status, i.created_at
from public.inquiries i
join public.products p on p.id = i.product_id
where public.is_org_member(p.organization_id) and i.status in ('open','quoted');

create or replace view public.buyer_offers as
select q.id as quote_id, q.quote_no, q.rfq_id, q.inquiry_id, q.status, q.valid_until,
       r.revision_no, r.lead_time_days, r.sample_available,
       mo.verification_level as supplier_level,
       (select jsonb_agg(jsonb_build_object('min_qty', t.min_qty, 'max_qty', t.max_qty,
                'unit_price_paise', t.unit_price_paise) order by t.min_qty)
          from public.offer_price_tiers t where t.revision_id = q.current_revision_id) as price_tiers,
       q.created_at
from public.quotes q
join public.quote_revisions r on r.id = q.current_revision_id
join public.organizations mo on mo.id = q.manufacturer_org_id
where public.is_org_member(q.buyer_org_id)
  and q.status in ('offered','accepted','declined','expired');

-- ---------------------------------------------------------------------
-- 5. WORKFLOW FUNCTIONS (the only way quotes change state)
-- ---------------------------------------------------------------------

create or replace function public.start_quote(p_rfq uuid default null, p_inquiry uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_mfr uuid; v_buyer uuid; v_quote uuid; v_rev uuid;
  v_status text; v_exp timestamptz; v_prod_org uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if not public.email_confirmed() then raise exception 'email not verified' using errcode = '42501'; end if;
  if (p_rfq is null) = (p_inquiry is null) then
    raise exception 'provide exactly one of rfq or inquiry';
  end if;

  select m.organization_id into v_mfr
  from public.organization_members m join public.organizations o on o.id = m.organization_id
  where m.profile_id = auth.uid() and o.type = 'manufacturer'
    and o.verification_status = 'approved' and o.deleted_at is null and o.suspended_at is null
  order by (m.member_role = 'owner') desc, m.created_at limit 1;
  if v_mfr is null then
    raise exception 'approved manufacturer account required' using errcode = '42501';
  end if;

  if p_rfq is not null then
    select buyer_org_id, status, expires_at into v_buyer, v_status, v_exp
    from public.rfqs where id = p_rfq and deleted_at is null;
    if not found then raise exception 'rfq not found'; end if;
    if v_status <> 'open' or v_exp < now() then raise exception 'rfq is not open'; end if;
  else
    select i.buyer_org_id, i.status, p.organization_id into v_buyer, v_status, v_prod_org
    from public.inquiries i join public.products p on p.id = i.product_id
    where i.id = p_inquiry;
    if not found then raise exception 'inquiry not found'; end if;
    if v_prod_org <> v_mfr then
      raise exception 'this inquiry is not for your product' using errcode = '42501';
    end if;
    if v_status not in ('open','quoted') then raise exception 'inquiry is closed'; end if;
  end if;

  select id into v_quote from public.quotes
  where manufacturer_org_id = v_mfr
    and ((p_rfq is not null and rfq_id = p_rfq) or (p_inquiry is not null and inquiry_id = p_inquiry));
  if found then return v_quote; end if;   -- idempotent: one quote per manufacturer per request

  insert into public.quotes (rfq_id, inquiry_id, buyer_org_id, manufacturer_org_id)
  values (p_rfq, p_inquiry, v_buyer, v_mfr) returning id into v_quote;
  insert into public.quote_revisions (quote_id, revision_no, created_by)
  values (v_quote, 1, auth.uid()) returning id into v_rev;
  update public.quotes set current_revision_id = v_rev where id = v_quote;

  perform public.log_transition('quote', v_quote, null, 'draft');
  return v_quote;
end $$;

create or replace function public.submit_quote(p_quote uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_q public.quotes; v_rev public.quote_revisions;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  select * into v_q from public.quotes where id = p_quote for update;
  if not found or not public.is_org_member(v_q.manufacturer_org_id) then
    raise exception 'quote not found' using errcode = '42501';
  end if;
  if v_q.status <> 'draft' then raise exception 'only draft quotes can be submitted'; end if;

  select * into v_rev from public.quote_revisions where id = v_q.current_revision_id;
  if v_rev.moq_qty is null or v_rev.lead_time_days is null then
    raise exception 'MOQ and lead time are required';
  end if;
  if not exists (select 1 from public.quote_price_tiers where revision_id = v_rev.id) then
    raise exception 'add at least one price tier';
  end if;

  update public.quotes set status = 'submitted', version = version + 1 where id = p_quote;
  perform public.log_transition('quote', p_quote, 'draft', 'submitted');
  perform public.notify_admins('quote_submitted', 'Quote submitted',
    v_q.quote_no || ' is ready for pricing', 'quote', p_quote,
    'quote_submitted:' || p_quote::text || ':' || v_rev.revision_no::text);
end $$;

create or replace function public.revise_quote(p_quote uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_q public.quotes; v_old uuid; v_new uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  select * into v_q from public.quotes where id = p_quote for update;
  if not found or not public.is_org_member(v_q.manufacturer_org_id) then
    raise exception 'quote not found' using errcode = '42501';
  end if;
  if v_q.status not in ('submitted','offered') then
    raise exception 'only submitted or offered quotes can be revised';
  end if;
  v_old := v_q.current_revision_id;

  insert into public.quote_revisions (quote_id, revision_no, created_by, moq_qty, lead_time_days,
    sample_available, customization_cost_paise, packaging_cost_paise, shipping_estimate_paise, terms, notes)
  select quote_id, revision_no + 1, auth.uid(), moq_qty, lead_time_days, sample_available,
         customization_cost_paise, packaging_cost_paise, shipping_estimate_paise, terms, notes
  from public.quote_revisions where id = v_old
  returning id into v_new;

  insert into public.quote_price_tiers (revision_id, min_qty, max_qty, unit_price_paise)
  select v_new, min_qty, max_qty, unit_price_paise
  from public.quote_price_tiers where revision_id = v_old;

  update public.quotes
  set status = 'draft', current_revision_id = v_new, valid_until = null, version = version + 1
  where id = p_quote;
  perform public.log_transition('quote', p_quote, v_q.status, 'draft', 'revised');
  return v_new;
end $$;

create or replace function public.withdraw_quote(p_quote uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_q public.quotes;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  select * into v_q from public.quotes where id = p_quote for update;
  if not found or not public.is_org_member(v_q.manufacturer_org_id) then
    raise exception 'quote not found' using errcode = '42501';
  end if;
  if v_q.status not in ('draft','submitted','offered') then
    raise exception 'this quote can no longer be withdrawn';
  end if;
  update public.quotes set status = 'withdrawn', version = version + 1 where id = p_quote;
  perform public.log_transition('quote', p_quote, v_q.status, 'withdrawn');
end $$;

-- Admin turns a manufacturer quote (cost) into a buyer-facing offer (price).
-- p_tiers example: [{"min_qty":100,"max_qty":249,"unit_price_paise":34000}, ...]
create or replace function public.admin_publish_offer(
  p_quote uuid, p_valid_until timestamptz, p_tiers jsonb, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_q public.quotes; v_min_cost bigint;
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

  select min(unit_price_paise) into v_min_cost
  from public.quote_price_tiers where revision_id = v_q.current_revision_id;

  -- Floor check only: no offer price may be below the lowest manufacturer price.
  if exists (select 1 from jsonb_to_recordset(p_tiers)
               as t(min_qty int, max_qty int, unit_price_paise bigint)
             where t.min_qty is null or t.unit_price_paise is null
                or t.unit_price_paise < v_min_cost) then
    raise exception 'every offer price must be at least the lowest manufacturer price';
  end if;

  delete from public.offer_price_tiers where revision_id = v_q.current_revision_id;
  insert into public.offer_price_tiers (revision_id, min_qty, max_qty, unit_price_paise)
  select v_q.current_revision_id, t.min_qty, t.max_qty, t.unit_price_paise
  from jsonb_to_recordset(p_tiers) as t(min_qty int, max_qty int, unit_price_paise bigint);

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

create or replace function public.accept_offer(p_quote uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_q public.quotes;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if not public.email_confirmed() then raise exception 'email not verified' using errcode = '42501'; end if;
  select * into v_q from public.quotes where id = p_quote for update;
  if not found or not public.is_org_member(v_q.buyer_org_id) then
    raise exception 'offer not found' using errcode = '42501';
  end if;
  if v_q.status <> 'offered' or v_q.valid_until is null or v_q.valid_until <= now() then
    raise exception 'this offer is no longer available';
  end if;

  update public.quotes set status = 'accepted', version = version + 1 where id = p_quote;
  perform public.log_transition('quote', p_quote, 'offered', 'accepted');

  if v_q.rfq_id is not null then
    update public.rfqs set status = 'awarded' where id = v_q.rfq_id and status = 'open';
    with other as (
      update public.quotes set status = 'not_selected', version = version + 1
      where rfq_id = v_q.rfq_id and id <> p_quote
        and status in ('draft','submitted','offered')
      returning id, status)
    insert into public.state_transitions (entity_type, entity_id, from_status, to_status, actor, reason)
    select 'quote', id, null, 'not_selected', auth.uid(), 'another offer accepted' from other;
  else
    update public.inquiries set status = 'closed' where id = v_q.inquiry_id;
  end if;

  perform public.notify_admins('offer_accepted', 'Offer accepted',
    v_q.quote_no || ' was accepted', 'quote', p_quote, 'offer_accepted:' || p_quote::text);
end $$;

create or replace function public.decline_offer(p_quote uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_q public.quotes;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  select * into v_q from public.quotes where id = p_quote for update;
  if not found or not public.is_org_member(v_q.buyer_org_id) then
    raise exception 'offer not found' using errcode = '42501';
  end if;
  if v_q.status <> 'offered' then raise exception 'this offer cannot be declined'; end if;
  update public.quotes set status = 'declined', version = version + 1 where id = p_quote;
  perform public.log_transition('quote', p_quote, 'offered', 'declined', p_reason);
  perform public.notify_admins('offer_declined', 'Offer declined',
    v_q.quote_no || ' was declined', 'quote', p_quote, 'offer_declined:' || p_quote::text);
end $$;

-- Safe to run repeatedly (status guards make it idempotent). Wrap the
-- scheduled call with a job_runs row (job_name, run_key) as well.
create or replace function public.expire_stale_items()
returns void language plpgsql security definer set search_path = public as $$
begin
  with q as (
    update public.quotes set status = 'expired', version = version + 1
    where status = 'offered' and valid_until < now() returning id)
  insert into public.state_transitions (entity_type, entity_id, from_status, to_status, reason)
  select 'quote', id, 'offered', 'expired', 'validity ended' from q;

  with r as (
    update public.rfqs set status = 'expired'
    where status = 'open' and expires_at < now() returning id)
  insert into public.state_transitions (entity_type, entity_id, from_status, to_status, reason)
  select 'rfq', id, 'open', 'expired', 'request expired' from r;
end $$;

create or replace function public.open_conversation(
  p_org uuid, p_context_type text default 'general',
  p_context_id uuid default null, p_subject text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_kind text; v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if not public.email_confirmed() then raise exception 'email not verified' using errcode = '42501'; end if;
  if not (public.is_org_member(p_org) or public.is_admin()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select case type when 'buyer' then 'buyer_support' else 'manufacturer_support' end
    into v_kind from public.organizations where id = p_org and deleted_at is null;
  if v_kind is null then raise exception 'organization not found'; end if;

  if p_context_id is not null then
    select id into v_id from public.conversations
    where organization_id = p_org and context_type = p_context_type
      and context_id = p_context_id and status = 'open';
    if found then return v_id; end if;
  end if;

  insert into public.conversations (organization_id, kind, context_type, context_id, subject)
  values (p_org, v_kind, p_context_type, p_context_id, p_subject)
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- 6. ROW-LEVEL SECURITY
-- ---------------------------------------------------------------------

alter table public.rfqs                     enable row level security;
alter table public.rfq_attachments          enable row level security;
alter table public.inquiries                enable row level security;
alter table public.inquiry_attachments      enable row level security;
alter table public.quotes                   enable row level security;
alter table public.quote_revisions          enable row level security;
alter table public.quote_price_tiers        enable row level security;
alter table public.offer_price_tiers        enable row level security;
alter table public.conversations            enable row level security;
alter table public.conversation_participants enable row level security;
alter table public.messages                 enable row level security;
alter table public.message_attachments      enable row level security;
alter table public.notifications            enable row level security;
alter table public.notification_preferences enable row level security;

-- rfqs and inquiries: buyer side and admins only (manufacturers use views)
create policy rfqs_select on public.rfqs for select to authenticated
  using (public.is_org_member(buyer_org_id) or public.is_admin());
create policy rfqs_insert on public.rfqs for insert to authenticated
  with check (public.is_org_member(buyer_org_id) and public.email_confirmed()
    and (created_by is null or created_by = auth.uid())
    and exists (select 1 from public.organizations o where o.id = buyer_org_id and o.type = 'buyer'
                  and o.suspended_at is null and o.deleted_at is null));
create policy rfqs_update on public.rfqs for update to authenticated
  using (public.is_org_member(buyer_org_id)) with check (public.is_org_member(buyer_org_id));

create policy rfq_att_select on public.rfq_attachments for select to authenticated
  using (public.owns_rfq(rfq_id) or public.is_admin());
create policy rfq_att_insert on public.rfq_attachments for insert to authenticated
  with check (public.owns_rfq(rfq_id) and public.email_confirmed()
    and exists (select 1 from public.rfqs r join public.files f on f.owner_org_id = r.buyer_org_id
                where r.id = rfq_id and f.id = file_id and f.purpose = 'rfq'));
create policy rfq_att_delete on public.rfq_attachments for delete to authenticated
  using (public.owns_rfq(rfq_id));

create policy inquiries_select on public.inquiries for select to authenticated
  using (public.is_org_member(buyer_org_id) or public.is_admin());
create policy inquiries_insert on public.inquiries for insert to authenticated
  with check (public.is_org_member(buyer_org_id) and public.email_confirmed()
    and (created_by is null or created_by = auth.uid())
    and public.is_public_product(product_id)
    and exists (select 1 from public.organizations o where o.id = buyer_org_id and o.type = 'buyer'
                  and o.suspended_at is null and o.deleted_at is null));
create policy inquiries_update on public.inquiries for update to authenticated
  using (public.is_org_member(buyer_org_id)) with check (public.is_org_member(buyer_org_id));

create policy inq_att_select on public.inquiry_attachments for select to authenticated
  using (public.owns_inquiry(inquiry_id) or public.is_admin());
create policy inq_att_insert on public.inquiry_attachments for insert to authenticated
  with check (public.owns_inquiry(inquiry_id) and public.email_confirmed()
    and exists (select 1 from public.inquiries i join public.files f on f.owner_org_id = i.buyer_org_id
                where i.id = inquiry_id and f.id = file_id and f.purpose = 'rfq'));
create policy inq_att_delete on public.inquiry_attachments for delete to authenticated
  using (public.owns_inquiry(inquiry_id));

-- quotes: manufacturer side and admins. Buyers never touch these tables.
create policy quotes_select on public.quotes for select to authenticated
  using (public.is_org_member(manufacturer_org_id) or public.is_admin());
create policy revisions_select on public.quote_revisions for select to authenticated
  using (public.owns_revision(id) or public.is_admin());
create policy revisions_update on public.quote_revisions for update to authenticated
  using (public.quote_draft_editable(id)) with check (public.quote_draft_editable(id));
create policy cost_tiers_select on public.quote_price_tiers for select to authenticated
  using (public.owns_revision(revision_id) or public.is_admin());
create policy cost_tiers_write on public.quote_price_tiers for all to authenticated
  using (public.quote_draft_editable(revision_id))
  with check (public.quote_draft_editable(revision_id));
create policy offer_tiers_admin on public.offer_price_tiers for select to authenticated
  using (public.is_admin());

-- messaging
create policy conv_select on public.conversations for select to authenticated
  using (public.is_admin() or public.is_org_member(organization_id));
create policy conv_part_all on public.conversation_participants for all to authenticated
  using (profile_id = auth.uid() and public.can_access_conversation(conversation_id))
  with check (profile_id = auth.uid() and public.can_access_conversation(conversation_id));
create policy messages_select on public.messages for select to authenticated
  using (public.can_access_conversation(conversation_id));
create policy messages_insert on public.messages for insert to authenticated
  with check (public.can_access_conversation(conversation_id) and public.email_confirmed());
create policy msg_att_select on public.message_attachments for select to authenticated
  using (public.can_access_message(message_id));
create policy msg_att_insert on public.message_attachments for insert to authenticated
  with check (public.email_confirmed()
    and exists (select 1 from public.messages m, public.files f
                where m.id = message_id and m.sender_profile_id = auth.uid()
                  and f.id = file_id and f.uploaded_by = auth.uid() and f.purpose = 'message'));

-- notifications
create policy notif_select on public.notifications for select to authenticated
  using (profile_id = auth.uid());
create policy notif_update on public.notifications for update to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());
create policy notif_prefs_all on public.notification_preferences for all to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());

-- ---------------------------------------------------------------------
-- 7. PRIVILEGES (reset defaults, then grant only what is needed)
-- ---------------------------------------------------------------------

revoke all on public.rfqs, public.rfq_attachments, public.inquiries, public.inquiry_attachments,
  public.quotes, public.quote_revisions, public.quote_price_tiers, public.offer_price_tiers,
  public.conversations, public.conversation_participants, public.messages,
  public.message_attachments, public.notifications, public.notification_preferences,
  public.manufacturer_rfqs, public.manufacturer_rfq_attachments,
  public.manufacturer_inquiries, public.buyer_offers
  from anon, authenticated;
revoke all on sequence public.rfq_no_seq, public.inquiry_no_seq, public.quote_no_seq
  from anon, authenticated;

revoke execute on function
  public.owns_rfq(uuid), public.owns_inquiry(uuid), public.owns_revision(uuid),
  public.quote_draft_editable(uuid), public.is_approved_manufacturer(),
  public.is_public_product(uuid), public.can_access_conversation(uuid),
  public.can_access_message(uuid),
  public.log_transition(text, uuid, text, text, text),
  public.notify_admins(text, text, text, text, uuid, text),
  public.notify_org(uuid, text, text, text, text, uuid, text),
  public.start_quote(uuid, uuid), public.submit_quote(uuid), public.revise_quote(uuid),
  public.withdraw_quote(uuid), public.admin_publish_offer(uuid, timestamptz, jsonb, text),
  public.accept_offer(uuid), public.decline_offer(uuid, text),
  public.expire_stale_items(), public.open_conversation(uuid, text, uuid, text)
  from public, anon, authenticated;

grant usage, select on sequence public.rfq_no_seq, public.inquiry_no_seq to authenticated;

grant select on public.rfqs, public.rfq_attachments, public.inquiries, public.inquiry_attachments,
  public.quotes, public.quote_revisions, public.quote_price_tiers, public.offer_price_tiers,
  public.conversations, public.conversation_participants, public.messages,
  public.message_attachments, public.notifications, public.notification_preferences
  to authenticated;

grant insert (buyer_org_id, title, category_id, material_id, quantity, gsm_min, colors,
  customization_type_ids, private_label, target_unit_price_paise, delivery_pincode, needed_by, notes)
  on public.rfqs to authenticated;
grant update (title, category_id, material_id, quantity, gsm_min, colors, customization_type_ids,
  private_label, target_unit_price_paise, delivery_pincode, needed_by, notes, status)
  on public.rfqs to authenticated;
grant insert (rfq_id, file_id), delete on public.rfq_attachments to authenticated;

grant insert (buyer_org_id, product_id, quantity, message) on public.inquiries to authenticated;
grant update (status) on public.inquiries to authenticated;
grant insert (inquiry_id, file_id), delete on public.inquiry_attachments to authenticated;

grant update (moq_qty, lead_time_days, sample_available, customization_cost_paise,
  packaging_cost_paise, shipping_estimate_paise, terms, notes)
  on public.quote_revisions to authenticated;
grant insert (revision_id, min_qty, max_qty, unit_price_paise),
  update (min_qty, max_qty, unit_price_paise), delete
  on public.quote_price_tiers to authenticated;

grant insert (conversation_id, profile_id, last_read_at, muted),
  update (last_read_at, muted) on public.conversation_participants to authenticated;
grant insert (conversation_id, body, ref_type, ref_id) on public.messages to authenticated;
grant insert (message_id, file_id) on public.message_attachments to authenticated;
grant update (read_at) on public.notifications to authenticated;
grant insert, update, delete on public.notification_preferences to authenticated;

grant select on public.manufacturer_rfqs, public.manufacturer_rfq_attachments,
  public.manufacturer_inquiries, public.buyer_offers to authenticated;

grant execute on function
  public.owns_rfq(uuid), public.owns_inquiry(uuid), public.owns_revision(uuid),
  public.quote_draft_editable(uuid), public.is_approved_manufacturer(),
  public.is_public_product(uuid), public.can_access_conversation(uuid),
  public.can_access_message(uuid), public.start_quote(uuid, uuid), public.submit_quote(uuid),
  public.revise_quote(uuid), public.withdraw_quote(uuid),
  public.admin_publish_offer(uuid, timestamptz, jsonb, text),
  public.accept_offer(uuid), public.decline_offer(uuid, text),
  public.open_conversation(uuid, text, uuid, text)
  to authenticated;
grant execute on function public.expire_stale_items() to service_role;

-- ---------------------------------------------------------------------
-- SMOKE TESTS TO RUN BEFORE MOVING ON
-- 1. Buyer posts an RFQ: status forced to open, rfq_no generated, admins
--    get a notification. Buyer cannot set status to awarded/expired.
-- 2. Approved manufacturer sees the RFQ in manufacturer_rfqs with NO buyer
--    identity or target price; an unapproved manufacturer sees nothing.
-- 3. Manufacturer: start_quote (twice = same quote), edit revision and
--    tiers while draft, submit_quote fails without MOQ/lead time/tier.
-- 4. After submit, the manufacturer can no longer edit tiers directly;
--    revise_quote makes a new draft revision with tiers copied.
-- 5. Buyer sees nothing in buyer_offers until an admin publishes; the
--    view never shows the manufacturer's name or cost prices.
-- 6. admin_publish_offer rejects prices below the lowest cost, overlapping
--    tiers, and past validity dates; buyer gets a notification.
-- 7. accept_offer: only buyer members, only while offered and valid;
--    the RFQ becomes awarded and rival quotes become not_selected.
-- 8. Manufacturer cannot read another manufacturer's quotes or the
--    offer_price_tiers table.
-- 9. Messages: sender fields cannot be spoofed; a user outside the
--    conversation's organization cannot read or post.
-- 10. expire_stale_items() can run twice with the same result.
-- 11. A suspended user cannot see manufacturer_rfqs, edit quote drafts, post
--     messages, or accept offers; a suspended buyer organization cannot
--     create RFQs or inquiries.
-- =====================================================================
