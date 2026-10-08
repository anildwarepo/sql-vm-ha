# SQL Control Plane

Monitoring and AG-safe patching for SQL Server Always On availability groups that run on AWS (or anywhere else)
and are managed from Azure through **SQL Server enabled by Azure Arc**, **Azure Update Manager** and **Microsoft
Defender for Cloud**. It answers questions about patching, outstanding updates, maintenance windows, security risks,
Always On status, performance and instance metadata, and it can patch nodes and fail over the AG safely.

Everything runs on one shared Python core, `sqlha`:

| Surface | Where | How it reaches Azure |
|---------|-------|----------------------|
| **Control plane UI** (React) | [frontend/](frontend) → http://127.0.0.1:5173 | Calls the backend API |
| **Control plane API** (FastAPI + Swagger) | [backend/](backend) → http://127.0.0.1:8000/docs | `sqlha` core with your `az login` |
| VS Code custom agent `sql-ha-agent` | [../.github/agents/sql-ha-agent.agent.md](../.github/agents/sql-ha-agent.agent.md) | Local MCP server `sqlha` ([../.vscode/mcp.json](../.vscode/mcp.json)) |
| Foundry hosted agent `sql-ha-agent` | [src/sql-ha-agent/](src/sql-ha-agent) (`azd`) | Function tools in-process, with the agent's managed identity |

```text
sql-controlplane/
  run_all.py                 Starts backend + UI (dev), or one port with --prod
  .env / .env.example        Shared settings (git-ignored .env)
  core/                      sqlha-core package: the shared library
    sqlha/arm.py               ARM + Resource Graph client (DefaultAzureCredential, retries, shared session)
    sqlha/service.py           Inventory, Always On, patching, maintenance, security, perf, actions
    sqlha/schedule.py          Maintenance-window recurrence math (DST-aware)
    sqlha/tools.py             Tool registry shared by the MCP server and the agents
    sqlha/agent.py             Agent Framework agent factory (hosted agent + backend chat)
    sqlha/mcp_server.py        stdio MCP server for VS Code
    tests/                     Unit tests (no Azure access needed)
  backend/                   FastAPI app
    app/main.py                App factory: middleware, routers, OpenAPI, static UI in --prod
    app/settings.py            Settings from env / .env
    app/errors.py              Uniform JSON error envelope
    app/schemas/               Pydantic response models (drive Swagger)
    app/services/              SqlManagementService, DashboardService (cached snapshot), ChatService (agent sessions)
    app/api/routes/            health, sql, actions, dashboard, chat
    tests/                     API tests with fake services
  frontend/                  React 19 + TypeScript + Vite
    src/api/                   Typed API client + SSE chat stream
    src/components/            common/ layout/ ag/ maintenance/ chat/ drawers/
    src/views/                 One view per tab
    src/hooks/, src/context/   Snapshot loading, hash routing, dashboard context
  src/sql-ha-agent/          Foundry hosted agent (main.py); sqlha/ and skills/ are synced in, not committed
  scripts/sync-agent.ps1     Copies core/sqlha and ../.github/skills into the hosted agent (azd predeploy)
  azure.yaml                 azd project for the hosted agent
```

## Run the control plane

Prerequisites: Python 3.11+, [uv](https://docs.astral.sh/uv/), Node.js 20+, and `az login`.

```powershell
cd sql-controlplane
python run_all.py              # API on :8000 (Swagger /docs) + UI with hot reload on :5173, opens the browser
python run_all.py --prod       # build the UI and serve UI + API from :8000
python run_all.py --api-only   # API only
# options: --api-port <n>  --ui-port <n>  --no-browser  --skip-install
```

On first run, `run_all.py` installs missing dependencies (`uv sync` in `backend/`, `npm install` in `frontend/`).
On Microsoft-managed devices PyPI is reachable only through the CFS proxy, so set
`$env:UV_DEFAULT_INDEX='https://packagefeedproxy.microsoft.io/pypi/simple/'` first. Ctrl+C stops both processes.
VS Code tasks: **Run SQL control plane** and **Run SQL control plane (single port)**.

### UI

- KPI cards, then tabs: Overview, Always On, Patching, Maintenance, Security, Instances, Databases, Runbook jobs.
- Click any node, replica or "Details ›" to open the node drawer (host, AG role, patching, maintenance, findings,
  Defender items, databases). The drawer's **Actions** section runs Patch preflight, Run assessment, Install patches
  and Fail over. Each write shows a preview first and runs only after **Confirm**.
- **💬 Ask** opens a chat panel backed by the sql-ha agent with read-only tools. It knows the current tab and node.
- Global search (`/`), dark/light theme, deep links (`#tab=patching&node=SQL-VM-1`), **⟳ Refresh** to re-collect.

### API

Swagger UI: http://127.0.0.1:8000/docs · OpenAPI: http://127.0.0.1:8000/openapi.json · ReDoc: `/redoc`

| Group | Endpoints |
|-------|-----------|
| Health | `GET /api/health` |
| SQL management | `GET /api/sql/overview`, `instances`, `availability-groups?live=`, `patching?machine=`, `patching/history?days=`, `patching/plan/{machine}`, `maintenance-windows?count=`, `security?severity=&machine=`, `databases?instance=&include_system=`, `jobs`, `jobs/{job_name}/output`, `performance?machine=`, `operations?url=`; `POST /api/sql/resource-graph` |
| SQL actions | `POST /api/sql/actions/machines/{machine}/assessment`, `…/periodic-assessment`, `…/install-patches`; `POST /api/sql/actions/failover` |
| Dashboard (UI) | `GET /api/dashboard/snapshot`, `POST /api/dashboard/refresh` |
| Chat | `GET /api/chat/status`, `POST /api/chat/messages` (server-sent events), `DELETE /api/chat/sessions/{id}` |

Errors use one envelope: `{"error": {"code", "message", ...}}` (404 unknown machine/job, 403 permission or write
disabled, 422 validation, 502 upstream Azure failure).

Security model for the local API:
- Binds to 127.0.0.1, and `TrustedHostMiddleware` blocks DNS-rebinding.
- CORS allows only the Vite dev origin.
- Every `POST`/`DELETE` needs an `X-SQLHA-Client` header. This forces a CORS preflight, so other websites can't
  trigger actions (CSRF).
- `operations?url=` accepts only `https://management.azure.com` URLs.
- Writes need `SQLHA_ENABLE_WRITE_ACTIONS=true` plus `confirm=true`, and the core's AG safety rules still apply.

## Tools (MCP server and agents)

| Tool | Kind | Purpose |
|------|------|---------|
| `sqlha_get_overview` | read | KPIs and prioritized findings across all areas |
| `sqlha_get_inventory` | read | Instances, builds, license, host, cloud, Arc agent, AG membership |
| `sqlha_get_availability_groups` | read | Live AG roles, sync health, DB sync matrix, failover readiness |
| `sqlha_get_patch_compliance` | read | Outstanding updates per host (MSRC, SQL CU/GDR, age), assessment age |
| `sqlha_get_patch_history` | read | Maintenance runs per wave (Cancelled/Failed + reason) and installations |
| `sqlha_get_maintenance_windows` | read | Schedules, next windows (local + UTC), overlapping or missing waves |
| `sqlha_get_security_posture` | read | Defender recommendations and alerts, missing security updates, TDE, endpoint encryption |
| `sqlha_get_databases` | read | Database state, recovery model, size, TDE, backups |
| `sqlha_get_orchestration_jobs`, `sqlha_get_job_output` | read | Pre-SqlAgFailover / Post-SqlAgValidate runs and logs |
| `sqlha_plan_patch_install` | read | AG-safety preflight for patching a node now |
| `sqlha_get_performance_snapshot` | read (runs a read-only script on the host) | Live CPU, memory/PLE, throughput, sessions/blocking, top waits, IO latency, free space, AG send/redo queues via Arc Run Command (~20-40 s) |
| `sqlha_query_resource_graph` | read | Read-only KQL for anything else |
| `sqlha_get_operation_status` | read | Poll an assessment or install |
| `sqlha_get_control_plane` | read (MCP only) | Whether the control plane is running, plus its UI / API / Swagger URLs |
| `sqlha_trigger_patch_assessment`, `sqlha_enable_periodic_assessment` | write (safe) | Scan only / assess every 24h |
| `sqlha_install_patches` | write (disruptive) | AG-safe one-node install via Update Manager (`failover_first` option) |
| `sqlha_failover_availability_group` | write (disruptive) | Planned no-data-loss failover/failback via the Arc AG API |

Write tools have three safety layers:
1. They do nothing unless `SQLHA_ENABLE_WRITE_ACTIONS=true`.
2. They only preview unless called with `confirm=true`, which the instructions allow only after explicit user approval.
3. They refuse unsafe actions. Patching the primary, patching while the partner is unhealthy or already
   patching, and failing over to a replica that isn't failover-ready are all blocked. These health rules match the
   [patching runbooks](../scripts/patching/README.md).

## Configuration

All local surfaces (backend, MCP server) read `sql-controlplane/.env` (git-ignored, see `.env.example`). Real
environment variables take precedence.

| Variable | Default | Meaning |
|----------|---------|---------|
| `SQLHA_SUBSCRIPTION_IDS` | all readable | Comma-separated subscription scope |
| `SQLHA_RESOURCE_GROUPS` | all | Comma-separated resource group filter (Arc resources) |
| `SQLHA_ENABLE_WRITE_ACTIONS` | `false` | Allow assessment, install, failover |
| `SQLHA_ENABLE_PERF_SNAPSHOT` | `true` | Allow performance snapshots (Arc Run Command on the hosts) |
| `FOUNDRY_PROJECT_ENDPOINT`, `AZURE_AI_MODEL_DEPLOYMENT_NAME` | – | Foundry project and model for the chat panel / hosted agent |
| `SQLHA_WRITE_APPROVAL_MODE` | `never_require` | Hosted agent: `always_require` asks the Foundry client to approve write tool calls |
| `SQLHA_API_HOST`, `SQLHA_API_PORT` | `127.0.0.1`, `8000` | Backend bind address |
| `SQLHA_CORS_ORIGINS` | Vite origins on :5173 | Allowed browser origins (set by `run_all.py`) |
| `SQLHA_ALLOWED_HOSTS` | `127.0.0.1,localhost` | Accepted `Host` headers |
| `SQLHA_UI_DIST` | `frontend/dist` | Built UI served by the backend at `/` when present |
| `SQLHA_CONTROLPLANE_API` | `http://127.0.0.1:8000` | Where `sqlha_get_control_plane` looks for the backend |

## Use it in VS Code

1. Run the control plane once, or `uv sync` in `backend/`, to create `backend/.venv`. The `sqlha` MCP server in
   `.vscode/mcp.json` runs from that venv.
2. `az login`, then start the `sqlha` server (MCP: List Servers → sqlha → Start).
3. In Copilot Chat, pick the **sql-ha-agent** agent and ask, for example:
   - "Status report" / "What needs attention?"
   - "Is the AG healthy? Who is primary?"
   - "What patches are outstanding on SQL-VM-1? Which SQL CU is pending?"
   - "When is the next maintenance window for each node?"
   - "How is SQL performance right now?"
   - "Open the dashboard"
   - "Patch SQL-VM-2 now with the security updates" (preview → approve → execute)

## Foundry hosted agent

The hosted agent ships its own copy of the core. `scripts/sync-agent.ps1` copies `core/sqlha` and the skills into
`src/sql-ha-agent/`; it runs as the azd predeploy hook and before the F5 tasks. Its dependencies are listed directly
in `src/sql-ha-agent/pyproject.toml`, because the remote build can't install path dependencies.

- **Local:** press **F5** ("Debug Local Agent/Workflow HTTP Server") to sync, start the agent under the debugger and
  open the Agent Inspector. Or run `pwsh scripts/sync-agent.ps1`, then `azd ai agent run --no-client` and
  `azd ai agent invoke --local "status report"`.
- **Deploy:** run `azd deploy` from `sql-controlplane/`.

Before deploying:
1. **Regenerate `src/sql-ha-agent/uv.lock` against public PyPI.** The local lock was generated through the CFS
   proxy (`packagefeedproxy.microsoft.io`), which the Foundry remote build can't reach. Run `uv lock` from a machine
   or CI runner with public PyPI access (for example Cloud Shell or GitHub Actions) and commit the result.
2. **Grant the agent's managed identity access** to the Arc resources:
   - *Reader* on `rg-dxc-test-sql-vm-ha-arc`: inventory, patches, maintenance and Automation jobs.
     Reading job output (`sqlha_get_job_output`) also needs *Automation Job Operator*.
   - *Security Reader* on the subscription: Defender data.
   - *Azure Connected Machine Resource Administrator*, or a custom role with
     `Microsoft.HybridCompute/machines/runCommands/*`: needed for performance snapshots (unless
     `SQLHA_ENABLE_PERF_SNAPSHOT=false`), and for assessments and installs if you enable writes.
   - *Contributor* on the Arc SQL instances: only if you enable writes. It covers AG failover.

## Tests and builds

```powershell
cd sql-controlplane\backend
.venv\Scripts\python.exe -m pytest -q                       # API tests
.venv\Scripts\python.exe -m pytest -q ..\core\tests         # core tests
cd ..\frontend
npm run build                                               # typecheck + production build
```

Known advisory: `source-map-js` < 1.2.2 (GHSA-68fv-2mgg-jv7q, DoS) comes in through Vite's dev tooling only, not
the shipped UI. Run `npm update source-map-js` once 1.2.2 passes the package feed's 7-day hold.
