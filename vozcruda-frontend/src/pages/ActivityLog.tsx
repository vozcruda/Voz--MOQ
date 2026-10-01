import { Fragment, useCallback, useEffect, useRef, useState } from 'react'
import { supabase, type Row } from '../supabase'
import { Err, Card, Empty, Loading } from '../ui/kit'

const KINDS = ['order', 'batch', 'reservation', 'purchase order', 'product', 'account', 'dispute', 'setting', 'verification', 'supplier profile', 'address', 'quote', 'RFQ', 'admin']
const ICON: Record<string, string> = { order: '🚚', batch: '📊', reservation: '📋', 'purchase order': '🧾', product: '📦', account: '👤', dispute: '⚖️', setting: '⚙️', verification: '✅', admin: '🛡️', address: '📍' }
const NOISE = new Set(['id', 'updated_at', 'created_at', 'version', 'search_vector', 'deleted_at'])
const pretty = (v: unknown) => v == null ? '—' : typeof v === 'object' ? JSON.stringify(v) : String(v)
const time = (s: string) => new Date(s).toLocaleTimeString('en-IN', { hour: 'numeric', minute: '2-digit' })
const day = (s: string) => {
  const d = new Date(s), t = new Date(), y = new Date(Date.now() - 864e5)
  return d.toDateString() === t.toDateString() ? 'Today' : d.toDateString() === y.toDateString() ? 'Yesterday' : d.toLocaleDateString('en-IN', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' })
}

export function Detail({ e }: { e: Row }) {
  const d = (e.ev_detail ?? {}) as Row
  if (e.ev_action === 'UPDATE') return <table className="log-diff"><thead><tr><th>Field</th><th>Before</th><th>After</th></tr></thead><tbody>
    {Object.entries(d).map(([k, v]) => <tr key={k}><td className="mono">{k}</td><td className="log-old">{pretty((v as unknown[])[0])}</td><td className="log-new">{pretty((v as unknown[])[1])}</td></tr>)}</tbody></table>
  if (e.ev_kind === 'status') return <div className="log-kv"><span>From</span><b>{d.from ?? 'new'}</b><span>To</span><b>{d.to}</b>{d.reason && <><span>Reason</span><b>{d.reason}</b></>}</div>
  const entries = Object.entries(d).filter(([k]) => !NOISE.has(k) && k !== 'summary')
  return <div className="log-kv">{entries.map(([k, v]) => <Fragment key={k}><span className="mono">{k}</span><b>{pretty(v)}</b></Fragment>)}{!entries.length && <span>No further details.</span>}</div>
}

export function LogRow({ e, open, toggle }: { e: Row; open: boolean; toggle: () => void }) {
  return (<div className={'log-item' + (open ? ' open' : '')}>
    <button className="log-line" onClick={toggle} aria-expanded={open}>
      <span className="log-ico">{ICON[e.ev_entity_kind] ?? '📝'}</span>
      <span className="log-main"><span className="log-sum">{e.ev_summary}</span>
        <span className="log-meta">{e.ev_actor} · {time(e.ev_at)} · <span className={'log-tag log-tag-' + e.ev_kind}>{e.ev_kind === 'status' ? 'status change' : e.ev_kind === 'action' ? 'admin action' : e.ev_action === 'INSERT' ? 'created' : e.ev_action === 'DELETE' ? 'deleted' : 'edited'}</span></span></span>
      <span className="log-chev">{open ? '▾' : '▸'}</span></button>
    {open && <div className="log-detail"><Detail e={e} /></div>}</div>)
}

const csv = (rows: Row[]) => {
  const q = (s: unknown) => '"' + String(s ?? '').replace(/"/g, '""') + '"'
  return ['When,Who,Type,What,Summary', ...rows.map(r => [new Date(r.ev_at).toISOString(), r.ev_actor, r.ev_kind, r.ev_entity_kind + ' ' + r.ev_label, r.ev_summary].map(q).join(','))].join('\n')
}

const PAGE = 50
export function ActivityLog() {
  const [rows, setRows] = useState<Row[]>([]); const [loading, setLoading] = useState(true); const [more, setMore] = useState(false); const [err, setErr] = useState('')
  const [s, setS] = useState(''); const [search, setSearch] = useState(''); const [kind, setKind] = useState(''); const [from, setFrom] = useState(''); const [to, setTo] = useState(''); const [lines, setLines] = useState(false)
  const [open, setOpen] = useState<string | null>(null); const seq = useRef(0)
  useEffect(() => { const t = setTimeout(() => setSearch(s.trim()), 300); return () => clearTimeout(t) }, [s])
  const load = useCallback(async (offset: number) => {
    const my = ++seq.current; setLoading(true)
    const { data, error } = await supabase.rpc('admin_activity_feed', { p_limit: PAGE, p_entity: kind || null, p_search: search || null,
      p_from: from ? new Date(from + 'T00:00:00').toISOString() : null, p_to: to ? new Date(new Date(to + 'T00:00:00').getTime() + 864e5).toISOString() : null, p_children: lines, p_offset: offset })
    if (my !== seq.current) return
    setLoading(false); setErr(error?.message ?? ''); const got = (data as Row[]) ?? []
    setRows(r => offset ? [...r, ...got] : got); setMore(got.length === PAGE)
  }, [kind, search, from, to, lines])
  useEffect(() => { setOpen(null); load(0) }, [load])
  const groups: [string, Row[]][] = []
  rows.forEach(r => { const g = day(r.ev_at); const last = groups[groups.length - 1]; if (last && last[0] === g) last[1].push(r); else groups.push([g, [r]]) })
  const download = () => { const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([csv(rows)], { type: 'text/csv' })); a.download = 'activity-log.csv'; a.click(); URL.revokeObjectURL(a.href) }
  return (<>
    <div className="filter-bar">
      <div className="search-input-wrap"><span className="search-icon">🔍</span><input className="search-input" placeholder="Search by order no., batch, person…" value={s} onChange={e => setS(e.target.value)} /></div>
      <select className="filter-select" value={kind} onChange={e => setKind(e.target.value)}><option value="">Everything</option>{KINDS.map(k => <option key={k} value={k}>{k[0].toUpperCase() + k.slice(1)}s</option>)}</select>
      <input className="filter-select" type="date" value={from} max={to || undefined} onChange={e => setFrom(e.target.value)} aria-label="From date" />
      <input className="filter-select" type="date" value={to} min={from || undefined} onChange={e => setTo(e.target.value)} aria-label="To date" />
    </div>
    <div className="row" style={{ marginBottom: 12, justifyContent: 'space-between' }}>
      <label className="row" style={{ fontSize: 13 }}><input type="checkbox" checked={lines} onChange={e => setLines(e.target.checked)} /> Show line-item changes (sizes, tiers, photos)</label>
      <button className="btn btn-outline btn-sm" disabled={!rows.length} onClick={download}>⬇ Export CSV</button></div>
    <Err m={err} />
    {loading && !rows.length ? <Card flush><Loading /></Card> : !rows.length ? <Card flush><Empty icon="🗂️" title="Nothing logged yet" desc="Every change to orders, batches, reservations, products, disputes and settings appears here." /></Card> :
      groups.map(([g, list]) => <div key={g}><div className="log-day">{g}</div><div className="log-card">{list.map(e => <LogRow key={e.ev_id} e={e} open={open === e.ev_id} toggle={() => setOpen(open === e.ev_id ? null : e.ev_id)} />)}</div></div>)}
    {more && <div style={{ textAlign: 'center', margin: '16px 0' }}><button className="btn btn-outline" disabled={loading} onClick={() => load(rows.length)}>{loading ? 'Loading…' : 'Load more'}</button></div>}
  </>)
}
