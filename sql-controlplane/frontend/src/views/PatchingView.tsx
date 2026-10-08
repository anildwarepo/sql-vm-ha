import { useMemo, useState } from 'react'
import type { Installation, MachinePatchState, MaintenanceRun, MissingUpdate } from '../api/types'
import { Card } from '../components/common/Card'
import { DataTable } from '../components/common/DataTable'
import { Pill } from '../components/common/Pill'
import { useDashboard } from '../context/DashboardContext'
import { fmt, lc, rel } from '../utils/format'

function UpdatesTable({ updates }: { updates: MissingUpdate[] }) {
  if (!updates.length) return <p className="muted">No outstanding updates in the latest assessment.</p>
  return (
    <table>
      <thead><tr><th>KB</th><th>Update</th><th>Classification</th><th>MSRC</th><th>Published</th><th>Reboot</th></tr></thead>
      <tbody>
        {updates.map(x => (
          <tr key={`${x.kb}-${x.name}`}>
            <td className="mono">KB{x.kb}</td>
            <td>{x.name} {x.is_sql_server_update && <Pill tone="low">SQL</Pill>}</td>
            <td>{x.classifications.join(', ')}</td>
            <td>{x.msrc_severity ? <Pill tone={lc(x.msrc_severity) === 'critical' ? 'bad' : 'high'}>{x.msrc_severity}</Pill> : '—'}</td>
            <td>{fmt(x.published)}<div className="muted">{x.age_days} days</div></td>
            <td>{x.reboot_behavior}</td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}

export function PatchingView() {
  const { snapshot: s, query, openNode } = useDashboard()
  const machines = s.patching?.machines ?? []
  const all = useMemo(() => machines.flatMap(m => m.outstanding.map(u => ({ ...u, machine: m.machine ?? '' }))), [machines])
  const classes = useMemo(() => [...new Set(all.flatMap(u => u.classifications))].sort(), [all])
  const [cls, setCls] = useState('')
  const [sqlOnly, setSqlOnly] = useState(false)

  return (
    <>
      <Card title="Patch compliance by host" actions={<span className="muted">click a row for outstanding updates</span>}>
        <DataTable<MachinePatchState>
          rows={machines} rowKey={m => m.machine_id} query={query} expand={m => <UpdatesTable updates={m.outstanding} />}
          columns={[
            { key: 'machine', title: 'Host', render: m => <b>{m.machine}</b> },
            { key: 'outstanding_total', title: 'Outstanding', render: m => <Pill tone={m.security_or_critical ? 'bad' : m.outstanding_total ? 'warn' : 'ok'}>{m.outstanding_total}</Pill> },
            { key: 'security_or_critical', title: 'Security' },
            { key: 'sql', title: 'SQL updates', sortValue: m => m.sql_server_updates.length, render: m => m.sql_server_updates.map(x => `KB${x.kb}`).join(', ') || '—' },
            { key: 'last_assessed', title: 'Last assessed', render: m => m.last_assessed ? <>{fmt(m.last_assessed)}<div className="muted">{rel(m.last_assessed)}</div></> : <Pill tone="bad">never</Pill> },
            { key: 'assessment_mode', title: 'Assessment mode', render: m => m.assessment_mode ?? '—' },
            { key: 'reboot_pending', title: 'Reboot pending', render: m => m.reboot_pending ? <Pill tone="warn">Yes</Pill> : 'No' },
            { key: 'last_install', title: 'Last install', sortValue: m => m.last_installation?.start ?? '',
              render: m => m.last_installation ? <><Pill>{m.last_installation.status ?? '?'}</Pill><div className="muted">{fmt(m.last_installation.start)}</div></> : <span className="muted">none</span> },
            { key: 'open', title: '', render: m => <button onClick={e => { e.stopPropagation(); openNode(m.machine ?? '') }}>Details ›</button> },
          ]} />
      </Card>

      <Card title="All outstanding updates">
        <div className="toolbar">
          <select value={cls} onChange={e => setCls(e.target.value)}>
            <option value="">All classifications</option>
            {classes.map(c => <option key={c}>{c}</option>)}
          </select>
          <label><input type="checkbox" checked={sqlOnly} onChange={e => setSqlOnly(e.target.checked)} /> SQL Server only</label>
        </div>
        <DataTable<MissingUpdate & { machine: string }>
          rows={all} rowKey={(u, i) => `${u.machine}-${u.kb}-${i}`} query={query} defaultSort={{ key: 'age_days', asc: false }}
          filter={u => (!cls || u.classifications.includes(cls)) && (!sqlOnly || u.is_sql_server_update)} empty="No outstanding updates"
          columns={[
            { key: 'machine', title: 'Host' },
            { key: 'kb', title: 'KB', render: u => <span className="mono">KB{u.kb}</span> },
            { key: 'name', title: 'Update' },
            { key: 'cls', title: 'Classification', sortValue: u => u.classifications.join(), render: u => u.classifications.join(', ') },
            { key: 'msrc_severity', title: 'MSRC', render: u => u.msrc_severity ?? '—' },
            { key: 'age_days', title: 'Age (days)' },
          ]} />
      </Card>

      <div className="grid2">
        <Card title={`Maintenance runs (${s.history?.days ?? 30} days)`}>
          <DataTable<MaintenanceRun>
            rows={s.history?.maintenance_runs ?? []} rowKey={(r, i) => `${r.maintenance_configuration}-${r.start}-${i}`} query={query}
            empty="No maintenance runs"
            columns={[
              { key: 'start', title: 'Start', render: r => fmt(r.start) },
              { key: 'maintenance_configuration', title: 'Schedule' },
              { key: 'target_node', title: 'Node' },
              { key: 'status', title: 'Status', render: r => <Pill>{r.status ?? '?'}</Pill> },
              { key: 'error', title: 'Detail', render: r => <span className="muted">{r.error}</span> },
            ]} />
        </Card>
        <Card title="Installations">
          <DataTable<Installation>
            rows={s.history?.installations ?? []} rowKey={(r, i) => `${r.machine}-${r.start}-${i}`} query={query}
            empty="No installations in the window"
            columns={[
              { key: 'start', title: 'Start', render: r => fmt(r.start) },
              { key: 'machine', title: 'Host' },
              { key: 'status', title: 'Status', render: r => <Pill>{r.status ?? '?'}</Pill> },
              { key: 'installed', title: 'Installed' },
              { key: 'failed', title: 'Failed' },
              { key: 'reboot_status', title: 'Reboot' },
            ]} />
        </Card>
      </div>
    </>
  )
}
