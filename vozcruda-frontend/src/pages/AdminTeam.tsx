import { useState } from 'react'
import { supabase, fdate, rpc, type Row } from '../supabase'
import { useAuth, ALL_PERMS, type Perm } from '../auth'
import { useQuery, Err, Chip, Card, Empty, Loading, Modal, Field } from '../ui/kit'

export const PERM_LABEL: Record<Perm, { name: string; desc: string }> = {
  catalogue: { name: 'Products', desc: 'Approve or reject supplier products' },
  quotes: { name: 'Quotes', desc: 'Publish supplier offers to buyers' },
  pools: { name: 'Batches', desc: 'Create, open, extend, cancel batches; place purchase orders' },
  payments: { name: 'Payments', desc: 'Mark reservations paid, cancel reservations' },
  orders: { name: 'Orders & POs', desc: 'Move orders and purchase orders through their stages' },
  disputes: { name: 'Disputes', desc: 'Resolve disputes and refunds' },
  suppliers: { name: 'Suppliers', desc: 'Verify, reject, suspend suppliers; set slugs' },
  users: { name: 'Users', desc: 'Create accounts; suspend businesses' },
  settings: { name: 'Settings', desc: 'Edit platform settings' },
}

async function fnError(error: unknown): Promise<string> {
  try { const j = await (error as { context: Response }).context.json(); return j.error ?? (error as Error).message } catch { return (error as Error).message }
}

function PermBoxes({ value, onChange, held, all }: { value: string[]; onChange: (v: string[]) => void; held: string[]; all: boolean }) {
  return <div className="stack" style={{ marginTop: 4 }}>{ALL_PERMS.map(p => {
    const allowed = all || held.includes(p)
    return <label key={p} className="row" style={{ alignItems: 'flex-start', opacity: allowed ? 1 : 0.45, fontSize: 13.5 }}>
      <input type="checkbox" disabled={!allowed} checked={value.includes(p)} onChange={e => onChange(e.target.checked ? [...value, p] : value.filter(x => x !== p))} />
      <span><b>{PERM_LABEL[p].name}</b><div className="form-hint" style={{ marginTop: 0 }}>{PERM_LABEL[p].desc}{!allowed && ' — you don’t hold this permission'}</div></span></label>
  })}</div>
}

/** Create a buyer / supplier / admin account on someone's behalf (uses the admin-create-user edge function). */
export function CreateAccount({ onClose, onDone, presetAdmin }: { onClose: () => void; onDone: () => void; presetAdmin?: boolean }) {
  const { can, canGrant, isSuper, access } = useAuth()
  const [f, setF] = useState({ type: presetAdmin ? 'admin' : 'buyer', full_name: '', phone: '', email: '', password: '', legal_name: '', trade_name: '', gstin: '', pan: '', approve: false, can_grant: false })
  const [perms, setPerms] = useState<string[]>([])
  const [err, setErr] = useState(''); const [busy, setBusy] = useState(false); const [done, setDone] = useState('')
  const up = (k: string, v: string | boolean) => setF({ ...f, [k]: v })
  const isAdmin = f.type === 'admin'
  const save = async () => {
    setErr(''); setBusy(true)
    const { data, error } = await supabase.functions.invoke('admin-create-user', { body: { account_type: f.type, email: f.email, password: f.password || undefined, full_name: f.full_name,
      phone: f.phone, legal_name: f.legal_name, trade_name: f.trade_name, gstin: f.gstin.toUpperCase(), pan: f.pan.toUpperCase(), approve: f.approve, permissions: perms, can_grant: f.can_grant, redirect_to: window.location.origin } })
    setBusy(false)
    if (error) return setErr(await fnError(error))
    setDone((data as Row).invited ? `Invitation email sent to ${f.email}. They set their own password.` : (data as Row).created ? `Account created for ${f.email}.` : `${f.email} already had an account; access was updated.`)
  }
  if (done) return <Modal title="Done" onClose={onDone} footer={<button className="btn btn-primary" onClick={onDone}>Close</button>}><div className="ok">{done}</div></Modal>
  return (
    <Modal title={isAdmin ? 'Add Admin' : 'Create Account'} sub="Creates the login and attaches the business / admin access" onClose={onClose}
      footer={<><button className="btn btn-outline" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy || !f.email || (!isAdmin && !f.legal_name)} onClick={save}>{busy ? 'Creating…' : isAdmin ? 'Add admin' : 'Create account'}</button></>}>
      {!presetAdmin && <Field label="Account type"><select className="form-input" value={f.type} onChange={e => up('type', e.target.value)}>
        {can('users') && <><option value="buyer">Buyer</option><option value="manufacturer">Supplier</option></>}{canGrant && <option value="admin">Admin</option>}</select></Field>}
      <div className="form-row"><Field label="Full name"><input className="form-input" value={f.full_name} onChange={e => up('full_name', e.target.value)} /></Field>
        <Field label="Phone"><input className="form-input" value={f.phone} onChange={e => up('phone', e.target.value)} /></Field></div>
      <Field label="Email"><input className="form-input" type="email" value={f.email} onChange={e => up('email', e.target.value)} /></Field>
      <Field label="Temporary password (optional)" hint="Leave blank to email an invitation so they choose their own password. If you set one, the email is marked confirmed."><input className="form-input" type="text" autoComplete="off" value={f.password} onChange={e => up('password', e.target.value)} placeholder="min. 8 characters" /></Field>
      {!isAdmin && <>
        <Field label="Legal business name"><input className="form-input" value={f.legal_name} onChange={e => up('legal_name', e.target.value)} /></Field>
        <div className="form-row"><Field label="Trade name (optional)"><input className="form-input" value={f.trade_name} onChange={e => up('trade_name', e.target.value)} /></Field>
          <Field label="GSTIN (optional)"><input className="form-input" value={f.gstin} onChange={e => up('gstin', e.target.value)} /></Field></div>
        {can('suppliers') && <label className="row" style={{ fontSize: 13 }}><input type="checkbox" checked={f.approve} onChange={e => up('approve', e.target.checked)} /> Mark business as verified now</label>}
        <p className="form-hint">The account holder has not accepted the Terms yet; that is recorded only when they do it themselves.</p></>}
      {isAdmin && <>
        <label className="form-label" style={{ marginTop: 6 }}>Permissions</label>
        <PermBoxes value={perms} onChange={setPerms} held={access?.permissions ?? []} all={isSuper} />
        {isSuper && <label className="row" style={{ fontSize: 13.5, marginTop: 14 }}><input type="checkbox" checked={f.can_grant} onChange={e => up('can_grant', e.target.checked)} /> <span><b>Can grant permissions to other admins</b> <span className="form-hint">(only super admins can give this)</span></span></label>}</>}
      <Err m={err} />
    </Modal>
  )
}

export function AdminTeam() {
  const { isSuper, access, session } = useAuth()
  const q = useQuery(() => supabase.rpc('admin_list_admins'), [])
  const [edit, setEdit] = useState<Row | null>(null); const [add, setAdd] = useState(false)
  const rows = q.rows as Row[]
  return (<>
    <div className="filter-bar"><div className="td-muted" style={{ flex: 1 }}>
      {isSuper ? 'You are a super admin: you control who can grant permissions.' : 'You can grant the permissions you hold to other admins.'}</div>
      <button className="btn btn-primary btn-sm" onClick={() => setAdd(true)}>+ Add Admin</button></div>
    <Err m={q.err} />
    <Card title="Admin team" flush>{q.loading ? <Loading /> : !rows.length ? <Empty title="No admins" /> : <table><thead><tr><th>Admin</th><th>Role</th><th>Permissions</th><th>Since</th><th></th></tr></thead><tbody>
      {rows.map(a => {
        const me = a.profile_id === session?.user.id
        const locked = !isSuper && (me || a.is_super || a.can_grant)
        return <tr key={a.profile_id}><td><div className="td-strong">{a.full_name || a.email}{me && ' (you)'}</div><div className="td-muted">{a.email}</div></td>
          <td>{a.is_super ? <Chip c="orange">Super admin</Chip> : a.can_grant ? <Chip c="blue">Admin · can grant</Chip> : <Chip>Admin</Chip>}</td>
          <td style={{ maxWidth: 320 }}>{a.is_super ? <span className="td-muted">Full access</span> : a.permissions?.length ? <div className="row">{(a.permissions as Perm[]).map(p => <Chip key={p} c="gray">{PERM_LABEL[p]?.name ?? p}</Chip>)}</div> : <span className="td-muted">View only</span>}</td>
          <td className="td-muted">{fdate(a.created_at)}</td>
          <td>{!locked && <button className="btn btn-outline btn-sm" onClick={() => setEdit(a)}>Manage</button>}</td></tr>
      })}</tbody></table>}</Card>
    <Card title="Permission guide" flush><table><tbody>{ALL_PERMS.map(p => <tr key={p}><td className="td-strong" style={{ width: 160 }}>{PERM_LABEL[p].name}</td><td className="td-muted">{PERM_LABEL[p].desc}</td>
      <td>{!isSuper && !access?.permissions.includes(p) && <Chip c="red">you don’t hold</Chip>}</td></tr>)}</tbody></table>
      <div className="form-hint" style={{ padding: '10px 20px' }}>Every admin can view all data; permissions control who can change things.</div></Card>
    {edit && <Manage a={edit} onClose={() => setEdit(null)} onDone={() => { setEdit(null); q.reload() }} />}
    {add && <CreateAccount presetAdmin onClose={() => setAdd(false)} onDone={() => { setAdd(false); q.reload() }} />}
  </>)
}

function Manage({ a, onClose, onDone }: { a: Row; onClose: () => void; onDone: () => void }) {
  const { isSuper, access } = useAuth()
  const [perms, setPerms] = useState<string[]>(a.permissions ?? []); const [grant, setGrant] = useState<boolean>(a.can_grant); const [sup, setSup] = useState<boolean>(a.is_super)
  const [err, setErr] = useState(''); const [busy, setBusy] = useState(false)
  const save = async () => {
    setErr(''); setBusy(true)
    const steps: [string, Row][] = []
    if (JSON.stringify([...perms].sort()) !== JSON.stringify([...(a.permissions ?? [])].sort())) steps.push(['admin_set_permissions', { p_profile: a.profile_id, p_permissions: perms }])
    if (isSuper && grant !== a.can_grant && !sup) steps.push(['admin_set_grant_right', { p_profile: a.profile_id, p_can_grant: grant }])
    if (isSuper && sup !== a.is_super) steps.push(['admin_set_super', { p_profile: a.profile_id, p_super: sup }])
    for (const [fn, args] of steps) { const e = await rpc(fn, args); if (e) { setBusy(false); return setErr(e) } }
    setBusy(false); onDone()
  }
  const remove = async () => { if (!confirm(`Remove ${a.email} as an admin?`)) return; const e = await rpc('admin_remove_admin', { p_profile: a.profile_id }); if (e) setErr(e); else onDone() }
  return (
    <Modal title={a.full_name || a.email} sub={a.email} onClose={onClose}
      footer={<>{isSuper && <button className="btn btn-ghost" style={{ color: 'var(--danger)', marginRight: 'auto' }} onClick={remove}>Remove admin</button>}<button className="btn btn-outline" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy} onClick={save}>Save</button></>}>
      {isSuper && <div className="res-summary"><div className="form-label">Super-admin controls</div>
        <label className="row" style={{ fontSize: 13.5, marginBottom: 8 }}><input type="checkbox" checked={sup} onChange={e => setSup(e.target.checked)} /> <span><b>Super admin</b> — full access, including this page</span></label>
        <label className="row" style={{ fontSize: 13.5, opacity: sup ? 0.5 : 1 }}><input type="checkbox" disabled={sup} checked={grant || sup} onChange={e => setGrant(e.target.checked)} /> <span><b>Can grant permissions to other admins</b></span></label></div>}
      {!sup && <><label className="form-label">Permissions</label><PermBoxes value={perms} onChange={setPerms} held={access?.permissions ?? []} all={isSuper} /></>}
      {!isSuper && <p className="form-hint">You can only change permissions you hold yourself. Others stay as they are.</p>}
      <Err m={err} />
    </Modal>
  )
}
