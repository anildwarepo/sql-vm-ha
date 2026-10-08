import { useState } from 'react'
import type { Database } from '../api/types'
import { Card } from '../components/common/Card'
import { DataTable } from '../components/common/DataTable'
import { BoolPill, Pill } from '../components/common/Pill'
import { useDashboard } from '../context/DashboardContext'
import { fmt } from '../utils/format'

export function DatabasesView() {
  const { snapshot: s, query } = useDashboard()
  const [system, setSystem] = useState(false)
  return (
    <Card title="Databases" actions={<label><input type="checkbox" checked={system} onChange={e => setSystem(e.target.checked)} /> include system</label>}>
      <DataTable<Database>
        rows={s.databases?.databases ?? []} rowKey={d => `${d.instance}/${d.name}`} query={query} filter={d => system || !d.system}
        columns={[
          { key: 'instance', title: 'Instance' },
          { key: 'name', title: 'Database', render: d => <b>{d.name}</b> },
          { key: 'state', title: 'State', render: d => <Pill tone={d.state === 'Online' ? 'ok' : 'bad'}>{d.state ?? '?'}</Pill> },
          { key: 'recovery_model', title: 'Recovery' },
          { key: 'compatibility_level', title: 'Compat' },
          { key: 'size_mb', title: 'Size (MB)' },
          { key: 'encrypted', title: 'TDE', render: d => <BoolPill value={d.encrypted} yes="On" no="Off" /> },
          { key: 'last_full_backup', title: 'Last full backup', render: d => d.last_full_backup ? fmt(d.last_full_backup) : <span className="muted">not reported</span> },
        ]} />
    </Card>
  )
}
