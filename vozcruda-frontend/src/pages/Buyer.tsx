import { useState } from 'react'
import { supabase, inr, fdate, daysLeft, type Row } from '../supabase'
import { useQuery, Err, Status, Stats, Stat, Progress, pct, Section, Card, Empty, Loading, Modal } from '../ui/kit'

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
  const q = useCommits(); const [tab, setTab] = useState<'active' | 'completed' | 'cancelled'>('active')
  const rows = (q.rows as Row[]).filter(c => tab === 'active' ? isActive(c) : tab === 'completed' ? c.status === 'fulfilled' : ['cancelled', 'expired', 'refund_pending', 'refunded'].includes(c.status))
  return (<>
    <div className="tabs">{(['active', 'completed', 'cancelled'] as const).map(t => <div key={t} className={'tab' + (tab === t ? ' active' : '')} onClick={() => setTab(t)}>{t[0].toUpperCase() + t.slice(1)}</div>)}</div>
    <Err m={q.err} />{q.loading ? <Loading /> : !rows.length ? <Empty title="Nothing here" /> : <div className="stack">
      {rows.map(c => <div className="info-card" key={c.id}><div className="info-card-body"><div className="row" style={{ justifyContent: 'space-between' }}>
        <div><div className="product-title">{c.pool?.title}</div><div className="td-muted">{c.qty} pcs · locked {inr(c.unit_price_locked_paise)}/pc · total {inr(c.amount_due_paise)}</div></div><Status s={c.status} /></div>
        <div className="progress-section" style={{ marginTop: 12 }}><div className="progress-header"><span className="progress-filled">{c.pool?.paid_qty} / {c.pool?.moq_qty} pcs</span><span className="progress-target">{pct(c.pool?.paid_qty ?? 0, c.pool?.moq_qty ?? 0)}%</span></div><Progress done={c.pool?.paid_qty ?? 0} total={c.pool?.moq_qty ?? 0} /></div>
        <div className="row" style={{ justifyContent: 'space-between' }}><span className="td-muted">{c.orders ? `${c.orders.order_no} · ${c.orders.status.replace(/_/g, ' ')}` : c.status === 'reserved' ? `Pay within ${daysLeft(c.reserved_until) ? daysLeft(c.reserved_until) + ' day(s)' : 'today'}` : `Batch closes in ${daysLeft(c.pool?.deadline_at)} days`}</span>
          <button className="btn btn-outline btn-sm" onClick={() => open(c.pool_id)}>Track Batch</button></div></div></div>)}</div>}
  </>)
}

export function Payments() {
  const q = useCommits(); const settings = useQuery(() => supabase.from('app_settings').select('*').like('key', '%payment%'), [])
  const [sel, setSel] = useState<Row | null>(null)
  const rows = q.rows as Row[]
  const paid = rows.filter(c => ['paid', 'fulfilled'].includes(c.status)).reduce((s, c) => s + Number(c.amount_due_paise), 0)
  const pend = rows.filter(c => c.status === 'reserved').reduce((s, c) => s + Number(c.amount_due_paise), 0)
  return (<>
    <Stats><Stat label="Total Paid" value={inr(paid)} /><Stat label="Pending" value={inr(pend)} /></Stats>
    <Err m={q.err} />
    <Card title="Payments" flush>{!rows.length ? <Empty icon="💳" title="No payments yet" /> : <table><thead><tr><th>Batch</th><th>Amount</th><th>Pay by</th><th>Reference</th><th>Status</th><th></th></tr></thead><tbody>
      {rows.map(c => <tr key={c.id}><td className="td-strong">{c.pool?.title} <span className="td-muted">({c.qty} pcs)</span></td><td>{inr(c.amount_due_paise)}</td><td>{c.status === 'reserved' ? fdate(c.reserved_until) : '—'}</td><td className="mono">{c.payment_ref ?? '—'}</td><td><Status s={c.status} /></td>
        <td>{c.status === 'reserved' && <button className="btn btn-primary btn-sm" onClick={() => setSel(c)}>How to pay</button>}</td></tr>)}</tbody></table>}</Card>
    {sel && <Modal title="Payment instructions" sub={`${sel.pool?.title} · ${inr(sel.amount_due_paise)} due`} onClose={() => setSel(null)} footer={<button className="btn btn-primary" onClick={() => setSel(null)}>Done</button>}>
      <div className="res-summary"><div className="res-summary-row"><span className="key">Amount</span><span>{inr(sel.amount_due_paise)}</span></div><div className="res-summary-row"><span className="key">Pay before</span><span>{fdate(sel.reserved_until)}</span></div></div>
      {(settings.rows as Row[]).map(s => <div className="info-row" key={s.key}><span className="info-key">{s.key.replace(/_/g, ' ')}</span><span className="info-val">{typeof s.value === 'object' ? JSON.stringify(s.value) : String(s.value)}</span></div>)}
      <p className="form-hint" style={{ marginTop: 12 }}>After transferring, quote your transaction ID to Voz Cruda support; your reservation is marked paid once it is verified. Unpaid reservations expire automatically.</p></Modal>}
  </>)
}
