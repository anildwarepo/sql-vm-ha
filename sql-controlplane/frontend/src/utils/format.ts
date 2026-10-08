export const lc = (v: unknown): string => String(v ?? '').toLowerCase()

export const SEVERITIES = ['critical', 'high', 'medium', 'low', 'info'] as const

export const sevRank = (s: unknown): number => {
  const i = (SEVERITIES as readonly string[]).indexOf(lc(s))
  return i < 0 ? 9 : i
}

export const toDate = (v: unknown): Date | null => {
  if (!v) return null
  const d = new Date(String(v))
  return Number.isNaN(d.getTime()) ? null : d
}

export const fmt = (v: unknown): string => {
  const d = toDate(v)
  return d ? d.toLocaleString(undefined, { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—'
}

export const hm = (v: unknown): string => {
  const d = toDate(v)
  return d ? d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' }) : ''
}

/** "in 3h 20m" / "5m ago" */
export const rel = (v: unknown, now = Date.now()): string => {
  const d = toDate(v)
  if (!d) return ''
  let s = (d.getTime() - now) / 1000
  const past = s < 0
  s = Math.abs(s)
  const days = Math.floor(s / 86400), hours = Math.floor((s % 86400) / 3600), mins = Math.floor((s % 3600) / 60)
  const t = days ? `${days}d ${hours}h` : hours ? `${hours}h ${mins}m` : `${mins}m`
  return past ? `${t} ago` : `in ${t}`
}

/** Map a status/severity string to a pill tone. */
export const tone = (v: unknown): string => {
  const s = lc(v)
  if (['critical', 'failed', 'cancelled', 'disconnected', 'expired', 'unhealthy', 'bad', 'not_synchronizing'].includes(s)) return 'bad'
  if (['high'].includes(s)) return 'high'
  if (['medium', 'warning', 'warn', 'inprogress', 'in progress', 'notstarted'].includes(s)) return 'warn'
  if (['low'].includes(s)) return 'low'
  if (['healthy', 'ok', 'succeeded', 'completed', 'connected', 'synchronized', 'online', 'protected'].includes(s)) return 'ok'
  return 'info'
}
