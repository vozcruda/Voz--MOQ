// Supabase Edge Function: admin-create-user
// Lets an admin create a buyer / supplier / admin account on someone's behalf.
// Needs the service-role key (auto-provided as SUPABASE_SERVICE_ROLE_KEY) — never expose that in the browser.
// Deploy:  supabase functions deploy admin-create-user
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json(405, { error: 'POST only' })
  try {
    const url = Deno.env.get('SUPABASE_URL')!
    const anon = Deno.env.get('SUPABASE_ANON_KEY')!
    const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const auth = req.headers.get('Authorization') ?? ''
    if (!auth) return json(401, { error: 'Not signed in' })

    // Everything the caller is allowed to do is decided by the database, as the caller.
    const caller = createClient(url, anon, { global: { headers: { Authorization: auth } } })
    const admin = createClient(url, service, { auth: { persistSession: false } })

    const { data: allowed } = await caller.rpc('can_create_accounts')
    if (allowed !== true) return json(403, { error: 'You do not have permission to create accounts' })

    const b = await req.json()
    const email = String(b.email ?? '').trim().toLowerCase()
    const type = String(b.account_type ?? '')
    if (!email || !['buyer', 'manufacturer', 'admin'].includes(type)) return json(400, { error: 'email and a valid account_type are required' })
    if (type !== 'admin' && !String(b.legal_name ?? '').trim()) return json(400, { error: 'Business name is required' })
    if (b.password && String(b.password).length < 8) return json(400, { error: 'Password must be at least 8 characters' })

    // 1. find or create the auth user
    let userId: string | null = null
    let created = false
    const meta = { full_name: b.full_name ?? '' }
    if (b.password) {
      const { data, error } = await admin.auth.admin.createUser({ email, password: b.password, email_confirm: true, user_metadata: meta })
      if (error && !/already|registered|exists/i.test(error.message)) return json(400, { error: error.message })
      if (data?.user) { userId = data.user.id; created = true }
    } else {
      const { data, error } = await admin.auth.admin.inviteUserByEmail(email, { data: meta })
      if (error && !/already|registered|exists/i.test(error.message)) return json(400, { error: error.message })
      if (data?.user) { userId = data.user.id; created = true }
    }
    if (!userId) {
      const { data } = await caller.rpc('admin_find_user', { p_email: email })
      userId = (data as string) ?? null
    }
    if (!userId) return json(400, { error: 'Could not create or find that user' })

    // 2. attach business / admin access — as the caller, so permission rules apply
    let err: string | null = null
    if (type === 'admin') {
      const r = await caller.rpc('admin_grant_admin', { p_email: email, p_permissions: b.permissions ?? [], p_can_grant: !!b.can_grant })
      err = r.error?.message ?? null
    } else {
      const r = await caller.rpc('admin_create_org_for', {
        p_profile: userId, p_type: type, p_legal_name: b.legal_name, p_trade_name: b.trade_name ?? null,
        p_gstin: b.gstin || null, p_pan: b.pan || null, p_phone: b.phone || null, p_approve: !!b.approve,
      })
      err = r.error?.message ?? null
    }
    if (err) {
      if (created) await admin.auth.admin.deleteUser(userId) // roll back the half-made user
      return json(400, { error: err })
    }
    return json(200, { user_id: userId, created, invited: created && !b.password })
  } catch (e) {
    return json(500, { error: (e as Error).message })
  }
})
