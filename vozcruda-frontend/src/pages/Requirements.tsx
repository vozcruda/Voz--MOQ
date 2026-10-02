import { useState } from 'react'
import { supabase, inr, fdate, type Row } from '../supabase'
import { useAuth } from '../auth'
import { useQuery, Err, Chip, Card, Empty, Loading, Modal, Field } from '../ui/kit'

const KIND: Record<string, string> = { product: 'Finished product', raw_material: 'Raw material' }
const ST: Record<string, ['green' | 'orange' | 'blue' | 'yellow' | 'gray' | 'red', string]> = {
  pending_review: ['yellow', 'Awaiting admin review'], published: ['green', 'Live'], closed: ['gray', 'Closed'], rejected: ['red', 'Not published'], fulfilled: ['blue', 'Fulfilled'] }
const RST: Record<string, ['green' | 'orange' | 'blue' | 'yellow' | 'gray' | 'red', string]> = {
  submitted: ['yellow', 'Submitted'], shortlisted: ['orange', 'Shortlisted'], selected: ['green', 'Selected'], declined: ['gray', 'Not selected'], withdrawn: ['gray', 'Withdrawn'] }
const ReqStatus = ({ s }: { s: string }) => <Chip c={(ST[s] ?? ['gray', s])[0]}>{(ST[s] ?? ['gray', s])[1]}</Chip>
const paise = (v: string) => v.trim() === '' ? null : Math.round(Number(v) * 100)
const qtyLine = (r: Row) => [r.qty && `${r.qty}${r.unit ? ' ' + r.unit : ''}`, r.target_price_paise && `target ${inr(r.target_price_paise)}${r.unit ? '/' + r.unit : ''}`, r.needed_by && `needed by ${fdate(r.needed_by)}`].filter(Boolean).join(' · ')
const today = () => new Date().toISOString().slice(0, 10)

/** Form used by suppliers (submit) and admins (post directly). */
function PostDialog({ admin, onClose, onDone }: { admin?: boolean; onClose: () => void; onDone: () => void }) {
  const cats = useQuery(() => supabase.from('categories').select('id,name').order('name'), [])
  const [f, setF] = useState({ kind: 'product', title: '', description: '', category: '', qty: '', unit: 'pcs', price: '', needed: '', respond: '' })
  const [err, setErr] = useState(''); const [busy, setBusy] = useState(false)
  const set = (k: string, v: string) => setF({ ...f, [k]: v })
  const go = async (publish = true) => {
    setErr('')
    if (f.title.trim().length < 3) return setErr('Give it a short title (at least 3 characters).')
    if (f.qty && !(Number(f.qty) > 0)) return setErr('Quantity must be a positive number.')
    setBusy(true)
    const base = { p_kind: f.kind, p_title: f.title, p_description: f.description || null, p_category: f.category || null, p_qty: f.qty ? Math.round(Number(f.qty)) : null,
      p_unit: f.unit || null, p_target_price_paise: paise(f.price), p_needed_by: f.needed || null }
    const { error } = admin ? await supabase.rpc('admin_create_requirement', { ...base, p_response_by: f.respond || null, p_publish: publish }) : await supabase.rpc('submit_requirement', base)
    setBusy(false); if (error) return setErr(error.message); onDone()
  }
  return (
    <Modal title={admin ? 'Post a requirement' : 'Post a requirement'} sub={admin ? 'Goes to every approved manufacturer' : 'Our team reviews it, then shares it with other manufacturers. Your company name is never shown.'} onClose={onClose}
      footer={<><button className="btn btn-outline" onClick={onClose}>Cancel</button>
        {admin && <button className="btn btn-outline" disabled={busy} onClick={() => go(false)}>Save for review</button>}
        <button className="btn btn-primary" disabled={busy} onClick={() => go(true)}>{busy ? 'Posting…' : admin ? 'Publish now' : 'Submit for review'}</button></>}>
      <div className="seg">{Object.entries(KIND).map(([k, l]) => <button key={k} className={'seg-btn' + (f.kind === k ? ' active' : '')} onClick={() => set('kind', k)}>{l}</button>)}</div>
      <Field label="What do you need?"><input className="form-input" maxLength={140} placeholder={f.kind === 'raw_material' ? 'e.g. 280 GSM black fleece fabric' : 'e.g. 500 oversized hoodies, 380 GSM'} value={f.title} onChange={e => set('title', e.target.value)} /></Field>
      <Field label="Details" hint="Specs, colours, certifications, packaging — anything a manufacturer needs to quote."><textarea className="form-input" rows={3} maxLength={4000} value={f.description} onChange={e => set('description', e.target.value)} /></Field>
      <div className="form-row"><Field label="Category"><select className="form-input" value={f.category} onChange={e => set('category', e.target.value)}><option value="">Not sure</option>{(cats.rows as Row[]).map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
        <Field label="Needed by"><input className="form-input" type="date" min={today()} value={f.needed} onChange={e => set('needed', e.target.value)} /></Field></div>
      <div className="form-row-3"><Field label="Quantity"><input className="form-input" type="number" min={1} value={f.qty} onChange={e => set('qty', e.target.value)} /></Field>
        <Field label="Unit"><input className="form-input" maxLength={20} placeholder="pcs / kg / m" value={f.unit} onChange={e => set('unit', e.target.value)} /></Field>
        <Field label="Target ₹/unit"><input className="form-input" type="number" min={0} step="0.01" value={f.price} onChange={e => set('price', e.target.value)} /></Field></div>
      {admin && <Field label="Response deadline" hint="Optional. Suppliers can’t respond after this date."><input className="form-input" type="date" min={today()} value={f.respond} onChange={e => set('respond', e.target.value)} /></Field>}
      <Err m={err} /></Modal>)
}

function RespondDialog({ r, mine, onClose, onDone }: { r: Row; mine?: Row; onClose: () => void; onDone: () => void }) {
  const [f, setF] = useState({ price: mine?.unit_price_paise ? String(mine.unit_price_paise / 100) : '', lead: mine?.lead_time_days ? String(mine.lead_time_days) : '', min: mine?.min_qty ? String(mine.min_qty) : '', note: mine?.note ?? '' })
  const [err, setErr] = useState(''); const [busy, setBusy] = useState(false)
  const go = async () => {
    setErr(''); setBusy(true)
    const { error } = await supabase.rpc('respond_to_requirement', { p_req: r.id, p_unit_price_paise: paise(f.price), p_lead_time_days: f.lead ? Math.round(Number(f.lead)) : null, p_min_qty: f.min ? Math.round(Number(f.min)) : null, p_note: f.note || null })
    setBusy(false); if (error) return setErr(error.message); onDone()
  }
  return (
    <Modal title={mine ? 'Edit your response' : 'Respond to ' + r.req_no} sub={r.title} onClose={onClose}
      footer={<><button className="btn btn-outline" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy} onClick={go}>{busy ? 'Sending…' : mine ? 'Update response' : 'Send response'}</button></>}>
      <div className="info-card" style={{ marginBottom: 12 }}><div className="info-card-body"><b>{KIND[r.kind]}</b>{qtyLine(r) && <> · {qtyLine(r)}</>}{r.description && <div style={{ marginTop: 6, whiteSpace: 'pre-wrap' }}>{r.description}</div>}</div></div>
      <div className="form-row-3"><Field label={`Your price ₹${r.unit ? '/' + r.unit : '/unit'}`}><input className="form-input" type="number" min={0} step="0.01" value={f.price} onChange={e => setF({ ...f, price: e.target.value })} /></Field>
        <Field label="Lead time (days)"><input className="form-input" type="number" min={1} value={f.lead} onChange={e => setF({ ...f, lead: e.target.value })} /></Field>
        <Field label="Min order"><input className="form-input" type="number" min={1} value={f.min} onChange={e => setF({ ...f, min: e.target.value })} /></Field></div>
      <Field label="Note" hint="Admin shares your offer with the requester without your company name. Don’t include contact details."><textarea className="form-input" rows={3} maxLength={2000} value={f.note} onChange={e => setF({ ...f, note: e.target.value })} /></Field>
      <Err m={err} /></Modal>)
}

/* ------------------------------ supplier ------------------------------ */
export function SupplierRequirements() {
  const [tab, setTab] = useState('board'); const [posting, setPosting] = useState(false); const [resp, setResp] = useState<Row | null>(null); const [wd, setWd] = useState<Row | null>(null); const [view, setView] = useState<Row | null>(null); const [wdErr, setWdErr] = useState('')
  const board = useQuery(() => supabase.from('requirement_board').select('*').order('published_at', { ascending: false }), [])
  const mine = useQuery(() => supabase.from('requirements').select('*').order('created_at', { ascending: false }), [])
  const rs = useQuery(() => supabase.from('requirement_responses').select('*'), [])
  const shared = useQuery(() => supabase.from('requirement_shared_responses').select('*').order('created_at'), [])
  const all = () => { board.reload(); mine.reload(); rs.reload(); shared.reload() }
  const myResp = (id: string) => (rs.rows as Row[]).find(x => x.requirement_id === id)
  const open = (board.rows as Row[]).filter(r => !r.mine)
  const catName = useQuery(() => supabase.from('categories').select('id,name'), []); const cn = (id?: string) => (catName.rows as Row[]).find(c => c.id === id)?.name
  return (<>
    <div className="row" style={{ justifyContent: 'space-between', marginBottom: 8 }}>
      <div className="tabs" style={{ marginBottom: 0 }}>{[['board', `Open requests (${open.filter(r => r.status === 'published').length})`], ['mine', `My requests (${(mine.rows as Row[]).length})`]].map(([k, l]) => <div key={k} className={'tab' + (tab === k ? ' active' : '')} onClick={() => setTab(k)}>{l}</div>)}</div>
      <button className="btn btn-primary btn-sm" onClick={() => setPosting(true)}>+ Post a requirement</button></div>
    <Err m={board.err || mine.err} />
    {tab === 'board' ? (board.loading ? <Loading /> : !open.length ? <Card><Empty icon="📌" title="No open requirements" desc="When MoqLess or another manufacturer needs a product or raw material, it appears here." /></Card> :
      <div className="req-grid">{open.map(r => { const m = myResp(r.id); return (
        <div className="req-card" key={r.id}>
          <div className="row" style={{ justifyContent: 'space-between' }}><Chip c={r.kind === 'raw_material' ? 'orange' : 'blue'}>{KIND[r.kind]}</Chip><span className="td-muted">{r.req_no}</span></div>
          <div className="req-title">{r.title}</div>
          {r.description && <div className="req-desc">{r.description}</div>}
          <div className="td-muted">{[cn(r.category_id), qtyLine(r)].filter(Boolean).join(' · ')}</div>
          <div className="td-muted">{r.response_by ? (r.past_deadline ? 'Responses closed' : `Respond by ${fdate(r.response_by)}`) : `Posted ${fdate(r.published_at)}`}</div>
          <div className="row" style={{ marginTop: 'auto' }}>
            {m && m.status !== 'withdrawn' ? <><Chip c={RST[m.status][0]}>{RST[m.status][1]}</Chip>
              {r.status === 'published' && m.status !== 'selected' && <><button className="btn btn-outline btn-sm" onClick={() => setResp(r)}>Edit</button><button className="btn btn-outline btn-sm" onClick={() => setWd(r)}>Withdraw</button></>}</>
              : r.status === 'published' && !r.past_deadline ? <button className="btn btn-primary btn-sm" onClick={() => setResp(r)}>{m ? 'Respond again' : 'Respond'}</button> : <Chip c="gray">Closed</Chip>}
          </div></div>) })}</div>)
      : <Card flush>{mine.loading ? <Loading /> : !(mine.rows as Row[]).length ? <Empty icon="📝" title="You haven’t posted anything" desc="Need a fabric, trim or a finished product? Post it — we’ll circulate it to other manufacturers." /> :
        <div className="table-card"><table><thead><tr><th>Request</th><th>Status</th><th>Offers</th><th></th></tr></thead><tbody>
          {(mine.rows as Row[]).map(r => { const n = (shared.rows as Row[]).filter(x => x.requirement_id === r.id).length; return (
            <tr key={r.id}><td className="td-strong">{r.title}<div className="td-muted">{r.req_no} · {KIND[r.kind]}{qtyLine(r) ? ' · ' + qtyLine(r) : ''}</div>{r.admin_note && <div className="td-muted">Admin: {r.admin_note}</div>}</td>
              <td><ReqStatus s={r.status} /></td><td>{n ? <button className="btn btn-outline btn-sm" onClick={() => setView(r)}>View {n} offer{n > 1 ? 's' : ''}</button> : <span className="td-muted">—</span>}</td>
              <td>{['pending_review', 'published'].includes(r.status) && <button className="btn btn-outline btn-sm" onClick={() => setWd({ ...r, own: true })}>Withdraw</button>}</td></tr>) })}</tbody></table></div>}</Card>}
    {posting && <PostDialog onClose={() => setPosting(false)} onDone={() => { setPosting(false); setTab('mine'); all() }} />}
    {resp && <RespondDialog r={resp} mine={myResp(resp.id)?.status === 'withdrawn' ? undefined : myResp(resp.id)} onClose={() => setResp(null)} onDone={() => { setResp(null); all() }} />}
    {wd && <Modal title={wd.own ? 'Withdraw this request?' : 'Withdraw your response?'} sub={wd.title} onClose={() => setWd(null)} footer={<><button className="btn btn-outline" onClick={() => setWd(null)}>Keep it</button>
      <button className="btn btn-danger" onClick={async () => { const { error } = wd.own ? await supabase.rpc('withdraw_requirement', { p_id: wd.id }) : await supabase.rpc('withdraw_response', { p_req: wd.id }); if (error) return setWdErr(error.message); setWd(null); all() }}>Withdraw</button></>}>
      {wd.own ? 'Other manufacturers will no longer see this request.' : 'The MoqLess team will no longer see your offer.'}<Err m={wdErr} /></Modal>}
    {view && <Modal title={`Offers for ${view.req_no}`} sub="Shared by MoqLess. Supplier names stay private — we’ll connect you when you pick one." onClose={() => setView(null)}
      footer={<button className="btn btn-primary" onClick={() => setView(null)}>Close</button>}>
      {(shared.rows as Row[]).filter(x => x.requirement_id === view.id).map((x, i) => <div className="offer" key={x.id}>
        <div className="row" style={{ justifyContent: 'space-between' }}><b>Offer {i + 1}</b>{x.status === 'selected' && <Chip c="green">Selected</Chip>}</div>
        <div>{x.unit_price_paise ? inr(x.unit_price_paise) + (view.unit ? '/' + view.unit : '') : 'Price on request'}{x.lead_time_days ? ` · ${x.lead_time_days} days lead time` : ''}{x.min_qty ? ` · min ${x.min_qty}` : ''}</div>
        {x.note && <div className="td-muted">{x.note}</div>}</div>)}
      <p className="form-hint">To go ahead with an offer, message us from <b>Support</b> and quote {view.req_no}.</p></Modal>}
  </>)
}

/* -------------------------------- admin ------------------------------- */
function AdminReqDialog({ r, onClose, onChanged }: { r: Row; onClose: () => void; onChanged: () => void }) {
  const { can } = useAuth(); const ok = can('suppliers')
  const resp = useQuery(() => supabase.from('requirement_responses').select('*, org:org_id(trade_name, legal_name)').eq('requirement_id', r.id).order('created_at'), [r.id])
  const [e, setE] = useState({ title: r.title ?? '', description: r.description ?? '', qty: r.qty ? String(r.qty) : '', unit: r.unit ?? '', price: r.target_price_paise ? String(r.target_price_paise / 100) : '', needed: r.needed_by ?? '', respond: r.response_by ?? '', note: r.admin_note ?? '' })
  const [err, setErr] = useState(''); const [busy, setBusy] = useState(false)
  const act = async (action: string) => {
    setErr(''); setBusy(true)
    const edits = { title: e.title, description: e.description, qty: e.qty, unit: e.unit, target_price_paise: e.price ? String(Math.round(Number(e.price) * 100)) : '', needed_by: e.needed, response_by: e.respond }
    const { error } = await supabase.rpc('admin_review_requirement', { p_id: r.id, p_action: action, p_note: e.note || null, p_edits: action === 'publish' || r.status === 'pending_review' ? edits : null })
    setBusy(false); if (error) return setErr(error.message); onChanged(); onClose()
  }
  const setResp = async (id: string, status: string | null, share: boolean | null) => { const { error } = await supabase.rpc('admin_set_response', { p_id: id, p_status: status, p_share: share }); if (error) setErr(error.message); else { setErr(''); resp.reload() } }
  const pending = r.status === 'pending_review'
  return (
    <Modal title={`${r.req_no} · ${KIND[r.kind]}`} sub={r.source === 'admin' ? 'Posted by MoqLess' : `Posted by ${r.poster?.trade_name ?? r.poster?.legal_name ?? 'a supplier'} (hidden from other suppliers)`} onClose={onClose}
      footer={<><button className="btn btn-outline" onClick={onClose}>Close</button>
        {ok && pending && <><button className="btn btn-danger" disabled={busy} onClick={() => act('reject')}>Reject</button><button className="btn btn-primary" disabled={busy} onClick={() => act('publish')}>Publish to suppliers</button></>}
        {ok && r.status === 'published' && <><button className="btn btn-outline" disabled={busy} onClick={() => act('close')}>Close</button><button className="btn btn-primary" disabled={busy} onClick={() => act('fulfil')}>Mark fulfilled</button></>}
        {ok && ['closed', 'fulfilled'].includes(r.status) && <button className="btn btn-outline" disabled={busy} onClick={() => act('reopen')}>Reopen</button>}</>}>
      <div className="row" style={{ marginBottom: 10 }}><ReqStatus s={r.status} /></div>
      <Field label="Title"><input className="form-input" disabled={!ok || !pending} value={e.title} onChange={x => setE({ ...e, title: x.target.value })} /></Field>
      <Field label="Details"><textarea className="form-input" rows={3} disabled={!ok || !pending} value={e.description} onChange={x => setE({ ...e, description: x.target.value })} /></Field>
      <div className="form-row-3"><Field label="Quantity"><input className="form-input" type="number" disabled={!ok || !pending} value={e.qty} onChange={x => setE({ ...e, qty: x.target.value })} /></Field>
        <Field label="Unit"><input className="form-input" disabled={!ok || !pending} value={e.unit} onChange={x => setE({ ...e, unit: x.target.value })} /></Field>
        <Field label="Target ₹"><input className="form-input" type="number" disabled={!ok || !pending} value={e.price} onChange={x => setE({ ...e, price: x.target.value })} /></Field></div>
      <div className="form-row"><Field label="Needed by"><input className="form-input" type="date" disabled={!ok || !pending} value={e.needed} onChange={x => setE({ ...e, needed: x.target.value })} /></Field>
        <Field label="Response deadline"><input className="form-input" type="date" disabled={!ok || !pending} value={e.respond} onChange={x => setE({ ...e, respond: x.target.value })} /></Field></div>
      {ok && <Field label={pending ? 'Note (required to reject — the supplier sees it)' : 'Note to supplier'}><input className="form-input" value={e.note} onChange={x => setE({ ...e, note: x.target.value })} /></Field>}
      <Err m={err} />
      {!pending && <><div className="req-sub">Responses ({(resp.rows as Row[]).length})</div>
        {resp.loading ? <Loading /> : !(resp.rows as Row[]).length ? <div className="td-muted">No responses yet.</div> : (resp.rows as Row[]).map(x => <div className="offer" key={x.id}>
          <div className="row" style={{ justifyContent: 'space-between' }}><b>{x.org?.trade_name ?? x.org?.legal_name}</b><Chip c={RST[x.status][0]}>{RST[x.status][1]}</Chip></div>
          <div>{x.unit_price_paise ? inr(x.unit_price_paise) + (r.unit ? '/' + r.unit : '') : 'No price'}{x.lead_time_days ? ` · ${x.lead_time_days} days` : ''}{x.min_qty ? ` · min ${x.min_qty}` : ''}</div>
          {x.note && <div className="td-muted">{x.note}</div>}
          {ok && x.status !== 'withdrawn' && <div className="row" style={{ marginTop: 6 }}>
            <button className="btn btn-outline btn-sm" onClick={() => setResp(x.id, 'shortlisted', null)}>Shortlist</button>
            <button className="btn btn-outline btn-sm" onClick={() => setResp(x.id, 'selected', null)}>Select</button>
            <button className="btn btn-outline btn-sm" onClick={() => setResp(x.id, 'declined', null)}>Decline</button>
            {r.posted_by_org && <label className="check"><input type="checkbox" checked={!!x.shared_with_poster} onChange={ev => setResp(x.id, null, ev.target.checked)} /> Share with requester</label>}</div>}</div>)}</>}
    </Modal>)
}

export function AdminRequirements() {
  const { can } = useAuth(); const [tab, setTab] = useState('review'); const [open, setOpen] = useState<Row | null>(null); const [posting, setPosting] = useState(false)
  const q = useQuery(() => supabase.from('requirements').select('*, poster:posted_by_org(trade_name, legal_name), requirement_responses(id,status)').order('created_at', { ascending: false }), [])
  const all = q.rows as Row[]
  const tabs: [string, string, (r: Row) => boolean][] = [['review', 'Needs review', r => r.status === 'pending_review'], ['live', 'Live', r => r.status === 'published'], ['done', 'Closed', r => ['closed', 'fulfilled', 'rejected'].includes(r.status)], ['all', 'All', () => true]]
  const f = tabs.find(t => t[0] === tab)![2]; const rows = all.filter(f)
  return (<>
    <div className="row" style={{ justifyContent: 'space-between', marginBottom: 8 }}>
      <div className="tabs" style={{ marginBottom: 0 }}>{tabs.map(([k, l, fn]) => <div key={k} className={'tab' + (tab === k ? ' active' : '')} onClick={() => setTab(k)}>{l}{k !== 'all' ? ` (${all.filter(fn).length})` : ''}</div>)}</div>
      {can('suppliers') && <button className="btn btn-primary btn-sm" onClick={() => setPosting(true)}>+ Post requirement</button>}</div>
    <Err m={q.err} />
    <Card flush>{q.loading ? <Loading /> : !rows.length ? <Empty icon="📌" title={tab === 'review' ? 'Nothing to review' : 'No requirements'} desc="Supplier requests land here for you to review and publish." /> :
      <div className="table-card"><table><thead><tr><th>Requirement</th><th>From</th><th>Status</th><th>Responses</th><th>Posted</th><th></th></tr></thead><tbody>
        {rows.map(r => <tr key={r.id}><td className="td-strong">{r.title}<div className="td-muted">{r.req_no} · {KIND[r.kind]}{qtyLine(r) ? ' · ' + qtyLine(r) : ''}</div></td>
          <td>{r.source === 'admin' ? 'MoqLess' : r.poster?.trade_name ?? r.poster?.legal_name ?? '—'}</td><td><ReqStatus s={r.status} /></td>
          <td>{(r.requirement_responses ?? []).filter((x: Row) => x.status !== 'withdrawn').length || '—'}</td><td>{fdate(r.created_at)}</td>
          <td><button className="btn btn-outline btn-sm" onClick={() => setOpen(r)}>{r.status === 'pending_review' && can('suppliers') ? 'Review' : 'View'}</button></td></tr>)}</tbody></table></div>}</Card>
    {open && <AdminReqDialog r={open} onClose={() => setOpen(null)} onChanged={q.reload} />}
    {posting && <PostDialog admin onClose={() => setPosting(false)} onDone={() => { setPosting(false); q.reload() }} />}
  </>)
}
