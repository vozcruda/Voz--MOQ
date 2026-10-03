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

Then run `backend/008_product_editor.sql` (full product create/edit for admins: details, sizes/colours, price tiers).

## 009 — settings, disputes, manual PO / reservation, activity log
Run `backend/009_ops_settings_disputes_logs.sql` in the Supabase SQL editor (after 005–008).
- **Settings**: seeded defaults + `admin_set_setting` (needs the `settings` permission).
- **Disputes**: buyers raise (`open_dispute`), admins open on a buyer's behalf (`admin_open_dispute`), review, reply, internal notes, resolve. Orders can no longer be set to "disputed" without a dispute record.
- **Manual reservation**: `admin_create_reservation` (optionally already paid), `admin_add_address`, `admin_extend_reservation`.
- **Manual PO**: `admin_place_manual_po` — also works before MOQ (reason required); the normal MOQ flow shares the same code (`_place_po`).
- **Activity log**: more tables audited, exact timestamps, `admin_activity_feed` (search / filter / paging) → Admin → Activity Log.

## 010 — batch photos + PO details
Run `backend/010_batch_images_po_details.sql`. Adds `product_id` to `open_pools` (buyers now see photos and size/colour options on batches) and a `pool_images` view. Purchase Orders → Details shows the full PO (photo, cost, size×colour matrix, spec, buyer orders, history).

## 011 — notification controls
Run `backend/011_notification_controls.sql`: adds `dismissed_at`, `mark_all_notifications_read()` and `dismiss_notifications()`.

## 012 — supplier insights, requirements board, support chat
Run `backend/012_supplier_insights_requirements_support.sql` (after 011).
- **Market insights** (supplier → Market Insights): `supplier_market_insights(days)` and `supplier_price_benchmark(...)`. Anonymous aggregates by product group (category + material + GSM band + fit). A group appears only with ≥3 batches from ≥2 manufacturers; no supplier names; prices shown are catalogue (listed) prices only — never what buyers pay — as 25th/median/75th percentile.
- **Requirements** (supplier → Requirements, admin → Requirements): supplier posts → admin reviews/edits → publishes → every approved manufacturer is notified and can respond with price / lead time / min order. Poster identity is never shown to other suppliers (`requirement_board` view). The poster only sees responses admin explicitly shares, anonymised (`requirement_shared_responses`). Admins can also post directly.
- **Support chat** (supplier & buyer → Support / Help & Support, admin → Support Inbox): shared inbox, any admin can reply, unread badge, notifications both ways, resolve/reopen, "Take" a conversation.

## 013 — PayU online payments
Run `backend/013_payu_gateway.sql`, then deploy the two Edge Functions and set secrets:
```
supabase secrets set PAYU_KEY=... PAYU_SALT=... PAYU_ENV=test APP_URL=https://YOUR-DOMAIN
supabase functions deploy payu-initiate
supabase functions deploy payu-callback --no-verify-jwt
```
Buyer → Payments → **Pay now** opens PayU. The reservation is marked paid only after `payu-callback` verifies PayU's signature and confirms the status and amount with PayU's `verify_payment` API; the database then settles it once per transaction. Admin → **Online Payments** lists every attempt. Late or mismatched payments are flagged for refund, never counted. Bank transfer + manual "Mark paid" remain as a fallback.

## 014 — guest browsing
Run `backend/014_guest_browsing.sql`. Visitors who are not signed in can browse open batches (with prices and photos) and the product catalogue; supplier names/ids are not exposed (`guest_*` views; the old anon access to `open_pools` / `public_products` is revoked). Joining, reserving, paying and everything else still needs a signed-in buyer. When a guest taps "Sign in to join this batch" the intent is saved (1 hour) and the buyer lands back on that batch with the join form open after signing in or onboarding. Suppliers and admins sign in as before ("Manufacturer or admin? Sign in" in the guest sidebar).

## Branding (v17)
Smallotz brand assets live in `public/` (favicons, manifest, OG image) and `public/brand/` (logos). Colours: ink `#13233A`, marigold `#F2A33A` (buttons and highlights; text uses darker `--accent-text` for contrast). Font: Bricolage Grotesque.

## 015 — Remove batches and products
`backend/015_remove_batches_products.sql` adds `admin_remove_pool` / `admin_restore_pool` and `remove_product` / `admin_restore_product`. Removing hides (soft delete); nothing is destroyed and an admin can restore from the "Removed" filter. Live batches are cancelled first (paid buyers go to refund pending). Batches with a purchase order cannot be removed. Suppliers can remove their own products when they have no live batch.

## Install as an app (PWA)
`public/site.webmanifest` + `public/sw.js` (no caching, network only) make the site installable: Android Chrome → ⋮ → Install app; iPhone Safari → Share → Add to Home Screen.
