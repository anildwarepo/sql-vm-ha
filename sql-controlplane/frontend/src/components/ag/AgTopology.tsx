import type { AvailabilityGroup, SqlInstance } from '../../api/types'
import { lc } from '../../utils/format'
import { Banner, Card } from '../common/Card'
import { BoolPill, Pill } from '../common/Pill'

interface AgTopologyProps {
  ag: AvailabilityGroup
  instances: SqlInstance[]
  onNode: (machine: string) => void
}

/** Primary/secondary cards joined by a sync link. Click a node to open its drawer. */
export function AgTopology({ ag, instances, onNode }: AgTopologyProps) {
  const replicas = Object.fromEntries(ag.replicas.map(r => [lc(r.replica), r]))
  const nodes = [...ag.nodes].sort((a, b) => (a.role === 'PRIMARY' ? 0 : 1) - (b.role === 'PRIMARY' ? 0 : 1))
  const allSync = ag.databases.every(db => db.replicas.every(r => r.sync_state === 'SYNCHRONIZED'))

  return (
    <Card
      title={<>{ag.name} <Pill tone={ag.healthy ? 'ok' : 'bad'}>{ag.healthy ? 'Healthy' : 'Unhealthy'}</Pill></>}
      actions={<span className="muted">{ag.cluster_type} · {ag.source}</span>}>
      <div className="topo">
        {nodes.map((n, i) => {
          const r = replicas[lc(n.instance)] ?? {}
          const inst = instances.find(x => lc(x.name) === lc(n.instance))
          const role = n.role ?? r.role ?? 'UNKNOWN'
          return (
            <div key={n.instance} className="topo-item">
              {i > 0 && (
                <div className={`link ${allSync && ag.healthy ? '' : 'bad'}`}>
                  <span>{allSync ? 'synchronized' : 'NOT synchronized'}</span>
                  <div className="line" />
                  <span>{ag.databases.length} DBs</span>
                </div>
              )}
              <button className={`node ${lc(role)}`} onClick={() => onNode(inst?.machine ?? n.instance)}>
                <div className="role">{role}{lc(ag.preferred_primary) === lc(n.instance) ? ' · preferred' : ''}</div>
                <div className="name">{n.instance}</div>
                <div className="kv">
                  <span>Health</span><span><BoolPill value={n.healthy} yes="Healthy" no="Unhealthy" /></span>
                  <span>Mode</span><span>{r.availability_mode ?? n.mode ?? '—'}</span>
                  <span>Failover</span><span>{r.failover_mode ?? '—'}{n.role === 'SECONDARY' ? ` · ${n.failover_ready ? 'ready' : 'not ready'}` : ''}</span>
                  <span>Build</span><span className="mono">{inst?.build ?? '—'}</span>
                  <span>Host</span><span>{inst?.host.cloud} <Pill>{inst?.host.status ?? '?'}</Pill></span>
                </div>
                {n.message && <div className="muted small">{n.message}</div>}
              </button>
            </div>
          )
        })}
      </div>
      {ag.on_preferred_primary === false && (
        <Banner>Running on {ag.primary_replica}; preferred primary is {ag.preferred_primary}.</Banner>
      )}
    </Card>
  )
}
