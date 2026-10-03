import { supabase, inr, type Row } from '../supabase'
import { useAuth } from '../auth'
import { useQuery, Err, Status, Stats, Stat, Section, Card, Empty, Loading, Progress, pct } from '../ui/kit'

export function SupplierDashboard({ go }: { go: (p: string) => void }) {
  const { org } = useAuth()
  const prods = useQuery(() => supabase.from('products').select('id,title,status,min_moq,categories(name),price_tiers(min_qty,unit_price_paise)').eq('organization_id', org?.id ?? '').is('deleted_at', null), [org?.id])
  const pos = useQuery(() => supabase.from('purchase_orders').select('*, pool:pool_id(title, moq_qty, paid_qty)'), [])
  const pools = useQuery(() => supabase.from('moq_pools').select('*').eq('manufacturer_org_id', org?.id ?? '').is('removed_at', null), [org?.id])
  const p = prods.rows as Row[]; const o = pos.rows as Row[]
  return (<>
    {org?.verification_status !== 'approved' && <div className="info-card" style={{ marginBottom: 20 }}><div className="info-card-body">⏳ Your supplier account is <b>{org?.verification_status}</b>. An admin must verify it before your products go live.</div></div>}
    <Stats><Stat label="Products" value={p.length} sub={`${p.filter(x => x.status === 'approved').length} live`} />
      <Stat label="Pending Production" value={o.filter(x => ['sent', 'accepted'].includes(x.status)).length} sub="POs awaiting action" />
      <Stat label="Confirmed Orders" value={inr(o.filter(x => !['cancelled', 'rejected'].includes(x.status)).reduce((s, x) => s + Number(x.total_cost_paise), 0))} />
      <Stat label="In Production" value={`${o.filter(x => x.status === 'in_production').reduce((s, x) => s + x.total_qty, 0)} pcs`} /></Stats>
    <div className="info-card" style={{ marginBottom: 20 }}><div className="info-card-body row" style={{ justifyContent: 'space-between' }}>
      <span>📈 See which products are filling fastest and what similar items sell for.</span>
      <span className="row"><button className="btn btn-outline btn-sm" onClick={() => go('insights')}>Market insights</button><button className="btn btn-outline btn-sm" onClick={() => go('requirements')}>Requirements</button></span></div></div>
    <Section title="My Products" action={<button className="btn btn-primary btn-sm" onClick={() => go('products')}>Manage products</button>} />
    <Err m={prods.err} />
    <Card flush>{prods.loading ? <Loading /> : !p.length ? <Empty title="No products yet" /> : <table><thead><tr><th>Product</th><th>Status</th><th>Price</th></tr></thead><tbody>
      {p.slice(0, 6).map(x => <tr key={x.id}><td className="td-strong">{x.title}</td><td><Status s={x.status} /></td><td>{x.price_tiers?.length ? inr(x.price_tiers[0].unit_price_paise) + '/pc' : '—'}</td></tr>)}</tbody></table>}</Card>
    <Section title="My Batches" />
    <Card flush>{!pools.rows.length ? <Empty title="No batches yet" desc="Admin creates batches from your approved products." /> : <table><thead><tr><th>Batch</th><th>Progress</th><th>Status</th></tr></thead><tbody>
      {(pools.rows as Row[]).map(x => <tr key={x.id}><td className="td-strong">{x.title}</td><td style={{ minWidth: 140 }}><div className="row" style={{ flexWrap: 'nowrap' }}><div style={{ flex: 1 }}><Progress done={x.paid_qty} total={x.moq_qty} /></div><b style={{ fontSize: 12 }}>{pct(x.paid_qty, x.moq_qty)}%</b></div></td><td><Status s={x.status} /></td></tr>)}</tbody></table>}</Card>
  </>)
}
