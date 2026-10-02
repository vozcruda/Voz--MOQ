import { useEffect, useState } from 'react'
import { supabase, inr, type Row } from '../supabase'
import { useQuery, Err, Card, Section, Empty, Loading, Stats, Stat, Field } from '../ui/kit'

const hrs = (h?: number | null) => h == null ? '—' : h < 1 ? '<1 hr' : h < 48 ? `${Math.round(h)} hrs` : `${Math.round(h / 24)} days`
const label = (b: Row) => [b.fit && b.fit[0].toUpperCase() + b.fit.slice(1), b.category, b.material, b.gsm && `${b.gsm} GSM`].filter(Boolean).join(' · ')
const Trend = ({ v }: { v?: number | null }) => v == null ? <span className="td-muted">new</span> : <span className={'trend ' + (v >= 0 ? 'up' : 'down')}>{v >= 0 ? '▲' : '▼'} {Math.abs(v)}%</span>

/** Where the buyer-price band sits, with an optional "you" marker. */
function PriceBand({ p, mine }: { p: Row; mine?: number | null }) {
  const lo = Math.min(p.p25, mine ?? p.p25) * 0.92, hi = Math.max(p.p75, mine ?? p.p75) * 1.08
  const x = (v: number) => ((v - lo) / (hi - lo)) * 100
  return (<div className="band" title={`Middle half of batches: ${inr(p.p25)} – ${inr(p.p75)}`}>
    <div className="band-range" style={{ left: x(p.p25) + '%', width: x(p.p75) - x(p.p25) + '%' }} />
    <div className="band-med" style={{ left: x(p.median) + '%' }} />
    {mine != null && <div className="band-me" style={{ left: x(mine) + '%' }}><span>You</span></div>}
  </div>)
}

function Benchmark() {
  const cats = useQuery(() => supabase.from('categories').select('id,name').order('name'), [])
  const mats = useQuery(() => supabase.from('materials').select('id,name').order('name'), [])
  const [f, setF] = useState({ cat: '', mat: '', gsm: '', fit: '' }); const [res, setRes] = useState<Row | null>(null); const [err, setErr] = useState(''); const [busy, setBusy] = useState(false)
  const run = async () => {
    if (!f.cat) return setErr('Pick a category first.'); setErr(''); setBusy(true)
    const { data, error } = await supabase.rpc('supplier_price_benchmark', { p_category: f.cat, p_material: f.mat || null, p_gsm: f.gsm ? Number(f.gsm) : null, p_fit: f.fit || null, p_days: 180 })
    setBusy(false); if (error) return setErr(error.message); setRes(data as Row)
  }
  return (
    <Card title="Price check" action={<span className="td-muted">Last 6 months</span>}><div style={{ padding: '0 1rem 1rem' }}>
      <p className="form-hint" style={{ marginTop: 0 }}>Pick a spec to see what similar products are listed at — e.g. T-shirt · Cotton · 180 GSM · oversized.</p>
      <div className="bench-grid">
        <Field label="Category"><select className="form-input" value={f.cat} onChange={e => setF({ ...f, cat: e.target.value })}><option value="">Choose…</option>{(cats.rows as Row[]).map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
        <Field label="Material"><select className="form-input" value={f.mat} onChange={e => setF({ ...f, mat: e.target.value })}><option value="">Any</option>{(mats.rows as Row[]).map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
        <Field label="GSM" hint="Matches ±15"><input className="form-input" type="number" min={60} max={800} placeholder="e.g. 180" value={f.gsm} onChange={e => setF({ ...f, gsm: e.target.value })} /></Field>
        <Field label="Fit"><input className="form-input" placeholder="e.g. oversized" value={f.fit} onChange={e => setF({ ...f, fit: e.target.value })} /></Field>
      </div>
      <Err m={err} />
      <button className="btn btn-primary btn-sm" disabled={busy} onClick={run}>{busy ? 'Checking…' : 'Check prices'}</button>
      {res && (!res.enough
        ? <div className="info-card" style={{ marginTop: 14 }}><div className="info-card-body">Not enough listings or batches for this exact spec yet. To protect every supplier’s pricing we only show numbers backed by at least 3 products or batches from 2 or more manufacturers. Try widening it — leave fit or material on “Any”.</div></div>
        : <div className="bench-out">
          {res.batches != null && <div className="bench-box"><div className="bench-k">Demand for this spec</div><div className="bench-v">{res.fill_rate != null ? res.fill_rate + '% fill' : res.batches + ' batches'}</div>
            <div className="td-muted">{res.batches} batches · {res.units} pcs ordered · median time to MOQ {hrs(res.median_fill_hours)}</div></div>}
          {res.listed_price && <div className="bench-box"><div className="bench-k">Catalogue price (per pc)</div><div className="bench-v">{inr(res.listed_price.median)}</div>
            <div className="td-muted">Typical range {inr(res.listed_price.p25)} – {inr(res.listed_price.p75)} · {res.listed_price.products} live products</div></div>}
        </div>)}
    </div></Card>)
}

export function MarketInsights() {
  const [days, setDays] = useState(90); const [d, setD] = useState<Row | null>(null); const [err, setErr] = useState(''); const [loading, setLoading] = useState(true)
  useEffect(() => { setLoading(true); supabase.rpc('supplier_market_insights', { p_days: days }).then(({ data, error }) => { setErr(error?.message ?? ''); setD((data as Row) ?? null); setLoading(false) }) }, [days])
  const b: Row[] = d?.buckets ?? []
  const fastest = [...b].filter(x => x.median_fill_hours != null).sort((a, c) => a.median_fill_hours - c.median_fill_hours).slice(0, 3)
  const gaps = b.filter(x => !x.mine.lists_product && (x.fill_rate ?? 0) >= 60).slice(0, 3)
  return (<>
    <Section title="Market insights" sub="What buyers are ordering across MoqLess. Anonymous — no supplier names or individual prices. Prices shown are catalogue prices."
      action={<select className="form-input" style={{ width: 'auto' }} value={days} onChange={e => setDays(Number(e.target.value))}><option value={30}>Last 30 days</option><option value={90}>Last 90 days</option><option value={180}>Last 6 months</option></select>} />
    <Err m={err} />
    {loading ? <Loading /> : !b.length ? <Card><Empty icon="📈" title="Not enough market activity yet" desc="Insights appear once there are at least 3 batches from 2 manufacturers in the same spec. Check back as more batches go live." /></Card> : <>
      <Stats><Stat label="Batches tracked" value={d?.totals.batches} sub={`${d?.totals.groups} product groups`} />
        <Stat label="Pieces ordered" value={d?.totals.units} />
        <Stat label="Batches filled" value={d?.totals.filled} sub="reached MOQ" />
        <Stat label="Median time to fill" value={hrs(d?.totals.median_fill_hours)} /></Stats>
      {(fastest.length > 0 || gaps.length > 0) && <div className="ins-cols">
        {fastest.length > 0 && <Card title="⚡ Filling fastest"><ul className="ins-list">{fastest.map(x => <li key={x.key}><b>{label(x)}</b><span>{hrs(x.median_fill_hours)} to MOQ{x.mine.median_fill_hours != null ? ` · you ${hrs(x.mine.median_fill_hours)}` : ''}</span></li>)}</ul></Card>}
        {gaps.length > 0 && <Card title="💡 In demand, not in your catalogue"><ul className="ins-list">{gaps.map(x => <li key={x.key}><b>{label(x)}</b><span>{x.fill_rate}% of batches fill · {x.units} pcs ordered</span></li>)}</ul></Card>}
      </div>}
      <Card title="Demand by product" flush>
        <div className="table-card"><table><thead><tr><th>Product group</th><th>Pcs ordered</th><th>Trend</th><th>Filled</th><th>Time to MOQ</th><th>Catalogue price / pc</th><th>Price spread</th></tr></thead><tbody>
          {b.map(x => <tr key={x.key}>
            <td className="td-strong">{label(x)}<div className="td-muted">{x.batches} batches · {x.makers} manufacturers{x.mine.lists_product ? ' · you list this' : ''}</div></td>
            <td>{x.units}</td><td><Trend v={x.trend_pct} /></td>
            <td>{x.fill_rate != null ? x.fill_rate + '%' : '—'}</td>
            <td>{hrs(x.median_fill_hours)}{x.mine.median_fill_hours != null && <div className="td-muted">you: {hrs(x.mine.median_fill_hours)}</div>}</td>
            <td>{x.listed ? <><b>{inr(x.listed.median)}</b><div className="td-muted">avg {inr(x.listed.avg)}</div>{x.mine.listed_price != null && <div className="td-muted">you: {inr(x.mine.listed_price)}</div>}</> : <span className="td-muted">not enough listings</span>}</td>
            <td style={{ minWidth: 150 }}>{x.listed ? <PriceBand p={x.listed} mine={x.mine.listed_price} /> : '—'}</td></tr>)}</tbody></table></div>
      </Card>
      <p className="form-hint">Catalogue price is the supplier-listed price per piece at the first quantity tier, across live products. The bar shows the middle half of listings; the line is the median.</p>
    </>}
    <Benchmark />
  </>)
}
