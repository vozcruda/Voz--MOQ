import { useState } from 'react'
import { supabase, inr, type Row } from '../supabase'
import { useQuery, Err, Chip, Card, Empty, Loading, Stats, Stat } from '../ui/kit'

const COLOR: Record<string, 'green' | 'orange' | 'blue' | 'yellow' | 'gray' | 'red'> = { success: 'green', failed: 'red', initiated: 'gray', pending: 'yellow', refund_needed: 'orange', mismatch: 'red' }
const LABEL: Record<string, string> = { success: 'Paid', failed: 'Failed', initiated: 'Not completed', pending: 'Processing', refund_needed: 'Refund needed', mismatch: 'Check amount' }
const when = (s: string) => new Date(s).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit', hour12: true }).replace(' am', ' am').replace(' pm', ' pm')

/** Admin: every online payment attempt and what PayU's server confirmed. */
export function OnlinePayments() {
  const q = useQuery(() => supabase.from('payment_attempts').select('id, txnid, status, outcome, amount_paise, gateway_ref, mode, message, created_at, commitment:commitment_id(qty, pool:pool_id(pool_no, title)), buyer:buyer_org_id(trade_name, legal_name)').order('created_at', { ascending: false }).limit(200), [])
  const [tab, setTab] = useState('attention'); const all = q.rows as Row[]
  const tabs: [string, string, (r: Row) => boolean][] = [['attention', 'Needs attention', r => ['refund_needed', 'mismatch'].includes(r.status)], ['success', 'Paid', r => r.status === 'success'], ['issues', 'Failed / abandoned', r => ['failed', 'initiated', 'pending'].includes(r.status)], ['all', 'All', () => true]]
  const f = tabs.find(t => t[0] === tab)![2]; const rows = all.filter(f)
  const paid = all.filter(r => r.status === 'success').reduce((s, r) => s + Number(r.amount_paise), 0)
  return (<>
    <Stats><Stat label="Received online" value={inr(paid)} sub={`${all.filter(r => r.status === 'success').length} payments`} />
      <Stat label="Needs attention" value={all.filter(tabs[0][2]).length} sub="refund or amount check" />
      <Stat label="Failed / abandoned" value={all.filter(tabs[2][2]).length} /></Stats>
    <div className="tabs">{tabs.map(([k, l, fn]) => <div key={k} className={'tab' + (tab === k ? ' active' : '')} onClick={() => setTab(k)}>{l}{k !== 'all' ? ` (${all.filter(fn).length})` : ''}</div>)}</div>
    <Err m={q.err} />
    <Card flush>{q.loading ? <Loading /> : !rows.length ? <Empty icon="💳" title="Nothing here" desc="Online payments made through PayU appear here with the status PayU confirmed." /> :
      <div className="table-card"><table><thead><tr><th>When</th><th>Buyer</th><th>Batch</th><th>Amount</th><th>Status</th><th>Mode</th><th>PayU ref</th></tr></thead><tbody>
        {rows.map(r => <tr key={r.id}><td className="td-muted" style={{ whiteSpace: 'nowrap' }}>{when(r.created_at)}</td><td className="td-strong">{r.buyer?.trade_name ?? r.buyer?.legal_name}</td>
          <td>{r.commitment?.pool?.pool_no}<div className="td-muted">{r.commitment?.pool?.title}</div></td><td>{inr(r.amount_paise)}</td>
          <td><Chip c={COLOR[r.status] ?? 'gray'}>{LABEL[r.status] ?? r.status}</Chip>{(r.outcome || r.message) && <div className="td-muted" style={{ maxWidth: 220 }}>{r.outcome || r.message}</div>}</td>
          <td>{r.mode ?? '—'}</td><td className="mono">{r.gateway_ref ?? '—'}<div className="td-muted">{r.txnid}</div></td></tr>)}</tbody></table></div>}</Card>
    <p className="form-hint">Statuses come from PayU’s own server, not from the buyer’s browser. “Refund needed” means money arrived after the reservation lapsed or twice — refund it from the PayU dashboard, then mark the reservation refunded.</p>
  </>)
}
