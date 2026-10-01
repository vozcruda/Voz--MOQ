import { Fragment, useState } from 'react'
import { supabase, inr, fdate, daysLeft, rpc, type Row } from '../supabase'
import { useQuery, Err, Status, Chip, Stats, Stat, Progress, pct, Section, Card, Empty, Loading } from '../ui/kit'
import { usePools, levelLabel } from './Pools'
import { useAuth } from '../auth'
import { CreateAccount } from './AdminTeam'

export function AdminDashboard({ open, go }: { open: (id: string) => void; go: (p: string) => void }) {
  const { pools } = usePools(true)
  const pend = useQuery(() => supabase.from('organizations').select('id').eq('type', 'manufacturer').eq('verification_status', 'pending'), [])
  const buyers = useQuery(() => supabase.from('organizations').select('id').eq('type', 'buyer'), [])
  const res = useQuery(() => supabase.from('pool_commitments').select('amount_due_paise').eq('status', 'reserved'), [])
  const disp = useQuery(() => supabase.from('disputes').select('id').eq('status', 'open'), [])
  const log = useQuery(() => supabase.from('audit_logs').select('*').order('created_at', { ascending: false }).limit(6), [])
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
      <div><Section title="Recent Activity" />
        <Card flush>{!log.rows.length ? <Empty title="No activity yet" /> : <div className="activity-feed">
          {(log.rows as Row[]).map(l => <div className="activity-item" key={l.id}><div className="activity-dot" style={{ background: 'rgba(212,85,26,0.12)' }}>📝</div>
            <div className="activity-content"><div className="activity-title">{String(l.action).replace(/_/g, ' ')}</div><div className="activity-meta">{l.entity_type} · {fdate(l.created_at)}</div></div></div>)}</div>}</Card>
        <Err m={log.err} />
      </div>
    </div>
  </>)
}

export function Reservations() {
  const { can } = useAuth()
  const q = useQuery(() => supabase.from('pool_commitments').select('*, buyer:buyer_org_id(legal_name, trade_name), pool:pool_id(pool_no, title)').order('created_at', { ascending: false }).limit(100), [])
  const [st, setSt] = useState('')
  const rows = (q.rows as Row[]).filter(r => !st || r.status === st)
  return (<>
    <div className="filter-bar"><select className="filter-select" value={st} onChange={e => setSt(e.target.value)}><option value="">All Statuses</option>
      {['reserved', 'paid', 'fulfilled', 'cancelled', 'expired', 'refund_pending', 'refunded'].map(s => <option key={s} value={s}>{s.replace(/_/g, ' ')}</option>)}</select></div>
    <Err m={q.err} />
    <Card flush>{q.loading ? <Loading /> : !rows.length ? <Empty title="No reservations" /> : <table><thead><tr><th>Buyer</th><th>Batch</th><th>Qty</th><th>Total</th><th>Status</th><th>Date</th><th></th></tr></thead><tbody>
      {rows.map(r => <tr key={r.id}><td className="td-strong">{r.buyer?.trade_name || r.buyer?.legal_name}</td><td>{r.pool?.title}<div className="td-muted">{r.pool?.pool_no}</div></td><td>{r.qty}</td><td>{inr(r.amount_due_paise)}</td><td><Status s={r.status} /></td><td className="td-muted">{fdate(r.created_at)}</td>
        <td className="row">{can('payments') && r.status === 'reserved' && <button className="btn btn-outline btn-sm" onClick={async () => { const ref = prompt('Payment reference (UTR)?'); if (!ref) return; const e = await rpc('admin_mark_paid', { p_commitment: r.id, p_payment_ref: ref }); if (e) alert(e); q.reload() }}>Mark paid</button>}
          {can('payments') && ['reserved', 'paid'].includes(r.status) && <button className="btn btn-ghost btn-sm" style={{ color: 'var(--danger)' }} onClick={async () => { const why = prompt('Reason for cancelling this reservation?'); if (!why) return; const e = await rpc('admin_cancel_commitment', { p_commitment: r.id, p_reason: why }); if (e) alert(e); q.reload() }}>Cancel</button>}</td></tr>)}</tbody></table>}</Card></>)
}

const PO_NEXT: Record<string, string[]> = { sent: ['cancelled'], accepted: ['in_production'], in_production: ['ready'], ready: ['shipped_to_voz'], shipped_to_voz: ['received'], received: ['closed'] }
export function PurchaseOrders({ role }: { role: 'admin' | 'supplier' }) {
  const { can } = useAuth()
  const q = useQuery(() => supabase.from('purchase_orders').select('*, pool:pool_id(title, pool_no), mfr:manufacturer_org_id(legal_name, trade_name), purchase_order_items(size,color,qty)').order('created_at', { ascending: false }), [])
  const [open, setOpen] = useState<string | null>(null)
  const mv = async (id: string, to: string) => { const e = await rpc('update_po_status', { p_po: id, p_to: to }); if (e) alert(e); q.reload() }
  const supplierNext = (s: string) => (s === 'sent' ? ['accepted', 'rejected'] : (PO_NEXT[s] ?? []).filter(x => ['in_production', 'ready'].includes(x)))
  return (<><Err m={q.err} />
    <Card flush>{q.loading ? <Loading /> : !q.rows.length ? <Empty icon="🧾" title="No purchase orders" desc="A PO is created when a batch reaches its MOQ." /> : <table><thead><tr><th>PO</th><th>Batch</th>{role === 'admin' && <th>Supplier</th>}<th>Qty</th><th>Amount</th><th>Status</th><th>Date</th><th></th></tr></thead><tbody>
      {(q.rows as Row[]).map(p => <Fragment key={p.id}><tr><td className="td-strong">{p.po_no}</td><td>{p.pool?.title}</td>{role === 'admin' && <td>{p.mfr?.trade_name || p.mfr?.legal_name}</td>}
        <td>{p.total_qty}</td><td>{inr(p.total_cost_paise)}</td><td><Status s={p.status} /></td><td className="td-muted">{fdate(p.created_at)}</td>
        <td className="row">{(role === 'admin' ? (can('orders') ? PO_NEXT[p.status] ?? [] : []) : supplierNext(p.status)).map(t => <button key={t} className="btn btn-outline btn-sm" onClick={() => mv(p.id, t)}>{t.replace(/_/g, ' ')}</button>)}
          {role === 'admin' && can('orders') && !['cancelled', 'closed', 'received'].includes(p.status) && <button className="btn btn-ghost btn-sm" style={{ color: 'var(--danger)' }} onClick={async () => { const why = prompt('Reason for cancelling this PO?'); if (!why) return; const e = await rpc('admin_cancel_po', { p_po: p.id, p_reason: why }); if (e) alert(e); q.reload() }}>Cancel</button>}
          <button className="btn btn-ghost btn-sm" onClick={() => setOpen(open === p.id ? null : p.id)}>{open === p.id ? 'Hide' : 'View'}</button></td></tr>
        {open === p.id && <tr key={p.id + 'd'}><td colSpan={8}><table className="po-table"><thead><tr><th>Size</th><th>Color</th><th>Qty</th></tr></thead><tbody>
          {(p.purchase_order_items ?? []).map((i: Row, k: number) => <tr key={k}><td>{i.size}</td><td>{i.color}</td><td>{i.qty}</td></tr>)}</tbody></table>
          <div className="po-total-row total"><span>Unit cost {inr(p.unit_cost_paise)}</span><span>Total {inr(p.total_cost_paise)}</span></div>
          {p.expected_ready_date && <div className="td-muted">Expected ready: {fdate(p.expected_ready_date)}</div>}</td></tr>}</Fragment>)}</tbody></table>}</Card></>)
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
