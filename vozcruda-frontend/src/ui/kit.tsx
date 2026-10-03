import { useCallback, useEffect, useState, type KeyboardEvent as ReactKeyEvent, type ReactNode } from 'react'

export function useQuery<T = Record<string, unknown>>(
  fn: () => PromiseLike<{ data: unknown; error: { message: string } | null }>,
  deps: unknown[],
) {
  const [rows, setRows] = useState<T[]>([])
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(true)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const run = useCallback(() => {
    setLoading(true)
    fn().then(({ data, error }) => { setErr(error?.message ?? ''); setRows((data as T[]) ?? []); setLoading(false) })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)
  useEffect(() => { run() }, [run])
  return { rows, err, loading, reload: run }
}

export const Err = ({ m }: { m?: string }) => (m ? <div className="err">{m}</div> : null)

export function Chip({ c = 'gray', children }: { c?: 'green' | 'orange' | 'blue' | 'yellow' | 'gray' | 'red'; children: ReactNode }) {
  return <span className={'chip chip-' + c}>{children}</span>
}
const STATUS_COLOR: Record<string, 'green' | 'orange' | 'blue' | 'yellow' | 'gray' | 'red'> = {
  open: 'green', approved: 'green', paid: 'green', confirmed: 'green', completed: 'green', delivered: 'green', accepted: 'green', fulfilled: 'green',
  moq_reached: 'orange', po_placed: 'blue', in_production: 'blue', sent: 'blue', shipped: 'blue', ready: 'blue',
  pending: 'yellow', reserved: 'yellow', refund_pending: 'orange', refunded: 'gray', draft: 'gray', archived: 'gray',
  cancelled: 'red', rejected: 'red', expired: 'red', disputed: 'red',
}
export const Status = ({ s }: { s?: string }) => <Chip c={STATUS_COLOR[s ?? ''] ?? 'gray'}>{(s ?? '—').replace(/_/g, ' ')}</Chip>

export const Stat = ({ label, value, sub }: { label: string; value: ReactNode; sub?: ReactNode }) => (
  <div className="stat-card"><div className="stat-label">{label}</div><div className="stat-value">{value}</div>{sub && <div className="stat-sub">{sub}</div>}</div>
)
export const Stats = ({ children }: { children: ReactNode }) => <div className="stats-grid">{children}</div>

export function Progress({ done, total, big }: { done: number; total: number; big?: boolean }) {
  const pct = total > 0 ? Math.min(100, Math.round((done / total) * 100)) : 0
  const cls = pct >= 100 ? 'reached' : pct >= 80 ? 'near' : ''
  return big
    ? <div className="big-progress-track"><div className="big-progress-fill" style={{ width: pct + '%' }} /></div>
    : <div className="progress-bar-track"><div className={'progress-bar-fill ' + cls} style={{ width: pct + '%' }} /></div>
}
export const pct = (a: number, b: number) => (b > 0 ? Math.min(100, Math.round((a / b) * 100)) : 0)

export const Empty = ({ icon = '📭', title, desc }: { icon?: string; title: string; desc?: string }) => (
  <div className="empty-state"><div className="empty-icon">{icon}</div><div className="empty-title">{title}</div>{desc && <div className="empty-desc">{desc}</div>}</div>
)
export const Loading = () => <div className="empty-state"><div className="empty-desc">Loading…</div></div>

export function Modal({ title, sub, onClose, children, footer }: { title: string; sub?: string; onClose: () => void; children: ReactNode; footer?: ReactNode }) {
  useEffect(() => { const k = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }; window.addEventListener('keydown', k); return () => window.removeEventListener('keydown', k) }, [onClose])
  return (
    <div className="modal-overlay open" onClick={e => { if (e.target === e.currentTarget) onClose() }}>
      <div className="modal">
        <div className="modal-header"><div><div className="modal-title">{title}</div>{sub && <div className="modal-sub">{sub}</div>}</div>
          <button className="modal-close" onClick={onClose}>✕</button></div>
        <div className="modal-body">{children}</div>
        {footer && <div className="modal-footer">{footer}</div>}
      </div>
    </div>
  )
}
export const Section = ({ title, sub, action }: { title: string; sub?: string; action?: ReactNode }) => (
  <div className="section-header"><div><div className="section-title">{title}</div>{sub && <div className="section-sub">{sub}</div>}</div>{action}</div>
)
export const Card = ({ title, action, children, flush }: { title?: string; action?: ReactNode; children: ReactNode; flush?: boolean }) => (
  <div className="table-card" style={{ marginBottom: 20 }}>
    {title && <div className="table-header"><div className="table-title">{title}</div>{action}</div>}
    <div style={flush ? undefined : { padding: 0 }}>{children}</div>
  </div>
)
export const Field = ({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) => (
  <div className="form-group"><label className="form-label">{label}</label>{children}{hint && <div className="form-hint">{hint}</div>}</div>
)

/** Password box with a show/hide eye. */
export function PasswordInput({ value, onChange, placeholder, onKeyDown, autoFocus, autoComplete }: {
  value: string; onChange: (v: string) => void; placeholder?: string; onKeyDown?: (e: ReactKeyEvent<HTMLInputElement>) => void; autoFocus?: boolean; autoComplete?: string
}) {
  const [show, setShow] = useState(false)
  return (
    <div className="pw-wrap">
      <input className="form-input" type={show ? 'text' : 'password'} value={value} placeholder={placeholder} autoFocus={autoFocus} autoComplete={autoComplete}
        onChange={e => onChange(e.target.value)} onKeyDown={onKeyDown} />
      <button type="button" className="pw-eye" aria-label={show ? 'Hide password' : 'Show password'} aria-pressed={show} onClick={() => setShow(s => !s)}>
        {show
          ? <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M17.94 17.94A10.94 10.94 0 0 1 12 20C5 20 1 12 1 12a18.5 18.5 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19M14.12 14.12A3 3 0 1 1 9.88 9.88"/><line x1="1" y1="1" x2="23" y2="23"/></svg>
          : <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>}
      </button>
    </div>
  )
}
