import { useCallback, useEffect, useState } from 'react'
import { api } from '../api/client'
import type { DashboardSnapshot, Health } from '../api/types'

export interface SnapshotState {
  snapshot: DashboardSnapshot | null
  health: Health | null
  loading: boolean
  refreshing: boolean
  error: string | null
  refresh: () => Promise<void>
}

/** Loads the dashboard snapshot and backend health; `refresh` re-collects from Azure. */
export function useSnapshot(): SnapshotState {
  const [snapshot, setSnapshot] = useState<DashboardSnapshot | null>(null)
  const [health, setHealth] = useState<Health | null>(null)
  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    Promise.all([api.snapshot(), api.health()])
      .then(([snap, h]) => { if (!cancelled) { setSnapshot(snap); setHealth(h) } })
      .catch((e: Error) => { if (!cancelled) setError(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [])

  const refresh = useCallback(async () => {
    setRefreshing(true)
    setError(null)
    try {
      await api.refresh()
      const [snap, h] = await Promise.all([api.snapshot(), api.health()])
      setSnapshot(snap)
      setHealth(h)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setRefreshing(false)
    }
  }, [])

  return { snapshot, health, loading, refreshing, error, refresh }
}
