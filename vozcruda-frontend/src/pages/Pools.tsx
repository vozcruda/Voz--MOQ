import { useState } from 'react'
import { supabase, inr, fdate, daysLeft, rpc, pubUrl, type Row } from '../supabase'
import { useAuth } from '../auth'
import { useQuery, Err, Status, Chip, Progress, pct, Empty, Loading, Modal, Field, Section, Card } from '../ui/kit'

export interface Pool { id: string; no: string; title: string; moq: number; target: number; paid: number; reserved: number
  deadline: string; status: string; min: number; max: number; level?: string; spec: Row; productId?: string; raw: Row }
export const normPool = (r: Row): Pool => ({
  id: r.pool_id ?? r.id, no: r.pool_no, title: r.title, moq: r.moq_qty, target: r.target_qty, paid: r.paid_qty ?? 0,
  reserved: r.reserved_qty ?? 0, deadline: r.deadline_at, status: r.status, min: r.min_commit_qty, max: r.max_commit_qty,
  level: r.supplier_level, spec: r.spec_snapshot ?? {}, productId: r.product_id, raw: r,
})
export const levelLabel = (l?: string) => (l ? l.replace(/_/g, ' ') : '')
/** Price in paise at a given pool size, from tier rows {min_total_qty, unit_price_paise}. */
export const priceAt = (tiers: Row[], qty: number): number | null => {
  const s = [...tiers].sort((a, b) => a.min_total_qty - b.min_total_qty)
  if (!s.length) return null
  let p = s[0].unit_price_paise
  for (const t of s) if (qty >= t.min_total_qty) p = t.unit_price_paise
  return p
}

export function usePools(all: boolean) {
  const pools = useQuery(() => all ? supabase.from('moq_pools').select('*').order('created_at', { ascending: false })
    : supabase.from('open_pools').select('*').order('deadline_at'), [all])
  const tiers = useQuery(() => supabase.from(all ? 'pool_price_tiers' : 'open_pool_price_tiers').select('*'), [all])
  const pics = useQuery(() => supabase.from('pool_images').select('pool_id, position, object_key'), [all])
  const byPool = (id: string) => tiers.rows.filter((t: Row) => t.pool_id === id)
  const cover = (id: string): string | undefined => { const r = (pics.rows as Row[]).filter(x => x.pool_id === id).sort((a, b) => a.position - b.position)[0]; return r ? pubUrl(r.object_key) : undefined }
  return { pools: (pools.rows as Row[]).map(normPool), byPool, cover, err: pools.err, loading: pools.loading, reload: pools.reload }
}

export function PoolCard({ p, tiers, img, onOpen }: { p: Pool; tiers: Row[]; img?: string; onOpen: (id: string) => void }) {
  const price = priceAt(tiers, p.paid)
  const closed = !['open', 'moq_reached'].includes(p.status)
  return (
    <div className="product-card" onClick={() => onOpen(p.id)}>
      <div className="product-image">{img ? <img src={img} alt={p.title} loading="lazy" /> : <span className="product-image-emoji">📦</span>}
        <span className={'product-status-badge ' + (closed ? 'badge-production' : p.paid >= p.moq ? 'badge-active' : 'badge-moq')}>
          {p.paid >= p.moq && !closed ? 'MOQ reached' : p.status.replace(/_/g, ' ')}</span></div>
      <div className="product-body">
        <div className="product-category">{p.no}</div>
        <div className="product-title">{p.title}</div>
        <div className="product-supplier">{p.level ? levelLabel(p.level) + ' supplier' : 'Verified supplier'}</div>
        <div className="progress-section">
          <div className="progress-header"><span className="progress-filled">{p.paid} pcs</span><span className="progress-target">MOQ: {p.moq}</span></div>
          <Progress done={p.paid} total={p.moq} />
          <div className="progress-meta">
            <div className="progress-meta-item">🎯 <strong>{Math.max(0, p.moq - p.paid)} remaining</strong></div>
            <div className="progress-meta-item">📅 <strong>{daysLeft(p.deadline)} days</strong> left</div>
          </div>
        </div>
        <div className="product-footer">
          <div className="product-price">{inr(price)} <span>/ piece</span></div>
          <button className={'btn btn-sm ' + (closed ? 'btn-outline' : 'btn-primary')}>{closed ? 'View' : 'Join Batch'}</button>
        </div>
      </div>
    </div>
  )
}

export function PoolsBrowse({ admin, onOpen }: { admin: boolean; onOpen: (id: string) => void }) {
  const { pools, byPool, cover, err, loading } = usePools(admin)
  const [q, setQ] = useState(''); const [st, setSt] = useState('')
  const list = pools.filter(p => p.title.toLowerCase().includes(q.toLowerCase()) && (!st || p.status === st))
  return (<>
    <div className="filter-bar">
      <div className="search-input-wrap"><span className="search-icon">🔍</span>
        <input className="search-input" placeholder="Search batches…" value={q} onChange={e => setQ(e.target.value)} /></div>
      {admin && <select className="filter-select" value={st} onChange={e => setSt(e.target.value)}>
        <option value="">All Status</option>{['draft', 'open', 'moq_reached', 'po_placed', 'cancelled', 'expired'].map(s => <option key={s} value={s}>{s.replace(/_/g, ' ')}</option>)}</select>}
    </div>
    <Err m={err} />
    {loading ? <Loading /> : !list.length ? <Empty icon="📦" title="No batches yet" desc="Open batches will appear here." /> :
      <div className="products-grid">{list.map(p => <PoolCard key={p.id} p={p} tiers={byPool(p.id)} img={cover(p.id)} onOpen={onOpen} />)}</div>}
  </>)
}

export function PoolDetail({ id, onBack, goPage }: { id: string; onBack: () => void; goPage: (p: string) => void }) {
  const { role, org, can } = useAuth(); const admin = role === 'admin'
  const [join, setJoin] = useState(false); const [msg, setMsg] = useState(''); const [bad, setBad] = useState(false)
  const pr = useQuery(() => admin ? supabase.from('moq_pools').select('*').eq('id', id) : supabase.from('open_pools').select('*').eq('pool_id', id), [id, admin])
  const tr = useQuery(() => supabase.from(admin ? 'pool_price_tiers' : 'open_pool_price_tiers').select('*').eq('pool_id', id).order('min_total_qty'), [id, admin])
  const cm = useQuery(() => supabase.from('pool_commitments').select('*, buyer:buyer_org_id(legal_name, trade_name), pool_commitment_items(size, color, qty)').eq('pool_id', id).order('created_at', { ascending: false }), [id])
  const pics = useQuery(() => supabase.from('pool_images').select('position, object_key, alt_text').eq('pool_id', id).order('position'), [id])
  const [shot, setShot] = useState(0)
  const po = useQuery(() => admin ? supabase.from('purchase_orders').select('id, po_no, status').eq('pool_id', id) : Promise.resolve({ data: [], error: null }), [id, admin])
  if (pr.loading) return <Loading />
  const raw = (pr.rows as Row[])[0]
  if (!raw) return <><button className="btn btn-ghost btn-sm" onClick={onBack}>← Back</button><Empty title="Batch not found" desc={pr.err || 'It may be closed or not yet open.'} /></>
  const p = normPool(raw); const tiers = tr.rows as Row[]; const commits = cm.rows as Row[]
  const live = commits.filter(c => ['reserved', 'paid', 'fulfilled'].includes(c.status))
  const sizes: Record<string, number> = {}
  live.forEach(c => (c.pool_commitment_items ?? []).forEach((i: Row) => { sizes[i.size] = (sizes[i.size] ?? 0) + i.qty }))
  const act = async (name: string, args: Row, okMsg: string) => { const e = await rpc(name, args); setBad(!!e); setMsg(e ?? okMsg); pr.reload(); cm.reload(); po.reload() }
  const canJoin = !admin && role === 'buyer' && ['open', 'moq_reached'].includes(p.status)
  return (<>
    <div className="row" style={{ marginBottom: 14 }}><button className="btn btn-ghost btn-sm" onClick={onBack}>← Back</button></div>
    <div className="batch-progress-hero">
      <div className="hero-top">
        <div><div className="hero-label">{p.no} · <Status s={p.status} /></div><div className="hero-title">{p.title}</div>
          <div className="hero-supplier">{p.level ? levelLabel(p.level) + ' supplier' : ''}</div></div>
        <div style={{ textAlign: 'right' }}><div className="hero-big">{p.paid}<span className="hero-big-unit"> / {p.moq}</span></div><div className="hero-supplier">pieces paid</div></div>
      </div>
      <Progress big done={p.paid} total={p.moq} />
      <div className="hero-stats">
        <div className="hero-stat-item"><div className="hero-stat-label">Progress</div><div className="hero-stat-value">{pct(p.paid, p.moq)}%</div></div>
        <div className="hero-stat-item"><div className="hero-stat-label">Remaining</div><div className="hero-stat-value">{Math.max(0, p.moq - p.paid)} pcs</div></div>
        <div className="hero-stat-item"><div className="hero-stat-label">Days left</div><div className="hero-stat-value">{daysLeft(p.deadline)}</div></div>
        {admin && <div className="hero-stat-item"><div className="hero-stat-label">Reserved (unpaid)</div><div className="hero-stat-value">{p.reserved}</div></div>}
      </div>
    </div>
    {msg && <div className={bad ? 'err' : 'ok'}>{msg}</div>}
    <div className="two-col">
      <div className="col-main">
        {admin && <Card title={`Buyers in this batch (${commits.length})`} flush>
          {!commits.length ? <Empty title="No commitments yet" /> : <table><thead><tr><th>Buyer</th><th>Qty</th><th>Sizes / colors</th><th>Due</th><th>Status</th><th></th></tr></thead><tbody>
            {commits.map(c => <tr key={c.id}><td className="td-strong">{c.buyer?.trade_name || c.buyer?.legal_name}</td><td>{c.qty}</td>
              <td className="td-muted">{(c.pool_commitment_items ?? []).map((i: Row) => `${i.size}/${i.color}×${i.qty}`).join(', ')}</td>
              <td>{inr(c.amount_due_paise)}</td><td><Status s={c.status} /></td>
              <td>{c.status === 'reserved' && can('payments') && <button className="btn btn-outline btn-sm" onClick={() => { const ref = prompt('Payment reference (UTR)?'); if (ref) act('admin_mark_paid', { p_commitment: c.id, p_payment_ref: ref }, 'Marked paid') }}>Mark paid</button>}</td></tr>)}
          </tbody></table>}</Card>}
        {!admin && commits.length > 0 && <Card title="Your commitments" flush><table><thead><tr><th>Qty</th><th>Locked price</th><th>Total</th><th>Status</th></tr></thead><tbody>
          {commits.map(c => <tr key={c.id}><td>{c.qty}</td><td>{inr(c.unit_price_locked_paise)}</td><td>{inr(c.amount_due_paise)}</td><td><Status s={c.status} /></td></tr>)}</tbody></table></Card>}
        {admin && Object.keys(sizes).length > 0 && <Card title="Size breakdown" flush><table><tbody>{Object.entries(sizes).map(([s, q]) => <tr key={s}><td className="td-strong">{s}</td><td>{q}</td></tr>)}</tbody></table></Card>}
        <Card title="Price by pool size" flush>{!tiers.length ? <Empty title="No tiers" /> : <table><thead><tr><th>Total qty</th><th>Price / pc</th></tr></thead><tbody>
          {tiers.map(t => <tr key={t.min_total_qty}><td className={t.min_total_qty === p.moq ? 'td-strong' : ''}>{t.min_total_qty}+ {t.min_total_qty === p.moq && <Chip c="orange">MOQ</Chip>}</td><td className="td-strong">{inr(t.unit_price_paise)}</td></tr>)}</tbody></table>}</Card>
      </div>
      <div className="col-side">
        {(pics.rows as Row[]).length > 0 && <div className="info-card gallery"><div className="gallery-main"><img src={pubUrl((pics.rows as Row[])[Math.min(shot, pics.rows.length - 1)].object_key)} alt={p.title} /></div>
          {pics.rows.length > 1 && <div className="gallery-thumbs">{(pics.rows as Row[]).map((r, i) => <button key={i} className={i === shot ? 'on' : ''} onClick={() => setShot(i)} aria-label={'Photo ' + (i + 1)}><img src={pubUrl(r.object_key)} alt="" /></button>)}</div>}</div>}
        <div className="info-card"><div className="info-card-header">Batch details</div><div className="info-card-body">
          <div className="info-row"><span className="info-key">Closes</span><span className="info-val">{fdate(p.deadline)}</span></div>
          <div className="info-row"><span className="info-key">Per-buyer qty</span><span className="info-val">{p.min}–{p.max}</span></div>
          <div className="info-row"><span className="info-key">Capacity</span><span className="info-val">{p.target}</span></div>
          {Object.entries(p.spec).filter(([, v]) => typeof v !== 'object').map(([k, v]) => <div className="info-row" key={k}><span className="info-key">{k.replace(/_/g, ' ')}</span><span className="info-val">{String(v)}</span></div>)}
        </div></div>
        {canJoin && <button className="btn btn-primary" style={{ width: '100%', justifyContent: 'center' }} onClick={() => setJoin(true)}>Join Batch</button>}
        {!admin && role === 'buyer' && <p className="form-hint">Other buyers only see the total, never who committed.</p>}
        {admin && <div className="info-card"><div className="info-card-header">Admin actions</div><div className="info-card-body stack">
          {can('pools') && p.status === 'draft' && <button className="btn btn-success" onClick={() => act('admin_open_pool', { p_pool: p.id }, 'Pool opened')}>Open pool</button>}
          {can('pools') && p.status === 'moq_reached' && <button className="btn btn-primary" onClick={() => { const d = prompt('Expected ready date (YYYY-MM-DD, optional)'); act('admin_place_purchase_order', { p_pool: p.id, p_expected_ready: d || null }, 'Purchase order placed') }}>🧾 Generate Purchase Order</button>}
          {(po.rows as Row[])[0] && <button className="btn btn-outline" onClick={() => goPage('purchase-orders')}>View {(po.rows as Row[])[0].po_no}</button>}
          {can('pools') && ['open', 'moq_reached'].includes(p.status) && <button className="btn btn-outline" onClick={() => { const d = prompt('New deadline (YYYY-MM-DD)'); if (d) act('admin_extend_pool', { p_pool: p.id, p_new_deadline: new Date(d).toISOString() }, 'Deadline extended') }}>Extend deadline</button>}
          {can('pools') && ['draft', 'open', 'moq_reached'].includes(p.status) && <button className="btn btn-outline" style={{ color: 'var(--danger)' }} onClick={() => { const r = prompt('Reason for cancelling?'); if (r) act('admin_cancel_pool', { p_pool: p.id, p_reason: r }, 'Pool cancelled') }}>✖ Cancel batch</button>}
        </div></div>}
      </div>
    </div>
    {join && org && <JoinModal pool={p} tiers={tiers} buyerOrg={org.id} onClose={() => setJoin(false)} onDone={() => { setJoin(false); setBad(false); setMsg('Reserved! Pay before the reservation expires.'); cm.reload(); pr.reload() }} />}
  </>)
}

function JoinModal({ pool, tiers, buyerOrg, onClose, onDone }: { pool: Pool; tiers: Row[]; buyerOrg: string; onClose: () => void; onDone: () => void }) {
  const vars = useQuery(() => pool.productId ? supabase.from('public_product_variants').select('size,color').eq('product_id', pool.productId) : Promise.resolve({ data: [], error: null }), [pool.productId])
  const addr = useQuery(() => supabase.from('addresses').select('*').eq('organization_id', buyerOrg).is('deleted_at', null), [buyerOrg])
  const [items, setItems] = useState([{ size: '', color: '', qty: pool.min }])
  const [ship, setShip] = useState(''); const [bill, setBill] = useState(''); const [err, setErr] = useState(''); const [busy, setBusy] = useState(false)
  const [na, setNa] = useState({ line1: '', city: '', state: '', pincode: '' })
  const variants = vars.rows as Row[]; const sizes = [...new Set(variants.map(v => v.size))]; const colors = [...new Set(variants.map(v => v.color))]
  const total = items.reduce((s, i) => s + (Number(i.qty) || 0), 0)
  const price = priceAt(tiers, pool.paid + total)
  const set = (i: number, k: string, v: string | number) => setItems(items.map((x, j) => (j === i ? { ...x, [k]: v } : x)))
  const addresses = addr.rows as Row[]
  const addAddress = async () => {
    setErr('')
    const base = { organization_id: buyerOrg, ...na }
    const { data, error } = await supabase.from('addresses').insert([{ ...base, kind: 'shipping' }, { ...base, kind: 'billing' }]).select()
    if (error) return setErr(error.message)
    const d = (data as Row[]) ?? []; setShip(d.find(x => x.kind === 'shipping')?.id ?? ''); setBill(d.find(x => x.kind === 'billing')?.id ?? ''); addr.reload()
  }
  const submit = async () => {
    setErr(''); setBusy(true)
    if (total < pool.min || total > pool.max) { setBusy(false); return setErr(`Quantity must be between ${pool.min} and ${pool.max}.`) }
    if (items.some(i => !i.size || !i.color || !(i.qty > 0))) { setBusy(false); return setErr('Fill size, color and quantity on every line.') }
    if (!ship || !bill) { setBusy(false); return setErr('Choose shipping and billing addresses.') }
    const e = await rpc('reserve_commitment', { p_pool: pool.id, p_buyer_org: buyerOrg, p_qty: total,
      p_items: items.map(i => ({ size: i.size, color: i.color, qty: Number(i.qty) })), p_shipping_address: ship, p_billing_address: bill, p_idempotency_key: crypto.randomUUID() })
    setBusy(false); if (e) setErr(e); else onDone()
  }
  const pick = (opts: string[], val: string, on: (v: string) => void, ph: string) => opts.length
    ? <select className="form-input" value={val} onChange={e => on(e.target.value)}><option value="">{ph}</option>{opts.map(o => <option key={o}>{o}</option>)}</select>
    : <input className="form-input" placeholder={ph} value={val} onChange={e => on(e.target.value)} />
  return (
    <Modal title={`Join Batch — ${pool.title}`} sub={`${Math.max(0, pool.moq - pool.paid)} pieces to MOQ · ${inr(price)}/piece`} onClose={onClose}
      footer={<><button className="btn btn-outline" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy} onClick={submit}>{busy ? 'Reserving…' : 'Reserve & Pay →'}</button></>}>
      {items.map((it, i) => <div className="form-row-3" key={i}>
        {pick(sizes, it.size, v => set(i, 'size', v), 'Size')}{pick(colors, it.color, v => set(i, 'color', v), 'Color')}
        <input className="form-input" type="number" min={1} value={it.qty} onChange={e => set(i, 'qty', +e.target.value)} /></div>)}
      <button className="link" onClick={() => setItems([...items, { size: '', color: '', qty: 1 }])}>+ add size / color</button>
      <div className="form-hint" style={{ marginBottom: 14 }}>Allowed {pool.min}–{pool.max} pcs in total.</div>
      <Field label="Shipping address"><select className="form-input" value={ship} onChange={e => setShip(e.target.value)}><option value="">Select…</option>
        {addresses.filter(a => a.kind === 'shipping').map(a => <option key={a.id} value={a.id}>{a.line1}, {a.city} {a.pincode}</option>)}</select></Field>
      <Field label="Billing address"><select className="form-input" value={bill} onChange={e => setBill(e.target.value)}><option value="">Select…</option>
        {addresses.filter(a => a.kind === 'billing').map(a => <option key={a.id} value={a.id}>{a.line1}, {a.city} {a.pincode}</option>)}</select></Field>
      {!addresses.length && <div className="res-summary"><div className="form-label">Add an address (used for shipping & billing)</div>
        <input className="form-input" placeholder="Address line" value={na.line1} onChange={e => setNa({ ...na, line1: e.target.value })} style={{ marginBottom: 8 }} />
        <div className="form-row"><input className="form-input" placeholder="City" value={na.city} onChange={e => setNa({ ...na, city: e.target.value })} />
          <input className="form-input" placeholder="State" value={na.state} onChange={e => setNa({ ...na, state: e.target.value })} /></div>
        <input className="form-input" placeholder="Pincode (6 digits)" value={na.pincode} onChange={e => setNa({ ...na, pincode: e.target.value })} style={{ margin: '8px 0' }} />
        <button className="btn btn-outline btn-sm" onClick={addAddress}>Save address</button></div>}
      <div className="res-summary">
        <div className="res-summary-row"><span className="key">Quantity × price</span><span>{total} × {inr(price)}</span></div>
        <div className="res-summary-row"><span className="key">Estimated total (excl. GST)</span><span>{price ? inr(price * total) : '—'}</span></div>
      </div>
      <p className="form-hint">Price is locked at reservation; if the pool reaches a cheaper tier you receive the difference as a rebate.</p>
      <Err m={err || addr.err} />
    </Modal>
  )
}
export { Section }
