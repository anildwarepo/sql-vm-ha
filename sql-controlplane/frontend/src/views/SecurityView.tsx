import { useState } from 'react'
import type { DefenderFinding, SecurityPosture } from '../api/types'
import { Card, Empty } from '../components/common/Card'
import { DataTable } from '../components/common/DataTable'
import { BoolPill, Pill } from '../components/common/Pill'
import { useDashboard } from '../context/DashboardContext'
import { fmt, lc, sevRank } from '../utils/format'

type Control = SecurityPosture['instance_controls'][number]
type Alert = SecurityPosture['active_alerts'][number]
type SecPatch = SecurityPosture['missing_security_patches'][number]

const sevTone = (s?: string) => (lc(s) === 'high' ? 'high' : lc(s) === 'medium' ? 'warn' : 'low')

export function SecurityView() {
  const { snapshot: s, query, openNode } = useDashboard()
  const sec = s.security
  const [sev, setSev] = useState('')
  const [host, setHost] = useState('')
  if (!sec) return <Card><Empty>Security data unavailable{s.errors.security ? `: ${s.errors.security}` : ''}</Empty></Card>

  const bySev = sec.defender_unhealthy_by_severity
  const total = Object.values(bySev).reduce((a, b) => a + b, 0) || 1
  const hosts = [...new Set(sec.defender_findings.map(f => f.machine).filter(Boolean))] as string[]
  const machineOf = (instance: string) => s.inventory?.instances.find(i => i.name === instance)?.machine ?? instance

  return (
    <>
      <div className="grid2">
        <Card title="Defender for Cloud recommendations">
          <div className="bars">
            {['High', 'Medium', 'Low'].map(x => (
              <div key={x} className={`bar ${x.toLowerCase()}`} style={{ width: `${((bySev[x] ?? 0) / total) * 100}%` }} title={`${x}: ${bySev[x] ?? 0}`} />
            ))}
          </div>
          <div className="muted">{['High', 'Medium', 'Low'].map(x => `${bySev[x] ?? 0} ${x.toLowerCase()}`).join(' · ')} · {sec.defender_healthy_count} healthy checks</div>
        </Card>
        <Card title="Active alerts">
          <DataTable<Alert> rows={sec.active_alerts} rowKey={(a, i) => `${a.title}-${i}`} empty="No active Defender alerts"
            columns={[
              { key: 'time', title: 'Time', render: a => fmt(a.time) },
              { key: 'severity', title: 'Severity', render: a => <Pill tone={lc(a.severity) === 'high' ? 'bad' : 'high'}>{a.severity}</Pill> },
              { key: 'title', title: 'Alert' },
              { key: 'entity', title: 'Entity' },
            ]} />
        </Card>
      </div>

      <Card title="Unhealthy recommendations">
        <div className="toolbar">
          <select value={sev} onChange={e => setSev(e.target.value)}>
            <option value="">All severities</option>{['High', 'Medium', 'Low'].map(x => <option key={x}>{x}</option>)}
          </select>
          <select value={host} onChange={e => setHost(e.target.value)}>
            <option value="">All hosts</option>{hosts.map(h => <option key={h}>{h}</option>)}
          </select>
        </div>
        <DataTable<DefenderFinding>
          rows={sec.defender_findings} rowKey={(f, i) => `${f.assessment_key}-${f.target}-${i}`} query={query}
          defaultSort={{ key: 'severity' }} filter={f => (!sev || f.severity === sev) && (!host || f.machine === host)}
          expand={f => (
            <>
              {f.description && <p>{f.description}</p>}
              {f.remediation && <p><b>Remediation:</b> {f.remediation}</p>}
              <div className="muted">Categories: {f.categories?.join(', ') || '—'} · key {f.assessment_key}</div>
            </>
          )}
          columns={[
            { key: 'severity', title: 'Severity', sortValue: f => sevRank(f.severity), render: f => <Pill tone={sevTone(f.severity)}>{f.severity}</Pill> },
            { key: 'title', title: 'Recommendation', render: f => <b>{f.title}</b> },
            { key: 'machine', title: 'Host' },
            { key: 'target', title: 'Object', render: f => <span className="mono small">{f.target}</span> },
          ]} />
      </Card>

      <div className="grid2">
        <Card title="Missing security updates">
          <DataTable<SecPatch> rows={sec.missing_security_patches} rowKey={(p, i) => `${p.machine}-${p.kb}-${i}`} empty="No missing security updates"
            columns={[
              { key: 'machine', title: 'Host' },
              { key: 'kb', title: 'KB', render: p => <span className="mono">KB{p.kb}</span> },
              { key: 'name', title: 'Update' },
              { key: 'msrc_severity', title: 'MSRC', render: p => p.msrc_severity ?? '—' },
              { key: 'age_days', title: 'Age' },
            ]} />
        </Card>
        <Card title="Instance controls">
          <DataTable<Control> rows={sec.instance_controls} rowKey={c => c.instance} onRowClick={c => openNode(machineOf(c.instance))}
            columns={[
              { key: 'instance', title: 'Instance' },
              { key: 'defender_for_sql', title: 'Defender for SQL', render: c => <Pill tone={c.defender_for_sql === 'Protected' ? 'ok' : 'bad'}>{c.defender_for_sql ?? '?'}</Pill> },
              { key: 'mirroring_endpoint_encrypted', title: 'AG endpoint enc.', render: c => <><BoolPill value={c.mirroring_endpoint_encrypted} /> <span className="muted">{c.mirroring_endpoint_algorithm}</span></> },
              { key: 'license_type', title: 'License' },
              { key: 'arc_agent_version', title: 'Arc agent', render: c => <span className="mono">{c.arc_agent_version}</span> },
            ]} />
        </Card>
      </div>
    </>
  )
}
