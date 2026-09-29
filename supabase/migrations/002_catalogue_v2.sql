-- =====================================================================
-- Voz Cruda | Migration 002: catalogue
-- Categories, materials, capabilities, products, variants, images,
-- customizations, manufacturer price tiers, public views, search.
-- Requires 001_foundation_v2.sql. STATUS: UNTESTED DRAFT (v2: suspension-aware,
-- guard only restricts direct client writes, suspended organizations blocked).
--
-- PRICING NOTE: price_tiers holds the MANUFACTURER's price, which is
-- Voz Cruda's cost. It is private (owner + admin). Buyer-facing prices
-- (Voz Cruda's selling price) come in a later migration once the margin
-- rule is decided, so no price is exposed publicly here.
-- =====================================================================

create extension if not exists btree_gist;

-- ---------------------------------------------------------------------
-- 1. REFERENCE TABLES (admin-managed, publicly readable when active)
-- ---------------------------------------------------------------------

create table public.categories (
  id         uuid primary key default gen_random_uuid(),
  parent_id  uuid references public.categories(id) on delete set null,
  name       text not null,
  slug       text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  sort_order integer not null default 0,
  is_active  boolean not null default true
);

create table public.materials (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  composition text,
  fibre_type  text,
  is_active   boolean not null default true
);

create table public.customization_types (
  id        uuid primary key default gen_random_uuid(),
  name      text not null unique,
  is_active boolean not null default true
);

create table public.capabilities (
  id        uuid primary key default gen_random_uuid(),
  name      text not null unique,
  is_active boolean not null default true
);

create table public.manufacturer_capabilities (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  capability_id   uuid not null references public.capabilities(id) on delete cascade,
  primary key (organization_id, capability_id)
);

-- ---------------------------------------------------------------------
-- 2. PRODUCTS
-- ---------------------------------------------------------------------

create table public.products (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  category_id      uuid references public.categories(id),
  material_id      uuid references public.materials(id),
  title            text not null check (length(trim(title)) > 0),
  slug             text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  description      text,
  gsm              integer check (gsm is null or gsm between 60 and 800),
  fit              text,
  min_moq          integer check (min_moq is null or min_moq > 0),
  lead_time_days   integer check (lead_time_days is null or lead_time_days > 0),
  sample_available boolean not null default false,
  status           text not null default 'draft'
                     check (status in ('draft','pending','approved','rejected','archived')),
  rejected_reason  text,
  search_vector    tsvector,
  seo_title        text,
  seo_description  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz
);
create index products_org_idx      on public.products (organization_id);
create index products_status_idx   on public.products (status, category_id);
create index products_gsm_moq_idx  on public.products (gsm, min_moq);
create index products_search_idx   on public.products using gin (search_vector);

create table public.product_variants (
  id         uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  sku        text,
  size       text not null,
  color      text not null,
  is_active  boolean not null default true,
  unique (product_id, size, color)
);

create table public.product_images (
  id         uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  file_id    uuid not null references public.files(id),
  position   integer not null default 0,
  alt_text   text
);
create index product_images_product_idx on public.product_images (product_id, position);

create table public.product_customizations (
  product_id            uuid not null references public.products(id) on delete cascade,
  customization_type_id uuid not null references public.customization_types(id),
  extra_cost_paise      bigint not null default 0 check (extra_cost_paise >= 0),
  min_qty               integer check (min_qty is null or min_qty > 0),
  primary key (product_id, customization_type_id)
);

-- Manufacturer price bands (Voz Cruda's cost). max_qty NULL = open-ended.
create table public.price_tiers (
  id               uuid primary key default gen_random_uuid(),
  product_id       uuid not null references public.products(id) on delete cascade,
  min_qty          integer not null check (min_qty > 0),
  max_qty          integer,
  unit_price_paise bigint not null check (unit_price_paise > 0),
  created_at       timestamptz not null default now(),
  check (max_qty is null or max_qty >= min_qty),
  exclude using gist (
    product_id with =,
    int4range(min_qty, coalesce(max_qty, 1000000000), '[]') with &&
  )
);

-- ---------------------------------------------------------------------
-- 3. HELPER FUNCTIONS
-- ---------------------------------------------------------------------

create or replace function public.owns_product(p_product uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_active_user() and exists (
    select 1 from public.products p
    join public.organization_members m on m.organization_id = p.organization_id
    where p.id = p_product and m.profile_id = auth.uid());
$$;

-- ---------------------------------------------------------------------
-- 4. TRIGGERS (named so they fire in order: guard, search, updated_at)
-- ---------------------------------------------------------------------

create or replace function public.products_guard()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if current_user in ('authenticated','anon') then
      new.status := 'draft';            -- clients always start with a draft
      new.rejected_reason := null;
    end if;
    return new;
  end if;

  if current_user in ('authenticated','anon') and not public.is_admin() then
    new.rejected_reason := old.rejected_reason;   -- clients cannot edit this

    if new.status is distinct from old.status then
      if not (
           (old.status = 'draft'    and new.status = 'pending')
        or (old.status = 'pending'  and new.status = 'draft')
        or (old.status = 'rejected' and new.status = 'draft')
        or (old.status = 'archived' and new.status = 'draft')
        or (old.status in ('draft','rejected','approved') and new.status = 'archived')
      ) then
        raise exception 'status change % to % is not allowed', old.status, new.status
          using errcode = '42501';
      end if;

      if new.status = 'pending' then      -- minimum bar for review
        if new.category_id is null or new.min_moq is null then
          raise exception 'category and MOQ are required before submitting';
        end if;
        if not exists (select 1 from public.price_tiers where product_id = new.id) then
          raise exception 'add at least one price tier before submitting';
        end if;
        if not exists (select 1 from public.product_variants
                       where product_id = new.id and is_active) then
          raise exception 'add at least one size/colour variant before submitting';
        end if;
      end if;

    elsif old.status = 'approved'
      and (new.title, new.slug, new.description, new.category_id, new.material_id, new.gsm, new.fit)
          is distinct from
          (old.title, old.slug, old.description, old.category_id, old.material_id, old.gsm, old.fit)
    then
      new.status := 'pending';            -- content edits need re-review
    end if;
  end if;
  return new;
end $$;

create or replace function public.products_search_update()
returns trigger language plpgsql as $$
declare
  v_material text;
  v_category text;
begin
  select coalesce(name, '') || ' ' || coalesce(composition, '')
    into v_material from public.materials where id = new.material_id;
  select name into v_category from public.categories where id = new.category_id;

  new.search_vector :=
      setweight(to_tsvector('simple', coalesce(new.title, '')), 'A')
   || setweight(to_tsvector('simple', coalesce(v_category, '')), 'B')
   || setweight(to_tsvector('simple', coalesce(new.description, '')), 'C')
   || setweight(to_tsvector('simple', coalesce(v_material, '')), 'C');
  return new;
end $$;

create trigger trg_a_products_guard
  before insert or update on public.products
  for each row execute function public.products_guard();
create trigger trg_b_products_search
  before insert or update on public.products
  for each row execute function public.products_search_update();
create trigger trg_c_products_updated
  before update on public.products
  for each row execute function public.set_updated_at();

create trigger trg_audit_products
  after insert or update or delete on public.products
  for each row execute function public.audit_row_change();
create trigger trg_audit_price_tiers
  after insert or update or delete on public.price_tiers
  for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------
-- 5. ADMIN REVIEW FUNCTION
-- ---------------------------------------------------------------------

create or replace function public.admin_review_product(
  p_product uuid, p_status text, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_old text;
begin
  if not public.is_admin() then
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

-- ---------------------------------------------------------------------
-- 6. PUBLIC VIEWS (approved products of approved manufacturers only;
--    no prices, no costs, no documents)
-- ---------------------------------------------------------------------

create or replace view public.public_products as
select
  p.id, p.organization_id,
  coalesce(o.trade_name, o.legal_name) as display_name,
  o.verification_level,
  p.category_id, c.slug as category_slug, c.name as category_name,
  mt.name as material_name, mt.composition,
  p.title, p.slug, p.description, p.gsm, p.fit, p.min_moq,
  p.lead_time_days, p.sample_available,
  p.seo_title, p.seo_description, p.created_at
from public.products p
join public.organizations o on o.id = p.organization_id
left join public.categories c on c.id = p.category_id
left join public.materials mt on mt.id = p.material_id
where p.status = 'approved' and p.deleted_at is null
  and o.type = 'manufacturer' and o.verification_status = 'approved'
  and o.deleted_at is null and o.suspended_at is null;

create or replace view public.public_product_variants as
select v.product_id, v.size, v.color
from public.product_variants v
join public.public_products pp on pp.id = v.product_id
where v.is_active;

create or replace view public.public_product_images as
select i.product_id, i.position, i.alt_text, f.bucket, f.object_key
from public.product_images i
join public.files f on f.id = i.file_id
join public.public_products pp on pp.id = i.product_id
where f.visibility = 'public' and f.status = 'uploaded';

create or replace view public.public_product_customizations as
select pc.product_id, ct.name as customization
from public.product_customizations pc
join public.customization_types ct on ct.id = pc.customization_type_id
join public.public_products pp on pp.id = pc.product_id
where ct.is_active;

create or replace view public.public_manufacturer_capabilities as
select mc.organization_id, cp.name as capability
from public.manufacturer_capabilities mc
join public.capabilities cp on cp.id = mc.capability_id
join public.public_manufacturers pm on pm.organization_id = mc.organization_id
where cp.is_active;

-- ---------------------------------------------------------------------
-- 7. SEARCH (Postgres full text plus filters; no AI needed yet)
-- ---------------------------------------------------------------------

create or replace function public.search_products(
  p_query    text    default null,
  p_category uuid    default null,
  p_min_gsm  integer default null,
  p_max_moq  integer default null,
  p_limit    integer default 20,
  p_offset   integer default 0)
returns table (
  id uuid, organization_id uuid, display_name text, title text, slug text,
  category_name text, gsm integer, min_moq integer, lead_time_days integer, rank real)
language sql stable security definer set search_path = public as $$
  select pp.id, pp.organization_id, pp.display_name, pp.title, pp.slug,
         pp.category_name, pp.gsm, pp.min_moq, pp.lead_time_days,
         case when nullif(trim(p_query), '') is null then 0::real
              else ts_rank(p.search_vector, websearch_to_tsquery('simple', p_query)) end as rank
  from public.public_products pp
  join public.products p on p.id = pp.id
  where (nullif(trim(p_query), '') is null
         or p.search_vector @@ websearch_to_tsquery('simple', p_query))
    and (p_category is null or pp.category_id = p_category)
    and (p_min_gsm  is null or pp.gsm >= p_min_gsm)
    and (p_max_moq  is null or pp.min_moq <= p_max_moq)
  order by rank desc, pp.created_at desc
  limit least(greatest(p_limit, 1), 50)
  offset greatest(p_offset, 0);
$$;

-- ---------------------------------------------------------------------
-- 8. ROW-LEVEL SECURITY
-- ---------------------------------------------------------------------

alter table public.categories                enable row level security;
alter table public.materials                 enable row level security;
alter table public.customization_types       enable row level security;
alter table public.capabilities              enable row level security;
alter table public.manufacturer_capabilities enable row level security;
alter table public.products                  enable row level security;
alter table public.product_variants          enable row level security;
alter table public.product_images            enable row level security;
alter table public.product_customizations    enable row level security;
alter table public.price_tiers               enable row level security;

-- reference tables: everyone reads active rows; admins manage everything
create policy categories_read on public.categories for select to anon, authenticated using (is_active);
create policy categories_admin on public.categories for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy materials_read on public.materials for select to anon, authenticated using (is_active);
create policy materials_admin on public.materials for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy custtypes_read on public.customization_types for select to anon, authenticated using (is_active);
create policy custtypes_admin on public.customization_types for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy capabilities_read on public.capabilities for select to anon, authenticated using (is_active);
create policy capabilities_admin on public.capabilities for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- manufacturer_capabilities
create policy mfr_caps_select on public.manufacturer_capabilities for select to authenticated
  using (public.is_org_member(organization_id) or public.is_admin());
create policy mfr_caps_insert on public.manufacturer_capabilities for insert to authenticated
  with check (
    public.is_org_member(organization_id) and public.email_confirmed()
    and exists (select 1 from public.organizations o
                where o.id = organization_id and o.type = 'manufacturer'
                  and o.suspended_at is null and o.deleted_at is null));
create policy mfr_caps_delete on public.manufacturer_capabilities for delete to authenticated
  using (public.is_org_member(organization_id));

-- products (owners see all their own; the public uses the views)
create policy products_select on public.products for select to authenticated
  using (public.is_org_member(organization_id) or public.is_admin());
create policy products_insert on public.products for insert to authenticated
  with check (
    public.is_org_member(organization_id) and public.email_confirmed()
    and exists (select 1 from public.organizations o
                where o.id = organization_id and o.type = 'manufacturer'
                  and o.suspended_at is null and o.deleted_at is null));
create policy products_update on public.products for update to authenticated
  using (public.is_org_member(organization_id))
  with check (public.is_org_member(organization_id));

-- child tables: access follows product ownership
create policy variants_select on public.product_variants for select to authenticated
  using (public.owns_product(product_id) or public.is_admin());
create policy variants_write on public.product_variants for all to authenticated
  using (public.owns_product(product_id))
  with check (public.owns_product(product_id) and public.email_confirmed());

create policy images_select on public.product_images for select to authenticated
  using (public.owns_product(product_id) or public.is_admin());
create policy images_write on public.product_images for all to authenticated
  using (public.owns_product(product_id))
  with check (
    public.owns_product(product_id) and public.email_confirmed()
    and exists (select 1 from public.products p
                join public.files f on f.owner_org_id = p.organization_id
                where p.id = product_id and f.id = file_id and f.purpose = 'product_image'));

create policy custom_select on public.product_customizations for select to authenticated
  using (public.owns_product(product_id) or public.is_admin());
create policy custom_write on public.product_customizations for all to authenticated
  using (public.owns_product(product_id))
  with check (public.owns_product(product_id) and public.email_confirmed());

create policy tiers_select on public.price_tiers for select to authenticated
  using (public.owns_product(product_id) or public.is_admin());
create policy tiers_write on public.price_tiers for all to authenticated
  using (public.owns_product(product_id))
  with check (public.owns_product(product_id) and public.email_confirmed());

-- ---------------------------------------------------------------------
-- 9. PRIVILEGES (new objects get default grants, so reset them explicitly)
-- ---------------------------------------------------------------------

revoke all on public.categories, public.materials, public.customization_types,
  public.capabilities, public.manufacturer_capabilities, public.products,
  public.product_variants, public.product_images, public.product_customizations,
  public.price_tiers, public.public_products, public.public_product_variants,
  public.public_product_images, public.public_product_customizations,
  public.public_manufacturer_capabilities
  from anon, authenticated;
revoke execute on function public.owns_product(uuid), public.admin_review_product(uuid, text, text),
  public.search_products(text, uuid, integer, integer, integer, integer)
  from public, anon, authenticated;

-- reference tables
grant select on public.categories, public.materials, public.customization_types,
  public.capabilities to anon, authenticated;
grant insert, update, delete on public.categories, public.materials,
  public.customization_types, public.capabilities to authenticated;  -- admin only via policy

-- owner-managed tables
grant select on public.manufacturer_capabilities, public.products, public.product_variants,
  public.product_images, public.product_customizations, public.price_tiers to authenticated;
grant insert, delete on public.manufacturer_capabilities to authenticated;
grant insert (organization_id, category_id, material_id, title, slug, description, gsm, fit,
  min_moq, lead_time_days, sample_available, seo_title, seo_description)
  on public.products to authenticated;
grant update (category_id, material_id, title, slug, description, gsm, fit, min_moq,
  lead_time_days, sample_available, status, seo_title, seo_description)
  on public.products to authenticated;                                -- status changes checked by trigger
grant insert, update, delete on public.product_variants, public.product_images,
  public.product_customizations, public.price_tiers to authenticated;

-- public read surface
grant select on public.public_products, public.public_product_variants,
  public.public_product_images, public.public_product_customizations,
  public.public_manufacturer_capabilities to anon, authenticated;

grant execute on function public.owns_product(uuid) to authenticated;
grant execute on function public.admin_review_product(uuid, text, text) to authenticated;
grant execute on function public.search_products(text, uuid, integer, integer, integer, integer)
  to anon, authenticated;

-- ---------------------------------------------------------------------
-- 10. STARTER DATA (editable by admins; adjust freely)
-- ---------------------------------------------------------------------

insert into public.categories (name, slug, sort_order) values
  ('T-shirts', 't-shirts', 10),
  ('Hoodies and sweatshirts', 'hoodies-sweatshirts', 20),
  ('Polo shirts', 'polo-shirts', 30),
  ('Joggers and trousers', 'joggers-trousers', 40),
  ('Jackets', 'jackets', 50)
on conflict (slug) do nothing;

insert into public.categories (parent_id, name, slug, sort_order)
select id, 'Oversized T-shirts', 'oversized-t-shirts', 11 from public.categories where slug = 't-shirts'
on conflict (slug) do nothing;

insert into public.customization_types (name) values
  ('Screen print'), ('DTG print'), ('Embroidery'),
  ('Neck label'), ('Wash care label'), ('Custom packaging')
on conflict (name) do nothing;

insert into public.capabilities (name) values
  ('Screen printing'), ('DTG printing'), ('Embroidery'), ('Private label'), ('Sampling')
on conflict (name) do nothing;

insert into public.materials (name, composition, fibre_type) values
  ('Cotton', '100% cotton', 'cotton'),
  ('Cotton blend', 'cotton-polyester blend', 'blend'),
  ('Polyester', '100% polyester', 'synthetic')
on conflict (name) do nothing;

-- ---------------------------------------------------------------------
-- SMOKE TESTS TO RUN BEFORE MOVING ON
-- 1. Anonymous: search_products() and public_products work; products,
--    price_tiers and files are denied. No price appears anywhere public.
-- 2. Verified manufacturer creates a product: status is forced to draft.
-- 3. Submit without a price tier, category or variant: rejected.
-- 4. Manufacturer cannot set status to approved/rejected, or edit
--    rejected_reason; other manufacturers cannot see or edit the product.
-- 5. Admin runs admin_review_product: only from pending; a reason is
--    required to reject; a state_transitions row and audit rows appear.
-- 6. Editing the title of an approved product sends it back to pending
--    and removes it from public_products.
-- 7. Overlapping price tiers (e.g. 1-100 and 50-200) are rejected.
-- 8. An approved product disappears publicly if its manufacturer is
--    suspended or its verification is no longer approved.
-- 9. A buyer organization cannot create products.
-- 10. Adding an image that points at another organization's file fails.
-- 11. After admin_set_profile_status('suspended'), that user can no longer edit
--     products, tiers, variants, images or capabilities; a suspended
--     organization cannot create products.
-- =====================================================================
