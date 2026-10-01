import { useEffect, useState } from 'react'
import { AuthProvider, useAuth, type Role } from './auth'
import { AuthScreen, Onboarding } from './pages/AuthScreens'
import { PoolsBrowse, PoolDetail } from './pages/Pools'
import { AdminDashboard, Reservations, PurchaseOrders, Suppliers, Users } from './pages/Admin'
import { BuyerDashboard, MyOrders, Payments } from './pages/Buyer'
import { SupplierDashboard } from './pages/Supplier'
import { Catalogue } from './pages/Catalogue'
import { CreateBatch, Orders } from './pages/AdminExtra'
import { Disputes, BuyerDisputes } from './pages/Disputes'
import { Settings } from './pages/Settings'
import { ActivityLog } from './pages/ActivityLog'
import { AdminTeam } from './pages/AdminTeam'
import { Notifications } from './pages/Notifications'
import { supabase } from './supabase'
import { useQuery, Modal } from './ui/kit'

type Item = { id: string; icon: string; label: string }
const NAV: Record<Exclude<Role, 'none'>, { home: string; label: string; groups: [string, Item[]][] }> = {
  admin: { home: 'dashboard', label: 'Admin', groups: [
    ['Overview', [{ id: 'dashboard', icon: '⬛', label: 'Dashboard' }, { id: 'notifications', icon: '🔔', label: 'Notifications' }]],
    ['Catalog', [{ id: 'products', icon: '📦', label: 'Products' }, { id: 'batches', icon: '📊', label: 'Batches' }]],
    ['Operations', [{ id: 'reservations', icon: '📋', label: 'Reservations' }, { id: 'purchase-orders', icon: '🧾', label: 'Purchase Orders' }, { id: 'orders', icon: '🚚', label: 'Orders' }, { id: 'disputes', icon: '⚖️', label: 'Disputes' }]],
    ['Admin', [{ id: 'suppliers', icon: '🏭', label: 'Suppliers' }, { id: 'users', icon: '👤', label: 'Users' }, { id: 'settings', icon: '⚙️', label: 'Settings' }, { id: 'activity', icon: '🗂️', label: 'Activity Log' }]]] },
  buyer: { home: 'dashboard', label: 'Buyer', groups: [
    ['Overview', [{ id: 'dashboard', icon: '⬛', label: 'Dashboard' }, { id: 'notifications', icon: '🔔', label: 'Notifications' }]],
    ['Marketplace', [{ id: 'browse', icon: '🛍️', label: 'Browse Batches' }, { id: 'catalogue', icon: '👕', label: 'Product Catalogue' }]],
    ['My Account', [{ id: 'orders', icon: '📋', label: 'My Orders' }, { id: 'payments', icon: '💳', label: 'Payments' }, { id: 'disputes', icon: '⚖️', label: 'Disputes' }]]] },
  supplier: { home: 'dashboard', label: 'Supplier', groups: [
    ['Overview', [{ id: 'dashboard', icon: '⬛', label: 'Dashboard' }, { id: 'notifications', icon: '🔔', label: 'Notifications' }]],
    ['Products', [{ id: 'products', icon: '📦', label: 'My Products' }, { id: 'purchase-orders', icon: '🏭', label: 'Production Queue' }]]] },
}
const TITLES: Record<string, string> = { dashboard: 'Dashboard', products: 'Products', batches: 'Aggregation Batches', browse: 'Browse Batches', catalogue: 'Product Catalogue', reservations: 'Reservations',
  'purchase-orders': 'Purchase Orders', suppliers: 'Suppliers', users: 'Users', disputes: 'Disputes', settings: 'Settings', activity: 'Activity Log', team: 'Admin Team', notifications: 'Notifications', orders: 'Orders', payments: 'Payments', pool: 'Batch Detail' }

function Shell() {
  const { role, name, email, signOut, can, canGrant, isSuper } = useAuth()
  const r = role as Exclude<Role, 'none'>; const nav = NAV[r]
  const [page, setPage] = useState('dashboard'); const [pool, setPool] = useState<string | null>(null); const [back, setBack] = useState('dashboard')
  const unread = useQuery(() => supabase.from('notifications').select('id').is('read_at', null), [page])
  const go = (p: string) => { setPool(null); setPage(p); setMenu(false) }
  const openPool = (id: string) => { setBack(page); setPool(id); setPage('pool'); setMenu(false) }
  const groups = nav.groups.map(([g, items]) => [g, g === 'Admin' && canGrant ? [...items, { id: 'team', icon: '🛡️', label: 'Admin Team' }] : items] as [string, Item[]])
  const initials = (name || email).split(/[\s@]/).filter(Boolean).slice(0, 2).map(s => s[0]?.toUpperCase()).join('')
  const admin = r === 'admin'
  const [creating, setCreating] = useState(false)
  const [menu, setMenu] = useState(false)
  const [confirmOut, setConfirmOut] = useState(false); const [outBusy, setOutBusy] = useState(false)
  useEffect(() => { const k = (e: KeyboardEvent) => { if (e.key === 'Escape') setMenu(false) }; window.addEventListener('keydown', k); return () => window.removeEventListener('keydown', k) }, [])

  let view = null
  if (page === 'pool' && pool) view = <PoolDetail id={pool} onBack={() => go(back)} goPage={go} />
  else if (page === 'dashboard') view = admin ? <AdminDashboard open={openPool} go={go} /> : r === 'buyer' ? <BuyerDashboard go={go} open={openPool} /> : <SupplierDashboard go={go} />
  else if (page === 'notifications') view = <Notifications />
  else if (page === 'products') view = <Catalogue mode={admin ? 'admin' : 'supplier'} />
  else if (page === 'catalogue') view = <Catalogue mode="buyer" />
  else if (page === 'batches' || page === 'browse') view = <PoolsBrowse admin={admin} onOpen={openPool} />
  else if (page === 'reservations') view = <Reservations />
  else if (page === 'purchase-orders') view = <PurchaseOrders role={admin ? 'admin' : 'supplier'} />
  else if (page === 'suppliers') view = <Suppliers />
  else if (page === 'users') view = <Users />
  else if (page === 'orders') view = admin ? <Orders /> : <MyOrders open={openPool} />
  else if (page === 'disputes') view = admin ? <Disputes /> : <BuyerDisputes />
  else if (page === 'activity') view = <ActivityLog />
  else if (page === 'settings') view = <Settings />
  else if (page === 'team') view = <AdminTeam />
  else if (page === 'payments') view = <Payments />

  return (
    <div className="app">
      <div className={'sidebar-backdrop' + (menu ? ' open' : '')} onClick={() => setMenu(false)} />
      <div className={'sidebar' + (menu ? ' open' : '')}>
        <button className="sidebar-close" aria-label="Close menu" onClick={() => setMenu(false)}>✕</button>
        <div className="sidebar-brand"><img className="brand-logo" src="/brand/logo-lockup-dark.png" alt="MoqLess — Voz Cruda's MOQ Aggregation App" width="640" height="411" /></div>
        <div className="sidebar-role"><span className="role-dot" /><span>{admin ? (isSuper ? 'Super Admin' : 'Admin') : nav.label}</span></div>
        <nav className="sidebar-nav">
          {groups.map(([g, items]) => <div key={g}><div className="nav-section-label">{g}</div>
            {items.map(i => <button key={i.id} className={'nav-item' + (page === i.id || (page === 'pool' && back === i.id) ? ' active' : '')} onClick={() => go(i.id)}>
              <span className="nav-icon">{i.icon}</span> {i.label}{i.id === 'notifications' && unread.rows.length > 0 && <span className="nav-badge">{unread.rows.length}</span>}</button>)}</div>)}
        </nav>
        <div className="sidebar-user"><div className="user-avatar">{initials || 'VC'}</div>
          <div className="user-info"><div className="user-name">{name}</div><div className="user-email">{email}</div></div>
        </div>
        <div className="sidebar-logout"><button className="logout-btn" onClick={() => setConfirmOut(true)}><span aria-hidden>⎋</span> Log out</button></div>
      </div>
      <div className="main">
        <div className="topbar"><button className="menu-btn" aria-label="Open menu" onClick={() => setMenu(true)}>☰</button><div className="topbar-title">{TITLES[page] ?? page}</div>
          {admin && can('pools') && <div className="topbar-actions"><button className="btn btn-primary btn-sm" onClick={() => setCreating(true)}>+ Create Batch</button></div>}</div>
        <div className="page-content"><div className="page-inner">{view}</div></div>
      </div>
      {confirmOut && <Modal title="Log out?" sub={email} onClose={() => setConfirmOut(false)} footer={<><button className="btn btn-outline" onClick={() => setConfirmOut(false)}>Stay signed in</button><button className="btn btn-primary" disabled={outBusy} onClick={async () => { setOutBusy(true); await signOut() }}>{outBusy ? 'Logging out…' : 'Log out'}</button></>}>You’ll need to sign in again to use MoqLess on this device.</Modal>}
      {creating && <CreateBatch onClose={() => setCreating(false)} onDone={id => { setCreating(false); openPool(id) }} />}
    </div>
  )
}

function Gate() {
  const { ready, session, role } = useAuth()
  if (!ready) return <div className="root-loading">Loading…</div>
  if (!session) return <AuthScreen />
  if (role === 'none') return <Onboarding />
  return <Shell key={role} />
}
export default function App() { return <AuthProvider><Gate /></AuthProvider> }
