import type { ReactNode } from 'react'
import type { DashboardSnapshot } from '../../api/types'
import { fmt, lc, rel } from '../../utils/format'
import { KeyValueGrid } from '../common/Card'
import { Pill } from '../common/Pill'
import { ActionsPanel } from './ActionsPanel'

interface NodeDetailsProps {
  machine: string
  snapshot: DashboardSnapshot
  writeEnabled: boolean
  onChanged: () => void
}

const Section = ({ title, children }: { title: string; children: ReactNode }) => (
  <section className="drawer-section"><h3>{title}</h3>{children}</section>
)

/** Everything about one SQL host: instance, Always On, patching, maintenance, findings, Defender, databases, actions. */
export function NodeDetails({ machine, snapshot: s, writeEnabled, onChanged }: NodeDetailsProps) {
  const m = lc(machine)
  const inst = s.inventory?.instances.find(i => lc(i.machine) === m)
  const host = inst?.host ?? {}
  const pm = s.patching?.machines.find(x => lc(x.machine) === m)
  const cfgs = s.maintenance?.configurations.filter(c => c.assigned_machines.some(x => lc(x) === m)) ?? []
  const secF = s.security?.defender_findings.filter(f => lc(f.machine) === m) ?? []
  const nodeF = s.findings.filter(f => lc(f.resource).includes(m) || lc(f.title).includes(m))
  const ag = s.availability_groups?.availability_groups.find(a => a.nodes.some(n => lc(n.instance) === lc(inst?.name)))
  const node = ag?.nodes.find(n => lc(n.instance) === lc(inst?.name))
  const dbs = s.databases?.databases.filter(d => lc(d.instance) === lc(inst?.name) && !d.system) ?? []
  const runs = s.history?.maintenance_runs.filter(r => lc(r.target_node) === m || cfgs.some(c => c.name === r.maintenance_configuration)) ?? []

  return (
    <>
      <Section title="Host & SQL Server">
        <KeyValueGrid items={{
          'SQL instance': inst?.name, Version: `${inst?.version ?? ''} ${inst?.edition ?? ''}`, Build: <span className="mono">{inst?.build}</span>,
          'Base version': inst?.base_version, 'Arc SQL status': inst?.status, License: inst?.license_type, vCores: inst?.vcores,
          'Defender for SQL': inst?.defender_status, 'OS version': host.os_version, 'Arc agent': host.arc_agent_version,
          'Cores / RAM': `${host.logical_cores ?? '?'} / ${host.memory_gb ?? '?'} GB`, 'Last status change': fmt(host.last_status_change),
        }} />
        {host.tags && Object.keys(host.tags).length > 0 && (
          <p className="muted small">Tags: {Object.entries(host.tags).map(([k, v]) => <span key={k} className="mono">{k}={v} </span>)}</p>
        )}
      </Section>

      {ag && node && (
        <Section title={`Always On — ${ag.name}`}>
          <KeyValueGrid items={{
            Role: node.role, Healthy: node.healthy, 'Failover ready': node.role === 'SECONDARY' ? node.failover_ready : 'n/a (primary)',
            'Commit mode': node.mode, Connected: node.connected, 'Data collected': fmt(node.collected),
          }} />
          {node.message && <p className="muted">{node.message}</p>}
        </Section>
      )}

      <Section title="Actions">
        <ActionsPanel machine={machine} instance={inst?.name} role={node?.role} writeEnabled={writeEnabled} onChanged={onChanged} />
      </Section>

      <Section title="Patching">
        <KeyValueGrid items={{
          Outstanding: pm?.outstanding_total, 'Security/critical': pm?.security_or_critical,
          'Last assessed': pm?.last_assessed ? `${fmt(pm.last_assessed)} (${rel(pm.last_assessed)})` : 'never',
          'Assessment mode': pm?.assessment_mode, 'Reboot pending': pm?.reboot_pending,
          'Last install': pm?.last_installation ? `${pm.last_installation.status} ${fmt(pm.last_installation.start)}` : 'none',
        }} />
        {!!pm?.outstanding.length && (
          <table><thead><tr><th>KB</th><th>Update</th><th>MSRC</th><th>Age</th></tr></thead>
            <tbody>{pm.outstanding.map(x => (
              <tr key={x.kb ?? x.name}><td className="mono">KB{x.kb}</td><td>{x.name}</td><td>{x.msrc_severity ?? '—'}</td><td>{x.age_days}d</td></tr>
            ))}</tbody></table>
        )}
      </Section>

      <Section title="Maintenance">
        {cfgs.length ? cfgs.map(c => (
          <div key={c.id} className="cfg-line">
            <b>{c.name}</b> {c.wave && <Pill tone="low">wave {c.wave}</Pill>} · {c.recur_every} {c.start?.slice(11)} {c.time_zone} for {c.duration}
            <div className="muted">Next: {c.next_windows.filter(w => w.start_utc).slice(0, 3).map(w => `${fmt(w.start_utc)} (${rel(w.start_utc)})`).join(' · ')}</div>
          </div>
        )) : <Pill tone="bad">No schedule</Pill>}
        {runs.length > 0 && (
          <table><thead><tr><th>Run</th><th>Status</th><th>Detail</th></tr></thead>
            <tbody>{runs.slice(0, 6).map((r, i) => (
              <tr key={i}><td>{fmt(r.start)}</td><td><Pill>{r.status ?? '?'}</Pill></td><td className="muted">{r.error}</td></tr>
            ))}</tbody></table>
        )}
      </Section>

      <Section title={`Findings (${nodeF.length})`}>
        {nodeF.length ? nodeF.map((f, i) => (
          <div key={i} className="finding static">
            <Pill tone={f.severity === 'critical' ? 'bad' : f.severity === 'medium' ? 'warn' : f.severity}>{f.severity}</Pill>
            <div className="finding-text"><div className="t">{f.title}</div><div className="d">{f.detail}</div></div>
          </div>
        )) : <p className="muted">None</p>}
      </Section>

      <Section title={`Defender recommendations (${secF.length})`}>
        {secF.length ? (
          <table><tbody>{secF.map((f, i) => (
            <tr key={i}><td><Pill tone={lc(f.severity) === 'medium' ? 'warn' : lc(f.severity)}>{f.severity}</Pill></td>
              <td>{f.title}<div className="muted mono small">{f.target}</div></td></tr>
          ))}</tbody></table>
        ) : <p className="muted">None</p>}
      </Section>

      <Section title={`Databases (${dbs.length})`}>
        {dbs.length ? (
          <table><thead><tr><th>Database</th><th>State</th><th>Recovery</th><th>Size</th><th>TDE</th></tr></thead>
            <tbody>{dbs.map(d => (
              <tr key={d.name}><td>{d.name}</td><td>{d.state}</td><td>{d.recovery_model}</td><td>{d.size_mb} MB</td><td>{d.encrypted ? 'On' : 'Off'}</td></tr>
            ))}</tbody></table>
        ) : <p className="muted">None</p>}
      </Section>
    </>
  )
}
