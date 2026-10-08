import type { Inventory, SqlInstance } from '../api/types'
import { Card } from '../components/common/Card'
import { DataTable } from '../components/common/DataTable'
import { Pill } from '../components/common/Pill'
import { useDashboard } from '../context/DashboardContext'
import { lc } from '../utils/format'

type OtherService = Inventory['other_sql_services'][number]

export function InstancesView() {
  const { snapshot: s, query, openNode } = useDashboard()
  const ags = s.availability_groups?.availability_groups ?? []
  const roleOf = (instance: string) => ags.flatMap(a => a.nodes).find(n => lc(n.instance) === lc(instance))?.role
  const other = s.inventory?.other_sql_services ?? []
  return (
    <>
      <Card title="SQL Server instances (Azure Arc)">
        <DataTable<SqlInstance>
          rows={s.inventory?.instances ?? []} rowKey={i => i.id} query={query} onRowClick={i => openNode(i.machine ?? i.name)}
          columns={[
            { key: 'name', title: 'Instance', render: i => <b>{i.name}</b> },
            { key: 'status', title: 'Arc SQL', render: i => <Pill>{i.status ?? '?'}</Pill> },
            { key: 'host', title: 'Host', sortValue: i => i.host.status, render: i => <>{i.machine} <Pill>{i.host.status ?? '?'}</Pill></> },
            { key: 'cloud', title: 'Cloud', sortValue: i => i.host.cloud, render: i => i.host.cloud },
            { key: 'version', title: 'Version', render: i => `${i.version ?? ''} ${i.edition ?? ''}` },
            { key: 'build', title: 'Build', render: i => <span className="mono">{i.build}</span> },
            { key: 'role', title: 'AG role', sortValue: i => roleOf(i.name), render: i => roleOf(i.name) ?? i.always_on_role ?? '—' },
            { key: 'license_type', title: 'License' },
            { key: 'os', title: 'OS', sortValue: i => i.host.os, render: i => i.host.os },
          ]} />
      </Card>
      {other.length > 0 && (
        <Card title="Other SQL services">
          <DataTable<OtherService> rows={other} rowKey={o => o.name} query={query}
            columns={[
              { key: 'name', title: 'Name' },
              { key: 'machine', title: 'Host' },
              { key: 'service_type', title: 'Service' },
              { key: 'version', title: 'Version' },
              { key: 'status', title: 'Status', render: o => <Pill>{o.status ?? '?'}</Pill> },
            ]} />
        </Card>
      )}
    </>
  )
}
