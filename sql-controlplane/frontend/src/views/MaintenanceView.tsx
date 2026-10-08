import type { MaintenanceConfiguration, MaintenanceWindows } from '../api/types'
import { Card, KeyValueGrid } from '../components/common/Card'
import { DataTable } from '../components/common/DataTable'
import { Pill } from '../components/common/Pill'
import { Timeline } from '../components/maintenance/Timeline'
import { useDashboard } from '../context/DashboardContext'
import { fmt, rel } from '../utils/format'

type MachineRow = MaintenanceWindows['machines'][number]

function ConfigDetail({ c }: { c: MaintenanceConfiguration }) {
  return (
    <>
      <KeyValueGrid items={{
        Partner: c.partner_node, 'Preferred primary': c.preferred_primary, AG: c.ag_name, Reboot: c.reboot_setting,
        Classifications: c.classifications.join(', '), 'Excluded KBs': c.kb_exclude.join(', ') || 'none',
        Expires: c.expiration ?? 'never', 'Resource group': c.resource_group,
      }} />
      <h3 className="small">Upcoming windows</h3>
      {c.next_windows.slice(0, 6).map((w, i) => (
        <div key={i}>
          {w.error ?? <>{fmt(w.start_utc)} → {fmt(w.end_utc)} <span className="muted">({rel(w.start_utc)})</span></>}
          {w.in_progress && <> <Pill tone="high">in progress</Pill></>}
        </div>
      ))}
    </>
  )
}

export function MaintenanceView() {
  const { snapshot: s, query, openNode } = useDashboard()
  const m = s.maintenance
  return (
    <>
      <Card title="Maintenance timeline"><Timeline configurations={m?.configurations ?? []} defaultDays={28} /></Card>
      {!!m?.risks.length && (
        <Card title="Scheduling risks">
          {m.risks.map((r, i) => (
            <div key={i} className="finding static">
              <Pill tone={r.severity === 'critical' ? 'bad' : r.severity === 'medium' ? 'warn' : r.severity}>{r.severity}</Pill>
              <div className="finding-text"><div className="t">{r.title}</div><div className="d">{r.detail}</div></div>
            </div>
          ))}
        </Card>
      )}
      <Card title="Schedules">
        <DataTable<MaintenanceConfiguration>
          rows={m?.configurations ?? []} rowKey={c => c.id} query={query} expand={c => <ConfigDetail c={c} />}
          columns={[
            { key: 'name', title: 'Configuration', render: c => <><b>{c.name}</b> {c.ag_aware && <Pill tone="low">AG-aware</Pill>}</> },
            { key: 'target_node', title: 'Target' },
            { key: 'wave', title: 'Wave' },
            { key: 'recur_every', title: 'Recurrence' },
            { key: 'start', title: 'Start / TZ', render: c => <>{c.start?.slice(11)} <span className="muted">{c.time_zone}</span></> },
            { key: 'duration', title: 'Duration' },
            { key: 'next', title: 'Next window', sortValue: c => c.next_windows[0]?.start_utc ?? '',
              render: c => c.next_windows[0]?.start_utc ? <>{fmt(c.next_windows[0].start_utc)}<div className="muted">{rel(c.next_windows[0].start_utc)}</div></> : '—' },
            { key: 'hosts', title: 'Hosts', sortValue: c => c.assigned_machines.join(), render: c => c.assigned_machines.join(', ') || '—' },
          ]} />
      </Card>
      <Card title="Host assignments">
        <DataTable<MachineRow>
          rows={m?.machines ?? []} rowKey={r => r.machine} query={query} onRowClick={r => openNode(r.machine)}
          columns={[
            { key: 'machine', title: 'Host', render: r => <b>{r.machine}</b> },
            { key: 'assignments', title: 'Schedules', sortValue: r => r.assignments.length,
              render: r => r.assignments.length ? r.assignments.map(a => <div key={a.configuration}>{a.configuration} <span className="muted">({a.kind})</span></div>) : <Pill tone="bad">none</Pill> },
            { key: 'next', title: 'Next window', sortValue: r => r.next_window?.start_utc ?? '',
              render: r => r.next_window?.start_utc ? <>{fmt(r.next_window.start_utc)} <span className="muted">{rel(r.next_window.start_utc)}</span></> : '—' },
          ]} />
      </Card>
    </>
  )
}
