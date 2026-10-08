// Types mirroring the backend's Pydantic models (see /docs). Fields not listed pass through as unknown.

export type Severity = 'critical' | 'high' | 'medium' | 'low' | 'info'

export interface Finding {
  severity: Severity | string
  category: string
  title: string
  detail?: string | null
  resource?: string | null
  recommendation?: string | null
}

export interface HostInfo {
  id?: string | null
  status?: string | null
  last_status_change?: string | null
  os?: string | null
  os_version?: string | null
  arc_agent_version?: string | null
  cloud?: string | null
  logical_cores?: string | number | null
  memory_gb?: string | number | null
  tags?: Record<string, string>
}

export interface SqlInstance {
  name: string
  id: string
  machine?: string | null
  version?: string | null
  edition?: string | null
  build?: string | null
  base_version?: string | null
  status?: string | null
  license_type?: string | null
  vcores?: string | number | null
  always_on_role?: string | null
  availability_groups: string[]
  defender_status?: string | null
  tcp_port?: string | null
  last_inventory_upload?: string | null
  host: HostInfo
}

export interface Inventory {
  instance_count: number
  connected_count: number
  instances: SqlInstance[]
  other_sql_services: { name: string; machine?: string; service_type?: string; version?: string; status?: string }[]
}

export interface ReplicaState {
  instance: string
  role?: string | null
  mode?: string | null
  connected?: string | null
  replica_health?: string | null
  collected?: string | null
  healthy?: boolean | null
  failover_ready?: boolean | null
  message?: string | null
}

export interface Replica {
  replica: string
  role?: string | null
  availability_mode?: string | null
  failover_mode?: string | null
  connected?: string | null
  sync_health?: string | null
  readable_secondary?: string | null
  seeding_mode?: string | null
}

export interface DatabaseReplicaState {
  replica: string
  is_primary?: boolean | null
  sync_state?: string | null
  sync_health?: string | null
  suspended?: boolean | null
  suspend_reason?: string | null
}

export interface AvailabilityGroup {
  name: string
  availability_group_id?: string | null
  cluster_type?: string | null
  primary_replica?: string | null
  preferred_primary?: string | null
  on_preferred_primary?: boolean | null
  healthy?: boolean | null
  source?: string | null
  automated_backup_preference?: string | null
  db_level_failover?: boolean | null
  required_synchronized_secondaries?: number | null
  nodes: ReplicaState[]
  replicas: Replica[]
  databases: { database: string; replicas: DatabaseReplicaState[] }[]
  errors: { instance: string; error: string }[]
}

export interface MissingUpdate {
  kb?: string | null
  name?: string | null
  classifications: string[]
  msrc_severity?: string | null
  published?: string | null
  age_days?: number | null
  reboot_behavior?: string | null
  is_sql_server_update: boolean
}

export interface MachinePatchState {
  machine?: string | null
  machine_id: string
  assessment_mode?: string | null
  last_assessed?: string | null
  assessment_stale: boolean
  reboot_pending?: boolean | null
  outstanding_total: number
  security_or_critical: number
  msrc_critical: number
  sql_server_updates: MissingUpdate[]
  outstanding: MissingUpdate[]
  last_installation?: { status?: string; start?: string; installed?: number; failed?: number } | null
}

export interface PatchCompliance {
  machine_count: number
  outstanding_total: number
  security_or_critical_total: number
  machines: MachinePatchState[]
}

export interface MaintenanceRun {
  maintenance_configuration?: string | null
  target_node?: string | null
  wave?: string | null
  status?: string | null
  start?: string | null
  end?: string | null
  error?: string | null
}

export interface Installation {
  machine?: string
  status?: string
  start?: string
  installed?: number
  failed?: number
  reboot_status?: string
}

export interface WindowOccurrence {
  start_local?: string
  end_local?: string
  start_utc?: string
  end_utc?: string
  in_progress?: boolean
  error?: string
}

export interface MaintenanceConfiguration {
  id: string
  name: string
  resource_group?: string | null
  recur_every?: string | null
  start?: string | null
  duration?: string | null
  time_zone?: string | null
  expiration?: string | null
  reboot_setting?: string | null
  ag_aware?: boolean | null
  ag_name?: string | null
  wave?: string | null
  target_node?: string | null
  partner_node?: string | null
  preferred_primary?: string | null
  classifications: string[]
  kb_exclude: string[]
  assigned_machines: string[]
  next_windows: WindowOccurrence[]
}

export interface MaintenanceWindows {
  configurations: MaintenanceConfiguration[]
  machines: { machine: string; assignments: { configuration: string; kind: string }[]; next_window?: WindowOccurrence | null }[]
  risks: Finding[]
}

export interface DefenderFinding {
  title?: string
  severity?: string
  machine?: string | null
  target?: string | null
  categories?: string[]
  description?: string | null
  remediation?: string | null
  assessment_key?: string
}

export interface SecurityPosture {
  defender_unhealthy_by_severity: Record<string, number>
  defender_healthy_count: number
  defender_findings: DefenderFinding[]
  active_alerts: { time?: string; severity?: string; title?: string; entity?: string; description?: string }[]
  missing_security_patches: (MissingUpdate & { machine?: string })[]
  instance_controls: {
    instance: string
    defender_for_sql?: string
    mirroring_endpoint_encrypted?: boolean | null
    mirroring_endpoint_algorithm?: string | null
    license_type?: string
    arc_agent_version?: string
  }[]
  unencrypted_user_databases: { instance: string; database: string }[]
}

export interface Database {
  instance: string
  name: string
  system: boolean
  state?: string | null
  recovery_model?: string | null
  compatibility_level?: number | null
  size_mb?: number | null
  encrypted?: boolean | null
  last_full_backup?: string | null
}

export interface OrchestrationJob {
  automation_account?: string
  job_name?: string
  runbook?: string
  status?: string
  created?: string
  end?: string
}

export interface Kpis {
  overall: 'critical' | 'warning' | 'healthy' | string
  findings_by_severity: Record<string, number>
  instances_total: number
  instances_connected: number
  ag_total: number
  ag_healthy: number
  outstanding_patches: number
  security_patches: number
  next_window?: (WindowOccurrence & { configuration?: string; target_node?: string }) | null
  last_run?: MaintenanceRun | null
  defender_unhealthy: number
}

export interface DashboardSnapshot {
  generated_at: string
  scope: { subscriptions?: string[]; resource_groups?: string[] }
  errors: Record<string, string>
  kpis: Kpis
  findings: Finding[]
  inventory: Inventory | null
  availability_groups: { availability_group_count: number; availability_groups: AvailabilityGroup[] } | null
  patching: PatchCompliance | null
  history: { days: number; maintenance_runs: MaintenanceRun[]; installations: Installation[] } | null
  maintenance: MaintenanceWindows | null
  security: SecurityPosture | null
  databases: { database_count: number; databases: Database[] } | null
  jobs: { jobs: OrchestrationJob[]; failed_count: number } | null
}

export interface Health {
  status: string
  version: string
  write_actions_enabled: boolean
  perf_snapshot_enabled: boolean
  chat_configured: boolean
  snapshot_cached: boolean
  scope: Record<string, string[]>
}

export interface ActionResult {
  executed?: boolean | null
  success?: boolean | null
  message?: string | null
  next_step?: string | null
  operation_url?: string | null
  reason?: string
  blockers?: string[]
  warnings?: string[]
  can_proceed?: boolean
  [key: string]: unknown
}

export type ChatEvent =
  | { type: 'session'; id: string }
  | { type: 'tool'; name: string }
  | { type: 'text'; delta: string }
  | { type: 'done'; seconds: number }
  | { type: 'error'; message: string }
