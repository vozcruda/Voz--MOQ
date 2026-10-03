-- =====================================================================
-- 016  Batches close on time, refunds can be finished, delivered orders complete
-- Run in the Supabase SQL editor (after 015). Safe to run twice.
--
--  1. Scheduled jobs: close_due_pools() and release_expired_reservations() existed
--     but nothing ran them, so a batch that missed its MOQ stayed open forever and
--     its buyers were never queued for a refund. pg_cron now runs both.
--  2. Refunds: nothing ever moved a reservation from refund_pending to refunded.
--     admin_mark_refunded() records the refund (and closes the order); tier
--     rebates (rebate_paise) get admin_mark_rebate_paid(); extra PayU payments on a
--     reservation that stays paid get admin_mark_attempt_refunded().
--  3. Fulfilment: a reservation becomes 'fulfilled' when its order is delivered,
--     so it leaves the buyer's Active list and shows under Completed.
--  4. Late bank transfers: admin_record_late_payment() records a payment on a
--     reservation that already expired. If the batch still has room it counts;
--     otherwise it is kept as refund_pending so it can be refunded.
-- =====================================================================

-- ---------- 1. scheduled jobs ----------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    -- cron.schedule with an existing job name updates that job, so this is safe to re-run
    perform cron.schedule('smallotz-release-expired-reservations', '*/5 * * * *',
                          'select public.release_expired_reservations()');
    perform cron.schedule('smallotz-close-due-batches', '*/10 * * * *',
                          'select public.close_due_pools()');
  else
    raise warning 'pg_cron is not available: schedule close_due_pools() and release_expired_reservations() another way';
  end if;
end $$;

-- ---------- 2. refunds and rebates ----------
alter table public.pool_commitments
  add column if not exists refund_ref      text,
  add column if not exists refunded_at     timestamptz,
  add column if not exists refunded_by     uuid references public.profiles(id),
  add column if not exists rebate_ref      text,
  add column if not exists rebate_paid_at  timestamptz,
  add column if not exists rebate_paid_by  uuid references public.profiles(id);

alter table public.payment_attempts drop constraint if exists payment_attempts_status_check;
alter table public.payment_attempts add constraint payment_attempts_status_check
  check (status in ('initiated', 'success', 'failed', 'pending', 'refund_needed', 'mismatch', 'refunded'));
alter table public.payment_attempts add column if not exists refund_ref text;
grant select (refund_ref) on public.payment_attempts to authenticated;

create or replace function public.admin_mark_refunded(p_commitment uuid, p_refund_ref text)
returns void language plpgsql security definer set search_path = public as $$
declare v_pool_id uuid; v_pool public.moq_pools; c public.pool_commitments;
begin
  if not public.has_perm('payments') then raise exception 'not allowed: payments permission required' using errcode = '42501'; end if;
  if nullif(trim(p_refund_ref), '') is null then raise exception 'a refund reference is required'; end if;
  select pool_id into v_pool_id from public.pool_commitments where id = p_commitment;
  if v_pool_id is null then raise exception 'reservation not found'; end if;
  select * into v_pool from public.moq_pools where id = v_pool_id for update;          -- pool first
  select * into c from public.pool_commitments where id = p_commitment for update;
  if c.status <> 'refund_pending' then
    raise exception 'only reservations waiting for a refund can be marked refunded (status %)', replace(c.status, '_', ' ');
  end if;

  update public.pool_commitments set status = 'refunded', refund_ref = trim(p_refund_ref),
      refunded_at = now(), refunded_by = auth.uid()
    where id = p_commitment;
  update public.orders set status = 'refunded', version = version + 1
    where commitment_id = p_commitment and status = 'refund_pending';
  -- the online payment this refund returns no longer needs attention on the gateway page
  update public.payment_attempts set status = 'refunded', refund_ref = trim(p_refund_ref)
    where commitment_id = p_commitment and status = 'refund_needed'
      and c.payment_ref is not null and 'PAYU-' || gateway_ref = c.payment_ref;
  perform public.log_transition('commitment', p_commitment, 'refund_pending', 'refunded', 'refund ref ' || trim(p_refund_ref));

  perform public.notify_org(c.buyer_org_id, 'refund_sent', 'Refund sent',
    'We refunded ₹' || to_char(c.amount_due_paise / 100.0, 'FM99,99,99,990.00') || ' for ' || v_pool.pool_no
      || ' (reference ' || trim(p_refund_ref) || '). Banks can take a few working days to show it.',
    'commitment', p_commitment, 'refund_sent:' || p_commitment::text);
end $$;

create or replace function public.admin_mark_rebate_paid(p_commitment uuid, p_ref text)
returns void language plpgsql security definer set search_path = public as $$
declare c public.pool_commitments; v_pool_no text;
begin
  if not public.has_perm('payments') then raise exception 'not allowed: payments permission required' using errcode = '42501'; end if;
  if nullif(trim(p_ref), '') is null then raise exception 'a payment reference is required'; end if;
  select * into c from public.pool_commitments where id = p_commitment for update;
  if not found then raise exception 'reservation not found'; end if;
  if coalesce(c.rebate_paise, 0) <= 0 then raise exception 'no rebate is owed on this reservation'; end if;
  if c.rebate_paid_at is not null then raise exception 'this rebate was already paid (reference %)', c.rebate_ref; end if;
  if c.status not in ('paid', 'fulfilled') then
    raise exception 'this reservation is % - refund it in full instead', replace(c.status, '_', ' ');
  end if;

  update public.pool_commitments set rebate_ref = trim(p_ref), rebate_paid_at = now(), rebate_paid_by = auth.uid()
    where id = p_commitment;
  perform public.log_transition('commitment', p_commitment, c.status, c.status,
    'rebate paid: ' || c.rebate_paise || ' paise, ref ' || trim(p_ref));

  select pool_no into v_pool_no from public.moq_pools where id = c.pool_id;
  perform public.notify_org(c.buyer_org_id, 'rebate_sent', 'Price drop refunded',
    'Your batch ' || v_pool_no || ' reached a cheaper price tier, so we refunded the difference of ₹'
      || to_char(c.rebate_paise / 100.0, 'FM99,99,99,990.00') || ' (reference ' || trim(p_ref) || ').',
    'commitment', p_commitment, 'rebate_sent:' || p_commitment::text);
end $$;

-- An extra online payment on a reservation that stays paid (e.g. the buyer paid twice).
-- A refund for the reservation's own payment goes through admin_mark_refunded instead.
create or replace function public.admin_mark_attempt_refunded(p_attempt uuid, p_refund_ref text)
returns void language plpgsql security definer set search_path = public as $$
declare a public.payment_attempts; c public.pool_commitments;
begin
  if not public.has_perm('payments') then raise exception 'not allowed: payments permission required' using errcode = '42501'; end if;
  if nullif(trim(p_refund_ref), '') is null then raise exception 'a refund reference is required'; end if;
  select * into a from public.payment_attempts where id = p_attempt for update;
  if not found then raise exception 'payment not found'; end if;
  if a.status not in ('refund_needed', 'mismatch') then
    raise exception 'only payments that need attention can be marked refunded (status %)', replace(a.status, '_', ' ');
  end if;
  select * into c from public.pool_commitments where id = a.commitment_id;
  if c.payment_ref is not null and c.payment_ref = 'PAYU-' || a.gateway_ref then
    raise exception 'this payment is the reservation''s own payment: use "Mark refunded" on the reservation instead';
  end if;

  update public.payment_attempts set status = 'refunded', refund_ref = trim(p_refund_ref) where id = p_attempt;
  perform public.log_transition('commitment', a.commitment_id, c.status, c.status,
    'extra payment ' || a.txnid || ' refunded, ref ' || trim(p_refund_ref));
  perform public.notify_org(a.buyer_org_id, 'refund_sent', 'Refund sent',
    'We refunded an extra payment of ₹' || to_char(a.amount_paise / 100.0, 'FM99,99,99,990.00')
      || ' (reference ' || trim(p_refund_ref) || ').',
    'commitment', a.commitment_id, 'refund_sent_attempt:' || a.id::text);
end $$;

-- ---------- 3. delivered orders complete the reservation ----------
create or replace function public.orders_fulfil_commitment()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('delivered', 'completed') and new.status is distinct from old.status then
    update public.pool_commitments set status = 'fulfilled' where id = new.commitment_id and status = 'paid';
    if found then
      perform public.log_transition('commitment', new.commitment_id, 'paid', 'fulfilled', 'order ' || new.status);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_orders_fulfil_commitment on public.orders;
create trigger trg_orders_fulfil_commitment after update of status on public.orders
  for each row execute function public.orders_fulfil_commitment();

-- orders delivered before this migration
update public.pool_commitments c set status = 'fulfilled'
  from public.orders o
  where o.commitment_id = c.id and o.status in ('delivered', 'completed') and c.status = 'paid';

-- ---------- 4. late bank transfers ----------
-- Returns what mark_commitment_paid returns: 'paid' when it counted toward the batch,
-- 'refund_pending' when it could not (batch closed or full) and must be refunded.
create or replace function public.admin_record_late_payment(p_commitment uuid, p_payment_ref text)
returns text language plpgsql security definer set search_path = public as $$
declare v_pool_id uuid; v_pool public.moq_pools; c public.pool_commitments;
begin
  if not public.has_perm('payments') then raise exception 'not allowed: payments permission required' using errcode = '42501'; end if;
  if nullif(trim(p_payment_ref), '') is null then raise exception 'payment reference required'; end if;
  select pool_id into v_pool_id from public.pool_commitments where id = p_commitment;
  if v_pool_id is null then raise exception 'reservation not found'; end if;
  select * into v_pool from public.moq_pools where id = v_pool_id for update;          -- pool first
  select * into c from public.pool_commitments where id = p_commitment for update;
  if c.status not in ('expired', 'cancelled') then
    raise exception 'this is for expired or cancelled reservations (status %)', replace(c.status, '_', ' ');
  end if;

  -- an expired reservation counts again if the batch is still taking orders and has room
  if c.status = 'expired'
     and v_pool.status in ('open', 'moq_reached')
     and v_pool.paid_qty + v_pool.reserved_qty + c.qty <= v_pool.target_qty
     and not exists (select 1 from public.pool_commitments o
                     where o.pool_id = c.pool_id and o.buyer_org_id = c.buyer_org_id and o.id <> c.id
                       and o.status in ('reserved', 'paid', 'fulfilled')) then
    update public.pool_commitments set status = 'reserved', reserved_until = now() where id = p_commitment;
    update public.moq_pools set reserved_qty = reserved_qty + c.qty, version = version + 1 where id = v_pool_id;
    perform public.log_transition('commitment', p_commitment, 'expired', 'reserved', 'late payment recorded');
  end if;

  return public.mark_commitment_paid(p_commitment, trim(p_payment_ref), c.amount_due_paise);
end $$;

revoke all on function public.admin_mark_refunded(uuid, text), public.admin_mark_rebate_paid(uuid, text),
  public.admin_mark_attempt_refunded(uuid, text), public.admin_record_late_payment(uuid, text),
  public.orders_fulfil_commitment() from public, anon, authenticated;
grant execute on function public.admin_mark_refunded(uuid, text), public.admin_mark_rebate_paid(uuid, text),
  public.admin_mark_attempt_refunded(uuid, text), public.admin_record_late_payment(uuid, text) to authenticated;
