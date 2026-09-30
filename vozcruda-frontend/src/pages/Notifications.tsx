import { supabase, fdate, type Row } from '../supabase'
import { useQuery, Err, Empty, Loading } from '../ui/kit'

export function Notifications() {
  const q = useQuery(() => supabase.from('notifications').select('*').order('created_at', { ascending: false }).limit(50), [])
  const read = async (n: Row) => { if (!n.read_at) { await supabase.from('notifications').update({ read_at: new Date().toISOString() }).eq('id', n.id); q.reload() } }
  return (<><Err m={q.err} />{q.loading ? <Loading /> : !q.rows.length ? <Empty icon="🔔" title="You're all caught up" /> : <div className="notif-list">
    {(q.rows as Row[]).map(n => <div key={n.id} className={'notif-item' + (n.read_at ? '' : ' unread')} onClick={() => read(n)}><div className="notif-icon">🔔</div>
      <div className="notif-body"><div className="notif-title">{n.title}</div>{n.body && <div className="notif-desc">{n.body}</div>}<div className="notif-time">{fdate(n.created_at)}</div></div></div>)}</div>}</>)
}
