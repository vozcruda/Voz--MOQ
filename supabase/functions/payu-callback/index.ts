// Supabase Edge Function: payu-callback
// PayU sends the buyer here after payment (surl/furl) and also calls it as a webhook.
// We never trust what arrives: we (1) check PayU's response signature, then
// (2) ask PayU's own server for the real status and amount (verify_payment),
// and only then (3) let the database settle the reservation.
// Deploy:  supabase functions deploy payu-callback --no-verify-jwt
// Secrets: PAYU_KEY, PAYU_SALT, PAYU_ENV (test|live), APP_URL (e.g. https://moqless.vozcruda.com)
import { createClient } from 'npm:@supabase/supabase-js@2'

async function sha512(s: string) {
  const buf = await crypto.subtle.digest('SHA-512', new TextEncoder().encode(s))
  return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('')
}
const back = (app: string, result: string, txn: string) =>
  new Response(null, { status: 303, headers: { Location: `${app}/?payment=${encodeURIComponent(result)}&txn=${encodeURIComponent(txn)}` } })

Deno.serve(async (req) => {
  const app = (Deno.env.get('APP_URL') ?? '').replace(/\/$/, '')
  const wantsPage = (req.headers.get('accept') ?? '').includes('text/html')
  const reply = (status: number, result: string, txn = '') =>
    wantsPage && app ? back(app, result, txn) : new Response(JSON.stringify({ result }), { status, headers: { 'Content-Type': 'application/json' } })
  try {
    if (req.method !== 'POST') return reply(405, 'error')
    const key = Deno.env.get('PAYU_KEY')!, salt = Deno.env.get('PAYU_SALT')!
    const live = (Deno.env.get('PAYU_ENV') ?? 'test').toLowerCase() === 'live'
    if (!key || !salt) return reply(500, 'error')

    const ct = req.headers.get('content-type') ?? ''
    const p: Record<string, string> = {}
    if (ct.includes('application/json')) Object.entries(await req.json()).forEach(([k, v]) => (p[k] = String(v ?? '')))
    else new URLSearchParams(await req.text()).forEach((v, k) => (p[k] = v))
    const txnid = p.txnid
    if (!txnid) return reply(400, 'error')

    // 1. response signature: salt|status||||||udf5..udf1|email|firstname|productinfo|amount|txnid|key
    //    (with additionalCharges, it is prepended)
    if (p.hash) {
      const parts = [salt, p.status, '', '', '', '', '', p.udf5 ?? '', p.udf4 ?? '', p.udf3 ?? '', p.udf2 ?? '', p.udf1 ?? '', p.email, p.firstname, p.productinfo, p.amount, txnid, p.key]
      if (p.additionalCharges) parts.unshift(p.additionalCharges)
      if ((await sha512(parts.join('|'))).toLowerCase() !== p.hash.toLowerCase()) return reply(400, 'invalid_signature', txnid)
    }

    // 2. the truth comes from PayU's server, not from this request
    const command = 'verify_payment'
    const vh = await sha512([key, command, txnid, salt].join('|'))
    const vr = await fetch(live ? 'https://info.payu.in/merchant/postservice?form=2' : 'https://test.payu.in/merchant/postservice?form=2', {
      method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ key, command, var1: txnid, hash: vh }),
    })
    const vj = await vr.json().catch(() => null)
    const d = vj?.transaction_details?.[txnid]
    if (!d) return reply(502, 'unverified', txnid)
    const paise = Math.round(Number(d.amt ?? d.transaction_amount ?? 0) * 100)

    // 3. the database settles it (idempotent per txnid)
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
    const { data, error } = await admin.rpc('payu_record_result', {
      p_txnid: txnid, p_gateway_status: String(d.status ?? ''), p_amount_paise: paise,
      p_ref: d.mihpayid ? String(d.mihpayid) : null, p_mode: d.mode ?? null, p_bank_ref: d.bank_ref_num ?? null,
      p_message: d.error_Message ?? d.field9 ?? null,
      p_payload: { verify: d },
    })
    if (error) return reply(500, 'error', txnid)
    return reply(200, String(data), txnid)
  } catch (_e) {
    return reply(500, 'error')
  }
})
