import { createContext, useContext, useEffect, useState, useCallback, type ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase, type Row } from './supabase'

export type Role = 'admin' | 'buyer' | 'supplier' | 'none'
export const ALL_PERMS = ['catalogue', 'quotes', 'pools', 'payments', 'orders', 'disputes', 'suppliers', 'users', 'settings'] as const
export type Perm = (typeof ALL_PERMS)[number]
interface Access { is_super: boolean; can_grant: boolean; permissions: string[] }
interface Ctx {
  session: Session | null; ready: boolean; role: Role; org: Row | null; name: string; email: string
  access: Access | null; isSuper: boolean; canGrant: boolean; can: (p: Perm) => boolean
  refresh: () => Promise<void>; signOut: () => Promise<void>
}
const C = createContext<Ctx>(null as unknown as Ctx)
export const useAuth = () => useContext(C)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [ready, setReady] = useState(false)
  const [role, setRole] = useState<Role>('none')
  const [org, setOrg] = useState<Row | null>(null)
  const [name, setName] = useState('')
  const [access, setAccess] = useState<Access | null>(null)

  const load = useCallback(async (s: Session | null) => {
    if (!s) { setRole('none'); setOrg(null); setName(''); setAccess(null); setReady(true); return }
    const [{ data: adm }, { data: mem }, { data: prof }] = await Promise.all([
      supabase.rpc('my_admin_access'),
      supabase.from('organization_members').select('member_role, organizations(*)').eq('profile_id', s.user.id),
      supabase.from('profiles').select('full_name').eq('id', s.user.id).maybeSingle(),
    ])
    const orgs = ((mem as Row[]) ?? []).map(m => m.organizations).filter(Boolean) as Row[]
    const first = orgs[0] ?? null
    setOrg(first)
    setName((prof as Row | null)?.full_name || s.user.email || '')
    const acc = (adm as Access | null) ?? null
    setAccess(acc)
    setRole(acc ? 'admin' : first ? (first.type === 'manufacturer' ? 'supplier' : 'buyer') : 'none')
    setReady(true)
  }, [])

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => { setSession(data.session); load(data.session) })
    const { data } = supabase.auth.onAuthStateChange((_e, s) => { setSession(s); load(s) })
    return () => data.subscription.unsubscribe()
  }, [load])

  const value: Ctx = {
    session, ready, role, org, name, email: session?.user.email ?? '',
    access, isSuper: !!access?.is_super, canGrant: !!access?.can_grant, can: p => !!access && (access.is_super || access.permissions.includes(p)),
    refresh: () => load(session), signOut: async () => { await supabase.auth.signOut() },
  }
  return <C.Provider value={value}>{children}</C.Provider>
}
