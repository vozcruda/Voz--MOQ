import { createContext, useContext } from 'react'

/** What a visitor was about to do when we asked them to sign in, so we can put them back there. */
export type Intent = { page: 'pool'; poolId: string; action?: 'join' }
const KEY = 'vc_intent'
export const saveIntent = (i: Intent) => { try { localStorage.setItem(KEY, JSON.stringify({ ...i, t: Date.now() })) } catch { /* ignore */ } }
export const takeIntent = (): Intent | null => {
  try {
    const raw = localStorage.getItem(KEY); if (!raw) return null; localStorage.removeItem(KEY)
    const v = JSON.parse(raw); if (!v?.poolId || Date.now() - (v.t ?? 0) > 60 * 60 * 1000) return null   // expires after 1 hour
    return { page: 'pool', poolId: String(v.poolId), action: v.action === 'join' ? 'join' : undefined }
  } catch { return null }
}

export const GuestCtx = createContext<{ guest: boolean; requireAuth: (i?: Intent) => void }>({ guest: false, requireAuth: () => {} })
export const useGuest = () => useContext(GuestCtx)
