import { Fragment, useState } from 'react'
import { supabase, inr, fdate, daysLeft, rpc, type Row } from '../supabase'
import { useQuery, Err, Status, Chip, Stats, Stat, Progress, pct, Section, Card, Empty, Loading } from '../ui/kit'
import { usePools, levelLabel } from './Pools'
import { useAuth } from '../auth'
import { CreateAccount } from './AdminTeam'
import { NoteDialog, ManualReservation, ManualPO, ExtendReservation, PODetail } from './Ops'

export function AdminDashboard({ open, go }: { open: (id: string) => void; go: (p: string) => void }) {
  const { pools } = usePools(true)
  const pend = useQuery(() => supabase.from('organizations').select('id').eq('type', 'manufacturer').eq('verification_status', 'pending'), [])
  const buyers = useQuery(() => supabase.from('organizations').select('id').eq('type', 'buyer'), [])
  const res = useQuery(() => supabase.from('pool_commitments').select('amount_due_paise').eq('status', 'reserved'), [])
  const disp = useQuery(() => supabase.from('disputes').select('id').eq('status', 'open'), [])
  const log = useQuery(() => supabase.rpc('admin_activity_feed', { p_limit: 8 }), [])
  const active = pools.filter(p => p.status === 'open' || p.status === 'moq_reached')
  const near = [...active].sort((a, b) => pct(b.paid, b.moq) - pct(a.paid, a.moq)).slice(0, 5)
  const due = (res.rows as Row[]).reduce((s, r) => s + Number(r.amount_due_paise), 0)
  return (<>
    <Stats>
      <Stat label="Active Batches" value={active.length} sub={`${pools.length} total`} />
      <Stat label="Pending Suppliers" value={pend.rows.length} sub="awaiting verification" />
      <Stat label="Total Buyers" value={buyers.rows.length} />
      <Stat label="Pending Payments" value={inr(due)} sub={`${res.rows.length} reservations`} />
    </Stats>
    {(disp.rows.length > 0 || pend.rows.length > 0) && <div className="info-card" style={{ marginBottom: 20 }}><div className="info-card-body row">
      {pend.rows.length > 0 && <button className="btn btn-outline btn-sm" onClick={() => go('suppliers')}>🏭 {pend.rows.length} supplier(s) awaiting verification</button>}
      {disp.rows.length > 0 && <button className="btn btn-outline btn-sm" onClick={() => go('disputes')}>⚖️ {disp.rows.length} open dispute(s)</button>}</div></div>}
    <div className="dash-grid">
      <div>
        <Section title="🔥 Nearing MOQ" sub="Batches closest to triggering" />
        <Card flush>{!near.length ? <Empty title="No active batches" /> : <table><thead><tr><th>Batch</th><th>Progress</th><th>Remaining</th><th>Closes</th><th></th></tr></thead><tbody>
          {near.map(p => <tr key={p.id}><td><div className="td-strong">{p.title}</div><div className="td-muted">{p.no}</div></td>
            <td style={{ minWidth: 140 }}><div className="row" style={{ flexWrap: 'nowrap' }}><div style={{ flex: 1 }}><Progress done={p.paid} total={p.moq} /></div><b style={{ fontSize: 12 }}>{pct(p.paid, p.moq)}%</b></div></td>
            <td><b>{Math.max(0, p.moq - p.paid)} pcs</b></td><td><Chip c={daysLeft(p.deadline) <= 3 ? 'orange' : 'gray'}>{daysLeft(p.deadline)} days</Chip></td>
            <td><button className="btn btn-ghost btn-sm" onClick={() => open(p.id)}>View →</button></td></tr>)}</tbody></table>}</Card>
      </div>
      <div><Section title="Recent Activity" action={<button className="btn btn-ghost btn-sm" onClick={() => go('activity')}>View all →</button>} />
        <Card flush>{!log.rows.length ? <Empty title="No activity yet" /> : <div className="activity-feed">
          {(log.rows as Row[]).map(l => <div className="activity-item" key={l.ev_id}><div className="activity-dot" style={{ background: 'rgba(212,85,26,0.12)' }}>{l.ev_kind === 'status' ? '🔄' : l.ev_kind === 'action' ? '⚡' : '📝'}</div>
            <div className="activity-content"><div className="activity-title">{l.ev_summary}</div><div className="activity-meta">{l.ev_actor} · {new Date(l.ev_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' })}</div></div></div>)}</div>}</Card>
        <Err m={log.err} />
      </div>
    </div>
  </>)
}

export function Reservations() {
  const { can } = useAuth()
  const q = useQuery(() => supabase.from('pool_commitments').select('*, buyer:buyer_org_id(legal_name, trade_name), pool:pool_id(pool_no, title), pool_commitment_items(size, color, qty)').order('created_at', { ascending: false }).limit(200), [])
  const [st, setSt] = useState(''); const [open, setOpen] = useState<string | null>(null)
  const [manual, setManual] = useState(false); const [pay, setPay] = useState<Row | null>(null); const [cancel, setCancel] = useState<Row | null>(null); const [ext, setExt] = useState<Row | null>(null)
  const [late, setLate] = useState<Row | null>(null); const [refund, setRefund] = useState<Row | null>(null); const [rebate, setRebate] = useState<Row | null>(null); const [notice, setNotice] = useState('')
  const rebateDue = (r: Row) => Number(r.rebate_paise ?? 0) > 0 && !r.rebate_paid_at && ['paid', 'fulfilled'].includes(r.status)
  const rows = (q.rows as Row[]).filter(r => !st || r.status === st)
  const canBook = can('payments') || can('pools')
  return (<>
    <div className="filter-bar"><select className="filter-select" value={st} onChange={e => setSt(e.target.value)}><option value="">All Statuses</option>
      {['reserved', 'paid', 'fulfilled', 'cancelled', 'expired', 'refund_pending', 'refunded'].map(s => <option key={s} value={s}>{s.replace(/_/g, ' ')}</option>)}</select>
      {canBook && <button className="btn btn-primary btn-sm" style={{ marginLeft: 'auto' }} onClick={() => setManual(true)}>+ Manual reservation</button>}</div>
    <Err m={q.err} />
    {notice && <div className="pay-banner warn">{notice}<button className="notif-x" aria-label="Dismiss" onClick={() => setNotice('')}>✕</button></div>}
    <Card flush>{q.loading ? <Loading /> : !rows.length ? <Empty icon="📋" title="No reservations" desc={canBook ? 'Use “Manual reservation” to book a buyer into a batch yourself.' : undefined} /> : <table><thead><tr><th>Buyer</th><th>Batch</th><th>Qty</th><th>Total</th><th>Status</th><th>Date</th><th></th></tr></thead><tbody>
      {rows.map(r => <Fragment key={r.id}><tr><td className="td-strong">{r.buyer?.trade_name || r.buyer?.legal_name}</td><td>{r.pool?.title}<div className="td-muted">{r.pool?.pool_no}</div></td><td>{r.qty}</td><td>{inr(r.amount_due_paise)}</td><td><Status s={r.status} />{r.status === 'reserved' && <div className="td-muted">pay by {fdate(r.reserved_until)}</div>}</td><td className="td-muted">{fdate(r.created_at)}</td>
        <td className="row">{can('payments') && r.status === 'reserved' && <button className="btn btn-outline btn-sm" onClick={() => setPay(r)}>Mark paid</button>}
          {can('payments') && ['expired', 'cancelled'].includes(r.status) && <button className="btn btn-outline btn-sm" onClick={() => setLate(r)}>Record late payment</button>}
          {can('payments') && r.status === 'refund_pending' && <button className="btn btn-outline btn-sm" onClick={() => setRefund(r)}>Mark refunded</button>}
          {can('payments') && rebateDue(r) && <button className="btn btn-outline btn-sm" onClick={() => setRebate(r)}>Pay rebate {inr(r.rebate_paise)}</button>}
          {can('payments') && r.status === 'reserved' && <button className="btn btn-ghost btn-sm" onClick={() => setExt(r)}>Extend</button>}
          {can('payments') && ['reserved', 'paid'].includes(r.status) && <button className="btn btn-ghost btn-sm" style={{ color: 'var(--danger)' }} onClick={() => setCancel(r)}>Cancel</button>}
          <button className="btn btn-ghost btn-sm" onClick={() => setOpen(open === r.id ? null : r.id)}>{open === r.id ? 'Hide' : 'Details'}</button></td></tr>
        {open === r.id && <tr><td colSpan={7}><table className="po-table"><thead><tr><th>Size</th><th>Colour</th><th>Qty</th></tr></thead><tbody>
          {(r.pool_commitment_items ?? []).map((i: Row, k: number) => <tr key={k}><td>{i.size}</td><td>{i.color}</td><td>{i.qty}</td></tr>)}</tbody></table>
          <div className="td-muted" style={{ marginTop: 8 }}>Locked price {inr(r.unit_price_locked_paise)}/pc{r.payment_ref ? ` · payment ref ${r.payment_ref}` : ''}{r.paid_at ? ` · paid ${fdate(r.paid_at)}` : ''}{r.refund_ref ? ` · refunded ${fdate(r.refunded_at)} (ref ${r.refund_ref})` : ''}{Number(r.rebate_paise ?? 0) > 0 ? ` · rebate ${inr(r.rebate_paise)} ${r.rebate_paid_at ? `paid ${fdate(r.rebate_paid_at)} (ref ${r.rebate_ref})` : 'owed'}` : ''}{r.shipping_address ? ` · ship to ${[r.shipping_address.line1, r.shipping_address.city, r.shipping_address.pincode].filter(Boolean).join(', ')}` : ''}</div></td></tr>}</Fragment>)}</tbody></table>}</Card>
    {manual && <ManualReservation onClose={() => setManual(false)} onDone={() => { setManual(false); q.reload() }} />}
    {ext && <ExtendReservation r={ext} onClose={() => setExt(null)} onDone={q.reload} />}
    {pay && <NoteDialog title="Mark as paid" sub={`${pay.buyer?.trade_name || pay.buyer?.legal_name} · ${inr(pay.amount_due_paise)}`} label="Payment reference (UTR / transaction ID)" confirm="Mark paid" onClose={() => setPay(null)}
      onSubmit={async ref => { const e = await rpc('admin_mark_paid', { p_commitment: pay.id, p_payment_ref: ref }); if (!e) q.reload(); return e }} />}
    {late && <NoteDialog title="Record late payment" sub={`${late.buyer?.trade_name || late.buyer?.legal_name} · ${inr(late.amount_due_paise)} · this reservation is ${late.status}`} label="Payment reference (UTR / transaction ID)" confirm="Record payment"
      extra={<p className="form-hint">If the batch is still open and has room, the payment counts toward it. Otherwise it is kept as refund pending so you can return the money.</p>} onClose={() => setLate(null)}
      onSubmit={async ref => { const { data, error } = await supabase.rpc('admin_record_late_payment', { p_commitment: late.id, p_payment_ref: ref }); if (error) return error.message
        if (data !== 'paid') setNotice(`Payment ${ref} was recorded but could not count toward the batch (it is closed or full), so it is now refund pending.`); q.reload(); return null }} />}
    {refund && <NoteDialog title="Mark refunded" sub={`${refund.buyer?.trade_name || refund.buyer?.legal_name} · ${inr(refund.amount_due_paise)} · ${refund.pool?.pool_no}`} label="Refund reference (UTR / PayU refund ID)" confirm="Mark refunded"
      extra={<p className="form-hint">Send the money back first (bank transfer or the PayU dashboard), then record it here. The buyer is notified.</p>} onClose={() => setRefund(null)}
      onSubmit={async ref => { const e = await rpc('admin_mark_refunded', { p_commitment: refund.id, p_refund_ref: ref }); if (!e) q.reload(); return e }} />}
    {rebate && <NoteDialog title="Pay price-drop rebate" sub={`${rebate.buyer?.trade_name || rebate.buyer?.legal_name} · ${inr(rebate.rebate_paise)} owed · ${rebate.pool?.pool_no}`} label="Payment reference (UTR / PayU refund ID)" confirm="Mark rebate paid"
      extra={<p className="form-hint">The batch reached a cheaper price tier than the buyer paid. Send them the difference, then record it here.</p>} onClose={() => setRebate(null)}
      onSubmit={async ref => { const e = await rpc('admin_mark_rebate_paid', { p_commitment: rebate.id, p_ref: ref }); if (!e) q.reload(); return e }} />}
    {cancel && <NoteDialog title="Cancel reservation" sub={`${cancel.buyer?.trade_name || cancel.buyer?.legal_name} · ${cancel.pool?.pool_no}${cancel.status === 'paid' ? ' — a paid reservation moves to refund pending' : ''}`} label="Reason" confirm="Cancel reservation" danger onClose={() => setCancel(null)}
      onSubmit={async why => { const e = await rpc('admin_cancel_commitment', { p_commitment: cancel.id, p_reason: why }); if (!e) q.reload(); return e }} />}
  </>)
}

const PO_NEXT: Record<string, string[]> = { sent: ['cancelled'], accepted: ['in_production'], in_production: ['ready'], ready: ['shipped_to_voz'], shipped_to_voz: ['received'], received: ['closed'] }
export function PurchaseOrders({ role }: { role: 'admin' | 'supplier' }) {
  const { can } = useAuth()
  const q = useQuery(() => supabase.from('purchase_orders').select('*, pool:pool_id(title, pool_no), mfr:manufacturer_org_id(legal_name, trade_name), purchase_order_items(size,color,qty)').order('created_at', { ascending: false }), [])
  const [open, setOpen] = useState<string | null>(null); const [manual, setManual] = useState(false); const [cancel, setCancel] = useState<Row | null>(null)
  const mv = async (id: string, to: string) => { const e = await rpc('update_po_status', { p_po: id, p_to: to }); if (e) alert(e); q.reload() }
  const supplierNext = (s: string) => (s === 'sent' ? ['accepted', 'rejected'] : (PO_NEXT[s] ?? []).filter(x => ['in_production', 'ready'].includes(x)))
  return (<>
    {role === 'admin' && can('orders') && <div className="filter-bar"><span className="td-muted">POs are created automatically when a batch reaches its MOQ. You can also place one yourself.</span>
      <button className="btn btn-primary btn-sm" style={{ marginLeft: 'auto' }} onClick={() => setManual(true)}>+ Manual PO</button></div>}
    <Err m={q.err} />
    <Card flush>{q.loading ? <Loading /> : !q.rows.length ? <Empty icon="🧾" title="No purchase orders" desc={role === 'admin' ? 'A PO is created when a batch reaches its MOQ — or use “Manual PO”.' : 'You’ll see purchase orders here when a batch is sent to you.'} /> : <table><thead><tr><th>PO</th><th>Batch</th>{role === 'admin' && <th>Supplier</th>}<th>Qty</th><th>Amount</th><th>Status</th><th>Date</th><th></th></tr></thead><tbody>
      {(q.rows as Row[]).map(p => <Fragment key={p.id}><tr><td className="td-strong">{p.po_no}</td><td>{p.pool?.title}</td>{role === 'admin' && <td>{p.mfr?.trade_name || p.mfr?.legal_name}</td>}
        <td>{p.total_qty}</td><td>{inr(p.total_cost_paise)}</td><td><Status s={p.status} /></td><td className="td-muted">{fdate(p.created_at)}</td>
        <td className="row">{(role === 'admin' ? (can('orders') ? PO_NEXT[p.status] ?? [] : []) : supplierNext(p.status)).filter(t => !(role === 'admin' && t === 'cancelled')).map(t => <button key={t} className="btn btn-outline btn-sm" onClick={() => mv(p.id, t)}>{t.replace(/_/g, ' ')}</button>)}
          {role === 'admin' && can('orders') && !['cancelled', 'closed', 'received'].includes(p.status) && <button className="btn btn-ghost btn-sm" style={{ color: 'var(--danger)' }} onClick={() => setCancel(p)}>Cancel</button>}
          <button className="btn btn-outline btn-sm" onClick={() => setOpen(p.id)}>Details</button></td></tr>
</Fragment>)}</tbody></table>}</Card>
    {open && <PODetail id={open} role={role} onClose={() => setOpen(null)} />}
    {manual && <ManualPO onClose={() => setManual(false)} onDone={() => { setManual(false); q.reload() }} />}
    {cancel && <NoteDialog title={`Cancel ${cancel.po_no}`} sub="The supplier is notified. Buyer orders stay in place." label="Reason" confirm="Cancel PO" danger onClose={() => setCancel(null)}
      onSubmit={async why => { const e = await rpc('admin_cancel_po', { p_po: cancel.id, p_reason: why }); if (!e) q.reload(); return e }} />}
  </>)
}

async function suspendOrg(r: Row, reload: () => void) {
  const why = prompt(r.suspended_at ? 'Reason for unsuspending?' : 'Reason for suspending?'); if (!why) return
  const e = await rpc('admin_set_org_suspension', { p_org: r.id, p_suspend: !r.suspended_at, p_reason: why }); if (e) alert(e); reload()
}
export function Suppliers() {
  const { can } = useAuth()
  const q = useQuery(() => supabase.from('organizations').select('*, manufacturer_profiles(monthly_capacity, min_moq)').eq('type', 'manufacturer').order('created_at', { ascending: false }), [])
  const set = async (r: Row, status: string, level: string) => { const n = prompt('Note (optional)') ?? null; const e = await rpc('admin_set_verification', { p_org: r.id, p_status: status, p_level: level, p_notes: n }); if (e) alert(e); q.reload() }
  const suspend = (r: Row) => suspendOrg(r, q.reload)
  const slug = async (r: Row) => { const v = prompt('URL slug (lowercase, hyphens), e.g. tiruppur-knits'); if (!v) return; const e = await rpc('admin_set_manufacturer_slug', { p_org: r.id, p_slug: v }); if (e) alert(e); q.reload() }
  return (<><Err m={q.err} />
    <Card title="Suppliers" flush>{q.loading ? <Loading /> : !q.rows.length ? <Empty icon="🏭" title="No suppliers yet" /> : <table><thead><tr><th>Supplier</th><th>GSTIN</th><th>Level</th><th>Status</th><th></th></tr></thead><tbody>
      {(q.rows as Row[]).map(r => <tr key={r.id}><td><div className="td-strong">{r.trade_name || r.legal_name}</div><div className="td-muted">{r.legal_name}</div></td><td className="mono">{r.gstin ?? '—'}</td>
        <td>{levelLabel(r.verification_level)}</td><td><Status s={r.suspended_at ? 'suspended' : r.verification_status} /></td>
        <td className="row">{can('suppliers') && r.verification_status !== 'approved' && <button className="btn btn-success btn-sm" onClick={() => set(r, 'approved', 'business_verified')}>Approve</button>}
          {can('suppliers') && r.verification_status === 'approved' && r.verification_level !== 'factory_verified' && <button className="btn btn-outline btn-sm" onClick={() => set(r, 'approved', 'factory_verified')}>Mark factory verified</button>}
          {can('suppliers') && r.verification_status !== 'rejected' && <button className="btn btn-ghost btn-sm" onClick={() => set(r, 'rejected', r.verification_level)}>Reject</button>}
          {can('suppliers') && <button className="btn btn-ghost btn-sm" onClick={() => suspend(r)}>{r.suspended_at ? 'Unsuspend' : 'Suspend'}</button>}
          {can('suppliers') && r.verification_status === 'approved' && <button className="btn btn-ghost btn-sm" onClick={() => slug(r)}>Set slug</button>}</td></tr>)}</tbody></table>}</Card></>)
}

export function Users() {
  const { can } = useAuth(); const [creating, setCreating] = useState(false)
  const q = useQuery(() => supabase.from('organizations').select('*').order('created_at', { ascending: false }).limit(200), [])
  const [role, setRole] = useState(''); const [s, setS] = useState('')
  const rows = (q.rows as Row[]).filter(r => (!role || r.type === role) && (r.legal_name + (r.trade_name ?? '')).toLowerCase().includes(s.toLowerCase()))
  return (<>
    <div className="filter-bar"><div className="search-input-wrap"><span className="search-icon">🔍</span><input className="search-input" placeholder="Search…" value={s} onChange={e => setS(e.target.value)} /></div>
      <select className="filter-select" value={role} onChange={e => setRole(e.target.value)}><option value="">All Roles</option><option value="buyer">Buyer</option><option value="manufacturer">Supplier</option></select>
      {can('users') && <button className="btn btn-primary btn-sm" style={{ marginLeft: 'auto' }} onClick={() => setCreating(true)}>+ Create Account</button>}</div>
    <Err m={q.err} />
    <Card flush>{q.loading ? <Loading /> : <table><thead><tr><th>Business</th><th>Role</th><th>GST</th><th>Verification</th><th>Joined</th><th></th></tr></thead><tbody>
      {rows.map(r => <tr key={r.id}><td><div className="td-strong">{r.trade_name || r.legal_name}</div></td><td><Chip c={r.type === 'buyer' ? 'blue' : 'orange'}>{r.type === 'buyer' ? 'Buyer' : 'Supplier'}</Chip></td>
        <td className="mono">{r.gstin ?? '—'}</td><td><Status s={r.suspended_at ? 'suspended' : r.verification_status} /></td><td className="td-muted">{fdate(r.created_at)}</td><td>{(can('users') || can('suppliers')) && <button className="btn btn-ghost btn-sm" onClick={() => suspendOrg(r, q.reload)}>{r.suspended_at ? 'Unsuspend' : 'Suspend'}</button>}</td></tr>)}</tbody></table>}</Card>
    {creating && <CreateAccount onClose={() => setCreating(false)} onDone={() => { setCreating(false); q.reload() }} />}</>)
}
