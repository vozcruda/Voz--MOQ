import { useState } from 'react'
import { supabase, rpc, type Row } from '../supabase'
import { useQuery, Err, Empty, Loading } from '../ui/kit'

const COMPACT = 'vc_notif_compact'
const day = (s: string) => {
  const d = new Date(s), t = new Date(), y = new Date(Date.now() - 864e5)
  return d.toDateString() === t.toDateString() ? 'Today' : d.toDateString() === y.toDateString() ? 'Yesterday' : d.toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: d.getFullYear() === t.getFullYear() ? undefined : 'numeric' })
}
const clock = (s: string) => new Date(s).toLocaleTimeString('en-IN', { hour: 'numeric', minute: '2-digit', hour12: true })
const ago = (s: string) => {
  const m = Math.floor((Date.now() - new Date(s).getTime()) / 6e4)
  return m < 1 ? 'just now' : m < 60 ? m + ' min ago' : m < 1440 ? Math.floor(m / 60) + ' h ago' : ''
}
const changed = () => window.dispatchEvent(new Event('vc:notif'))

export function Notifications() {
  const q = useQuery(() => supabase.from('notifications').select('*').is('dismissed_at', null).order('created_at', { ascending: false }).limit(100), [])
  const [tab, setTab] = useState<'all' | 'unread'>('all'); const [err, setErr] = useState('')
  const [compact, setCompact] = useState(() => { try { return localStorage.getItem(COMPACT) === '1' } catch { return false } })
  const rows = q.rows as Row[]; const unread = rows.filter(n => !n.read_at).length; const readCount = rows.length - unread
  const list = rows.filter(n => tab === 'all' || !n.read_at)
  const run = async (name: string, args: Row = {}) => { setErr(''); const e = await rpc(name, args); if (e) setErr(e); changed(); q.reload() }
  const open = async (n: Row) => { if (!n.read_at) { await supabase.from('notifications').update({ read_at: new Date().toISOString() }).eq('id', n.id); changed(); q.reload() } }
  const setView = (c: boolean) => { setCompact(c); try { localStorage.setItem(COMPACT, c ? '1' : '0') } catch { /* ignore */ } }
  const groups: [string, Row[]][] = []
  list.forEach(n => { const g = day(n.created_at); const last = groups[groups.length - 1]; if (last && last[0] === g) last[1].push(n); else groups.push([g, [n]]) })
  return (<>
    <Err m={q.err || err} />
    {q.loading ? <Loading /> : !rows.length ? <Empty icon="🔔" title="You're all caught up" /> : <>
      <div className="notif-bar">
        <div className="tabs" style={{ marginBottom: 0, borderBottom: 0 }}>
          <div className={'tab' + (tab === 'all' ? ' active' : '')} onClick={() => setTab('all')}>All ({rows.length})</div>
          <div className={'tab' + (tab === 'unread' ? ' active' : '')} onClick={() => setTab('unread')}>Unread ({unread})</div></div>
        <div className="row">
          <button className="btn btn-ghost btn-sm" disabled={!unread} onClick={() => run('mark_all_notifications_read')}>✓ Mark all read</button>
          <button className="btn btn-ghost btn-sm" disabled={!readCount} onClick={() => run('dismiss_notifications', { p_only_read: true })}>🧹 Clear read</button>
          <button className="btn btn-outline btn-sm" onClick={() => setView(!compact)} aria-pressed={compact}>{compact ? '☰ Comfortable' : '≡ Compact'}</button></div></div>
      {!list.length ? <Empty icon="✅" title="No unread notifications" /> : groups.map(([g, items]) => <div key={g}>
        <div className="log-day">{g}</div>
        <div className={'notif-list' + (compact ? ' compact' : '')}>
          {items.map(n => <div key={n.id} className={'notif-item' + (n.read_at ? '' : ' unread')} onClick={() => open(n)}>
            {!compact && <div className="notif-icon">🔔</div>}
            <div className="notif-body">
              <div className="notif-title">{n.title}{compact && n.body && <span className="notif-inline"> — {n.body}</span>}</div>
              {!compact && n.body && <div className="notif-desc">{n.body}</div>}
              {!compact && <div className="notif-time">{clock(n.created_at)}{ago(n.created_at) && ' · ' + ago(n.created_at)}</div>}</div>
            {compact && <div className="notif-time notif-time-c">{clock(n.created_at)}</div>}
            <button className="notif-x" aria-label="Dismiss" title="Dismiss" onClick={e => { e.stopPropagation(); run('dismiss_notifications', { p_ids: [n.id] }) }}>✕</button>
          </div>)}</div></div>)}
    </>}
  </>)
}
