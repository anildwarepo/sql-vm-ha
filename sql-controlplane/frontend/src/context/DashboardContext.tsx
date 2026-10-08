import { createContext, useContext } from 'react'
import type { DashboardSnapshot, Finding, Health } from '../api/types'

export interface DashboardContextValue {
  snapshot: DashboardSnapshot
  health: Health | null
  query: string
  openNode: (machine: string) => void
  openFinding: (finding: Finding) => void
  goTab: (tab: string) => void
  refresh: () => Promise<void>
}

export const DashboardContext = createContext<DashboardContextValue | null>(null)

export function useDashboard(): DashboardContextValue {
  const ctx = useContext(DashboardContext)
  if (!ctx) throw new Error('useDashboard must be used inside <DashboardContext.Provider>')
  return ctx
}
