// Supabase Edge Function: payu-initiate
// The signed-in buyer taps "Pay now". The DATABASE decides the amount (from the reservation);
// this function only signs it with the PayU salt, which never leaves the server.
// Deploy:  supabase functions deploy payu-initiate        (Verify JWT stays ON)
// Secrets: PAYU_KEY, PAYU_SALT, PAYU_ENV (test|live)
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

async function sha512(s: string) {
  const buf = await crypto.subtle.digest('SHA-512', new TextEncoder().encode(s))
  return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('')
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json(405, { error: 'POST only' })
  try {
    const key = Deno.env.get('PAYU_KEY'), salt = Deno.env.get('PAYU_SALT')
    if (!key || !salt) return json(500, { error: 'Online payments are not set up yet. Please use bank transfer.' })
    const live = (Deno.env.get('PAYU_ENV') ?? 'test').toLowerCase() === 'live'
    const auth = req.headers.get('Authorization') ?? ''
    if (!auth) return json(401, { error: 'Not signed in' })

    const caller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } })
    const { commitment_id } = await req.json()
    if (!commitment_id) return json(400, { error: 'commitment_id is required' })

    // All checks (ownership, status, expiry, amount) happen in the database, as the buyer.
    const { data, error } = await caller.rpc('payu_prepare_attempt', { p_commitment: commitment_id })
    if (error) return json(400, { error: error.message })
    const a = data as { txnid: string; amount_paise: number; productinfo: string; firstname: string; email: string; phone: string | null }

    const amount = (a.amount_paise / 100).toFixed(2)
    const callback = `${Deno.env.get('SUPABASE_URL')}/functions/v1/payu-callback`
    // key|txnid|amount|productinfo|firstname|email|udf1..udf5||||||SALT
    const hash = await sha512([key, a.txnid, amount, a.productinfo, a.firstname, a.email, '', '', '', '', '', '', '', '', '', '', salt].join('|'))

    const fields: Record<string, string> = {
      key, txnid: a.txnid, amount, productinfo: a.productinfo, firstname: a.firstname, email: a.email,
      surl: callback, furl: callback, hash,
    }
    if (a.phone) fields.phone = a.phone.slice(-10)
    return json(200, { action: live ? 'https://secure.payu.in/_payment' : 'https://test.payu.in/_payment', fields })
  } catch (e) {
    return json(500, { error: String((e as Error)?.message ?? e) })
  }
})
