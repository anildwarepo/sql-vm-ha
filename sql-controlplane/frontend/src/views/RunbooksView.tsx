import type { OrchestrationJob } from '../api/types'
import { Card } from '../components/common/Card'
import { DataTable } from '../components/common/DataTable'
import { Pill } from '../components/common/Pill'
import { useDashboard } from '../context/DashboardContext'
import { fmt } from '../utils/format'

export function RunbooksView() {
  const { snapshot: s, query } = useDashboard()
  return (
    <Card title="AG-aware patching runbook jobs">
      <p className="muted">
        Pre-SqlAgFailover moves the AG off a node before its window; Post-SqlAgValidate checks health and fails back.
        Ask the chat to "show the output of job &lt;name&gt;" for details.
      </p>
      <DataTable<OrchestrationJob>
        rows={s.jobs?.jobs ?? []} rowKey={(j, i) => j.job_name ?? String(i)} query={query} empty="No runbook jobs"
        columns={[
          { key: 'created', title: 'Created', render: j => fmt(j.created) },
          { key: 'runbook', title: 'Runbook', render: j => <b>{j.runbook}</b> },
          { key: 'status', title: 'Status', render: j => <Pill>{j.status ?? '?'}</Pill> },
          { key: 'end', title: 'Ended', render: j => fmt(j.end) },
          { key: 'job_name', title: 'Job', render: j => <span className="mono small">{j.job_name}</span> },
          { key: 'automation_account', title: 'Account' },
        ]} />
    </Card>
  )
}
