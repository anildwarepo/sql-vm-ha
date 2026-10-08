import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Finding } from './api/types'
import { ChatPanel } from './components/chat/ChatPanel'
import { Banner } from './components/common/Card'
import { Drawer } from './components/common/Drawer'
import { FindingDetails } from './components/drawers/FindingDetails'
import { NodeDetails } from './components/drawers/NodeDetails'
import { Header } from './components/layout/Header'
import { KpiGrid } from './components/layout/KpiGrid'
import { TabBar } from './components/layout/TabBar'
import { DashboardContext } from './context/DashboardContext'
import type { DashboardContextValue } from './context/DashboardContext'
import { useHashState } from './hooks/useHashState'
import { useSnapshot } from './hooks/useSnapshot'
import { VIEWS, tabsFor } from './views'

type Theme = 'light' | 'dark'
const THEME_KEY = 'sqlha-theme'

function initialTheme(): Theme {
  const saved = localStorage.getItem(THEME_KEY)
  if (saved === 'light' || saved === 'dark') return saved
  return window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
}

export function App() {
  const { snapshot, health, loading, refreshing, error, refresh } = useSnapshot()
  const [hash, setHash] = useHashState()
  const [query, setQuery] = useState('')
  const [theme, setTheme] = useState<Theme>(initialTheme)
  const [chatOpen, setChatOpen] = useState(false)
  const [finding, setFinding] = useState<Finding | null>(null)

  useEffect(() => {
    document.documentElement.dataset.theme = theme
    localStorage.setItem(THEME_KEY, theme)
  }, [theme])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement
      if (e.key === '/' && !['INPUT', 'TEXTAREA', 'SELECT'].includes(t.tagName)) {
        e.preventDefault()
        document.getElementById('global-search')?.focus()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  const openNode = useCallback((machine: string) => { setFinding(null); setHash({ node: machine }) }, [setHash])
  const openFinding = useCallback((f: Finding) => { setHash({ node: null }); setFinding(f) }, [setHash])
  const goTab = useCallback((tab: string) => { setFinding(null); setHash({ tab, node: null }) }, [setHash])
  const closeDrawer = useCallback(() => { setFinding(null); setHash({ node: null }) }, [setHash])

  const machines = useMemo(() => {
    const names = new Set<string>()
    snapshot?.inventory?.instances.forEach(i => i.machine && names.add(i.machine))
    snapshot?.patching?.machines.forEach(m => m.machine && names.add(m.machine))
    return [...names]
  }, [snapshot])

  const ctx = useMemo<DashboardContextValue | null>(() => snapshot && {
    snapshot, health, query, openNode, openFinding, goTab, refresh,
  }, [snapshot, health, query, openNode, openFinding, goTab, refresh])

  const tabs = snapshot ? tabsFor(snapshot) : []
  const activeTab = VIEWS[hash.tab] ? hash.tab : 'overview'
  const View = VIEWS[activeTab]
  const writeEnabled = !!health?.write_actions_enabled
  const chatContext = `tab=${activeTab}${hash.node ? `, node=${hash.node}` : ''}${snapshot ? `, dashboard data generated ${snapshot.generated_at}` : ''}`
  const sectionErrors = Object.entries(snapshot?.errors ?? {})

  return (
    <div className={`app ${chatOpen ? 'with-chat' : ''}`}>
      <Header snapshot={snapshot} health={health} query={query} onQuery={setQuery}
        refreshing={refreshing} onRefresh={refresh} chatOpen={chatOpen} onToggleChat={() => setChatOpen(o => !o)}
        theme={theme} onToggleTheme={() => setTheme(t => (t === 'dark' ? 'light' : 'dark'))} />

      <main className="content">
        {error && <Banner tone="bad">Backend error: {error}</Banner>}
        {sectionErrors.length > 0 && (
          <Banner tone="warn">
            Some data couldn't be collected: {sectionErrors.map(([k, v]) => <div key={k}><b>{k}</b>: {v}</div>)}
          </Banner>
        )}

        {loading && !snapshot && (
          <div className="loading"><span className="spin">⟳</span> Collecting data from Azure Arc, Update Manager and Defender…</div>
        )}

        {ctx && (
          <DashboardContext.Provider value={ctx}>
            <KpiGrid snapshot={ctx.snapshot} onSelect={goTab} />
            <TabBar tabs={tabs} active={activeTab} onSelect={goTab} />
            <section className="view" role="tabpanel"><View /></section>

            <Drawer open={!!hash.node} title={hash.node ?? ''} subtitle="Node details" onClose={closeDrawer}>
              {hash.node && <NodeDetails machine={hash.node} snapshot={ctx.snapshot} writeEnabled={writeEnabled} onChanged={refresh} />}
            </Drawer>
            <Drawer open={!!finding} title={finding?.title ?? ''} subtitle={finding?.category} onClose={closeDrawer}>
              {finding && <FindingDetails finding={finding} machines={machines} onOpenNode={openNode} onGoTab={goTab} />}
            </Drawer>
          </DashboardContext.Provider>
        )}
      </main>

      <ChatPanel open={chatOpen} onClose={() => setChatOpen(false)} context={chatContext} configured={health?.chat_configured ?? true} />
    </div>
  )
}
