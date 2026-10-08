export interface TabDef {
  id: string
  label: string
  count?: number
}

export function TabBar({ tabs, active, onSelect }: { tabs: TabDef[]; active: string; onSelect: (id: string) => void }) {
  return (
    <nav className="tabs" role="tablist">
      {tabs.map(t => (
        <button key={t.id} role="tab" aria-selected={active === t.id} className={active === t.id ? 'active' : ''}
          onClick={() => onSelect(t.id)}>
          {t.label}
          {t.count !== undefined && <span className="count">{t.count}</span>}
        </button>
      ))}
    </nav>
  )
}
