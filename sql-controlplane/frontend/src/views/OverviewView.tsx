import { AgTopology } from '../components/ag/AgTopology'
import { Card, Empty } from '../components/common/Card'
import { FindingList } from '../components/common/FindingList'
import { Timeline } from '../components/maintenance/Timeline'
import { useDashboard } from '../context/DashboardContext'

export function OverviewView() {
  const { snapshot: s, query, openNode, openFinding } = useDashboard()
  const ags = s.availability_groups?.availability_groups ?? []
  return (
    <div className="grid2">
      <div>
        {ags.length ? ags.map(ag => (
          <AgTopology key={ag.name} ag={ag} instances={s.inventory?.instances ?? []} onNode={openNode} />
        )) : <Card><Empty>No availability groups</Empty></Card>}
        <Card title="Upcoming maintenance">
          <Timeline configurations={s.maintenance?.configurations ?? []} defaultDays={7} />
        </Card>
      </div>
      <Card title="Findings">
        <FindingList findings={s.findings} query={query} onSelect={openFinding} />
      </Card>
    </div>
  )
}
