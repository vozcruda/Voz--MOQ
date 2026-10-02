-- =====================================================================
-- 013  PayU online payments
-- Run in the Supabase SQL editor (after 012). Safe to run twice.
--
-- Flow: buyer taps "Pay now" -> Edge Function payu-initiate asks the database to
-- create an attempt (amount comes from the reservation, never from the browser)
-- -> PayU hosted page -> payu-callback verifies PayU's signature AND calls PayU's
-- verify_payment API -> payu_record_result() marks the reservation paid.
-- Nothing is ever marked paid from the browser.
-- =====================================================================
create table if not exists public.payment_attempts (
  id uuid primary key default gen_random_uuid(),
  txnid text not null unique,
  commitment_id uuid not null references public.pool_commitments(id),
  buyer_org_id uuid not null references public.organizations(id),
  gateway text not null default 'payu',
  amount_paise bigint not null check (amount_paise > 0),
  status text not null default 'initiated'
    check (status in ('initiated', 'success', 'failed', 'pending', 'refund_needed', 'mismatch')),
  outcome text,
  gateway_ref text,
  mode text,
  bank_ref text,
  gateway_status text,
  message text,
  payload jsonb,
  initiated_by uuid default auth.uid(),
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists payment_attempts_commitment_idx on public.payment_attempts (commitment_id);
create index if not exists payment_attempts_created_idx on public.payment_attempts (created_at desc);
drop trigger if exists trg_payment_attempts_updated on public.payment_attempts;
create trigger trg_payment_attempts_updated before update on public.payment_attempts for each row execute function public.set_updated_at();

alter table public.payment_attempts enable row level security;
drop policy if exists pay_attempt_select on public.payment_attempts;
create policy pay_attempt_select on public.payment_attempts for select to authenticated
  using (public.has_perm('payments') or public.is_org_member(buyer_org_id));
revoke all on public.payment_attempts from anon, authenticated;
-- the raw gateway payload stays server-side
grant select (id, txnid, commitment_id, buyer_org_id, gateway, amount_paise, status, outcome, gateway_ref, mode, bank_ref,
              gateway_status, message, verified_at, created_at, updated_at) on public.payment_attempts to authenticated;

-- Called by the payu-initiate Edge Function AS THE BUYER (their JWT).
create or replace function public.payu_prepare_attempt(p_commitment uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare c public.pool_commitments; p public.moq_pools; v_tx text; v_name text; v_email text; v_phone text; v_info text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into c from public.pool_commitments where id = p_commitment;
  if not found or not public.is_org_member(c.buyer_org_id) then raise exception 'Reservation not found'; end if;
  if not public.email_confirmed() then raise exception 'Confirm your email first'; end if;
  if c.status <> 'reserved' then raise exception 'This reservation is already %', replace(c.status, '_', ' '); end if;
  if c.reserved_until <= now() then raise exception 'This reservation has expired'; end if;
  select * into p from public.moq_pools where id = c.pool_id;
  if p.status not in ('open', 'moq_reached') then raise exception 'This batch is no longer open'; end if;

  select coalesce(nullif(trim(split_part(coalesce(pr.full_name, ''), ' ', 1)), ''), 'Buyer'), u.email::text,
         nullif(regexp_replace(coalesce(pr.phone, ''), '[^0-9]', '', 'g'), '')
    into v_name, v_email, v_phone
    from auth.users u left join public.profiles pr on pr.id = u.id where u.id = auth.uid();
  v_name := left(regexp_replace(v_name, '[^A-Za-z0-9]', '', 'g'), 40); if v_name = '' then v_name := 'Buyer'; end if;
  v_info := left(regexp_replace(p.pool_no || ' ' || p.title, '[^A-Za-z0-9 ,.-]', '', 'g'), 100);
  v_tx := 'VC' || substr(md5(random()::text || clock_timestamp()::text || c.id::text), 1, 22);

  insert into public.payment_attempts (txnid, commitment_id, buyer_org_id, amount_paise) values (v_tx, c.id, c.buyer_org_id, c.amount_due_paise);
  return jsonb_build_object('txnid', v_tx, 'amount_paise', c.amount_due_paise, 'productinfo', v_info,
                            'firstname', v_name, 'email', v_email, 'phone', v_phone);
end $$;

-- Called ONLY by the payu-callback Edge Function (service role) after it has verified
-- the payment with PayU's server. Idempotent: a txnid is settled once.
create or replace function public.payu_record_result(
  p_txnid text, p_gateway_status text, p_amount_paise bigint, p_ref text, p_mode text,
  p_bank_ref text, p_message text, p_payload jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare a public.payment_attempts; v_res text; v_status text; v_pool text;
begin
  select * into a from public.payment_attempts where txnid = p_txnid for update;
  if not found then raise exception 'unknown transaction'; end if;
  if a.status in ('success', 'refund_needed') then return a.status; end if;   -- already settled

  select pl.pool_no into v_pool from public.pool_commitments c join public.moq_pools pl on pl.id = c.pool_id where c.id = a.commitment_id;

  if lower(coalesce(p_gateway_status, '')) = 'success' then
    if nullif(trim(coalesce(p_ref, '')), '') is null then raise exception 'gateway reference missing'; end if;
    if p_amount_paise is distinct from a.amount_paise then
      v_status := 'mismatch'; v_res := 'amount mismatch: expected ' || a.amount_paise || ', paid ' || coalesce(p_amount_paise::text, '?');
    else
      begin
        v_res := public.mark_commitment_paid(a.commitment_id, 'PAYU-' || p_ref, a.amount_paise);
        v_status := case when v_res in ('paid', 'already_paid') then 'success' else 'refund_needed' end;
      exception when others then
        v_status := 'mismatch'; v_res := sqlerrm;
      end;
    end if;
  elsif lower(coalesce(p_gateway_status, '')) in ('pending', 'in progress', 'initiated') then
    v_status := 'pending'; v_res := null;
  else
    v_status := 'failed'; v_res := null;
  end if;

  update public.payment_attempts set status = v_status, outcome = v_res, gateway_status = p_gateway_status,
      gateway_ref = coalesce(p_ref, gateway_ref), mode = coalesce(p_mode, mode), bank_ref = coalesce(p_bank_ref, bank_ref),
      message = left(p_message, 500), payload = p_payload, verified_at = now()
    where id = a.id;

  if v_status = 'success' then
    perform public.notify_org(a.buyer_org_id, 'payment_received', 'Payment received',
      'We received ₹' || to_char(a.amount_paise / 100.0, 'FM99,99,99,990.00') || ' for ' || coalesce(v_pool, 'your reservation') || '. Your order is confirmed.',
      'commitment', a.commitment_id, 'pay_ok:' || a.id::text);
    perform public.notify_admins('payment_received', 'Online payment received',
      coalesce(v_pool, 'Reservation') || ' · ₹' || to_char(a.amount_paise / 100.0, 'FM99,99,99,990.00') || ' via PayU', 'commitment', a.commitment_id, 'pay_ok_a:' || a.id::text);
  elsif v_status in ('refund_needed', 'mismatch') then
    perform public.notify_admins('payment_attention', 'Online payment needs attention',
      coalesce(v_pool, 'Reservation') || ' · ' || coalesce(v_res, v_status) || ' · txn ' || p_txnid, 'commitment', a.commitment_id, 'pay_bad:' || a.id::text);
    perform public.notify_org(a.buyer_org_id, 'payment_review', 'Payment under review',
      'We received your payment but need to check it before confirming. Our team will contact you.', 'commitment', a.commitment_id, 'pay_bad_b:' || a.id::text);
  end if;
  return v_status;
end $$;

revoke all on function public.payu_prepare_attempt(uuid), public.payu_record_result(text, text, bigint, text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.payu_prepare_attempt(uuid) to authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.payu_record_result(text, text, bigint, text, text, text, text, jsonb) to service_role;
  end if;
end $$;
