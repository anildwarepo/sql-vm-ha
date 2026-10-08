import type { DashboardSnapshot, Health } from '../../api/types'
import { useNow } from '../../hooks/useNow'
import { fmt, rel } from '../../utils/format'
import { Pill } from '../common/Pill'

interface HeaderProps {
  snapshot: DashboardSnapshot | null
  health: Health | null
  query: string
  onQuery: (q: string) => void
  refreshing: boolean
  onRefresh: () => void
  chatOpen: boolean
  onToggleChat: () => void
  theme: 'light' | 'dark'
  onToggleTheme: () => void
}

const OVERALL: Record<string, [string, string]> = {
  critical: ['Action required', 'bad'],
  warning: ['Attention', 'warn'],
  healthy: ['Healthy', 'ok'],
}

export function Header({ snapshot, health, query, onQuery, refreshing, onRefresh, chatOpen, onToggleChat, theme, onToggleTheme }: HeaderProps) {
  useNow(60000)
  const [label, cls] = OVERALL[snapshot?.kpis.overall ?? ''] ?? ['Loading', 'info']
  return (
    <header className="app-header">
      <div className="brand">
        <h1>SQL Control Plane</h1>
        <div className="sub">
          {snapshot ? <>Generated {fmt(snapshot.generated_at)} <b>({rel(snapshot.generated_at)})</b> · scope: {snapshot.scope.resource_groups?.join(', ')} </> : 'Loading data from Azure…'}
          {health && !health.write_actions_enabled && <> · <span className="muted">read-only</span></>}
        </div>
      </div>
      <Pill tone={cls}>{label}</Pill>
      <div className="spacer" />
      <input className="search" placeholder="Search… ( / )" value={query} onChange={e => onQuery(e.target.value)} id="global-search" />
      <button onClick={onToggleChat} className={chatOpen ? 'active' : ''} title="Ask about HA, patching, maintenance, security and performance">💬 Ask</button>
      <button className="primary" onClick={onRefresh} disabled={refreshing} title="Collect fresh data from Azure">
        {refreshing ? <><span className="spin">⟳</span> Refreshing…</> : '⟳ Refresh'}
      </button>
      <button className="icon" onClick={onToggleTheme} title="Toggle theme">{theme === 'dark' ? '☀' : '◐'}</button>
      <a className="icon-link" href="/docs" target="_blank" rel="noreferrer" title="API (Swagger)">API</a>
    </header>
  )
}
