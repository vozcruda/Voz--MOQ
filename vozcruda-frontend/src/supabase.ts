import { createClient } from '@supabase/supabase-js'
export const supabase = createClient(import.meta.env.VITE_SUPABASE_URL, import.meta.env.VITE_SUPABASE_ANON_KEY)
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type Row = Record<string, any>
export const inr = (paise?: number | string | null) =>
  paise == null ? '—' : '₹' + (Number(paise) / 100).toLocaleString('en-IN', { maximumFractionDigits: 0 })
export const fdate = (s?: string | null) => (s ? new Date(s).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' }) : '—')
export const daysLeft = (iso?: string | null) => (iso ? Math.max(0, Math.ceil((new Date(iso).getTime() - Date.now()) / 864e5)) : 0)
/** Call an RPC; returns an error message or null. */
export async function rpc(name: string, args: Row = {}): Promise<string | null> {
  const { error } = await supabase.rpc(name, args)
  return error ? error.message : null
}
