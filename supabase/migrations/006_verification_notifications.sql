-- 006: notify an organization's members when admin approves / rejects / re-levels it.
-- Run once in the Supabase SQL editor. Safe to re-run (create or replace).

create or replace function public.admin_set_verification(
  p_org uuid, p_status text, p_level text, p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_old text; v_old_level text; v_type text; v_gstin text; v_pan text;
  v_title text; v_body text;
begin
  if not public.has_perm('suppliers') then raise exception 'admin only' using errcode = '42501'; end if;
  if p_status not in ('pending','approved','rejected') then raise exception 'invalid status'; end if;
  if p_level not in ('unverified','document_verified','business_verified','factory_verified') then
    raise exception 'invalid level';
  end if;
  if p_status = 'approved' and p_level = 'unverified' then
    raise exception 'approved organizations need a verification level';
  end if;

  select verification_status, verification_level, type, gstin, pan
    into v_old, v_old_level, v_type, v_gstin, v_pan
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

  -- Notify the organization (only when something the user cares about changed)
  if p_status is distinct from v_old or p_level is distinct from v_old_level then
    if p_status = 'approved' then
      if v_old = 'approved' then
        v_title := 'Your verification level was upgraded';
        v_body  := 'Your account is now ' || replace(p_level, '_', ' ') || '.';
      else
        v_title := 'Your account has been approved';
        v_body  := case when v_type = 'manufacturer'
                        then 'You can now publish products and receive quote requests and purchase orders.'
                        else 'You can now browse and join batches.' end;
      end if;
    elsif p_status = 'rejected' then
      v_title := 'Your application was not approved';
      v_body  := coalesce(nullif(p_notes, ''), 'Please contact Voz Cruda support for details.');
    else
      v_title := 'Your application is under review';
      v_body  := coalesce(nullif(p_notes, ''), 'We will notify you once it has been reviewed.');
    end if;
    if p_status = 'approved' and nullif(p_notes, '') is not null then
      v_body := v_body || ' Note from admin: ' || p_notes;
    end if;

    perform public.notify_org(
      p_org, 'verification_' || p_status, v_title, v_body, 'organization', p_org,
      'verification:' || p_org::text || ':' || extract(epoch from clock_timestamp())::bigint::text);
  end if;
end $$;
