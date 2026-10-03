import { useEffect, useState } from 'react'
import { supabase, fdate, type Row } from '../supabase'
import { useAuth } from '../auth'
import { useQuery, Err, Card, Loading, Modal, Field } from '../ui/kit'

type F = { k: string; label: string; hint?: string; area?: boolean; num?: boolean }
type Group = { key: string; title: string; sub: string; fields: F[] }

/** Object-valued settings: one card per key, one input per field. */
const GROUPS: Group[] = [
  { key: 'payment_instructions', title: 'Payment instructions', sub: 'Shown to buyers when they tap “How to pay”. Buyers can read these, so never put passwords here.', fields: [
    { k: 'account_name', label: 'Account name' }, { k: 'bank_name', label: 'Bank' },
    { k: 'account_number', label: 'Account number' }, { k: 'ifsc', label: 'IFSC code' },
    { k: 'upi_id', label: 'UPI ID', hint: 'e.g. smallotz@hdfcbank' },
    { k: 'note', label: 'Note to buyers', area: true } ] },
  { key: 'company_profile', title: 'Company profile', sub: 'Your business details for support and invoices.', fields: [
    { k: 'name', label: 'Company name' }, { k: 'support_email', label: 'Support email' },
    { k: 'support_phone', label: 'Support phone' }, { k: 'gstin', label: 'GSTIN' },
    { k: 'address', label: 'Registered address', area: true } ] },
]
/** Single-value settings, grouped into one card. */
const DEFAULTS: { key: string; label: string; hint: string; min: number; max: number }[] = [
  { key: 'default_payment_window_minutes', label: 'Payment window (minutes)', hint: 'How long a buyer has to pay after reserving. 1440 = 24 hours.', min: 5, max: 10080 },
  { key: 'platform_fee_percent', label: 'Platform fee (%)', hint: 'Recorded for reference. Prices on batches are what buyers actually pay.', min: 0, max: 100 },
  { key: 'default_pool_max_extensions', label: 'Deadline extensions per batch', hint: 'How many times a batch deadline can be extended.', min: 0, max: 10 },
]
const CORE = new Set([...GROUPS.map(g => g.key), ...DEFAULTS.map(d => d.key)])

async function save(key: string, value: unknown) {
  const { error } = await supabase.rpc('admin_set_setting', { p_key: key, p_value: value })
  return error ? error.message : ''
}

function GroupCard({ g, row, can, onSaved }: { g: Group; row?: Row; can: boolean; onSaved: () => void }) {
  const [v, setV] = useState<Record<string, string>>({}); const [msg, setMsg] = useState(''); const [err, setErr] = useState(''); const [busy, setBusy] = useState(false)
  useEffect(() => { setV(Object.fromEntries(g.fields.map(f => [f.k, String((row?.value as Row | undefined)?.[f.k] ?? '')]))) }, [row, g])
  const dirty = g.fields.some(f => (v[f.k] ?? '') !== String((row?.value as Row | undefined)?.[f.k] ?? ''))
  const go = async () => {
    setBusy(true); setErr(''); setMsg('')
    const merged = { ...((row?.value as Row) ?? {}), ...Object.fromEntries(g.fields.map(f => [f.k, (v[f.k] ?? '').trim()])) }
    const e = await save(g.key, merged); setBusy(false)
    if (e) return setErr(e); setMsg('Saved'); onSaved()
  }
  return (
    <Card title={g.title} flush action={row?.updated_at && <span className="td-muted">Updated {fdate(row.updated_at)}</span>}>
      <div className="settings-body"><p className="form-hint" style={{ marginTop: 0, marginBottom: 14 }}>{g.sub}</p>
        <div className="settings-grid">{g.fields.map(f => <Field key={f.k} label={f.label} hint={f.hint}>
          {f.area ? <textarea className="form-input" rows={3} disabled={!can} value={v[f.k] ?? ''} onChange={e => { setV({ ...v, [f.k]: e.target.value }); setMsg('') }} />
            : <input className="form-input" disabled={!can} value={v[f.k] ?? ''} onChange={e => { setV({ ...v, [f.k]: e.target.value }); setMsg('') }} />}</Field>)}</div>
        <Err m={err} />
        {can && <div className="row"><button className="btn btn-primary btn-sm" disabled={busy || !dirty} onClick={go}>{busy ? 'Saving…' : 'Save'}</button>{msg && !dirty && <span className="saved-note">✓ {msg}</span>}</div>}
      </div>
    </Card>)
}

function DefaultsCard({ rows, can, onSaved }: { rows: Row[]; can: boolean; onSaved: () => void }) {
  const cur = (k: string) => { const r = rows.find(x => x.key === k); return r ? String(r.value) : '' }
  const [v, setV] = useState<Record<string, string>>({}); const [err, setErr] = useState(''); const [msg, setMsg] = useState(''); const [busy, setBusy] = useState(false)
  useEffect(() => { setV(Object.fromEntries(DEFAULTS.map(d => [d.key, cur(d.key)]))) /* eslint-disable-next-line */ }, [rows])
  const changed = DEFAULTS.filter(d => (v[d.key] ?? '') !== cur(d.key))
  const go = async () => {
    setErr(''); setMsg('')
    for (const d of changed) { const n = Number(v[d.key]); if (v[d.key] === '' || !Number.isFinite(n) || n < d.min || n > d.max) return setErr(`${d.label}: enter a number from ${d.min} to ${d.max}.`) }
    setBusy(true)
    for (const d of changed) { const e = await save(d.key, Number(v[d.key])); if (e) { setBusy(false); return setErr(e) } }
    setBusy(false); setMsg('Saved'); onSaved()
  }
  return (
    <Card title="Platform defaults" flush>
      <div className="settings-body">
        <div className="settings-grid">{DEFAULTS.map(d => <Field key={d.key} label={d.label} hint={d.hint}>
          <input className="form-input" type="number" disabled={!can} min={d.min} max={d.max} value={v[d.key] ?? ''} onChange={e => { setV({ ...v, [d.key]: e.target.value }); setMsg('') }} /></Field>)}</div>
        <Err m={err} />
        {can && <div className="row"><button className="btn btn-primary btn-sm" disabled={busy || !changed.length} onClick={go}>{busy ? 'Saving…' : 'Save'}</button>{msg && !changed.length && <span className="saved-note">✓ {msg}</span>}</div>}
      </div>
    </Card>)
}

export function Settings() {
  const { can } = useAuth(); const ok = can('settings')
  const q = useQuery(() => supabase.from('app_settings').select('*').order('key'), [])
  const rows = q.rows as Row[]
  const [edit, setEdit] = useState<{ key: string; val: string; isNew: boolean } | null>(null); const [err, setErr] = useState('')
  const extra = rows.filter(r => !CORE.has(r.key))
  const submit = async () => {
    if (!edit) return; setErr('')
    let parsed: unknown
    try { parsed = JSON.parse(edit.val) } catch { return setErr('Value must be valid JSON — a number like 30, text in quotes like "hello", or an object like {"a":1}.') }
    const e = await save(edit.key.trim(), parsed); if (e) return setErr(e)
    setEdit(null); q.reload()
  }
  return (<>
    <Err m={q.err} />
    {!ok && <div className="info-card" style={{ marginBottom: 16 }}><div className="info-card-body">You can view settings, but changing them needs the <b>settings</b> permission.</div></div>}
    {q.loading ? <Loading /> : <>
      {GROUPS.map(g => <GroupCard key={g.key} g={g} row={rows.find(r => r.key === g.key)} can={ok} onSaved={q.reload} />)}
      <DefaultsCard rows={rows} can={ok} onSaved={q.reload} />
      <Card title="Other settings" flush action={ok && <button className="btn btn-outline btn-sm" onClick={() => { setErr(''); setEdit({ key: '', val: '', isNew: true }) }}>+ Add setting</button>}>
        {!extra.length ? <div className="settings-body td-muted">No custom settings. Use “Add setting” for anything else you want to store (key + JSON value).</div> :
          <table><thead><tr><th>Key</th><th>Value</th><th>Updated</th><th></th></tr></thead><tbody>
            {extra.map(s => <tr key={s.key}><td className="mono">{s.key}</td><td className="mono" style={{ maxWidth: 360, wordBreak: 'break-all' }}>{JSON.stringify(s.value)}</td><td className="td-muted">{fdate(s.updated_at)}</td>
              <td>{ok && <button className="btn btn-outline btn-sm" onClick={() => { setErr(''); setEdit({ key: s.key, val: JSON.stringify(s.value, null, 2), isNew: false }) }}>Edit</button>}</td></tr>)}</tbody></table>}
      </Card></>}
    {edit && <Modal title={edit.isNew ? 'Add setting' : edit.key} sub="Value is stored as JSON" onClose={() => setEdit(null)}
      footer={<><button className="btn btn-outline" onClick={() => setEdit(null)}>Cancel</button><button className="btn btn-primary" onClick={submit}>Save</button></>}>
      {edit.isNew && <Field label="Key" hint="Lowercase letters, digits and underscores, e.g. holiday_notice"><input className="form-input mono" value={edit.key} onChange={e => setEdit({ ...edit, key: e.target.value })} /></Field>}
      <Field label="Value (JSON)"><textarea className="form-input mono" rows={7} value={edit.val} onChange={e => setEdit({ ...edit, val: e.target.value })} /></Field><Err m={err} /></Modal>}
  </>)
}
