import { useState } from 'react'
import { supabase, rpc, inr, type Row } from '../supabase'
import { useAuth } from '../auth'
import { useQuery, Err, Status, Chip, Empty, Loading, Modal, Field, Card } from '../ui/kit'
import { levelLabel } from './Pools'

const slugify = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') + '-' + Math.random().toString(36).slice(2, 6)

export function Catalogue({ mode }: { mode: 'buyer' | 'admin' | 'supplier' }) {
  const { org, can } = useAuth()
  const [q, setQ] = useState(''); const [cat, setCat] = useState(''); const [st, setSt] = useState(''); const [add, setAdd] = useState(false)
  const cats = useQuery(() => supabase.from('categories').select('id,name').eq('is_active', true).order('sort_order'), [])
  const prods = useQuery(() => {
    if (mode === 'buyer') return supabase.from('public_products').select('*').order('created_at', { ascending: false })
    let b = supabase.from('products').select('*, categories(name), price_tiers(min_qty, unit_price_paise), organizations(legal_name, trade_name)').is('deleted_at', null).order('created_at', { ascending: false })
    if (mode === 'supplier' && org) b = b.eq('organization_id', org.id)
    return b
  }, [mode, org?.id])
  const rows = (prods.rows as Row[]).filter(p => p.title.toLowerCase().includes(q.toLowerCase()) && (!cat || p.category_id === cat) && (!st || p.status === st))
  const review = async (p: Row, status: string) => { const reason = status === 'rejected' ? prompt('Reason for rejection?') : null; if (status === 'rejected' && !reason) return; const e = await rpc('admin_review_product', { p_product: p.id, p_status: status, p_reason: reason }); if (e) alert(e); prods.reload() }
  const submit = async (p: Row) => { const { error } = await supabase.from('products').update({ status: 'pending' }).eq('id', p.id); if (error) alert(error.message); prods.reload() }
  return (<>
    <div className="filter-bar">
      <div className="search-input-wrap"><span className="search-icon">🔍</span><input className="search-input" placeholder="Search products…" value={q} onChange={e => setQ(e.target.value)} /></div>
      <select className="filter-select" value={cat} onChange={e => setCat(e.target.value)}><option value="">All Categories</option>{(cats.rows as Row[]).map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select>
      {mode !== 'buyer' && <select className="filter-select" value={st} onChange={e => setSt(e.target.value)}><option value="">All Status</option>{['draft', 'pending', 'approved', 'rejected', 'archived'].map(s => <option key={s}>{s}</option>)}</select>}
      {mode === 'supplier' && <button className="btn btn-primary btn-sm" onClick={() => setAdd(true)}>+ Add Product</button>}
    </div>
    <Err m={prods.err} />
    {prods.loading ? <Loading /> : !rows.length ? <Empty icon="📦" title="No products" desc={mode === 'supplier' ? 'Add your first product.' : undefined} /> :
      mode === 'buyer' ? <div className="products-grid">{rows.map(p => <div className="product-card" key={p.id}><div className="product-image"><span className="product-image-emoji">👕</span></div>
        <div className="product-body"><div className="product-category">{p.category_name ?? 'Product'}</div><div className="product-title">{p.title}</div>
          <div className="product-supplier">{p.display_name} · {levelLabel(p.verification_level)}</div>
          <div className="row">{p.gsm && <Chip>{p.gsm} GSM</Chip>}{p.material_name && <Chip>{p.material_name}</Chip>}{p.min_moq && <Chip c="orange">MOQ {p.min_moq}</Chip>}{p.lead_time_days && <Chip c="blue">{p.lead_time_days}d lead</Chip>}{p.sample_available && <Chip c="green">Sample</Chip>}</div></div></div>)}</div> :
      <Card flush><table><thead><tr><th>Product</th>{mode === 'admin' && <th>Supplier</th>}<th>Category</th><th>MOQ</th><th>Price</th><th>Status</th><th></th></tr></thead><tbody>
        {rows.map(p => <tr key={p.id}><td><div className="td-strong">{p.title}</div>{p.rejected_reason && <div className="td-muted">Rejected: {p.rejected_reason}</div>}</td>
          {mode === 'admin' && <td>{p.organizations?.trade_name || p.organizations?.legal_name}</td>}<td>{p.categories?.name ?? '—'}</td><td>{p.min_moq ?? '—'}</td>
          <td>{p.price_tiers?.length ? inr([...p.price_tiers].sort((a: Row, b: Row) => a.min_qty - b.min_qty)[0].unit_price_paise) : '—'}</td><td><Status s={p.status} /></td>
          <td className="row">{mode === 'admin' && can('catalogue') && p.status === 'pending' && <><button className="btn btn-success btn-sm" onClick={() => review(p, 'approved')}>Approve</button><button className="btn btn-outline btn-sm" onClick={() => review(p, 'rejected')}>Reject</button></>}
            {mode === 'supplier' && ['draft', 'rejected'].includes(p.status) && <button className="btn btn-outline btn-sm" onClick={() => submit(p)}>Submit for review</button>}</td></tr>)}</tbody></table></Card>}
    {add && org && <CreateProduct org={org.id} cats={cats.rows as Row[]} onClose={() => setAdd(false)} onDone={() => { setAdd(false); prods.reload() }} />}
  </>)
}

function CreateProduct({ org, cats, onClose, onDone }: { org: string; cats: Row[]; onClose: () => void; onDone: () => void }) {
  const [f, setF] = useState({ title: '', category_id: '', description: '', gsm: '', min_moq: '', lead_time_days: '', price: '', sample: false })
  const [err, setErr] = useState(''); const [busy, setBusy] = useState(false)
  const up = (k: string, v: string | boolean) => setF({ ...f, [k]: v })
  const save = async () => {
    setErr(''); setBusy(true)
    if (!f.title.trim()) { setBusy(false); return setErr('Title is required.') }
    const { data, error } = await supabase.from('products').insert({ organization_id: org, title: f.title.trim(), slug: slugify(f.title), category_id: f.category_id || null,
      description: f.description || null, gsm: f.gsm ? +f.gsm : null, min_moq: f.min_moq ? +f.min_moq : null, lead_time_days: f.lead_time_days ? +f.lead_time_days : null, sample_available: f.sample }).select('id').single()
    if (error) { setBusy(false); return setErr(error.message) }
    if (f.price && f.min_moq) { const r = await supabase.from('price_tiers').insert({ product_id: (data as Row).id, min_qty: +f.min_moq, unit_price_paise: Math.round(+f.price * 100) }); if (r.error) { setBusy(false); return setErr('Saved, but price failed: ' + r.error.message) } }
    setBusy(false); onDone()
  }
  return (
    <Modal title="Create New Product" sub="Saved as draft — submit for review when ready" onClose={onClose} footer={<><button className="btn btn-outline" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy} onClick={save}>Save as Draft</button></>}>
      <Field label="Product Title"><input className="form-input" value={f.title} onChange={e => up('title', e.target.value)} placeholder="e.g. Oversized Cotton Tee" /></Field>
      <Field label="Category"><select className="form-input" value={f.category_id} onChange={e => up('category_id', e.target.value)}><option value="">Select…</option>{cats.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
      <div className="form-row"><Field label="GSM (optional)"><input className="form-input" type="number" value={f.gsm} onChange={e => up('gsm', e.target.value)} /></Field>
        <Field label="MOQ"><input className="form-input" type="number" value={f.min_moq} onChange={e => up('min_moq', e.target.value)} /></Field></div>
      <div className="form-row"><Field label="Price per piece (₹)"><input className="form-input" type="number" value={f.price} onChange={e => up('price', e.target.value)} /></Field>
        <Field label="Lead time (days)"><input className="form-input" type="number" value={f.lead_time_days} onChange={e => up('lead_time_days', e.target.value)} /></Field></div>
      <Field label="Description"><textarea className="form-input" rows={3} value={f.description} onChange={e => up('description', e.target.value)} /></Field>
      <label className="row" style={{ fontSize: 13 }}><input type="checkbox" checked={f.sample} onChange={e => up('sample', e.target.checked)} /> Sample available</label>
      <Err m={err} />
    </Modal>
  )
}
