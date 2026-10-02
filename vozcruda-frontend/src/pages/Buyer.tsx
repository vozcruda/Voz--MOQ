import { useState, useEffect } from 'react'
import { supabase, inr, fdate, daysLeft, type Row } from '../supabase'
import { useQuery, Err, Status, Stats, Stat, Progress, pct, Section, Card, Empty, Loading, Modal } from '../ui/kit'
import { OpenDispute } from './Disputes'

const useCommits = () => useQuery(() => supabase.from('pool_commitments').select('*, pool:pool_id(id, pool_no, title, moq_qty, paid_qty, deadline_at, status), orders:order_id(order_no, status, expected_ship_date)').order('created_at', { ascending: false }), [])
const isActive = (c: Row) => ['reserved', 'paid'].includes(c.status)

export function BuyerDashboard({ go, open }: { go: (p: string) => void; open: (id: string) => void }) {
  const q = useCommits(); const rows = q.rows as Row[]
  const active = rows.filter(isActive)
  const spent = rows.filter(c => ['paid', 'fulfilled'].includes(c.status)).reduce((s, c) => s + Number(c.amount_due_paise), 0)
  const due = rows.filter(c => c.status === 'reserved').reduce((s, c) => s + Number(c.amount_due_paise), 0)
  const shipping = rows.filter(c => c.orders && ['shipped', 'ready_to_ship'].includes(c.orders.status)).length
  return (<>
    <Stats><Stat label="Active Orders" value={active.length} sub={`${active.filter(c => c.status === 'paid').length} paid`} /><Stat label="Total Spent" value={inr(spent)} />
      <Stat label="Pending Payment" value={inr(due)} sub={`${rows.filter(c => c.status === 'reserved').length} action required`} /><Stat label="In Shipment" value={shipping} /></Stats>
    <Section title="My Active Reservations" action={<button className="btn btn-outline btn-sm" onClick={() => go('browse')}>Browse Batches</button>} />
    <Err m={q.err} />
    <Card flush>{q.loading ? <Loading /> : !active.length ? <Empty icon="🛍️" title="No active reservations" desc="Join a batch to get factory pricing." /> :
      <table><thead><tr><th>Batch</th><th>Progress</th><th>Qty</th><th>Total</th><th>Status</th><th></th></tr></thead><tbody>
        {active.map(c => <tr key={c.id}><td className="td-strong">{c.pool?.title}</td><td style={{ minWidth: 130 }}><div className="row" style={{ flexWrap: 'nowrap' }}><div style={{ flex: 1 }}><Progress done={c.pool?.paid_qty ?? 0} total={c.pool?.moq_qty ?? 0} /></div><b style={{ fontSize: 12 }}>{pct(c.pool?.paid_qty ?? 0, c.pool?.moq_qty ?? 0)}%</b></div></td>
          <td>{c.qty} pcs</td><td>{inr(c.amount_due_paise)}</td><td><Status s={c.status} /></td><td><button className="btn btn-ghost btn-sm" onClick={() => open(c.pool_id)}>Track →</button></td></tr>)}</tbody></table>}</Card>
  </>)
}

export function MyOrders({ open }: { open: (id: string) => void }) {
  const q = useCommits(); const [tab, setTab] = useState<'active' | 'completed' | 'cancelled'>('active'); const [dsp, setDsp] = useState<string | null>(null)
  const rows = (q.rows as Row[]).filter(c => tab === 'active' ? isActive(c) : tab === 'completed' ? c.status === 'fulfilled' : ['cancelled', 'expired', 'refund_pending', 'refunded'].includes(c.status))
  return (<>
    <div className="tabs">{(['active', 'completed', 'cancelled'] as const).map(t => <div key={t} className={'tab' + (tab === t ? ' active' : '')} onClick={() => setTab(t)}>{t[0].toUpperCase() + t.slice(1)}</div>)}</div>
    <Err m={q.err} />{q.loading ? <Loading /> : !rows.length ? <Empty title="Nothing here" /> : <div className="stack">
      {rows.map(c => <div className="info-card" key={c.id}><div className="info-card-body"><div className="row" style={{ justifyContent: 'space-between' }}>
        <div><div className="product-title">{c.pool?.title}</div><div className="td-muted">{c.qty} pcs · locked {inr(c.unit_price_locked_paise)}/pc · total {inr(c.amount_due_paise)}</div></div><Status s={c.status} /></div>
        <div className="progress-section" style={{ marginTop: 12 }}><div className="progress-header"><span className="progress-filled">{c.pool?.paid_qty} / {c.pool?.moq_qty} pcs</span><span className="progress-target">{pct(c.pool?.paid_qty ?? 0, c.pool?.moq_qty ?? 0)}%</span></div><Progress done={c.pool?.paid_qty ?? 0} total={c.pool?.moq_qty ?? 0} /></div>
        <div className="row" style={{ justifyContent: 'space-between' }}><span className="td-muted">{c.orders ? `${c.orders.order_no} · ${c.orders.status.replace(/_/g, ' ')}` : c.status === 'reserved' ? `Pay within ${daysLeft(c.reserved_until) ? daysLeft(c.reserved_until) + ' day(s)' : 'today'}` : `Batch closes in ${daysLeft(c.pool?.deadline_at)} days`}</span>
          <div className="row">{c.order_id && ['shipped', 'delivered', 'completed'].includes(c.orders?.status) && <button className="btn btn-ghost btn-sm" onClick={() => setDsp(c.order_id)}>Report a problem</button>}
            <button className="btn btn-outline btn-sm" onClick={() => open(c.pool_id)}>Track Batch</button></div></div></div></div>)}</div>}
    {dsp && <OpenDispute admin={false} orderId={dsp} onClose={() => setDsp(null)} onDone={() => { setDsp(null); q.reload() }} />}
  </>)
}

const PAY_MSG: Record<string, [string, string]> = {
  success: ['ok', '✓ Payment received and verified. Your reservation is confirmed.'],
  pending: ['warn', 'Your payment is still processing. It will update here automatically once the bank confirms.'],
  failed: ['bad', 'The payment did not go through, so you have not been charged. You can try again below.'],
  refund_needed: ['warn', 'We received your payment but need to check it before confirming. Our team will contact you.'],
  mismatch: ['warn', 'We received your payment but need to check it before confirming. Our team will contact you.'],
}
async function startPayU(commitmentId: string): Promise<string | null> {
  const { data, error } = await supabase.functions.invoke('payu-initiate', { body: { commitment_id: commitmentId } })
  if (error) {
    let m = error.message
    try { const j = await (error as { context?: Response }).context?.json(); if (j?.error) m = j.error } catch { /* keep default */ }
    return m
  }
  const d = data as { action?: string; fields?: Record<string, string>; error?: string }
  if (!d?.action || !d.fields) return d?.error ?? 'Could not start the payment.'
  const f = document.createElement('form'); f.method = 'POST'; f.action = d.action
  Object.entries(d.fields).forEach(([k, v]) => { const i = document.createElement('input'); i.type = 'hidden'; i.name = k; i.value = v; f.appendChild(i) })
  document.body.appendChild(f); f.submit()
  return null
}

export function Payments() {
  const q = useCommits();
  const [ret, setRet] = useState<string | null>(null); const [payBusy, setPayBusy] = useState<string | null>(null); const [payErr, setPayErr] = useState('')
  useEffect(() => {
    const u = new URL(window.location.href); const r = u.searchParams.get('payment')
    if (r) { setRet(r); u.searchParams.delete('payment'); u.searchParams.delete('txn'); window.history.replaceState({}, '', u.pathname + (u.search || '') + u.hash); q.reload() }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
  const payOnline = async (c: Row) => { setPayErr(''); setPayBusy(c.id); const e = await startPayU(c.id); if (e) { setPayBusy(null); setPayErr(e) } }; const settings = useQuery(() => supabase.from('app_settings').select('*').eq('key', 'payment_instructions'), [])
  const [sel, setSel] = useState<Row | null>(null)
  const rows = q.rows as Row[]
  const paid = rows.filter(c => ['paid', 'fulfilled'].includes(c.status)).reduce((s, c) => s + Number(c.amount_due_paise), 0)
  const pend = rows.filter(c => c.status === 'reserved').reduce((s, c) => s + Number(c.amount_due_paise), 0)
  return (<>
    {ret && <div className={'pay-banner ' + (PAY_MSG[ret]?.[0] ?? 'warn')}>{PAY_MSG[ret]?.[1] ?? 'We could not confirm your payment yet. If money was deducted, it is verified automatically — contact support with your transaction details.'}<button className="notif-x" aria-label="Dismiss" onClick={() => setRet(null)}>✕</button></div>}
    <Stats><Stat label="Total Paid" value={inr(paid)} /><Stat label="Pending" value={inr(pend)} /></Stats>
    <Err m={q.err || payErr} />
    <Card title="Payments" flush>{!rows.length ? <Empty icon="💳" title="No payments yet" /> : <table><thead><tr><th>Batch</th><th>Amount</th><th>Pay by</th><th>Reference</th><th>Status</th><th></th></tr></thead><tbody>
      {rows.map(c => <tr key={c.id}><td className="td-strong">{c.pool?.title} <span className="td-muted">({c.qty} pcs)</span></td><td>{inr(c.amount_due_paise)}</td><td>{c.status === 'reserved' ? fdate(c.reserved_until) : '—'}</td><td className="mono">{c.payment_ref ?? '—'}</td><td><Status s={c.status} /></td>
        <td>{c.status === 'reserved' && <div className="row" style={{ flexWrap: 'nowrap' }}><button className="btn btn-primary btn-sm" disabled={payBusy === c.id} onClick={() => payOnline(c)}>{payBusy === c.id ? 'Opening…' : 'Pay now'}</button><button className="btn btn-outline btn-sm" onClick={() => setSel(c)}>Bank transfer</button></div>}</td></tr>)}</tbody></table>}</Card>
    {sel && <Modal title="Pay by bank transfer" sub={`${sel.pool?.title} · ${inr(sel.amount_due_paise)} due`} onClose={() => setSel(null)} footer={<button className="btn btn-primary" onClick={() => setSel(null)}>Done</button>}>
      <div className="res-summary"><div className="res-summary-row"><span className="key">Amount</span><span>{inr(sel.amount_due_paise)}</span></div><div className="res-summary-row"><span className="key">Pay before</span><span>{fdate(sel.reserved_until)}</span></div></div>
      {(() => { const v = ((settings.rows as Row[])[0]?.value ?? {}) as Row; const L: [string, string][] = [['account_name', 'Account name'], ['bank_name', 'Bank'], ['account_number', 'Account number'], ['ifsc', 'IFSC'], ['upi_id', 'UPI ID']]
        const have = L.filter(([k]) => v[k]); return have.length ? have.map(([k, l]) => <div className="info-row" key={k}><span className="info-key">{l}</span><span className="info-val mono">{String(v[k])}</span></div>) : <div className="form-hint">Payment details are not set up yet — please contact support.</div> })()}
      <p className="form-hint" style={{ marginTop: 12 }}>{String(((settings.rows as Row[])[0]?.value as Row | undefined)?.note || 'After transferring, quote your transaction ID to Voz Cruda support.')} Your reservation is marked paid once it is verified. Unpaid reservations expire automatically.</p></Modal>}
  </>)
}
