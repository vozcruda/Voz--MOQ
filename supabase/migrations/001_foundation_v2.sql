-- =====================================================================
-- Voz Cruda | Migration 001: foundation (REVISED, COMPLETE)
-- Identity, consents, organizations, verification, files, audit, history.
-- STATUS: UNTESTED DRAFT. Run on a scratch Supabase project first.
-- NEVER run directly on production.
--
-- CHANGES FROM THE PREVIOUS REVISION
--  * Added: consents, organization_contacts, per-purpose file limits,
--    file type allowlist, deferred files/uploaded_at/expires_at,
--    job_runs.error_message, unique default address and primary contact.
--  * GSTIN/PAN are unique only among APPROVED organizations of the same
--    type, so nobody can squat a competitor's number while unverified.
--    Plain indexes support duplicate detection by admins.
--  * Approved organizations that change legal name, GSTIN or PAN go back
--    to 'pending' automatically.
--  * Suspended or deactivated profiles fail email_confirmed(),
--    is_org_member() and is_org_owner().
--  * Consents can only be written by functions; create_organization()
--    requires accepted terms and privacy (plus manufacturer terms).
--  * Default address / primary contact are changed through functions.
--  * files.owner_org_id uses ON DELETE RESTRICT: an organization that owns
--    files cannot be hard-deleted. Use deleted_at (soft delete).
-- =====================================================================

create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------------

create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  full_name    text,
  phone        text,
  status       text not null default 'active'
                 check (status in ('active','suspended','deactivated')),
  last_seen_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Admins are managed only with the service role.
create table public.admin_users (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- Append-only consent evidence. Written only by functions.
create table public.consents (
  id               uuid primary key default gen_random_uuid(),
  profile_id       uuid not null references public.profiles(id) on delete cascade,
  consent_type     text not null check (consent_type in
                     ('terms','privacy','manufacturer_terms','communications')),
  document_version text not null check (length(trim(document_version)) > 0),
  accepted         boolean not null,
  accepted_at      timestamptz not null default now(),
  ip_address       inet,
  user_agent       text
);
create index consents_profile_idx on public.consents (profile_id, consent_type, accepted_at desc);

create table public.organizations (
  id                  uuid primary key default gen_random_uuid(),
  type                text not null check (type in ('buyer','manufacturer')),
  legal_name          text not null check (length(trim(legal_name)) > 0),
  trade_name          text,
  gstin               text check (gstin is null
                        or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
  pan                 text check (pan is null or pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  business_type       text,
  website             text,
  verification_status text not null default 'pending'
                        check (verification_status in ('pending','approved','rejected')),
  verification_level  text not null default 'unverified'
                        check (verification_level in
                          ('unverified','document_verified','business_verified','factory_verified')),
  verified_at         timestamptz,
  verified_by         uuid references public.profiles(id),
  suspended_at        timestamptz,
  created_by          uuid references public.profiles(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz
);
-- Uniqueness only once approved (one business can be both buyer and manufacturer).
create unique index organizations_gstin_approved_uq on public.organizations (gstin, type)
  where gstin is not null and verification_status = 'approved' and deleted_at is null;
create unique index organizations_pan_approved_uq on public.organizations (pan, type)
  where pan is not null and verification_status = 'approved' and deleted_at is null;
-- Plain indexes so admins can spot duplicate claims before approving.
create index organizations_gstin_idx on public.organizations (gstin) where gstin is not null;
create index organizations_pan_idx   on public.organizations (pan)   where pan is not null;
create index organizations_type_status_idx on public.organizations (type, verification_status);

create table public.organization_members (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  profile_id      uuid not null references public.profiles(id) on delete cascade,
  member_role     text not null default 'staff' check (member_role in ('owner','staff')),
  invited_by      uuid references public.profiles(id),
  created_at      timestamptz not null default now(),
  unique (organization_id, profile_id)
);
create index organization_members_profile_idx  on public.organization_members (profile_id);
create index organization_members_org_role_idx on public.organization_members (organization_id, member_role);

create table public.organization_contacts (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  contact_type    text not null check (contact_type in
                    ('primary','sales','production','accounts','support')),
  name            text not null check (length(trim(name)) > 0),
  email           text,
  phone           text,
  designation     text,
  is_primary      boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz
);
create index organization_contacts_org_idx on public.organization_contacts (organization_id);
create unique index organization_contacts_primary_uq
  on public.organization_contacts (organization_id, contact_type)
  where is_primary and deleted_at is null;

create table public.addresses (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  kind            text not null check (kind in ('billing','shipping','factory','return')),
  line1           text not null,
  line2           text,
  city            text not null,
  state           text not null,
  gst_state_code  char(2),
  pincode         text not null check (pincode ~ '^[0-9]{6}$'),
  is_default      boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz
);
create index addresses_org_idx on public.addresses (organization_id);
create unique index addresses_default_uq on public.addresses (organization_id, kind)
  where is_default and deleted_at is null;

create table public.buyer_profiles (
  organization_id      uuid primary key references public.organizations(id) on delete cascade,
  buyer_kind           text check (buyer_kind in ('retail','b2b','d2c')),
  typical_order_qty    integer check (typical_order_qty is null or typical_order_qty > 0),
  preferred_categories text[] not null default '{}',
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create table public.manufacturer_profiles (
  organization_id    uuid primary key references public.organizations(id) on delete cascade,
  slug               text unique,     -- set by an admin at approval time
  about              text,
  years_operating    integer check (years_operating is null or years_operating >= 0),
  monthly_capacity   integer check (monthly_capacity is null or monthly_capacity > 0),
  min_moq            integer check (min_moq is null or min_moq > 0),
  standard_lead_days integer check (standard_lead_days is null or standard_lead_days > 0),
  sample_available   boolean not null default false,
  private_label      boolean not null default false,
  cities_served      text[] not null default '{}',
  seo_title          text,
  seo_description    text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- Rows are created by the server-side upload function (service role) after
-- it authenticates the user and validates type and size. Limits below are
-- PLACEHOLDERS: 5 MB images, 10 MB message files, 25 MB everything else.
create table public.files (
  id           uuid primary key default gen_random_uuid(),
  owner_org_id uuid not null references public.organizations(id) on delete restrict,
  uploaded_by  uuid references public.profiles(id) on delete set null,
  bucket       text not null check (bucket in ('vc-private','vc-public')),
  object_key   text not null,
  mime_type    text not null check (mime_type in
                 ('image/jpeg','image/png','image/webp','application/pdf')),
  size_bytes   bigint not null check (size_bytes > 0),
  checksum     text,
  purpose      text not null check (purpose in
                 ('product_image','document','rfq','message','proof','invoice','factory_photo')),
  visibility   text not null default 'private' check (visibility in ('public','private')),
  status       text not null default 'pending'
                 check (status in ('pending','uploaded','rejected','expired')),
  created_at   timestamptz not null default now(),
  uploaded_at  timestamptz,
  expires_at   timestamptz,
  unique (bucket, object_key),
  check ((visibility = 'public') = (bucket = 'vc-public')),
  check (size_bytes <= case purpose
           when 'product_image' then 5242880
           when 'factory_photo' then 5242880
           when 'message'       then 10485760
           else 26214400 end)
);
create index files_owner_idx  on public.files (owner_org_id);
create index files_status_idx on public.files (status, created_at);

create table public.manufacturer_documents (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  doc_type        text not null check (doc_type in ('gst','pan','factory_licence','udyam','other')),
  file_id         uuid not null references public.files(id) on delete restrict,
  status          text not null default 'submitted' check (status in ('submitted','approved','rejected')),
  reviewed_by     uuid references public.profiles(id),
  reviewed_at     timestamptz,
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index manufacturer_documents_org_idx    on public.manufacturer_documents (organization_id);
create index manufacturer_documents_status_idx on public.manufacturer_documents (status);

create table public.manufacturer_verifications (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  level           text not null check (level in
                    ('unverified','document_verified','business_verified','factory_verified')),
  status          text not null check (status in ('pending','approved','rejected')),
  decided_by      uuid references public.profiles(id),
  decided_at      timestamptz not null default now(),
  admin_notes     text
);
create index manufacturer_verifications_org_idx
  on public.manufacturer_verifications (organization_id, decided_at desc);

create table public.audit_logs (
  id               uuid primary key default gen_random_uuid(),
  actor_profile_id uuid,
  action           text not null,
  entity_type      text not null,
  entity_id        uuid,
  before           jsonb,
  after            jsonb,
  created_at       timestamptz not null default now()
);
create index audit_logs_entity_idx  on public.audit_logs (entity_type, entity_id);
create index audit_logs_created_idx on public.audit_logs (created_at);

create table public.state_transitions (
  id          uuid primary key default gen_random_uuid(),
  entity_type text not null,
  entity_id   uuid not null,
  from_status text,
  to_status   text not null,
  actor       uuid,
  reason      text,
  created_at  timestamptz not null default now()
);
create index state_transitions_entity_idx  on public.state_transitions (entity_type, entity_id);
create index state_transitions_created_idx on public.state_transitions (created_at);

create table public.app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_by uuid,
  updated_at timestamptz not null default now()
);

-- A job inserts (job_name, run_key) first; a duplicate means it already ran.
create table public.job_runs (
  id            uuid primary key default gen_random_uuid(),
  job_name      text not null,
  run_key       text not null,
  status        text not null default 'started' check (status in ('started','succeeded','failed')),
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,
  error_message text,
  unique (job_name, run_key)
);

-- ---------------------------------------------------------------------
-- 2. HELPER FUNCTIONS (used by RLS policies)
-- ---------------------------------------------------------------------

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admin_users where profile_id = auth.uid());
$$;

create or replace function public.is_active_user()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select status = 'active' from public.profiles where id = auth.uid()), false);
$$;

create or replace function public.is_org_member(p_org uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_active_user() and exists (
    select 1 from public.organization_members
    where organization_id = p_org and profile_id = auth.uid());
$$;

create or replace function public.is_org_owner(p_org uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_active_user() and exists (
    select 1 from public.organization_members
    where organization_id = p_org and profile_id = auth.uid() and member_role = 'owner');
$$;

-- Name kept because later migrations call it: true only for a confirmed
-- email AND an active (not suspended or deactivated) profile.
create or replace function public.email_confirmed()
returns boolean language sql stable security definer set search_path = public, auth as $$
  select coalesce((select u.email_confirmed_at is not null and p.status = 'active'
                   from auth.users u join public.profiles p on p.id = u.id
                   where u.id = auth.uid()), false);
$$;

-- Latest consent decision for that document type.
create or replace function public.has_accepted(p_profile uuid, p_type text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select accepted from public.consents
                   where profile_id = p_profile and consent_type = p_type
                   order by accepted_at desc, id desc limit 1), false);
$$;

-- ---------------------------------------------------------------------
-- 3. TRIGGERS
-- ---------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, new.raw_user_meta_data ->> 'full_name')
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create trigger trg_profiles_updated               before update on public.profiles
  for each row execute function public.set_updated_at();
create trigger trg_organizations_updated          before update on public.organizations
  for each row execute function public.set_updated_at();
create trigger trg_organization_contacts_updated  before update on public.organization_contacts
  for each row execute function public.set_updated_at();
create trigger trg_addresses_updated              before update on public.addresses
  for each row execute function public.set_updated_at();
create trigger trg_buyer_profiles_updated         before update on public.buyer_profiles
  for each row execute function public.set_updated_at();
create trigger trg_manufacturer_profiles_updated  before update on public.manufacturer_profiles
  for each row execute function public.set_updated_at();
create trigger trg_manufacturer_documents_updated before update on public.manufacturer_documents
  for each row execute function public.set_updated_at();

-- An approved organization that changes its legal identity must be
-- re-verified. Direct client edits only; our functions run as the owner.
create or replace function public.organizations_guard()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated','anon') and not public.is_admin()
     and old.verification_status = 'approved'
     and (new.legal_name, new.gstin, new.pan) is distinct from (old.legal_name, old.gstin, old.pan)
  then
    new.verification_status := 'pending';
    new.verification_level  := 'unverified';
    new.verified_at := null;
    new.verified_by := null;
  end if;
  return new;
end $$;

create trigger trg_a_organizations_guard before update on public.organizations
  for each row execute function public.organizations_guard();

create or replace function public.audit_row_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if tg_op = 'DELETE' then
    v_id := (to_jsonb(old) ->> 'id')::uuid;
  else
    v_id := (to_jsonb(new) ->> 'id')::uuid;
  end if;

  insert into public.audit_logs (actor_profile_id, action, entity_type, entity_id, before, after)
  values (auth.uid(), tg_op, tg_table_name, v_id,
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end);

  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

create trigger trg_audit_organizations
  after insert or update or delete on public.organizations
  for each row execute function public.audit_row_change();
create trigger trg_audit_members
  after insert or update or delete on public.organization_members
  for each row execute function public.audit_row_change();
create trigger trg_audit_mfr_documents
  after insert or update or delete on public.manufacturer_documents
  for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------
-- 4. PUBLIC VIEW (safe columns only: no GSTIN, PAN, contacts, documents)
-- ---------------------------------------------------------------------
-- Runs with the owner's rights on purpose, so anonymous visitors can see
-- approved manufacturers without any access to the base tables.

create or replace view public.public_manufacturers as
select
  o.id as organization_id,
  coalesce(o.trade_name, o.legal_name) as display_name,
  o.verification_level,
  m.slug, m.about, m.years_operating, m.monthly_capacity, m.min_moq,
  m.standard_lead_days, m.sample_available, m.private_label,
  m.cities_served, m.seo_title, m.seo_description
from public.organizations o
join public.manufacturer_profiles m on m.organization_id = o.id
where o.type = 'manufacturer'
  and o.verification_status = 'approved'
  and o.deleted_at is null
  and o.suspended_at is null;

-- ---------------------------------------------------------------------
-- 5. FUNCTIONS (the only ways to record consent, create organizations,
--    change verification or profile status, and set defaults)
-- ---------------------------------------------------------------------

-- Browser path: no IP or user agent (weaker evidence). Prefer routing
-- signup through your Cloudflare function and record_consent_server().
create or replace function public.record_consent(
  p_type text, p_version text, p_accepted boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if not public.is_active_user() then raise exception 'account is not active' using errcode = '42501'; end if;
  if p_type not in ('terms','privacy','manufacturer_terms','communications') then
    raise exception 'invalid consent type';
  end if;
  if nullif(trim(p_version), '') is null then raise exception 'document version required'; end if;
  insert into public.consents (profile_id, consent_type, document_version, accepted)
  values (auth.uid(), p_type, trim(p_version), p_accepted);
end $$;

-- Server path (service role): records the real IP and user agent.
create or replace function public.record_consent_server(
  p_profile uuid, p_type text, p_version text, p_accepted boolean,
  p_ip inet default null, p_user_agent text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_type not in ('terms','privacy','manufacturer_terms','communications') then
    raise exception 'invalid consent type';
  end if;
  if nullif(trim(p_version), '') is null then raise exception 'document version required'; end if;
  insert into public.consents (profile_id, consent_type, document_version, accepted, ip_address, user_agent)
  values (p_profile, p_type, trim(p_version), p_accepted, p_ip, left(p_user_agent, 500));
end $$;

create or replace function public.create_organization(
  p_type text, p_legal_name text,
  p_trade_name text default null, p_gstin text default null, p_pan text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_org uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if not public.email_confirmed() then
    raise exception 'email not verified or account not active' using errcode = '42501';
  end if;
  if p_type not in ('buyer','manufacturer') then raise exception 'invalid organization type'; end if;
  if nullif(trim(p_legal_name), '') is null then raise exception 'legal name is required'; end if;

  if not (public.has_accepted(auth.uid(), 'terms') and public.has_accepted(auth.uid(), 'privacy')) then
    raise exception 'accept the terms and privacy policy first' using errcode = '42501';
  end if;
  if p_type = 'manufacturer' and not public.has_accepted(auth.uid(), 'manufacturer_terms') then
    raise exception 'accept the manufacturer terms first' using errcode = '42501';
  end if;

  insert into public.organizations (type, legal_name, trade_name, gstin, pan, created_by)
  values (p_type, trim(p_legal_name), nullif(trim(p_trade_name), ''),
          nullif(trim(p_gstin), ''), nullif(trim(p_pan), ''), auth.uid())
  returning id into v_org;

  insert into public.organization_members (organization_id, profile_id, member_role)
  values (v_org, auth.uid(), 'owner');

  if p_type = 'buyer' then
    insert into public.buyer_profiles (organization_id) values (v_org);
  else
    insert into public.manufacturer_profiles (organization_id) values (v_org);
  end if;
  return v_org;
end $$;

create or replace function public.admin_set_verification(
  p_org uuid, p_status text, p_level text, p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_old text; v_type text; v_gstin text; v_pan text;
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
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

create or replace function public.admin_set_profile_status(
  p_profile uuid, p_status text, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_old text;
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  if p_status not in ('active','suspended','deactivated') then raise exception 'invalid status'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'a reason is required'; end if;
  if p_profile = auth.uid() then raise exception 'you cannot change your own status'; end if;
  select status into v_old from public.profiles where id = p_profile for update;
  if not found then raise exception 'profile not found'; end if;
  update public.profiles set status = p_status where id = p_profile;
  insert into public.state_transitions (entity_type, entity_id, from_status, to_status, actor, reason)
  values ('profile', p_profile, v_old, p_status, auth.uid(), p_reason);
end $$;

create or replace function public.set_default_address(p_address uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  a public.addresses;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  select * into a from public.addresses where id = p_address and deleted_at is null;
  if not found or not public.is_org_member(a.organization_id) then
    raise exception 'address not found' using errcode = '42501';
  end if;
  update public.addresses set is_default = false
    where organization_id = a.organization_id and kind = a.kind
      and is_default and id <> p_address and deleted_at is null;
  update public.addresses set is_default = true where id = p_address;
end $$;

create or replace function public.set_primary_contact(p_contact uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  c public.organization_contacts;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  select * into c from public.organization_contacts where id = p_contact and deleted_at is null;
  if not found or not public.is_org_member(c.organization_id) then
    raise exception 'contact not found' using errcode = '42501';
  end if;
  update public.organization_contacts set is_primary = false
    where organization_id = c.organization_id and contact_type = c.contact_type
      and is_primary and id <> p_contact and deleted_at is null;
  update public.organization_contacts set is_primary = true where id = p_contact;
end $$;

-- ---------------------------------------------------------------------
-- 6. ROW-LEVEL SECURITY
-- ---------------------------------------------------------------------

alter table public.profiles                   enable row level security;
alter table public.admin_users                enable row level security;
alter table public.consents                   enable row level security;
alter table public.organizations              enable row level security;
alter table public.organization_members       enable row level security;
alter table public.organization_contacts      enable row level security;
alter table public.addresses                  enable row level security;
alter table public.buyer_profiles             enable row level security;
alter table public.manufacturer_profiles      enable row level security;
alter table public.files                      enable row level security;
alter table public.manufacturer_documents     enable row level security;
alter table public.manufacturer_verifications enable row level security;
alter table public.audit_logs                 enable row level security;
alter table public.state_transitions          enable row level security;
alter table public.app_settings               enable row level security;
alter table public.job_runs                   enable row level security;
-- admin_users and job_runs: RLS on with no policies = service role only.

create policy profiles_select on public.profiles for select to authenticated
  using (
    id = auth.uid() or public.is_admin()
    or exists (
      select 1 from public.organization_members a
      join public.organization_members b on a.organization_id = b.organization_id
      where a.profile_id = auth.uid() and b.profile_id = profiles.id));
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy consents_select on public.consents for select to authenticated
  using (profile_id = auth.uid() or public.is_admin());

create policy organizations_select on public.organizations for select to authenticated
  using (public.is_org_member(id) or public.is_admin());
create policy organizations_update on public.organizations for update to authenticated
  using (public.is_org_owner(id)) with check (public.is_org_owner(id));

create policy members_select on public.organization_members for select to authenticated
  using (public.is_org_member(organization_id) or public.is_admin());
create policy members_insert on public.organization_members for insert to authenticated
  with check (public.is_org_owner(organization_id) and public.email_confirmed());
create policy members_delete on public.organization_members for delete to authenticated
  using (public.is_org_owner(organization_id) and profile_id <> auth.uid());

create policy contacts_select on public.organization_contacts for select to authenticated
  using (public.is_org_member(organization_id) or public.is_admin());
create policy contacts_insert on public.organization_contacts for insert to authenticated
  with check (public.is_org_member(organization_id) and public.email_confirmed());
create policy contacts_update on public.organization_contacts for update to authenticated
  using (public.is_org_member(organization_id)) with check (public.is_org_member(organization_id));

create policy addresses_select on public.addresses for select to authenticated
  using (public.is_org_member(organization_id) or public.is_admin());
create policy addresses_insert on public.addresses for insert to authenticated
  with check (public.is_org_member(organization_id) and public.email_confirmed());
create policy addresses_update on public.addresses for update to authenticated
  using (public.is_org_member(organization_id)) with check (public.is_org_member(organization_id));

create policy buyer_profiles_select on public.buyer_profiles for select to authenticated
  using (public.is_org_member(organization_id) or public.is_admin());
create policy buyer_profiles_update on public.buyer_profiles for update to authenticated
  using (public.is_org_member(organization_id)) with check (public.is_org_member(organization_id));
create policy mfr_profiles_select on public.manufacturer_profiles for select to authenticated
  using (public.is_org_member(organization_id) or public.is_admin());
create policy mfr_profiles_update on public.manufacturer_profiles for update to authenticated
  using (public.is_org_member(organization_id)) with check (public.is_org_member(organization_id));

-- files: read only for clients; the upload function writes with the service role
create policy files_select on public.files for select to authenticated
  using (public.is_org_member(owner_org_id) or public.is_admin());

create policy mfr_docs_select on public.manufacturer_documents for select to authenticated
  using (public.is_org_member(organization_id) or public.is_admin());
create policy mfr_docs_insert on public.manufacturer_documents for insert to authenticated
  with check (
    public.is_org_member(organization_id) and public.email_confirmed()
    and status = 'submitted'
    and exists (select 1 from public.files f
                where f.id = file_id and f.owner_org_id = organization_id));
create policy mfr_docs_admin_update on public.manufacturer_documents for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy verifications_select on public.manufacturer_verifications for select to authenticated
  using (public.is_admin());
create policy audit_select on public.audit_logs for select to authenticated
  using (public.is_admin());
create policy transitions_select on public.state_transitions for select to authenticated
  using (public.is_admin());

create policy settings_select on public.app_settings for select to authenticated using (true);
create policy settings_admin_update on public.app_settings for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------------
-- 7. PRIVILEGES (column-level, so clients cannot touch protected fields)
-- ---------------------------------------------------------------------

revoke all on all tables in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

grant select on public.profiles, public.consents, public.organizations,
  public.organization_members, public.organization_contacts, public.addresses,
  public.buyer_profiles, public.manufacturer_profiles, public.files,
  public.manufacturer_documents, public.manufacturer_verifications,
  public.audit_logs, public.state_transitions, public.app_settings
  to authenticated;

grant update (full_name, phone) on public.profiles to authenticated;
grant update (legal_name, trade_name, gstin, pan, business_type, website)
  on public.organizations to authenticated;
grant insert (organization_id, profile_id, member_role, invited_by)
  on public.organization_members to authenticated;
grant delete on public.organization_members to authenticated;
grant insert (organization_id, contact_type, name, email, phone, designation)
  on public.organization_contacts to authenticated;
grant update (contact_type, name, email, phone, designation, deleted_at)
  on public.organization_contacts to authenticated;              -- is_primary via set_primary_contact()
grant insert (organization_id, kind, line1, line2, city, state, gst_state_code, pincode)
  on public.addresses to authenticated;
grant update (kind, line1, line2, city, state, gst_state_code, pincode, deleted_at)
  on public.addresses to authenticated;                          -- is_default via set_default_address()
grant update (buyer_kind, typical_order_qty, preferred_categories)
  on public.buyer_profiles to authenticated;
grant update (about, years_operating, monthly_capacity, min_moq, standard_lead_days,
  sample_available, private_label, cities_served, seo_title, seo_description)
  on public.manufacturer_profiles to authenticated;
grant insert (organization_id, doc_type, file_id) on public.manufacturer_documents to authenticated;
grant update (status, reviewed_by, reviewed_at, notes) on public.manufacturer_documents to authenticated; -- admin-only via policy
grant update (value, updated_by, updated_at) on public.app_settings to authenticated;                 -- admin-only via policy

grant select on public.public_manufacturers to anon, authenticated;

grant execute on function public.is_admin(), public.is_active_user(),
  public.is_org_member(uuid), public.is_org_owner(uuid), public.email_confirmed()
  to authenticated;
grant execute on function public.record_consent(text, text, boolean),
  public.create_organization(text, text, text, text, text),
  public.admin_set_verification(uuid, text, text, text),
  public.admin_set_profile_status(uuid, text, text),
  public.set_default_address(uuid), public.set_primary_contact(uuid)
  to authenticated;
grant execute on function public.record_consent_server(uuid, text, text, boolean, inet, text)
  to service_role;

-- ---------------------------------------------------------------------
-- SMOKE TESTS TO RUN BEFORE MOVING ON (as different roles)
-- 1. Anonymous: public_manufacturers works; organizations, files,
--    contacts, consents and documents are all denied.
-- 2. create_organization fails without accepted terms + privacy (and
--    manufacturer terms for manufacturers), and without a confirmed email.
-- 3. User B cannot see user A's organization, members, addresses,
--    contacts or documents.
-- 4. User A cannot update verification_status/level directly (column
--    denied) nor call admin_set_verification.
-- 5. Two organizations with the same GSTIN can exist while pending; the
--    second approval fails with a clear message; the same GSTIN for a
--    buyer and a manufacturer is allowed.
-- 6. An approved organization that changes its GSTIN goes back to pending
--    and leaves public_manufacturers.
-- 7. Suspend a user with admin_set_profile_status: create_organization,
--    address inserts and org updates now fail for them.
-- 8. Setting a default address or primary contact twice swaps the old one;
--    inserting with is_default directly is not permitted.
-- 9. Consent rows cannot be inserted, updated or deleted by clients; a
--    later "accepted = false" row overrides an earlier accept.
-- 10. Files above the purpose limit, or with a disallowed MIME type or a
--     mismatched bucket/visibility, are rejected by the database.
-- =====================================================================
