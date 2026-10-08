import type { AvailabilityGroup } from '../../api/types'
import { Empty } from '../common/Card'
import { Pill } from '../common/Pill'

/** Database × replica synchronization matrix. */
export function DbMatrix({ ag }: { ag: AvailabilityGroup }) {
  const replicas = [...new Set(ag.databases.flatMap(db => db.replicas.map(r => r.replica)))].sort()
  if (!replicas.length) return <Empty>No database state</Empty>
  return (
    <div className="table-wrap">
      <table className="matrix">
        <thead>
          <tr><th>Database</th>{replicas.map(r => <th key={r}>{r}</th>)}</tr>
        </thead>
        <tbody>
          {ag.databases.map(db => (
            <tr key={db.database}>
              <td><b>{db.database}</b></td>
              {replicas.map(name => {
                const x = db.replicas.find(r => r.replica === name)
                if (!x) return <td key={name} className="cell muted">—</td>
                const good = x.sync_state === 'SYNCHRONIZED' && x.sync_health === 'HEALTHY' && !x.suspended
                return (
                  <td key={name} className="cell" title={`${x.sync_health ?? ''}${x.suspend_reason ? ` · ${x.suspend_reason}` : ''}`}>
                    <Pill tone={good ? 'ok' : 'bad'}>{x.suspended ? 'SUSPENDED' : x.sync_state ?? '?'}</Pill>
                    {x.is_primary && <span className="muted"> (P)</span>}
                  </td>
                )
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
