import type { Replica } from '../api/types'
import { AgTopology } from '../components/ag/AgTopology'
import { DbMatrix } from '../components/ag/DbMatrix'
import { Banner, Card, Empty, KeyValueGrid } from '../components/common/Card'
import { DataTable } from '../components/common/DataTable'
import { Pill } from '../components/common/Pill'
import { useDashboard } from '../context/DashboardContext'
import { lc } from '../utils/format'

export function AlwaysOnView() {
  const { snapshot: s, openNode } = useDashboard()
  const ags = s.availability_groups?.availability_groups ?? []
  const instances = s.inventory?.instances ?? []
  if (!ags.length) return <Card><Empty>No availability groups</Empty></Card>

  const machineOf = (instance: string) => instances.find(i => lc(i.name) === lc(instance))?.machine ?? instance
  return (
    <>
      {ags.map(ag => (
        <div key={ag.name}>
          <AgTopology ag={ag} instances={instances} onNode={openNode} />
          <div className="grid2">
            <Card title="Replicas">
              <DataTable<Replica>
                rows={ag.replicas} rowKey={r => r.replica} onRowClick={r => openNode(machineOf(r.replica))}
                columns={[
                  { key: 'replica', title: 'Replica', render: r => <b>{r.replica}</b> },
                  { key: 'role', title: 'Role' },
                  { key: 'availability_mode', title: 'Commit' },
                  { key: 'failover_mode', title: 'Failover' },
                  { key: 'connected', title: 'Connected', render: r => <Pill tone={r.connected === 'CONNECTED' ? 'ok' : 'bad'}>{r.connected ?? '?'}</Pill> },
                  { key: 'sync_health', title: 'Sync health', render: r => <Pill tone={r.sync_health === 'HEALTHY' ? 'ok' : 'bad'}>{r.sync_health ?? '?'}</Pill> },
                  { key: 'readable_secondary', title: 'Readable' },
                ]} />
            </Card>
            <Card title="Database synchronization"><DbMatrix ag={ag} /></Card>
          </div>
          <Card title="AG settings">
            <KeyValueGrid items={{
              'Cluster type': ag.cluster_type, 'Preferred primary': ag.preferred_primary, 'Current primary': ag.primary_replica,
              'Backup preference': ag.automated_backup_preference, 'DB-level failover': ag.db_level_failover,
              'Required synced secondaries': ag.required_synchronized_secondaries, 'AG id': ag.availability_group_id,
            }} />
          </Card>
          {ag.errors.length > 0 && <Banner tone="bad">{ag.errors.map(e => <div key={e.instance}>{e.instance}: {e.error}</div>)}</Banner>}
        </div>
      ))}
    </>
  )
}
