import { useState, type ReactNode } from 'react'
import { supabase, rpc } from '../supabase'
import { useAuth } from '../auth'
import { Err, Field } from '../ui/kit'

const PENDING = 'vc_pending_signup'
const save = (v: object) => { try { localStorage.setItem(PENDING, JSON.stringify(v)) } catch { /* ignore */ } }
const load = (): { type?: string; business?: string; gstin?: string } => { try { return JSON.parse(localStorage.getItem(PENDING) ?? '{}') } catch { return {} } }

function Wrap({ quote, children, features }: { quote: ReactNode; children: ReactNode; features?: boolean }) {
  return (
    <div className="login-wrap">
      <div className="login-left"><div>
        <div className="brand-mark" style={{ marginBottom: 36 }}><div className="brand-icon">VC</div><div><div className="brand-name">Voz Cruda</div><div className="brand-tagline">MOQ Aggregation</div></div></div>
        <div className="login-quote">{quote}</div>
        {features && <div className="login-features">
          {[['🏭', 'Factory-Direct Pricing', "Access MOQ prices that solo buyers can't reach"], ['🤝', 'Group Aggregation', 'Your order pools with other buyers automatically'], ['📦', 'Real-Time Progress', 'Track exactly when your batch is ready to close']]
            .map(([i, t, d]) => <div className="login-feature" key={t}><div className="login-feature-icon">{i}</div><div><div className="login-feature-title">{t}</div><div className="login-feature-desc">{d}</div></div></div>)}</div>}
      </div><div style={{ color: 'rgba(255,255,255,0.25)', fontSize: 12 }}>© {new Date().getFullYear()} Voz Cruda LLP</div></div>
      <div className="login-right">{children}</div>
    </div>
  )
}

export function AuthScreen() {
  const [mode, setMode] = useState<'in' | 'up'>('in')
  const [f, setF] = useState({ email: '', pw: '', pw2: '', name: '', phone: '', business: '', gstin: '', type: 'buyer' })
  const [err, setErr] = useState(''); const [info, setInfo] = useState(''); const [busy, setBusy] = useState(false); const [needConfirm, setNeedConfirm] = useState(false)
  const up = (k: string, v: string) => setF({ ...f, [k]: v })
  const resend = async () => {
    setErr(''); const { error } = await supabase.auth.resend({ type: 'signup', email: f.email, options: { emailRedirectTo: window.location.origin } })
    if (error) setErr(error.message); else { setInfo('Confirmation email sent again. Open the newest one.'); setNeedConfirm(false) }
  }
  const submit = async () => {
    setErr(''); setInfo(''); setBusy(true)
    if (mode === 'in') {
      const { error } = await supabase.auth.signInWithPassword({ email: f.email, password: f.pw })
      if (error) { setErr(error.message); setNeedConfirm(/confirm/i.test(error.message)) }
    } else {
      if (f.pw.length < 8) { setBusy(false); return setErr('Password must be at least 8 characters.') }
      if (f.pw !== f.pw2) { setBusy(false); return setErr('Passwords do not match.') }
      save({ type: f.type, business: f.business, gstin: f.gstin })
      const { data, error } = await supabase.auth.signUp({ email: f.email, password: f.pw, options: { data: { full_name: f.name }, emailRedirectTo: window.location.origin } })
      if (error) setErr(error.message)
      else if (!data.session) setInfo('Account created. Check your email to confirm, then sign in.')
      if (data.session && f.phone) await supabase.from('profiles').update({ phone: f.phone }).eq('id', data.session.user.id)
    }
    setBusy(false)
  }
  return (
    <Wrap features={mode === 'in'} quote={mode === 'in' ? <>"Small orders,<br />collective power."</> : <>"Join the collective.<br />Buy better."</>}>
      <div className="login-card" style={{ width: mode === 'up' ? 460 : 420 }}>
        <div className="login-title">{mode === 'in' ? 'Welcome back' : 'Create account'}</div>
        <div className="login-sub">{mode === 'in' ? 'Sign in to your Voz Cruda account' : 'Start buying factory-direct today'}</div>
        {mode === 'up' && <>
          <div className="form-row"><Field label="Full name"><input className="form-input" value={f.name} onChange={e => up('name', e.target.value)} placeholder="Priya Sharma" /></Field>
            <Field label="Phone"><input className="form-input" value={f.phone} onChange={e => up('phone', e.target.value)} placeholder="+91 98765 43210" /></Field></div>
          <Field label="I am a"><select className="form-input" value={f.type} onChange={e => up('type', e.target.value)}><option value="buyer">Buyer (I want to buy)</option><option value="manufacturer">Supplier (I manufacture)</option></select></Field>
          <Field label="Business name"><input className="form-input" value={f.business} onChange={e => up('business', e.target.value)} placeholder="Sharma Boutique" /></Field></>}
        <Field label="Email address"><input className="form-input" type="email" value={f.email} onChange={e => up('email', e.target.value)} placeholder="you@business.com" /></Field>
        <div className={mode === 'up' ? 'form-row' : ''}>
          <Field label="Password"><input className="form-input" type="password" value={f.pw} onChange={e => up('pw', e.target.value)} placeholder="Min. 8 characters" onKeyDown={e => e.key === 'Enter' && mode === 'in' && submit()} /></Field>
          {mode === 'up' && <Field label="Confirm password"><input className="form-input" type="password" value={f.pw2} onChange={e => up('pw2', e.target.value)} /></Field>}</div>
        {mode === 'up' && <Field label="GST Number (optional)"><input className="form-input" value={f.gstin} onChange={e => up('gstin', e.target.value.toUpperCase())} placeholder="22AAAAA0000A1Z5" /></Field>}
        <Err m={err} />{info && <div className="ok">{info}</div>}
        {needConfirm && mode === 'in' && <button className="link" onClick={resend}>Resend confirmation email</button>}
        <button className="btn btn-primary" style={{ width: '100%', justifyContent: 'center', padding: 11, margin: '8px 0 16px' }} disabled={busy} onClick={submit}>{busy ? 'Please wait…' : mode === 'in' ? 'Sign in' : 'Create account'}</button>
        <div style={{ textAlign: 'center', fontSize: 13, color: 'var(--muted)' }}>
          {mode === 'in' ? <>No account? <button className="link" onClick={() => setMode('up')}>Create one →</button></> : <>Already have an account? <button className="link" onClick={() => setMode('in')}>Sign in →</button></>}</div>
      </div>
    </Wrap>
  )
}

export function Onboarding() {
  const { refresh, signOut, email } = useAuth(); const p = load()
  const [type, setType] = useState(p.type ?? 'buyer'); const [name, setName] = useState(p.business ?? ''); const [gstin, setGstin] = useState(p.gstin ?? '')
  const [err, setErr] = useState(''); const [busy, setBusy] = useState(false); const [ok, setOk] = useState(false)
  const go = async () => {
    setErr(''); setBusy(true)
    const need = ['terms', 'privacy', ...(type === 'manufacturer' ? ['manufacturer_terms'] : [])]
    for (const t of need) { const ce = await rpc('record_consent', { p_type: t, p_version: '2026-09', p_accepted: true }); if (ce) { setBusy(false); return setErr(ce) } }
    const e = await rpc('create_organization', { p_type: type, p_legal_name: name, p_gstin: gstin || null })
    setBusy(false); if (e) return setErr(e)
    try { localStorage.removeItem(PENDING) } catch { /* ignore */ }
    await refresh()
  }
  return (
    <Wrap quote={<>"One last step."</>}>
      <div className="login-card">
        <div className="login-title">Set up your business</div><div className="login-sub">Signed in as {email}. Your email must be confirmed to continue.</div>
        <Field label="Account type"><select className="form-input" value={type} onChange={e => setType(e.target.value)}><option value="buyer">Buyer</option><option value="manufacturer">Supplier</option></select></Field>
        <Field label="Legal business name"><input className="form-input" value={name} onChange={e => setName(e.target.value)} /></Field>
        <Field label="GSTIN (optional)" hint="15 characters, e.g. 22AAAAA0000A1Z5"><input className="form-input" value={gstin} onChange={e => setGstin(e.target.value.toUpperCase())} /></Field>
        <label className="row" style={{ fontSize: 13, margin: '4px 0 10px', alignItems: 'flex-start' }}><input type="checkbox" checked={ok} onChange={e => setOk(e.target.checked)} /><span>I accept the Terms of Service and Privacy Policy{type === 'manufacturer' ? ' and the Manufacturer Terms' : ''}.</span></label>
        <Err m={err} />
        <button className="btn btn-primary" style={{ width: '100%', justifyContent: 'center', padding: 11 }} disabled={busy || !name.trim() || !ok} onClick={go}>Continue</button>
        <div style={{ textAlign: 'center', marginTop: 16 }}><button className="link" onClick={signOut}>Sign out</button></div>
      </div>
    </Wrap>
  )
}
