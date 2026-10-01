import { useState } from 'react'
import { supabase, inr, rpc, type Row } from '../supabase'
import { useAuth } from '../auth'
import { useQuery, Err, Status, Card, Empty, Loading, Modal, Field, Chip } from '../ui/kit'

export const CATEGORIES: [string, string][] = [['damaged', 'Damaged goods'], ['wrong_item', 'Wrong item sent'], ['short_quantity', 'Short quantity'],
  ['quality', 'Quality problem'], ['late_delivery', 'Late delivery'], ['payment', 'Payment issue'], ['other', 'Other']]
const catLabel = (c?: string) => CATEGORIES.find(x => x[0] === c)?.[1] ?? 'Other'
const dt = (s?: string | null) => (s ? new Date(s).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' }) : '—')
const who = (b?: Row) => b?.trade_name || b?.legal_name || '—'
const OPEN = ['open', 'in_review']

/* ───────── open a dispute (admin on behalf of a buyer, or the buyer) ───────── */
export function OpenDispute({ admin, orderId, onClose, onDone }: { admin: boolean; orderId?: string; onClose: () => void; onDone: () => void }) {
  const q = useQuery(() => {
    const base = supabase.from('orders').select('id, order_no, status, total_paise, buyer:buyer_org_id(trade_name, legal_name), pool:pool_id(title)').order('created_at', { ascending: false }).limit(300)
    return admin ? base.not('status', 'in', '(cancelled,refunded,refund_pending,disputed)') : base.in('status', ['shipped', 'delivered', 'completed'])
  }, [])
  const [order, setOrder] = useState(orderId ?? ''); const [cat, setCat] = useState('damaged'); const [why, setWhy] = useState(''); const [err, setErr] = useState(''); const [busy, setBusy] = useState(false)
  const save = async () => {
    setErr('')
    if (!order) return setErr('Choose an order.')
    if (why.trim().length < 5) return setErr('Describe the problem (at least 5 characters).')
    setBusy(true); const e = await rpc(admin ? 'admin_open_dispute' : 'open_dispute', { p_order: order, p_reason: why.trim(), p_category: cat }); setBusy(false)
    if (e) return setErr(e); onDone()
  }
  const rows = q.rows as Row[]
  return (
    <Modal title={admin ? 'Open a dispute' : 'Raise a dispute'} sub={admin ? 'Record a complaint on behalf of a buyer. The buyer is notified.' : 'Tell us what went wrong with your order. Our team will review it.'} onClose={onClose}
      footer={<><button className="btn btn-outline" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy} onClick={save}>{busy ? 'Submitting…' : 'Submit dispute'}</button></>}>
      <Field label="Order" hint={admin ? 'Orders that are cancelled, refunded or already disputed are not listed.' : 'You can raise a dispute once an order has shipped.'}>
        <select className="form-input" value={order} onChange={e => setOrder(e.target.value)} disabled={!!orderId}><option value="">Select…</option>
          {rows.map(o => <option key={o.id} value={o.id}>{o.order_no} — {o.pool?.title}{admin ? ` — ${who(o.buyer)}` : ''} ({inr(o.total_paise)}, {String(o.status).replace(/_/g, ' ')})</option>)}</select></Field>
      {!q.loading && !rows.length && <div className="form-hint">{admin ? 'No eligible orders.' : 'You have no shipped orders yet.'}</div>}
      <Err m={q.err} />
      <Field label="Type of problem"><select className="form-input" value={cat} onChange={e => setCat(e.target.value)}>{CATEGORIES.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></Field>
      <Field label="What happened?"><textarea className="form-input" rows={4} maxLength={2000} value={why} onChange={e => setWhy(e.target.value)} placeholder="Quantities, sizes, photos you have, when it arrived…" /></Field>
      <Err m={err} /></Modal>)
}

/* ───────── detail: conversation + actions ───────── */
export function DisputeDetail({ id, admin, onClose, onChanged }: { id: string; admin: boolean; onClose: () => void; onChanged: () => void }) {
  const { can } = useAuth(); const manage = admin && can('disputes')
  const d = useQuery(() => supabase.from('disputes').select('*, buyer:buyer_org_id(legal_name, trade_name), order:order_id(id, order_no, status, total_paise, pool:pool_id(title), order_items(size, color, qty))').eq('id', id), [id])
  const m = useQuery(() => supabase.from('dispute_messages').select('*').eq('dispute_id', id).order('created_at', { ascending: true }), [id])
  const row = (d.rows as Row[])[0]
  const [body, setBody] = useState(''); const [internal, setInternal] = useState(false); const [err, setErr] = useState(''); const [busy, setBusy] = useState(false)
  const [resolving, setResolving] = useState<null | 'refund' | 'close'>(null); const [note, setNote] = useState('')
  const refresh = () => { d.reload(); m.reload(); onChanged() }
  const send = async () => {
    if (!body.trim()) return; setBusy(true); setErr('')
    const e = await rpc('add_dispute_message', { p_dispute: id, p_body: body.trim(), p_internal: internal }); setBusy(false)
    if (e) return setErr(e); setBody(''); setInternal(false); refresh()
  }
  const review = async () => { setBusy(true); const e = await rpc('admin_set_dispute_status', { p_dispute: id, p_status: 'in_review', p_note: null }); setBusy(false); if (e) return setErr(e); refresh() }
  const resolve = async () => {
    if (!note.trim()) return setErr('Write a short resolution note for the buyer.'); setBusy(true); setErr('')
    const e = await rpc('admin_resolve_dispute', { p_dispute: id, p_refund: resolving === 'refund', p_resolution: note.trim() }); setBusy(false)
    if (e) return setErr(e); setResolving(null); setNote(''); refresh()
  }
  const isOpen = row && OPEN.includes(row.status)
  const items = (row?.order?.order_items ?? []) as Row[]
  return (
    <Modal title={row ? row.dispute_no : 'Dispute'} sub={row ? `${row.order?.order_no} · ${catLabel(row.category)}` : ''} onClose={onClose}
      footer={<button className="btn btn-outline" onClick={onClose}>Close</button>}>
      <Err m={d.err || m.err} />
      {d.loading || !row ? <Loading /> : <>
        <div className="dispute-head">
          <div className="row"><Status s={row.status} />{row.opened_by_admin && <Chip c="blue">opened by team</Chip>}</div>
          <div className="info-row"><span className="info-key">Buyer</span><span className="info-val">{who(row.buyer)}</span></div>
          <div className="info-row"><span className="info-key">Order</span><span className="info-val">{row.order?.order_no} · {inr(row.order?.total_paise)}</span></div>
          <div className="info-row"><span className="info-key">Batch</span><span className="info-val">{row.order?.pool?.title}</span></div>
          {items.length > 0 && <div className="info-row"><span className="info-key">Items</span><span className="info-val">{items.map(i => `${i.qty}× ${i.size}/${i.color}`).join(', ')}</span></div>}
          <div className="info-row"><span className="info-key">Opened</span><span className="info-val">{dt(row.created_at)}</span></div>
          {row.resolved_at && <div className="info-row"><span className="info-key">Closed</span><span className="info-val">{dt(row.resolved_at)}</span></div>}
        </div>
        <div className="thread">
          {(m.rows as Row[]).map(x => <div key={x.id} className={'msg msg-' + x.author_role + (x.internal ? ' msg-internal' : '')}>
            <div className="msg-meta">{x.internal ? '🔒 Internal note' : x.author_role === 'buyer' ? 'Buyer' : 'Voz Cruda team'} · {dt(x.created_at)}</div>
            <div className="msg-body">{x.body}</div></div>)}
          {!m.loading && !m.rows.length && <div className="td-muted">No messages yet.</div>}
        </div>
        {row.resolution && <div className="resolution-box"><b>Resolution:</b> {row.resolution}</div>}
        {(isOpen || manage) && <div className="reply-box">
          <textarea className="form-input" rows={3} maxLength={2000} placeholder={isOpen ? 'Write a reply…' : 'Add a note…'} value={body} onChange={e => setBody(e.target.value)} />
          <div className="row" style={{ justifyContent: 'space-between' }}>
            {manage ? <label className="row" style={{ fontSize: 13 }}><input type="checkbox" checked={internal} onChange={e => setInternal(e.target.checked)} /> Internal note (buyer can’t see)</label> : <span />}
            <button className="btn btn-outline btn-sm" disabled={busy || !body.trim()} onClick={send}>{internal ? 'Save note' : 'Send reply'}</button></div></div>}
        {manage && isOpen && !resolving && <div className="row" style={{ marginTop: 12 }}>
          {row.status === 'open' && <button className="btn btn-outline btn-sm" disabled={busy} onClick={review}>Start review</button>}
          <button className="btn btn-success btn-sm" onClick={() => { setResolving('refund'); setNote(''); setErr('') }}>Resolve with refund</button>
          <button className="btn btn-ghost btn-sm" onClick={() => { setResolving('close'); setNote(''); setErr('') }}>Close, no refund</button></div>}
        {manage && isOpen && resolving && <div className="resolve-box">
          <div className="form-label">{resolving === 'refund' ? 'Resolve with refund — the order moves to “refund pending”.' : 'Close without refund — the order returns to its previous status.'}</div>
          <textarea className="form-input" rows={3} placeholder="Resolution note (the buyer will see this)" value={note} onChange={e => setNote(e.target.value)} />
          <div className="row"><button className={'btn btn-sm ' + (resolving === 'refund' ? 'btn-success' : 'btn-primary')} disabled={busy} onClick={resolve}>{resolving === 'refund' ? 'Confirm refund' : 'Confirm close'}</button>
            <button className="btn btn-ghost btn-sm" onClick={() => setResolving(null)}>Back</button></div></div>}
        <Err m={err} /></>}
    </Modal>)
}

/* ───────── admin list ───────── */
const TABS: [string, string][] = [['active', 'Open'], ['resolved', 'Closed'], ['all', 'All']]
export function Disputes() {
  const { can } = useAuth()
  const q = useQuery(() => supabase.from('disputes').select('*, buyer:buyer_org_id(legal_name, trade_name), order:order_id(order_no, total_paise)').order('created_at', { ascending: false }), [])
  const [tab, setTab] = useState('active'); const [s, setS] = useState(''); const [open, setOpen] = useState<string | null>(null); const [creating, setCreating] = useState(false)
  const all = q.rows as Row[]
  const rows = all.filter(r => (tab === 'all' || (tab === 'active' ? OPEN.includes(r.status) : !OPEN.includes(r.status))) &&
    (r.dispute_no + r.order?.order_no + who(r.buyer) + r.reason).toLowerCase().includes(s.toLowerCase()))
  return (<>
    <div className="tabs">{TABS.map(([k, l]) => <div key={k} className={'tab' + (tab === k ? ' active' : '')} onClick={() => setTab(k)}>{l}{k === 'active' && all.some(r => OPEN.includes(r.status)) ? ` (${all.filter(r => OPEN.includes(r.status)).length})` : ''}</div>)}</div>
    <div className="filter-bar"><div className="search-input-wrap"><span className="search-icon">🔍</span><input className="search-input" placeholder="Search dispute, order, buyer…" value={s} onChange={e => setS(e.target.value)} /></div>
      {can('disputes') && <button className="btn btn-primary btn-sm" style={{ marginLeft: 'auto' }} onClick={() => setCreating(true)}>+ Open dispute</button>}</div>
    <Err m={q.err} />
    <Card flush>{q.loading ? <Loading /> : !rows.length ? <Empty icon="⚖️" title={tab === 'active' ? 'No open disputes' : 'No disputes'} desc={can('disputes') ? 'Use “Open dispute” to record a buyer complaint.' : undefined} /> :
      <table><thead><tr><th>Dispute</th><th>Buyer</th><th>Order</th><th>Type</th><th>Reason</th><th>Status</th><th></th></tr></thead><tbody>
        {rows.map(d => <tr key={d.id}><td className="td-strong">{d.dispute_no}<div className="td-muted">{dt(d.created_at)}</div></td><td>{who(d.buyer)}</td><td>{d.order?.order_no}<div className="td-muted">{inr(d.order?.total_paise)}</div></td>
          <td>{catLabel(d.category)}</td><td style={{ maxWidth: 260 }}><div className="clamp-2">{d.reason}</div></td><td><Status s={d.status} /></td>
          <td><button className="btn btn-outline btn-sm" onClick={() => setOpen(d.id)}>{OPEN.includes(d.status) && can('disputes') ? 'Review' : 'View'}</button></td></tr>)}</tbody></table>}</Card>
    {open && <DisputeDetail id={open} admin onClose={() => setOpen(null)} onChanged={q.reload} />}
    {creating && <OpenDispute admin onClose={() => setCreating(false)} onDone={() => { setCreating(false); q.reload() }} />}
  </>)
}

/* ───────── buyer page ───────── */
export function BuyerDisputes() {
  const q = useQuery(() => supabase.from('disputes').select('*, order:order_id(order_no, total_paise)').order('created_at', { ascending: false }), [])
  const [open, setOpen] = useState<string | null>(null); const [creating, setCreating] = useState(false)
  const rows = q.rows as Row[]
  return (<>
    <div className="filter-bar"><span className="td-muted">Problem with a shipped order? Tell us here and we’ll review it.</span>
      <button className="btn btn-primary btn-sm" style={{ marginLeft: 'auto' }} onClick={() => setCreating(true)}>+ Raise a dispute</button></div>
    <Err m={q.err} />
    <Card flush>{q.loading ? <Loading /> : !rows.length ? <Empty icon="⚖️" title="No disputes" desc="If something is wrong with an order you can raise a dispute once it ships." /> :
      <table><thead><tr><th>Dispute</th><th>Order</th><th>Type</th><th>Status</th><th></th></tr></thead><tbody>
        {rows.map(d => <tr key={d.id}><td className="td-strong">{d.dispute_no}<div className="td-muted">{dt(d.created_at)}</div></td><td>{d.order?.order_no}<div className="td-muted">{inr(d.order?.total_paise)}</div></td>
          <td>{catLabel(d.category)}</td><td><Status s={d.status} /></td><td><button className="btn btn-outline btn-sm" onClick={() => setOpen(d.id)}>{OPEN.includes(d.status) ? 'Open / reply' : 'View'}</button></td></tr>)}</tbody></table>}</Card>
    {open && <DisputeDetail id={open} admin={false} onClose={() => setOpen(null)} onChanged={q.reload} />}
    {creating && <OpenDispute admin={false} onClose={() => setCreating(false)} onDone={() => { setCreating(false); q.reload() }} />}
  </>)
}
