import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { supabase, inr, fdate, rpc, type Row } from '../supabase'
import { useQuery, Err, Status, Modal, Field } from '../ui/kit'

const nm = (o?: Row) => o?.trade_name || o?.legal_name || '—'

/* ───────── small "ask for a note" dialog (replaces browser prompt()) ───────── */
export function NoteDialog({ title, sub, label, placeholder, confirm, required = true, danger, extra, onSubmit, onClose }: {
  title: string; sub?: string; label: string; placeholder?: string; confirm: string; required?: boolean; danger?: boolean; extra?: ReactNode
  onSubmit: (note: string) => Promise<string | null>; onClose: () => void
}) {
  const [v, setV] = useState(''); const [err, setErr] = useState(''); const [busy, setBusy] = useState(false)
  const go = async () => {
    if (required && !v.trim()) return setErr('This field is required.')
    setBusy(true); setErr(''); const e = await onSubmit(v.trim()); setBusy(false); if (e) return setErr(e); onClose()
  }
  return (
    <Modal title={title} sub={sub} onClose={onClose} footer={<><button className="btn btn-outline" onClick={onClose}>Cancel</button>
      <button className={'btn ' + (danger ? 'btn-danger' : 'btn-primary')} disabled={busy} onClick={go}>{busy ? 'Working…' : confirm}</button></>}>
      {extra}
      <Field label={label}><textarea className="form-input" rows={3} value={v} placeholder={placeholder} onChange={e => setV(e.target.value)} autoFocus /></Field><Err m={err} /></Modal>)
}

/* ───────── manual reservation ───────── */
type Line = { size: string; color: string; qty: string }
export function ManualReservation({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const pools = useQuery(() => supabase.from('moq_pools').select('id, pool_no, title, product_id, moq_qty, target_qty, paid_qty, reserved_qty, min_commit_qty, max_commit_qty, deadline_at, status').in('status', ['open', 'moq_reached']).order('created_at', { ascending: false }), [])
  const buyers = useQuery(() => supabase.from('organizations').select('id, legal_name, trade_name').eq('type', 'buyer').is('deleted_at', null).is('suspended_at', null).order('legal_name'), [])
  const [pool, setPool] = useState(''); const [buyer, setBuyer] = useState('')
  const tiers = useQuery(() => supabase.from('pool_price_tiers').select('min_total_qty, unit_price_paise').eq('pool_id', pool || '00000000-0000-0000-0000-000000000000'), [pool])
  const sel = (pools.rows as Row[]).find(p => p.id === pool)
  const vars = useQuery(() => supabase.from('product_variants').select('size, color, is_active').eq('product_id', sel?.product_id ?? '00000000-0000-0000-0000-000000000000'), [sel?.product_id])
  const addr = useQuery(() => supabase.from('addresses').select('id, kind, line1, city, state, pincode, is_default').eq('organization_id', buyer || '00000000-0000-0000-0000-000000000000').is('deleted_at', null).order('is_default', { ascending: false }), [buyer])
  const [lines, setLines] = useState<Line[]>([{ size: '', color: '', qty: '' }])
  const [ship, setShip] = useState(''); const [paid, setPaid] = useState(false); const [ref, setRef] = useState(''); const [over, setOver] = useState(false); const [note, setNote] = useState('')
  const [na, setNa] = useState({ line1: '', city: '', state: '', pincode: '' }); const [err, setErr] = useState(''); const [busy, setBusy] = useState(false)
  useEffect(() => { setShip('') }, [buyer])
  const active = ((vars.rows as Row[]) ?? []).filter(v => v.is_active !== false)
  const sizes = [...new Set(active.map(v => String(v.size)))]; const colors = [...new Set(active.map(v => String(v.color)))]
  const qty = lines.reduce((s, l) => s + (Number(l.qty) || 0), 0)
  const locked = useMemo(() => { if (!sel) return null; const t = (tiers.rows as Row[]).filter(x => x.min_total_qty <= sel.moq_qty).sort((a, b) => b.min_total_qty - a.min_total_qty)[0]; return t ? Number(t.unit_price_paise) : null }, [sel, tiers.rows])
  const left = sel ? Math.max(sel.target_qty - sel.paid_qty - sel.reserved_qty, 0) : 0
  const shipAddrs = (addr.rows as Row[]).filter(a => a.kind === 'shipping')
  const noAddr = !!buyer && !addr.loading && !addr.rows.length
  const setLine = (i: number, k: keyof Line, v: string) => setLines(lines.map((l, j) => j === i ? { ...l, [k]: v } : l))
  const save = async () => {
    setErr('')
    if (!pool || !buyer) return setErr('Choose a batch and a buyer.')
    const items = lines.filter(l => l.size.trim() || l.color.trim() || l.qty).map(l => ({ size: l.size.trim(), color: l.color.trim(), qty: Number(l.qty) }))
    if (!items.length || items.some(i => !i.size || !i.color || !(i.qty > 0))) return setErr('Each line needs a size, a colour and a quantity.')
    if (paid && !ref.trim()) return setErr('Enter the payment reference (UTR) or untick “already paid”.')
    setBusy(true)
    let shipId: string | null = ship || null
    if (noAddr) {
      if (!na.line1.trim() || !na.city.trim() || !na.state.trim() || !/^\d{6}$/.test(na.pincode)) { setBusy(false); return setErr('This buyer has no address yet. Fill in the shipping address (6-digit pincode).') }
      const { data, error } = await supabase.rpc('admin_add_address', { p_org: buyer, p_kind: 'shipping', p_line1: na.line1, p_line2: '', p_city: na.city, p_state: na.state, p_pincode: na.pincode })
      if (error) { setBusy(false); return setErr(error.message) }
      shipId = data as string
    }
    const { error } = await supabase.rpc('admin_create_reservation', { p_pool: pool, p_buyer_org: buyer, p_qty: items.reduce((s, i) => s + i.qty, 0), p_items: items,
      p_shipping_address: shipId, p_billing_address: null, p_payment_ref: paid ? ref.trim() : null, p_override: over, p_note: note.trim() || null })
    setBusy(false); if (error) return setErr(error.message); onDone()
  }
  return (
    <Modal title="Manual reservation" sub="Book a buyer into a batch yourself — e.g. an order taken by phone or WhatsApp" onClose={onClose}
      footer={<><button className="btn btn-outline" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy} onClick={save}>{busy ? 'Saving…' : paid ? 'Reserve & mark paid' : 'Create reservation'}</button></>}>
      <Field label="Batch"><select className="form-input" value={pool} onChange={e => { setPool(e.target.value); setLines([{ size: '', color: '', qty: '' }]) }}><option value="">Select an open batch…</option>
        {(pools.rows as Row[]).map(p => <option key={p.id} value={p.id}>{p.pool_no} — {p.title} ({p.paid_qty}/{p.moq_qty} paid)</option>)}</select></Field>
      <Err m={pools.err} />
      <Field label="Buyer"><select className="form-input" value={buyer} onChange={e => setBuyer(e.target.value)}><option value="">Select a buyer account…</option>
        {(buyers.rows as Row[]).map(b => <option key={b.id} value={b.id}>{nm(b)}</option>)}</select></Field>
      {sel && <div className="res-summary"><div className="res-summary-row"><span className="key">Capacity left</span><span>{left} pcs</span></div>
        <div className="res-summary-row"><span className="key">Per buyer</span><span>{sel.min_commit_qty}–{sel.max_commit_qty} pcs</span></div>
        <div className="res-summary-row"><span className="key">Price locked</span><span>{locked ? inr(locked) + ' / pc' : '—'}</span></div></div>}
      <div className="form-group"><label className="form-label">Size & colour split</label>
        {lines.map((l, i) => <div className="form-row-3" key={i}>
          <input className="form-input" list="mr-sizes" placeholder="Size" value={l.size} onChange={e => setLine(i, 'size', e.target.value)} />
          <input className="form-input" list="mr-colors" placeholder="Colour" value={l.color} onChange={e => setLine(i, 'color', e.target.value)} />
          <div className="row" style={{ flexWrap: 'nowrap' }}><input className="form-input" type="number" min={1} placeholder="Qty" value={l.qty} onChange={e => setLine(i, 'qty', e.target.value)} />
            {lines.length > 1 && <button className="link" aria-label="Remove line" onClick={() => setLines(lines.filter((_, j) => j !== i))}>✕</button>}</div></div>)}
        <datalist id="mr-sizes">{sizes.map(s => <option key={s} value={s} />)}</datalist><datalist id="mr-colors">{colors.map(s => <option key={s} value={s} />)}</datalist>
        <div className="row" style={{ justifyContent: 'space-between' }}><button className="link" onClick={() => setLines([...lines, { size: '', color: '', qty: '' }])}>+ add line</button>
          <b style={{ fontSize: 13 }}>{qty} pcs{locked && qty ? ` · ${inr(locked * qty)}` : ''}</b></div></div>
      {noAddr ? <div className="form-group"><label className="form-label">Shipping address (buyer has none saved)</label>
        <input className="form-input" placeholder="Address line" value={na.line1} onChange={e => setNa({ ...na, line1: e.target.value })} style={{ marginBottom: 6 }} />
        <div className="form-row"><input className="form-input" placeholder="City" value={na.city} onChange={e => setNa({ ...na, city: e.target.value })} /><input className="form-input" placeholder="State" value={na.state} onChange={e => setNa({ ...na, state: e.target.value })} /></div>
        <input className="form-input" placeholder="Pincode (6 digits)" inputMode="numeric" maxLength={6} value={na.pincode} onChange={e => setNa({ ...na, pincode: e.target.value })} style={{ marginTop: 6 }} /></div>
        : shipAddrs.length > 1 ? <Field label="Ship to"><select className="form-input" value={ship} onChange={e => setShip(e.target.value)}><option value="">Default address</option>
          {shipAddrs.map(a => <option key={a.id} value={a.id}>{a.line1}, {a.city} {a.pincode}</option>)}</select></Field> : null}
      <label className="row" style={{ fontSize: 13, marginBottom: 8 }}><input type="checkbox" checked={paid} onChange={e => setPaid(e.target.checked)} /> Already paid (record the payment now)</label>
      {paid && <Field label="Payment reference (UTR)" hint={locked && qty ? `Amount recorded: ${inr(locked * qty)}` : undefined}><input className="form-input mono" value={ref} onChange={e => setRef(e.target.value)} /></Field>}
      <Field label="Note (optional)"><input className="form-input" value={note} onChange={e => setNote(e.target.value)} placeholder="e.g. Ordered over WhatsApp on 3 Oct" /></Field>
      <label className="row" style={{ fontSize: 13 }}><input type="checkbox" checked={over} onChange={e => setOver(e.target.checked)} /> Ignore the per-buyer limits and the batch deadline</label>
      <Err m={err} /></Modal>)
}

/* ───────── manual purchase order ───────── */
export function ManualPO({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const pools = useQuery(() => supabase.from('moq_pools').select('id, pool_no, title, moq_qty, paid_qty, status, manufacturer:manufacturer_org_id(legal_name, trade_name)').in('status', ['open', 'moq_reached']).gt('paid_qty', 0).order('created_at', { ascending: false }), [])
  const [pool, setPool] = useState(''); const sel = (pools.rows as Row[]).find(p => p.id === pool)
  const cost = useQuery(() => supabase.from('pool_cost_tiers').select('min_total_qty, unit_price_paise').eq('pool_id', pool || '00000000-0000-0000-0000-000000000000'), [pool])
  const [ready, setReady] = useState(''); const [unit, setUnit] = useState(''); const [why, setWhy] = useState(''); const [ok, setOk] = useState(false); const [err, setErr] = useState(''); const [busy, setBusy] = useState(false)
  const below = !!sel && sel.status === 'open' && sel.paid_qty < sel.moq_qty
  const tiersSorted = [...(cost.rows as Row[])].sort((a, b) => a.min_total_qty - b.min_total_qty)
  const def = sel ? (tiersSorted.filter(t => t.min_total_qty <= sel.paid_qty).pop() ?? tiersSorted[0])?.unit_price_paise : null
  const eff = unit ? Math.round(Number(unit) * 100) : def ? Number(def) : null
  const save = async () => {
    setErr('')
    if (!sel) return setErr('Choose a batch.')
    if (below && !ok) return setErr('This batch has not reached its MOQ. Tick the box to confirm you want to place the PO anyway.')
    if (sel.status === 'open' && !why.trim()) return setErr('Give a reason for placing the PO before the MOQ is reached.')
    if (unit && !(Number(unit) > 0)) return setErr('Enter a valid unit cost.')
    setBusy(true)
    const { error } = await supabase.rpc('admin_place_manual_po', { p_pool: sel.id, p_expected_ready: ready || null, p_unit_cost_paise: unit ? Math.round(Number(unit) * 100) : null, p_reason: why.trim() || null })
    setBusy(false); if (error) return setErr(error.message); onDone()
  }
  return (
    <Modal title="Manual purchase order" sub="Send a batch to the factory now — including before its MOQ is reached" onClose={onClose}
      footer={<><button className="btn btn-outline" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy || !sel} onClick={save}>{busy ? 'Placing…' : 'Place purchase order'}</button></>}>
      <Field label="Batch" hint="Only batches with at least one paid reservation are listed."><select className="form-input" value={pool} onChange={e => { setPool(e.target.value); setUnit(''); setOk(false) }}><option value="">Select…</option>
        {(pools.rows as Row[]).map(p => <option key={p.id} value={p.id}>{p.pool_no} — {p.title} ({p.paid_qty}/{p.moq_qty})</option>)}</select></Field>
      <Err m={pools.err} />
      {!pools.loading && !pools.rows.length && <div className="form-hint">No batch has a paid reservation yet. Use “Manual reservation” to book a buyer first.</div>}
      {sel && <><div className="res-summary"><div className="res-summary-row"><span className="key">Supplier</span><span>{nm(sel.manufacturer)}</span></div>
        <div className="res-summary-row"><span className="key">Paid quantity</span><span>{sel.paid_qty} of {sel.moq_qty} MOQ <Status s={sel.status} /></span></div>
        <div className="res-summary-row"><span className="key">Cost tier price</span><span>{def ? inr(def) + ' / pc' : 'not set'}</span></div>
        <div className="res-summary-row"><span className="key">PO total</span><span><b>{eff ? inr(eff * sel.paid_qty) : '—'}</b></span></div></div>
        {below && <div className="warn-box">⚠️ MOQ not reached ({sel.paid_qty} of {sel.moq_qty}). The supplier may charge a higher price for a smaller run — you can override the unit cost below. Unpaid reservations will be released.
          <label className="row" style={{ marginTop: 8, fontSize: 13 }}><input type="checkbox" checked={ok} onChange={e => setOk(e.target.checked)} /> I understand — place it anyway</label></div>}
        <div className="form-row"><Field label="Unit cost override (₹ per piece)" hint="Leave blank to use the cost tier."><input className="form-input" type="number" min={0} step="0.01" value={unit} onChange={e => setUnit(e.target.value)} placeholder={def ? String(Number(def) / 100) : ''} /></Field>
          <Field label="Expected ready date"><input className="form-input" type="date" value={ready} min={new Date().toISOString().slice(0, 10)} onChange={e => setReady(e.target.value)} /></Field></div>
        <Field label={sel.status === 'open' ? 'Reason (required)' : 'Note (optional)'}><input className="form-input" value={why} onChange={e => setWhy(e.target.value)} placeholder="e.g. Factory agreed to run 40 pcs for the festival deadline" /></Field></>}
      <Err m={err} /></Modal>)
}

/* ───────── extend a reservation's payment time ───────── */
export function ExtendReservation({ r, onClose, onDone }: { r: Row; onClose: () => void; onDone: () => void }) {
  const [mins, setMins] = useState('1440')
  return <NoteDialog title="Give the buyer more time to pay" sub={`${nm(r.buyer)} · ${r.pool?.pool_no} · currently due ${fdate(r.reserved_until)}`} label="Reason" confirm="Extend" onClose={onClose}
    extra={<Field label="Extend by"><select className="form-input" value={mins} onChange={e => setMins(e.target.value)}><option value="360">6 hours</option><option value="1440">1 day</option><option value="2880">2 days</option><option value="10080">7 days</option></select></Field>}
    onSubmit={async note => { const e = await rpc('admin_extend_reservation', { p_commitment: r.id, p_minutes: Number(mins), p_reason: note }); if (!e) onDone(); return e }} />
}
