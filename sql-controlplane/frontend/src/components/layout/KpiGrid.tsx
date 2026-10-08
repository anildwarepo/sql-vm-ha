import type { DashboardSnapshot } from '../../api/types'
import { useNow } from '../../hooks/useNow'
import { SEVERITIES, fmt, rel } from '../../utils/format'

interface Kpi {
  label: string
  value: string | number
  hint: string
  tone: 'ok' | 'warning' | 'critical'
  tab: string
}

function buildKpis(s: DashboardSnapshot): Kpi[] {
  const k = s.kpis
  const ags = s.availability_groups?.availability_groups ?? []
  const risks = s.maintenance?.risks ?? []
  const critRisk = risks.some(r => r.severity === 'critical')
  const sev = s.security?.defender_unhealthy_by_severity ?? {}
  const alerts = s.security?.active_alerts.length ?? 0
  const fs = k.findings_by_severity
  const nw = k.next_window
  const lr = k.last_run
  return [
    { label: 'SQL instances', value: `${k.instances_connected}/${k.instances_total}`, hint: 'connected via Azure Arc',
      tone: k.instances_connected === k.instances_total ? 'ok' : 'critical', tab: 'instances' },
    { label: 'Always On', value: `${k.ag_healthy}/${k.ag_total}`,
      hint: ags.map(a => `${a.name}: primary ${a.primary_replica ?? '?'}`).join(' · ') || 'no AGs',
      tone: k.ag_healthy === k.ag_total ? 'ok' : 'critical', tab: 'alwayson' },
    { label: 'Outstanding patches', value: k.outstanding_patches, hint: `${k.security_patches} security/critical`,
      tone: k.security_patches ? 'critical' : k.outstanding_patches ? 'warning' : 'ok', tab: 'patching' },
    { label: 'Next maintenance', value: nw?.start_utc ? rel(nw.start_utc) : 'none',
      hint: nw?.start_utc ? `${fmt(nw.start_utc)} · ${nw.target_node ?? nw.configuration ?? ''}${critRisk ? ' · ⚠ waves overlap' : risks.length ? ` · ⚠ ${risks.length} risk(s)` : ''}` : 'no schedule',
      tone: !nw || critRisk ? 'critical' : risks.length ? 'warning' : 'ok', tab: 'maintenance' },
    { label: 'Last patch run', value: lr?.status ?? '—', hint: lr ? `${lr.maintenance_configuration ?? ''} · ${fmt(lr.start)}` : 'no runs in window',
      tone: !lr ? 'warning' : ['Succeeded', 'Completed'].includes(lr.status ?? '') ? 'ok' : 'critical', tab: 'patching' },
    { label: 'Security findings', value: k.defender_unhealthy, hint: `${sev.High ?? 0} high · ${alerts} active alerts`,
      tone: alerts ? 'critical' : sev.High ? 'warning' : 'ok', tab: 'security' },
    { label: 'Findings', value: s.findings.length, hint: SEVERITIES.filter(x => fs[x]).map(x => `${fs[x]} ${x}`).join(' · ') || 'none',
      tone: fs.critical ? 'critical' : fs.high || fs.medium ? 'warning' : 'ok', tab: 'overview' },
  ]
}

export function KpiGrid({ snapshot, onSelect }: { snapshot: DashboardSnapshot; onSelect: (tab: string) => void }) {
  useNow()
  return (
    <section className="kpis">
      {buildKpis(snapshot).map(k => (
        <button key={k.label} className={`kpi ${k.tone}`} onClick={() => onSelect(k.tab)}>
          <div className="label">{k.label}</div>
          <div className="value">{k.value}</div>
          <div className="hint">{k.hint}</div>
        </button>
      ))}
    </section>
  )
}
