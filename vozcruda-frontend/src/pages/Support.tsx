import { useEffect, useRef, useState } from 'react'
import { supabase, type Row } from '../supabase'
import { useAuth } from '../auth'
import { useQuery, Err, Chip, Card, Empty, Loading, Modal, Field } from '../ui/kit'

const TOPICS: Record<string, string> = { general: 'General question', account: 'My account / verification', batch: 'A batch', order: 'An order or PO', payment: 'Payments / payouts', product: 'Products / catalogue', requirement: 'A requirement', other: 'Something else' }
const stamp = (s: string) => { const d = new Date(s), t = new Date(), same = d.toDateString() === t.toDateString()
  const tm = d.toLocaleTimeString('en-IN', { hour: 'numeric', minute: '2-digit', hour12: true }).toLowerCase()
  return same ? tm : d.toLocaleDateString('en-IN', { day: 'numeric', month: 'short' }) + ', ' + tm }
const ping = () => window.dispatchEvent(new Event('vc:support'))

function NewThread({ onClose, onDone }: { onClose: () => void; onDone: (id: string) => void }) {
  const [f, setF] = useState({ subject: '', topic: 'general', body: '' }); const [err, setErr] = useState(''); const [busy, setBusy] = useState(false)
  const go = async () => {
    setErr(''); if (f.subject.trim().length < 3) return setErr('Add a short subject.'); if (!f.body.trim()) return setErr('Write your message.')
    setBusy(true); const { data, error } = await supabase.rpc('start_support_thread', { p_subject: f.subject, p_body: f.body, p_topic: f.topic }); setBusy(false)
    if (error) return setErr(error.message); ping(); onDone(data as string)
  }
  return (
    <Modal title="Message Smallotz support" sub="Any member of our team can pick this up" onClose={onClose}
      footer={<><button className="btn btn-outline" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy} onClick={go}>{busy ? 'Sending…' : 'Send'}</button></>}>
      <Field label="Topic"><select className="form-input" value={f.topic} onChange={e => setF({ ...f, topic: e.target.value })}>{Object.entries(TOPICS).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></Field>
      <Field label="Subject"><input className="form-input" maxLength={140} value={f.subject} onChange={e => setF({ ...f, subject: e.target.value })} /></Field>
      <Field label="Message"><textarea className="form-input" rows={5} maxLength={4000} value={f.body} onChange={e => setF({ ...f, body: e.target.value })} /></Field><Err m={err} /></Modal>)
}

function Thread({ t, admin, onBack, onChanged }: { t: Row; admin: boolean; onBack: () => void; onChanged: () => void }) {
  const { session } = useAuth(); const me = session?.user.id
  const q = useQuery(() => supabase.from('support_messages').select('*').eq('thread_id', t.id).order('created_at'), [t.id])
  const [body, setBody] = useState(''); const [err, setErr] = useState(''); const [busy, setBusy] = useState(false); const end = useRef<HTMLDivElement | null>(null)
  useEffect(() => { supabase.rpc('mark_support_read', { p_thread: t.id }).then(() => { onChanged(); ping() }) /* eslint-disable-next-line */ }, [t.id, (q.rows as Row[]).length])
  useEffect(() => { const i = setInterval(() => { q.reload(); onChanged() }, 8000); return () => clearInterval(i) /* eslint-disable-next-line */ }, [t.id])
  useEffect(() => { end.current?.scrollIntoView({ block: 'end' }) }, [(q.rows as Row[]).length])
  const send = async () => {
    if (!body.trim()) return; setBusy(true); setErr('')
    const { error } = await supabase.rpc('send_support_message', { p_thread: t.id, p_body: body.trim() }); setBusy(false)
    if (error) return setErr(error.message); setBody(''); q.reload(); onChanged()
  }
  const setStatus = async (p_status: string | null, p_assign_me: boolean | null) => { const { error } = await supabase.rpc('admin_set_support_thread', { p_thread: t.id, p_status, p_assign_me }); if (error) setErr(error.message); else onChanged() }
  const closed = t.status === 'closed'
  return (
    <div className="chat">
      <div className="chat-head"><button className="btn btn-outline btn-sm chat-back" onClick={onBack}>← Back</button>
        <div style={{ minWidth: 0 }}><div className="td-strong" style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{t.subject}</div>
          <div className="td-muted">{t.thread_no} · {TOPICS[t.topic] ?? t.topic}{admin && t.org ? ` · ${t.org.trade_name ?? t.org.legal_name} (${t.org.type})` : ''}</div></div>
        {admin && <div className="row" style={{ marginLeft: 'auto', flexWrap: 'nowrap' }}>
          {t.assigned_to ? (t.assigned_to === me ? <button className="btn btn-outline btn-sm" onClick={() => setStatus(null, false)}>Release</button> : <Chip c="blue">Taken</Chip>) : <button className="btn btn-outline btn-sm" onClick={() => setStatus(null, true)}>Take</button>}
          <button className="btn btn-outline btn-sm" onClick={() => setStatus(closed ? 'open' : 'closed', null)}>{closed ? 'Reopen' : 'Resolve'}</button></div>}</div>
      <div className="chat-body">{q.loading && !(q.rows as Row[]).length ? <Loading /> : (q.rows as Row[]).map(m => {
        const mineSide = admin ? m.sender_side === 'admin' : m.sender_side === 'org'
        return <div key={m.id} className={'bubble ' + (mineSide ? 'me' : 'them')}>
          <div className="msg-meta">{m.sender_side === 'admin' && !admin ? 'Smallotz Support' : m.sender_name} · {stamp(m.created_at)}</div><div className="msg-body">{m.body}</div></div>
      })}<div ref={end} /></div>
      <Err m={err || q.err} />
      <div className="chat-send">
        <textarea className="form-input" rows={2} maxLength={4000} placeholder={closed ? 'Resolved — sending a message reopens this conversation' : 'Write a message…'} value={body} onChange={e => setBody(e.target.value)}
          onKeyDown={e => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) send() }} />
        <button className="btn btn-primary" disabled={busy || !body.trim()} onClick={send}>{busy ? '…' : 'Send'}</button></div>
    </div>)
}

function List({ rows, sel, onSel, admin }: { rows: Row[]; sel?: string; onSel: (id: string) => void; admin: boolean }) {
  const unread = (t: Row) => admin ? t.status === 'open' && t.last_sender_side === 'org' && (!t.admin_read_at || t.admin_read_at < t.last_message_at) : t.last_sender_side === 'admin' && (!t.org_read_at || t.org_read_at < t.last_message_at)
  return <div className="chat-list">{rows.map(t => <button key={t.id} className={'chat-item' + (sel === t.id ? ' active' : '')} onClick={() => onSel(t.id)}>
    <div className="row" style={{ justifyContent: 'space-between', flexWrap: 'nowrap' }}><span className={'td-strong' + (unread(t) ? ' unread' : '')}>{unread(t) && <i className="dot" />}{t.subject}</span><span className="td-muted" style={{ whiteSpace: 'nowrap' }}>{stamp(t.last_message_at)}</span></div>
    <div className="td-muted">{admin && t.org ? (t.org.trade_name ?? t.org.legal_name) + ' · ' : ''}{t.thread_no}{t.status === 'closed' ? ' · resolved' : ''}</div></button>)}</div>
}

/** Supplier / buyer view */
export function Support() {
  const q = useQuery(() => supabase.from('support_threads').select('*').order('last_message_at', { ascending: false }), [])
  const [sel, setSel] = useState<string | null>(null); const [nw, setNw] = useState(false)
  const rows = q.rows as Row[]; const cur = rows.find(r => r.id === sel)
  return (<>
    <div className="row" style={{ justifyContent: 'space-between', marginBottom: 12 }}><div className="td-muted">Questions, problems or ideas? Message the Smallotz team — we reply here and notify you.</div><button className="btn btn-primary btn-sm" onClick={() => setNw(true)}>+ New message</button></div>
    <Err m={q.err} />
    {q.loading && !rows.length ? <Loading /> : !rows.length ? <Card><Empty icon="💬" title="No conversations yet" desc="Start one and a member of our team will reply." /></Card> :
      <div className={'chat-wrap' + (cur ? ' has-sel' : '')}><Card flush><List rows={rows} sel={sel ?? undefined} onSel={setSel} admin={false} /></Card>
        {cur ? <Card flush><Thread key={cur.id} t={cur} admin={false} onBack={() => setSel(null)} onChanged={q.reload} /></Card> : <Card><Empty icon="👈" title="Pick a conversation" /></Card>}</div>}
    {nw && <NewThread onClose={() => setNw(false)} onDone={id => { setNw(false); q.reload(); setSel(id) }} />}
  </>)
}

/** Shared inbox for every admin */
export function SupportInbox() {
  const q = useQuery(() => supabase.from('support_threads').select('*, org:org_id(trade_name, legal_name, type)').order('last_message_at', { ascending: false }), [])
  const [tab, setTab] = useState('wait'); const [s, setS] = useState(''); const [sel, setSel] = useState<string | null>(null)
  const all = q.rows as Row[]
  const waiting = (t: Row) => t.status === 'open' && t.last_sender_side === 'org'
  const tabs: [string, string, (t: Row) => boolean][] = [['wait', 'Needs reply', waiting], ['open', 'Open', t => t.status === 'open'], ['closed', 'Resolved', t => t.status === 'closed'], ['all', 'All', () => true]]
  const f = tabs.find(x => x[0] === tab)![2]; const needle = s.trim().toLowerCase()
  const rows = all.filter(f).filter(t => !needle || [t.subject, t.thread_no, t.org?.trade_name, t.org?.legal_name].some((x: string) => x?.toLowerCase().includes(needle)))
  const cur = all.find(r => r.id === sel)
  return (<>
    <div className="row" style={{ justifyContent: 'space-between', marginBottom: 8 }}>
      <div className="tabs" style={{ marginBottom: 0 }}>{tabs.map(([k, l, fn]) => <div key={k} className={'tab' + (tab === k ? ' active' : '')} onClick={() => setTab(k)}>{l}{k !== 'all' ? ` (${all.filter(fn).length})` : ''}</div>)}</div>
      <input className="form-input" style={{ maxWidth: 240 }} placeholder="Search name or subject" value={s} onChange={e => setS(e.target.value)} /></div>
    <Err m={q.err} />
    {q.loading && !all.length ? <Loading /> : !all.length ? <Card><Empty icon="📥" title="Inbox is empty" desc="Messages from suppliers and buyers appear here. Any admin can reply." /></Card> :
      <div className={'chat-wrap' + (cur ? ' has-sel' : '')}><Card flush>{rows.length ? <List rows={rows} sel={sel ?? undefined} onSel={setSel} admin /> : <Empty icon="✅" title="Nothing here" />}</Card>
        {cur ? <Card flush><Thread key={cur.id} t={cur} admin onBack={() => setSel(null)} onChanged={q.reload} /></Card> : <Card><Empty icon="👈" title="Pick a conversation" /></Card>}</div>}
  </>)
}
