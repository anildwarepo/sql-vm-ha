import type { ComponentType } from 'react'
import type { TabDef } from '../components/layout/TabBar'
import type { DashboardSnapshot } from '../api/types'
import { AlwaysOnView } from './AlwaysOnView'
import { DatabasesView } from './DatabasesView'
import { InstancesView } from './InstancesView'
import { MaintenanceView } from './MaintenanceView'
import { OverviewView } from './OverviewView'
import { PatchingView } from './PatchingView'
import { RunbooksView } from './RunbooksView'
import { SecurityView } from './SecurityView'

export const VIEWS: Record<string, ComponentType> = {
  overview: OverviewView,
  alwayson: AlwaysOnView,
  patching: PatchingView,
  maintenance: MaintenanceView,
  security: SecurityView,
  instances: InstancesView,
  databases: DatabasesView,
  runbooks: RunbooksView,
}

export function tabsFor(s: DashboardSnapshot): TabDef[] {
  return [
    { id: 'overview', label: 'Overview', count: s.findings.length },
    { id: 'alwayson', label: 'Always On', count: s.availability_groups?.availability_group_count },
    { id: 'patching', label: 'Patching', count: s.kpis.outstanding_patches },
    { id: 'maintenance', label: 'Maintenance', count: s.maintenance?.configurations.length },
    { id: 'security', label: 'Security', count: s.kpis.defender_unhealthy },
    { id: 'instances', label: 'Instances', count: s.kpis.instances_total },
    { id: 'databases', label: 'Databases', count: s.databases?.databases.filter(d => !d.system).length },
    { id: 'runbooks', label: 'Runbook jobs', count: s.jobs?.jobs.length },
  ]
}
