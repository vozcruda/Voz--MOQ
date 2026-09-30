import { useState } from 'react'
import { supabase, inr, fdate, rpc, type Row } from '../supabase'
import { useAuth } from '../auth'
import { useQuery, Err, Status, Card, Empty, Loading, Modal, Field } from '../ui/kit'

/* ───────────── Create batch ───────────── */
type Tier = { qty: string; price: string }
export function CreateBatch({ onClose, onDone }: { onClose: () => void; onDone: (id: string) => void }) {
  const prods = useQuery(() => supabase.from('products').select('id,title,min_moq,gsm,organizations(legal_name,trade_name)').eq('status', 'approved').is('deleted_at', null), [])
  const [f, setF] = useState({ product: '', title: '', moq: '500', target: '1000', min: '50', max: '250', deadline: '', window: '1440', open: true })
  const [sell, setSell] = useState<Tier[]>([{ qty: '100', price: '' }, { qty: '500', price: '' }])
  const [cost, setCost] = useState<Tier[]>([{ qty: '100', price: '' }, { qty: '500', price: '' }])
  const [err, setErr] = useState(''); const [busy, setBusy] = useState(false)
  const up = (k: string, v: string | boolean) => setF({ ...f, [k]: v })
  const pick = (id: string) => { const p = (prods.rows as Row[]).find(x => x.id === id); setF({ ...f, product: id, title: p?.title ?? f.title, moq: p?.min_moq ? String(p.min_moq) : f.moq }) }
  const tiers = (t: Tier[]) => t.filter(x => x.qty && x.price).map(x => ({ min_total_qty: +x.qty, unit_price_paise: Math.round(+x.price * 100) }))
  const tierEditor = (label: string, t: Tier[], set: (t: Tier[]) => void, hint: string) => (
    <div className="form-group"><label className="form-label">{label}</label>
      {t.map((x, i) => <div className="form-row" key={i} style={{ marginBottom: 6 }}>
        <input className="form-input" type="number" placeholder="From total qty" value={x.qty} onChange={e => set(t.map((y, j) => j === i ? { ...y, qty: e.target.value } : y))} />
        <input className="form-input" type="number" placeholder="₹ per piece" value={x.price} onChange={e => set(t.map((y, j) => j === i ? { ...y, price: e.target.value } : y))} /></div>)}
      <button className="link" onClick={() => set([...t, { qty: '', price: '' }])}>+ add tier</button><div className="form-hint">{hint}</div></div>)
  const save = async () => {
    setErr(''); setBusy(true)
    if (!f.product || !f.title || !f.deadline) { setBusy(false); return setErr('Product, title and deadline are required.') }
    const s = tiers(sell), c = tiers(cost)
    if (!s.length || !c.length) { setBusy(false); return setErr('Add at least one buyer price tier and one supplier cost tier.') }
    const { data, error } = await supabase.rpc('admin_create_pool', { p_title: f.title, p_spec: {}, p_moq: +f.moq, p_target: +f.target, p_min_commit: +f.min, p_max_commit: +f.max,
      p_deadline: new Date(f.deadline + 'T23:59:00').toISOString(), p_product: f.product, p_price_tiers: s, p_cost_tiers: c, p_payment_window_minutes: +f.window })
    if (error) { setBusy(false); return setErr(error.message) }
    const id = data as string
    if (f.open) { const e = await rpc('admin_open_pool', { p_pool: id }); if (e) { setBusy(false); setErr('Created as draft, but opening failed: ' + e); return } }
    setBusy(false); onDone(id)
  }
  return (
    <Modal title="Create Batch" sub="Buyer prices are public; supplier costs stay private to admin" onClose={onClose}
      footer={<><button className="btn btn-outline" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy} onClick={save}>{busy ? 'Creating…' : f.open ? 'Create & open' : 'Save as draft'}</button></>}>
      <Field label="Approved product"><select className="form-input" value={f.product} onChange={e => pick(e.target.value)}><option value="">Select…</option>
        {(prods.rows as Row[]).map(p => <option key={p.id} value={p.id}>{p.title} — {p.organizations?.trade_name || p.organizations?.legal_name}</option>)}</select></Field>
      <Err m={prods.err} />
      <Field label="Batch title"><input className="form-input" value={f.title} onChange={e => up('title', e.target.value)} /></Field>
      <div className="form-row"><Field label="MOQ (pieces)"><input className="form-input" type="number" value={f.moq} onChange={e => up('moq', e.target.value)} /></Field>
        <Field label="Capacity cap" hint="Must be ≥ MOQ"><input className="form-input" type="number" value={f.target} onChange={e => up('target', e.target.value)} /></Field></div>
      <div className="form-row"><Field label="Min per buyer"><input className="form-input" type="number" value={f.min} onChange={e => up('min', e.target.value)} /></Field>
        <Field label="Max per buyer"><input className="form-input" type="number" value={f.max} onChange={e => up('max', e.target.value)} /></Field></div>
      <div className="form-row"><Field label="Closes on"><input className="form-input" type="date" value={f.deadline} onChange={e => up('deadline', e.target.value)} /></Field>
        <Field label="Payment window (min)"><input className="form-input" type="number" value={f.window} onChange={e => up('window', e.target.value)} /></Field></div>
      {tierEditor('Buyer price tiers', sell, setSell, 'Price must not rise as quantity grows.')}
      {tierEditor('Supplier cost tiers', cost, setCost, 'What Voz Cruda pays the factory at each pool size.')}
      <label className="row" style={{ fontSize: 13 }}><input type="checkbox" checked={f.open} onChange={e => up('open', e.target.checked)} /> Open for buyers immediately</label>
      <Err m={err} />
    </Modal>
  )
}

/* ───────────── Orders ───────────── */
const ORDER_NEXT: Record<string, string[]> = { confirmed: ['in_production'], in_production: ['qc_passed'], qc_passed: ['ready_to_ship'], ready_to_ship: ['shipped'], shipped: ['delivered', 'disputed'], delivered: ['completed', 'disputed'], completed: ['disputed'] }
export function Orders() {
  const { can } = useAuth()
  const q = useQuery(() => supabase.from('orders').select('*, buyer:buyer_org_id(legal_name, trade_name), pool:pool_id(title, pool_no)').order('created_at', { ascending: false }).limit(200), [])
  const [st, setSt] = useState('')
  const rows = (q.rows as Row[]).filter(o => !st || o.status === st)
  const mv = async (o: Row, to: string) => { const note = prompt('Note (optional)') ?? null; const e = await rpc('admin_set_order_status', { p_order: o.id, p_to: to, p_note: note }); if (e) alert(e); q.reload() }
  return (<>
    <div className="filter-bar"><select className="filter-select" value={st} onChange={e => setSt(e.target.value)}><option value="">All Statuses</option>
      {['confirmed', 'in_production', 'qc_passed', 'ready_to_ship', 'shipped', 'delivered', 'completed', 'disputed', 'cancelled'].map(s => <option key={s} value={s}>{s.replace(/_/g, ' ')}</option>)}</select></div>
    <Err m={q.err} />
    <Card flush>{q.loading ? <Loading /> : !rows.length ? <Empty icon="📦" title="No orders yet" desc="Orders are created when a purchase order is placed for a batch." /> : <table><thead><tr><th>Order</th><th>Buyer</th><th>Batch</th><th>Total</th><th>Ship by</th><th>Status</th><th></th></tr></thead><tbody>
      {rows.map(o => <tr key={o.id}><td className="td-strong">{o.order_no}</td><td>{o.buyer?.trade_name || o.buyer?.legal_name}</td><td>{o.pool?.title}</td><td>{inr(o.total_paise)}</td><td className="td-muted">{fdate(o.expected_ship_date)}</td><td><Status s={o.status} /></td>
        <td className="row">{(can('orders') ? ORDER_NEXT[o.status] ?? [] : []).map(t => <button key={t} className={'btn btn-sm ' + (t === 'disputed' ? 'btn-ghost' : 'btn-outline')} onClick={() => mv(o, t)}>{t === 'disputed' ? 'Flag dispute' : '→ ' + t.replace(/_/g, ' ')}</button>)}</td></tr>)}</tbody></table>}</Card></>)
}

/* ───────────── Disputes ───────────── */
export function Disputes() {
  const { can } = useAuth()
  const q = useQuery(() => supabase.from('disputes').select('*, buyer:buyer_org_id(legal_name, trade_name), order:order_id(order_no, total_paise)').order('created_at', { ascending: false }), [])
  const resolve = async (d: Row, refund: boolean) => { const note = prompt(refund ? 'Resolution note (refund will be issued)' : 'Resolution note (no refund)'); if (!note) return; const e = await rpc('admin_resolve_dispute', { p_dispute: d.id, p_refund: refund, p_resolution: note }); if (e) alert(e); q.reload() }
  return (<><Err m={q.err} />
    <Card flush>{q.loading ? <Loading /> : !q.rows.length ? <Empty icon="⚖️" title="No disputes" /> : <table><thead><tr><th>Dispute</th><th>Buyer</th><th>Order</th><th>Reason</th><th>Status</th><th></th></tr></thead><tbody>
      {(q.rows as Row[]).map(d => <tr key={d.id}><td className="td-strong">{d.dispute_no}<div className="td-muted">{fdate(d.created_at)}</div></td><td>{d.buyer?.trade_name || d.buyer?.legal_name}</td><td>{d.order?.order_no}<div className="td-muted">{inr(d.order?.total_paise)}</div></td>
        <td style={{ maxWidth: 280 }}>{d.reason}{d.resolution && <div className="td-muted">Resolution: {d.resolution}</div>}</td><td><Status s={d.status} /></td>
        <td className="row">{can('disputes') && d.status === 'open' && <><button className="btn btn-success btn-sm" onClick={() => resolve(d, true)}>Refund</button><button className="btn btn-outline btn-sm" onClick={() => resolve(d, false)}>Resolve, no refund</button></>}</td></tr>)}</tbody></table>}</Card></>)
}

/* ───────────── Settings ───────────── */
export function Settings() {
  const { can } = useAuth()
  const q = useQuery(() => supabase.from('app_settings').select('*').order('key'), [])
  const [edit, setEdit] = useState<Row | null>(null); const [val, setVal] = useState(''); const [err, setErr] = useState('')
  const save = async () => {
    setErr(''); let parsed: unknown
    try { parsed = JSON.parse(val) } catch { return setErr('Value must be valid JSON (e.g. 30, "text", {"a":1}).') }
    const { error } = await supabase.from('app_settings').update({ value: parsed, updated_at: new Date().toISOString() }).eq('key', edit!.key)
    if (error) return setErr(error.message); setEdit(null); q.reload()
  }
  return (<><Err m={q.err} />
    <Card title="Platform settings" flush>{q.loading ? <Loading /> : !q.rows.length ? <Empty icon="⚙️" title="No settings" /> : <table><thead><tr><th>Key</th><th>Value</th><th>Updated</th><th></th></tr></thead><tbody>
      {(q.rows as Row[]).map(s => <tr key={s.key}><td className="mono">{s.key}</td><td className="mono" style={{ maxWidth: 360, wordBreak: 'break-all' }}>{JSON.stringify(s.value)}</td><td className="td-muted">{fdate(s.updated_at)}</td>
        <td>{can('settings') && <button className="btn btn-outline btn-sm" onClick={() => { setEdit(s); setVal(JSON.stringify(s.value, null, 2)); setErr('') }}>Edit</button>}</td></tr>)}</tbody></table>}</Card>
    {edit && <Modal title={edit.key} sub="Value is stored as JSON" onClose={() => setEdit(null)} footer={<><button className="btn btn-outline" onClick={() => setEdit(null)}>Cancel</button><button className="btn btn-primary" onClick={save}>Save</button></>}>
      <textarea className="form-input mono" rows={8} value={val} onChange={e => setVal(e.target.value)} /><Err m={err} /></Modal>}</>)
}
