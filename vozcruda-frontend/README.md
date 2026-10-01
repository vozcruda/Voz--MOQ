# Voz Cruda frontend (React + Vite + Supabase)

Implements the `voz-cruda-prototype.html` design (Admin / Buyer / Supplier) on top of the Supabase schema (migrations 001–004b).

## Run
1. `cp .env.example .env` and set `VITE_SUPABASE_URL` (project root URL only) and `VITE_SUPABASE_ANON_KEY` (the `sb_publishable_…` key).
2. `npm install && npm run dev`

## Backend (run these once)
1. SQL editor: run `backend/005_admin_roles.sql` (after 001–004b). Existing admins become **super admins**.
2. Deploy the edge function that creates accounts on someone's behalf (needs the service key, which only exists server-side):
   `supabase functions deploy admin-create-user` — copy `backend/functions/admin-create-user/` into your project's `supabase/functions/` first.

## Roles
- **Super admin**: everything, and the only role that can give another admin the right to grant permissions, make/remove super admins, or remove admins.
- **Admin**: only the permissions they were given (products, quotes, batches, payments, orders, disputes, suppliers, users, settings). Everyone can view all data.
- **Admin with grant right**: can add admins and grant permissions, but only ones they hold themselves; can't touch super admins or other grantors.
- First super admin: insert your profile id into `admin_users`, then `update admin_users set is_super = true where profile_id = '…'`.
- (old note) **Admin**: a row in `admin_users`.
- **Buyer / Supplier**: chosen at sign-up; an organization is created via `create_organization` (email must be confirmed). Suppliers need admin approval (Suppliers page).

## Screens → schema
| Screen | Source |
|---|---|
| Browse Batches / Batch detail | `open_pools`, `open_pool_price_tiers` (admin: `moq_pools`, `pool_price_tiers`, `pool_commitments`) |
| Join Batch | `reserve_commitment`, `addresses`, `public_product_variants` |
| Reservations | `pool_commitments`, `mark_commitment_paid` |
| Purchase Orders | `purchase_orders`, `admin_place_purchase_order`, `update_po_status` |
| Products / Catalogue | `products`, `public_products`, `admin_review_product` |
| Suppliers / Users | `organizations`, `admin_set_verification` |
| Notifications | `notifications` |
| Admin Team / Create Account | `admin_list_admins`, `admin_grant_admin`, `admin_set_permissions`, `admin_set_grant_right`, `admin_create_org_for`, edge function `admin-create-user` |

## Admin features
Create Batch (`admin_create_pool` + `admin_open_pool`), batch actions (open / extend / cancel / generate PO), reservations (mark paid / cancel), purchase orders (status moves / cancel), Orders (status pipeline via `admin_set_order_status`), Disputes (`admin_resolve_dispute`), Suppliers (approve / reject / factory-verified / suspend / slug), Users (suspend), Settings (`app_settings`).

## Known gaps
- Payment proof upload (no `payments` table yet): buyers see instructions; admin marks paid with the UTR.
- Product images, creating a batch from an accepted RFQ quote (`admin_create_direct_pool`), RFQ/quotes/messaging screens (not in the prototype).
- Supplier names are hidden from buyers by design (schema exposes only the verification level).


## Product photos + admin-created products
Run `backend/006_verification_notifications.sql` then `backend/007_product_images_admin_products.sql` in the Supabase SQL editor.
Photos are stored in the public Supabase Storage bucket `vc-public` (created by 007), under `products/<organization_id>/`.
