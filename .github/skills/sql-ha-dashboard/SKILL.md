---
name: sql-ha-dashboard
description: Open the SQL Control Plane - a React dashboard with a FastAPI backend for the Arc-managed SQL Server Always On estate - KPIs, AG topology and database sync matrix, outstanding patches and patch history, maintenance-window timeline, Defender security findings, instances, databases and patching runbook jobs, with click-through drill-down per node, node actions (preflight, assess, patch, fail over) and a chat panel. Use when the user asks for a "dashboard", "report", "visual", "single pane of glass", "control plane", "UI", "API" or "show me everything" (VS Code only).
---

# SQL Control Plane (dashboard)

The dashboard is the **SQL Control Plane** in `sql-controlplane/`:

| Part | Where | What |
|------|-------|------|
| React UI | http://127.0.0.1:5173 (dev) | Tabs, drill-down drawers, node actions, chat panel |
| FastAPI backend | http://127.0.0.1:8000/api | SQL management, actions, dashboard snapshot, chat (SSE) |
| Swagger | http://127.0.0.1:8000/docs | Interactive API docs (OpenAPI at `/openapi.json`) |

Both use the shared `sqlha` core, the same library behind the MCP tools, so the numbers match chat answers.

## Open it

1. Call `sqlha_get_control_plane()`. It reports `running`, `ui_url`, `api_url`, `swagger_url` and, when the backend
   is down, `start_command`.
2. If it's running, open `ui_url` in the VS Code integrated browser (`openBrowserPage`). Mention `swagger_url` for API users.
3. If it isn't running, start it in a background terminal from the repository root and wait for `Ctrl+C to stop`:

   ```powershell
   python sql-controlplane/run_all.py              # UI :5173 (hot reload) + API :8000
   python sql-controlplane/run_all.py --prod       # build the UI, serve UI + API on :8000 only
   python sql-controlplane/run_all.py --api-only   # just the API / Swagger
   # options: --api-port <n>  --ui-port <n>  --no-browser  --skip-install
   ```

   Or run the VS Code task **Run SQL control plane**. First run installs dependencies (`uv sync`, `npm install`).
   Then call `sqlha_get_control_plane()` again and open the UI.
4. In chat, summarize the headline from `sqlha_get_overview`: overall status, critical/high counts, next maintenance
   window, and any section errors.

Scope and credentials come from `sql-controlplane/.env` (`SQLHA_SUBSCRIPTION_IDS`, `SQLHA_RESOURCE_GROUPS`,
`FOUNDRY_PROJECT_ENDPOINT`, `AZURE_AI_MODEL_DEPLOYMENT_NAME`, `SQLHA_ENABLE_WRITE_ACTIONS`). The backend uses your
Azure CLI login (`az login`).

## Refreshing

- The header shows how old the data is. **⟳ Refresh** re-collects everything from Azure (about 5-10 s) through
  `POST /api/dashboard/refresh`; concurrent refreshes share one collection.
- When the user asks to "refresh the dashboard" and the control plane is running, tell them to click ⟳ Refresh.
- After a failover, patch or schedule change made from chat, suggest a refresh.

## Node actions

Open a node (click it in the topology or "Details ›" in a table). The drawer's **Actions** section offers
Patch preflight, Run assessment, Install patches (fails over first when the node is primary) and Fail over here
(on a secondary). Every write shows a preview first and only runs after **Confirm**. Writes need
`SQLHA_ENABLE_WRITE_ACTIONS=true`; the same AG safety checks as `sqlha_install_patches` and
`sqlha_failover_availability_group` apply.

## Chat panel

**💬 Ask** opens a panel backed by the sql-ha agent (the Foundry model in `sql-controlplane/.env`) with **read-only
tools**, including the live performance snapshot. Answers stream in with chips showing which tools ran. The agent
knows the current tab and node, and **New chat** starts over. API: `POST /api/chat/messages` (server-sent events).

## What's in it (for answering "where do I find…")

| Area | Content | Drill-down |
|------|---------|------------|
| KPI cards | Instances connected, AG health, outstanding/security patches, next window, last run, Defender findings, total findings | Click a card to open its tab |
| Overview | AG topology (primary/secondary, sync link, build, host cloud), maintenance timeline, findings | Click a node for the node drawer, or a finding for detail + recommendation |
| Always On | Topology, replica table, database × replica sync matrix, AG settings | Click a replica for its node drawer |
| Patching | Compliance per host (expand for KBs), all outstanding updates (classification / SQL-only filters), maintenance runs, installations | Row expand; "Details ›" opens the node drawer |
| Maintenance | 48 h / 7 d / 28 d wave timeline, scheduling risks, schedules (expand for windows, classifications, excluded KBs), host assignments | Row expand / node drawer |
| Security | Severity bar, active alerts, unhealthy recommendations (severity/host filters, expand for remediation), missing security updates, instance controls | Row expand / node drawer |
| Instances / Databases / Runbook jobs | Sortable, searchable tables | Click an instance for its node drawer |

Global search (`/`), dark/light theme, and an **API** link to Swagger. Deep links such as
`http://127.0.0.1:5173/#tab=patching&node=SQL-VM-1` open a tab and a node drawer directly.

## API quick reference

| Endpoint | Purpose |
|----------|---------|
| `GET /api/health` | Status, scope, chat/write configuration |
| `GET /api/sql/overview`, `/instances`, `/availability-groups?live=`, `/databases` | Estate, AGs, databases |
| `GET /api/sql/patching`, `/patching/history?days=`, `/patching/plan/{machine}` | Compliance, history, AG-safe preflight |
| `GET /api/sql/maintenance-windows`, `/security`, `/performance?machine=`, `/jobs` | Schedules, Defender, live perf, runbooks |
| `POST /api/sql/actions/machines/{m}/assessment` · `/install-patches` · `POST /api/sql/actions/failover` | Writes (need the `X-SQLHA-Client` header and `confirm=true`) |
| `GET /api/dashboard/snapshot` · `POST /api/dashboard/refresh` | Cached UI snapshot |

The backend listens on 127.0.0.1 only. It contains resource names and findings, so treat it as internal.
