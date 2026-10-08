import { useEffect, useState } from 'react'

/** Re-render periodically so relative times ("in 12m") stay current. */
export function useNow(intervalMs = 30000): number {
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    const t = window.setInterval(() => setNow(Date.now()), intervalMs)
    return () => window.clearInterval(t)
  }, [intervalMs])
  return now
}
