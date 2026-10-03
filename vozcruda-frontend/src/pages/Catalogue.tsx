import { useState, useRef } from 'react'
import { supabase, rpc, inr, type Row } from '../supabase'
import { useAuth } from '../auth'
import { useGuest } from '../guest'
import { useQuery, Err, Status, Chip, Empty, Loading, Modal, Field, Card } from '../ui/kit'
import { levelLabel } from './Pools'

const slugify = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') + '-' + Math.random().toString(36).slice(2, 6)

const BUCKET = 'vc-public'
const imgUrl = (key: string) => supabase.storage.from(BUCKET).getPublicUrl(key).data.publicUrl
const firstImage = (p: Row): string | null => {
  const list = ((p.product_images as Row[]) ?? []).slice().sort((a, b) => a.position - b.position)
  const k = list[0]?.files?.object_key as string | undefined
  return k ? imgUrl(k) : null
}
// Shrink big photos in the browser (max 1600px, JPEG) so uploads are fast and under the 5 MB limit.
async function prepare(file: File): Promise<{ blob: Blob; ext: string; type: string }> {
  const ok = ['image/jpeg', 'image/png', 'image/webp']
  if (!ok.includes(file.type)) throw new Error(`${file.name}: only JPG, PNG or WebP images are allowed.`)
  const ext = file.type === 'image/png' ? 'png' : file.type === 'image/webp' ? 'webp' : 'jpg'
  try {
    const bmp = await createImageBitmap(file)
    const scale = Math.min(1, 1600 / Math.max(bmp.width, bmp.height))
    if (scale < 1 || file.size > 2 * 1024 * 1024) {
      const c = document.createElement('canvas'); c.width = Math.round(bmp.width * scale); c.height = Math.round(bmp.height * scale)
      const ctx = c.getContext('2d'); if (!ctx) throw new Error('no canvas')
      ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, c.width, c.height); ctx.drawImage(bmp, 0, 0, c.width, c.height)
      const blob = await new Promise<Blob | null>(r => c.toBlob(r, 'image/jpeg', 0.85))
      if (blob) return { blob, ext: 'jpg', type: 'image/jpeg' }
    }
  } catch { /* fall through and upload the original */ }
  if (file.size > 5 * 1024 * 1024) throw new Error(`${file.name} is larger than 5 MB.`)
  return { blob: file, ext, type: file.type }
}

export function Catalogue({ mode }: { mode: 'buyer' | 'admin' | 'supplier' }) {
  const { org, can } = useAuth(); const { guest } = useGuest()
  const [q, setQ] = useState(''); const [cat, setCat] = useState(''); const [st, setSt] = useState('')
  const [edit, setEdit] = useState<Row | 'new' | null>(null)
  const cats = useQuery(() => supabase.from('categories').select('id,name').eq('is_active', true).order('sort_order'), [])
  const mats = useQuery(() => supabase.from('materials').select('id,name').eq('is_active', true).order('name'), [])
  const prods = useQuery(() => {
    if (mode === 'buyer') return supabase.from(guest ? 'guest_products' : 'public_products').select('*').order('created_at', { ascending: false })
    let b = supabase.from('products').select('*, categories(name), price_tiers(min_qty, unit_price_paise), organizations(legal_name, trade_name), product_images(id, position, files(object_key)), product_variants(size, color, is_active)').is('deleted_at', null).order('created_at', { ascending: false })
    if (mode === 'supplier' && org) b = b.eq('organization_id', org.id)
    return b
  }, [mode, org?.id, guest])
  const pics = useQuery(() => mode === 'buyer' ? supabase.from('public_product_images').select('product_id, position, bucket, object_key').order('position') : Promise.resolve({ data: [], error: null }), [mode])
  const cover = (id: string) => { const r = (pics.rows as Row[]).find(x => x.product_id === id); return r ? imgUrl(r.object_key) : null }
  const canManage = (mode === 'supplier') || (mode === 'admin' && can('catalogue'))
  const rows = (prods.rows as Row[]).filter(p => p.title.toLowerCase().includes(q.toLowerCase()) && (!cat || p.category_id === cat) && (!st || p.status === st))
  const review = async (p: Row, status: string) => { const reason = status === 'rejected' ? prompt('Reason for rejection?') : null; if (status === 'rejected' && !reason) return; const e = await rpc('admin_review_product', { p_product: p.id, p_status: status, p_reason: reason }); if (e) alert(e); prods.reload() }
  const submit = async (p: Row) => { const { error } = await supabase.from('products').update({ status: 'pending' }).eq('id', p.id); if (error) alert(error.message); prods.reload() }
  return (<>
    <div className="filter-bar">
      <div className="search-input-wrap"><span className="search-icon">🔍</span><input className="search-input" placeholder="Search products…" value={q} onChange={e => setQ(e.target.value)} /></div>
      <select className="filter-select" value={cat} onChange={e => setCat(e.target.value)}><option value="">All Categories</option>{(cats.rows as Row[]).map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select>
      {mode !== 'buyer' && <select className="filter-select" value={st} onChange={e => setSt(e.target.value)}><option value="">All Status</option>{['draft', 'pending', 'approved', 'rejected', 'archived'].map(s => <option key={s}>{s}</option>)}</select>}
      {canManage && <button className="btn btn-primary btn-sm" onClick={() => setEdit('new')}>+ Add Product</button>}
    </div>
    <Err m={prods.err} />
    {prods.loading ? <Loading /> : !rows.length ? <Empty icon="📦" title="No products" desc={canManage ? 'Add the first product.' : undefined} /> :
      mode === 'buyer' ? <div className="products-grid">{rows.map(p => <div className="product-card" key={p.id}><div className="product-image">{cover(p.id) ? <img src={cover(p.id)!} alt={p.title} loading="lazy" /> : <span className="product-image-emoji">👕</span>}</div>
        <div className="product-body"><div className="product-category">{p.category_name ?? 'Product'}</div><div className="product-title">{p.title}</div>
          <div className="product-supplier">{p.display_name ? p.display_name + ' · ' + levelLabel(p.verification_level) : levelLabel(p.verification_level) + ' supplier'}</div>
          <div className="row">{p.gsm && <Chip>{p.gsm} GSM</Chip>}{p.material_name && <Chip>{p.material_name}</Chip>}{p.min_moq && <Chip c="orange">MOQ {p.min_moq}</Chip>}{p.lead_time_days && <Chip c="blue">{p.lead_time_days}d lead</Chip>}{p.sample_available && <Chip c="green">Sample</Chip>}</div></div></div>)}</div> :
      <Card flush><table><thead><tr><th>Product</th>{mode === 'admin' && <th>Supplier</th>}<th>Category</th><th>MOQ</th><th>Price</th><th>Status</th><th></th></tr></thead><tbody>
        {rows.map(p => <tr key={p.id}><td className="row" style={{ flexWrap: 'nowrap' }}><div className="thumb">{firstImage(p) ? <img src={firstImage(p)!} alt="" /> : <span>👕</span>}</div><div><div className="td-strong">{p.title}</div>{p.rejected_reason && <div className="td-muted">Rejected: {p.rejected_reason}</div>}</div></td>
          {mode === 'admin' && <td>{p.organizations?.trade_name || p.organizations?.legal_name}</td>}<td>{p.categories?.name ?? '—'}</td><td>{p.min_moq ?? '—'}</td>
          <td>{p.price_tiers?.length ? inr([...p.price_tiers].sort((a: Row, b: Row) => a.min_qty - b.min_qty)[0].unit_price_paise) : '—'}</td><td><Status s={p.status} /></td>
          <td className="row">{canManage && <button className="btn btn-outline btn-sm" onClick={() => setEdit(p)}>✏️ Edit</button>}{mode === 'admin' && can('catalogue') && p.status === 'pending' && <><button className="btn btn-success btn-sm" onClick={() => review(p, 'approved')}>Approve</button><button className="btn btn-outline btn-sm" onClick={() => review(p, 'rejected')}>Reject</button></>}
            {mode === 'supplier' && ['draft', 'rejected'].includes(p.status) && <button className="btn btn-outline btn-sm" onClick={() => submit(p)}>Submit for review</button>}</td></tr>)}</tbody></table></Card>}
    {edit && (mode === 'admin' || org) && <ProductEditor admin={mode === 'admin'} orgId={org?.id ?? ''} product={edit === 'new' ? undefined : edit} cats={cats.rows as Row[]} mats={mats.rows as Row[]}
      onClose={() => setEdit(null)} onDone={() => { setEdit(null); prods.reload() }} />}
  </>)
}

const SIZE_PRESETS = ['XS', 'S', 'M', 'L', 'XL', 'XXL', '3XL']
const FITS = ['Regular', 'Oversized', 'Relaxed', 'Slim', 'Boxy']
const uniq = (a: string[]) => Array.from(new Set(a))
const val = (v: unknown) => (v == null ? '' : String(v))

function ProductEditor({ admin, orgId, product, cats, mats, onClose, onDone }: { admin: boolean; orgId: string; product?: Row; cats: Row[]; mats: Row[]; onClose: () => void; onDone: () => void }) {
  const [pid, setPid] = useState<string | null>(product?.id ?? null)
  const tiers0 = ((product?.price_tiers as Row[]) ?? []).slice().sort((a, b) => a.min_qty - b.min_qty)
  const vs0 = ((product?.product_variants as Row[]) ?? []).filter(v => v.is_active)
  const [f, setF] = useState({ supplier: val(product?.organization_id), title: val(product?.title), category_id: val(product?.category_id), material_id: val(product?.material_id),
    gsm: val(product?.gsm), fit: val(product?.fit), description: val(product?.description), min_moq: val(product?.min_moq), lead: val(product?.lead_time_days),
    sample: !!product?.sample_available, publish: false, basePrice: tiers0[0] ? String(tiers0[0].unit_price_paise / 100) : '' })
  const [extra, setExtra] = useState<{ min: string; price: string }[]>(tiers0.slice(1).map(t => ({ min: String(t.min_qty), price: String(t.unit_price_paise / 100) })))
  const [sizes, setSizes] = useState<string[]>(uniq(vs0.map(v => v.size)))
  const [colors, setColors] = useState<string[]>(uniq(vs0.map(v => v.color)))
  const [sizeIn, setSizeIn] = useState(''); const [colorIn, setColorIn] = useState('')
  const [kept, setKept] = useState<Row[]>(((product?.product_images as Row[]) ?? []).slice().sort((a, b) => a.position - b.position))
  const [removed, setRemoved] = useState<Row[]>([])
  const [staged, setStaged] = useState<{ file: File; url: string }[]>([])
  const [err, setErr] = useState(''); const [busy, setBusy] = useState(false); const pick = useRef<HTMLInputElement>(null)
  const suppliers = useQuery(() => admin && !product ? supabase.from('organizations').select('id, legal_name, trade_name, verification_status').eq('type', 'manufacturer').is('deleted_at', null).order('legal_name') : Promise.resolve({ data: [], error: null }), [admin])
  const up = (k: string, v: string | boolean) => setF(p => ({ ...p, [k]: v }))
  const status = product?.status as string | undefined
  const addTag = (list: string[], set: (v: string[]) => void, raw: string, clear: () => void) => {
    const parts = raw.split(',').map(x => x.trim()).filter(Boolean); if (parts.length) set(uniq([...list, ...parts])); clear()
  }
  const toggleSize = (z: string) => setSizes(sizes.includes(z) ? sizes.filter(x => x !== z) : [...sizes, z])
  const total = kept.length + staged.length

  const addFiles = (files: FileList | null) => {
    if (!files) return
    const room = 8 - total; const list = Array.from(files).slice(0, Math.max(room, 0))
    if (files.length > room) setErr('A product can have at most 8 photos.')
    setStaged(s => [...s, ...list.map(file => ({ file, url: URL.createObjectURL(file) }))])
    if (pick.current) pick.current.value = ''
  }

  const buildTiers = () => {
    if (!f.basePrice && !extra.some(t => t.min || t.price)) return []
    const moq = +f.min_moq
    if (!moq || moq < 1) throw new Error('Enter the MOQ before setting prices.')
    const rows = [{ min: moq, price: +f.basePrice }, ...extra.filter(t => t.min || t.price).map(t => ({ min: +t.min, price: +t.price }))]
    rows.forEach((r, i) => {
      if (!(r.price > 0)) throw new Error(i === 0 ? 'Enter the price per piece at the MOQ.' : `Tier ${i + 1}: enter a price.`)
      if (i > 0 && !(r.min > rows[i - 1].min)) throw new Error(`Tier ${i + 1}: quantity must be higher than the previous tier.`)
    })
    return rows.map((r, i) => ({ min_qty: r.min, max_qty: rows[i + 1] ? rows[i + 1].min - 1 : null, unit_price_paise: Math.round(r.price * 100) }))
  }

  const save = async (submit: boolean) => {
    setErr(''); setBusy(true)
    try {
      if (!f.title.trim()) throw new Error('Title is required.')
      if (admin && !pid && !f.supplier) throw new Error('Choose the supplier this product belongs to.')
      if (submit) {
        if (!f.category_id) throw new Error('Choose a category before submitting.')
        if (!f.min_moq) throw new Error('Enter the MOQ before submitting.')
        if (!f.basePrice) throw new Error('Enter the price before submitting.')
        if (!sizes.length || !colors.length) throw new Error('Add at least one size and one colour before submitting.')
        if (!total) throw new Error('Add at least one photo before submitting.')
      }
      const variants = sizes.flatMap(sz => colors.map(c => ({ size: sz, color: c })))
      const tiers = buildTiers()
      const num = (x: string) => (x ? +x : null)
      const owner = product?.organization_id ?? (admin ? f.supplier : orgId)
      let id = pid
      if (admin) {
        const { data, error } = await supabase.rpc('admin_save_product', { p_product: id, p_org: id ? null : f.supplier, p_title: f.title.trim(), p_category: f.category_id || null, p_material: f.material_id || null,
          p_description: f.description || null, p_gsm: num(f.gsm), p_fit: f.fit || null, p_moq: num(f.min_moq), p_lead_days: num(f.lead), p_sample: f.sample, p_variants: variants, p_tiers: tiers,
          p_publish: id ? null : f.publish })
        if (error) throw new Error(error.message)
        id = data as string; setPid(id)
      } else {
        const base = { title: f.title.trim(), category_id: f.category_id || null, material_id: f.material_id || null, description: f.description || null, gsm: num(f.gsm), fit: f.fit || null,
          min_moq: num(f.min_moq), lead_time_days: num(f.lead), sample_available: f.sample }
        if (!id) {
          const r = await supabase.from('products').insert({ ...base, organization_id: orgId, slug: slugify(f.title) }).select('id').single()
          if (r.error) throw new Error(r.error.message)
          id = (r.data as Row).id as string; setPid(id)
        } else {
          const r = await supabase.from('products').update(base).eq('id', id); if (r.error) throw new Error(r.error.message)
        }
        const have = await supabase.from('product_variants').select('id, size, color, is_active').eq('product_id', id)
        if (have.error) throw new Error(have.error.message)
        const rows = (have.data as Row[]) ?? []; const want = new Set(variants.map(v => v.size + '|' + v.color))
        const del = rows.filter(r => !want.has(r.size + '|' + r.color)).map(r => r.id)
        if (del.length) { const r = await supabase.from('product_variants').delete().in('id', del); if (r.error) throw new Error(r.error.message) }
        const react = rows.filter(r => want.has(r.size + '|' + r.color) && !r.is_active).map(r => r.id)
        if (react.length) { const r = await supabase.from('product_variants').update({ is_active: true }).in('id', react); if (r.error) throw new Error(r.error.message) }
        const have2 = new Set(rows.map(r => r.size + '|' + r.color))
        const add = variants.filter(v => !have2.has(v.size + '|' + v.color)).map(v => ({ product_id: id, size: v.size, color: v.color }))
        if (add.length) { const r = await supabase.from('product_variants').insert(add); if (r.error) throw new Error(r.error.message) }
        const dt = await supabase.from('price_tiers').delete().eq('product_id', id); if (dt.error) throw new Error(dt.error.message)
        if (tiers.length) { const r = await supabase.from('price_tiers').insert(tiers.map(t => ({ ...t, product_id: id }))); if (r.error) throw new Error('Prices: ' + r.error.message) }
      }
      // photos: remove, then upload
      for (const im of removed) {
        const r = await supabase.rpc('remove_product_image', { p_image: im.id })
        if (r.error) throw new Error(r.error.message)
        if (r.data) await supabase.storage.from(BUCKET).remove([r.data as string])
      }
      setRemoved([])
      const left: typeof staged = []
      for (const [i, st] of staged.entries()) {
        try {
          const { blob, ext, type } = await prepare(st.file)
          const key = `products/${owner}/${crypto.randomUUID()}.${ext}`
          const u = await supabase.storage.from(BUCKET).upload(key, blob, { contentType: type, upsert: false })
          if (u.error) throw new Error(u.error.message)
          const r = await supabase.rpc('register_product_image', { p_product: id, p_object_key: key, p_mime: type, p_size: blob.size, p_alt: f.title.trim() })
          if (r.error) { await supabase.storage.from(BUCKET).remove([key]); throw new Error(r.error.message) }
        } catch (e) { left.push(...staged.slice(i)); setStaged(left); throw e }
      }
      setStaged([])
      if (submit && !admin) {
        const r = await supabase.from('products').update({ status: 'pending' }).eq('id', id)
        if (r.error) throw new Error(r.error.message)
      }
      onDone()
    } catch (e) { setErr((e as Error).message) }
    setBusy(false)
  }

  const canSubmit = !admin && (!status || ['draft', 'rejected'].includes(status))
  const title = product ? 'Edit product' : admin ? 'Add Product (Admin)' : 'Add Product'
  return (
    <Modal title={title} sub={status ? `Status: ${status}` : admin ? 'Create a listing on behalf of a supplier' : 'Saved as a draft until you submit it for review'} onClose={onClose}
      footer={<><button className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button className="btn btn-outline" disabled={busy} onClick={() => save(false)}>{busy ? 'Saving…' : admin ? (product ? 'Save changes' : f.publish ? 'Save & publish' : 'Save as draft') : status && status !== 'draft' ? 'Save changes' : 'Save as draft'}</button>
        {canSubmit && <button className="btn btn-primary" disabled={busy} onClick={() => save(true)}>Save & submit for review</button>}</>}>
      {!admin && status === 'approved' && <p className="form-hint" style={{ marginTop: 0 }}>This product is live. Changing the title, description, category, material, GSM, fit, sizes/colours or photos sends it back to admin review until it is approved again.</p>}
      {admin && !product && <Field label="Supplier"><select className="form-input" value={f.supplier} onChange={e => up('supplier', e.target.value)}><option value="">Select supplier…</option>
        {(suppliers.rows as Row[]).map(o => <option key={o.id} value={o.id}>{o.trade_name || o.legal_name}{o.verification_status !== 'approved' ? ` (${o.verification_status})` : ''}</option>)}</select></Field>}

      <div className="editor-h">Details</div>
      <Field label="Product title"><input className="form-input" value={f.title} onChange={e => up('title', e.target.value)} placeholder="e.g. 240 GSM Oversized Cotton Tee" /></Field>
      <div className="form-row"><Field label="Category"><select className="form-input" value={f.category_id} onChange={e => up('category_id', e.target.value)}><option value="">Select…</option>{cats.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
        <Field label="Material"><select className="form-input" value={f.material_id} onChange={e => up('material_id', e.target.value)}><option value="">Select…</option>{mats.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field></div>
      <div className="form-row"><Field label="GSM"><input className="form-input" type="number" inputMode="numeric" value={f.gsm} onChange={e => up('gsm', e.target.value)} placeholder="e.g. 240" /></Field>
        <Field label="Fit"><input className="form-input" list="fits" value={f.fit} onChange={e => up('fit', e.target.value)} placeholder="e.g. Oversized" /><datalist id="fits">{FITS.map(x => <option key={x} value={x} />)}</datalist></Field></div>
      <Field label="Description"><textarea className="form-input" rows={3} value={f.description} onChange={e => up('description', e.target.value)} placeholder="Fabric, finish, print options, packing…" /></Field>

      <div className="editor-h">Sizes &amp; colours</div>
      <Field label="Sizes" hint="Tap the sizes you make, or type your own and press Add.">
        <div className="chips-row">{uniq([...SIZE_PRESETS, ...sizes]).map(z => <button type="button" key={z} className={'pill' + (sizes.includes(z) ? ' on' : '')} onClick={() => toggleSize(z)}>{z}</button>)}</div>
        <div className="row" style={{ marginTop: 8 }}><input className="form-input" value={sizeIn} onChange={e => setSizeIn(e.target.value)} placeholder="Custom size, e.g. 4XL" onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); addTag(sizes, setSizes, sizeIn, () => setSizeIn('')) } }} />
          <button type="button" className="btn btn-outline btn-sm" onClick={() => addTag(sizes, setSizes, sizeIn, () => setSizeIn(''))}>Add</button></div></Field>
      <Field label="Colours" hint="Type a colour and press Add (you can add several separated by commas).">
        <div className="chips-row">{colors.map(c => <span className="pill on" key={c}>{c}<button type="button" aria-label={`Remove ${c}`} onClick={() => setColors(colors.filter(x => x !== c))}>✕</button></span>)}</div>
        <div className="row" style={{ marginTop: 8 }}><input className="form-input" value={colorIn} onChange={e => setColorIn(e.target.value)} placeholder="e.g. Black, Off-white, Navy" onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); addTag(colors, setColors, colorIn, () => setColorIn('')) } }} />
          <button type="button" className="btn btn-outline btn-sm" onClick={() => addTag(colors, setColors, colorIn, () => setColorIn(''))}>Add</button></div></Field>
      <p className="form-hint" style={{ marginTop: -4 }}>{sizes.length && colors.length ? `${sizes.length * colors.length} size/colour combinations (${sizes.length} sizes × ${colors.length} colours).` : 'Pick at least one size and one colour.'}</p>

      <div className="editor-h">MOQ &amp; pricing</div>
      <div className="form-row"><Field label="MOQ (pieces)"><input className="form-input" type="number" inputMode="numeric" value={f.min_moq} onChange={e => up('min_moq', e.target.value)} /></Field>
        <Field label="Lead time (days)"><input className="form-input" type="number" inputMode="numeric" value={f.lead} onChange={e => up('lead', e.target.value)} /></Field></div>
      <Field label={`Price per piece at ${f.min_moq || 'MOQ'} pcs (₹)`}><input className="form-input" type="number" inputMode="decimal" value={f.basePrice} onChange={e => up('basePrice', e.target.value)} /></Field>
      {extra.map((t, i) => <div className="form-row tier-row" key={i}>
        <Field label={i === 0 ? 'Volume discount: from qty' : 'From qty'}><input className="form-input" type="number" inputMode="numeric" value={t.min} onChange={e => setExtra(extra.map((x, j) => j === i ? { ...x, min: e.target.value } : x))} /></Field>
        <Field label="Price per piece (₹)"><div className="row"><input className="form-input" type="number" inputMode="decimal" value={t.price} onChange={e => setExtra(extra.map((x, j) => j === i ? { ...x, price: e.target.value } : x))} />
          <button type="button" className="btn btn-ghost btn-sm" aria-label="Remove tier" onClick={() => setExtra(extra.filter((_, j) => j !== i))}>✕</button></div></Field></div>)}
      <button type="button" className="btn btn-ghost btn-sm" onClick={() => setExtra([...extra, { min: '', price: '' }])}>+ Add volume discount</button>
      <label className="row" style={{ fontSize: 13, margin: '10px 0 0' }}><input type="checkbox" checked={f.sample} onChange={e => up('sample', e.target.checked)} /> Sample available</label>

      <div className="editor-h">Photos <span className="td-muted">({total}/8)</span></div>
      <input ref={pick} type="file" accept="image/jpeg,image/png,image/webp" multiple hidden onChange={e => addFiles(e.target.files)} />
      <p className="form-hint" style={{ marginTop: 0 }}>JPG, PNG or WebP. Large photos are shrunk automatically. The first photo is the cover.</p>
      <div className="img-grid">
        {kept.map((im, i) => <div className="img-tile" key={im.id}><img src={imgUrl(im.files?.object_key)} alt="" />{i === 0 && !staged.length && <span className="img-cover">Cover</span>}
          <button type="button" className="img-del" aria-label="Remove photo" onClick={() => { setKept(kept.filter(x => x.id !== im.id)); setRemoved([...removed, im]) }}>✕</button></div>)}
        {staged.map((st, i) => <div className="img-tile" key={st.url}><img src={st.url} alt="" />{!kept.length && i === 0 && <span className="img-cover">Cover</span>}<span className="img-new">New</span>
          <button type="button" className="img-del" aria-label="Remove photo" onClick={() => { URL.revokeObjectURL(st.url); setStaged(staged.filter(x => x.url !== st.url)) }}>✕</button></div>)}
        {total < 8 && <button type="button" className="img-add" onClick={() => pick.current?.click()}><span>＋</span>Add photos</button>}
      </div>

      {admin && !product && <label className="row" style={{ fontSize: 13, marginTop: 14 }}><input type="checkbox" checked={f.publish} onChange={e => up('publish', e.target.checked)} /> Publish immediately (visible to buyers; the supplier must be verified)</label>}
      <Err m={err} />
    </Modal>
  )
}
