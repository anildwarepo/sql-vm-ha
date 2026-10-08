"""API tests with fake services (no Azure access needed).  Run: .venv\\Scripts\\python.exe -m pytest -q"""

from __future__ import annotations

import json
import threading
import time
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from sqlha.arm import ArmError

from app.main import create_app
from app.services.chat_service import ChatService
from app.services.dashboard_service import DashboardService
from app.services.sql_service import SqlManagementService
from app.settings import Settings

HDR = {"X-SQLHA-Client": "ui"}

SNAPSHOT = {
    "generated_at": "2026-10-06T14:00:00+00:00",
    "scope": {"subscriptions": ["sub"], "resource_groups": ["rg"]},
    "errors": {"security": "AuthorizationFailed"},
    "kpis": {"overall": "warning", "findings_by_severity": {"high": 1}, "instances_total": 2, "instances_connected": 2,
             "ag_total": 1, "ag_healthy": 1, "outstanding_patches": 0, "security_patches": 0, "next_window": None,
             "last_run": None, "defender_unhealthy": 0},
    "findings": [{"severity": "high", "category": "maintenance", "title": "AG waves are 0 min apart",
                  "detail": "x", "resource": "ag1", "recommendation": None}],
    "inventory": {"instance_count": 1, "connected_count": 1, "other_sql_services": [], "instances": [
        {"name": "N1", "id": "/x/N1", "machine": "N1", "vcores": "4", "build": "16.0.4255.1",
         "availability_groups": ["ag1"], "host": {"status": "Connected", "cloud": "AWS", "memory_gb": "16", "tags": {}}}]},
    "availability_groups": {"availability_group_count": 1, "availability_groups": [
        {"name": "ag1", "primary_replica": "N1", "healthy": True,
         "nodes": [{"instance": "N1", "role": "PRIMARY", "healthy": True, "failover_ready": False}],
         "replicas": [{"replica": "N1", "role": "PRIMARY"}],
         "databases": [{"database": "db1", "replicas": [{"replica": "N1", "sync_state": "SYNCHRONIZED"}]}]}]},
    "patching": {"machine_count": 1, "outstanding_total": 0, "security_or_critical_total": 0, "machines": [
        {"machine": "N1", "machine_id": "/x/n1", "outstanding": [], "sql_server_updates": [], "last_installation": None}]},
    "history": {"days": 30, "maintenance_runs": [{"maintenance_configuration": "mc-1", "status": "Cancelled"}],
                "installations": []},
    "maintenance": {"configurations": [{"id": "/x/mc-1", "name": "mc-1", "next_windows": [
        {"start_utc": "2026-10-06T21:30:00+00:00", "end_utc": "2026-10-06T23:30:00+00:00", "in_progress": False}]}],
        "machines": [{"machine": "N1", "assignments": [], "next_window": None}], "risks": []},
    "security": None,
    "databases": {"database_count": 1, "databases": [{"instance": "N1", "name": "db1", "system": False}]},
    "jobs": {"jobs": [{"runbook": "Pre-SqlAgFailover", "status": "Completed"}], "failed_count": 0},
}


class FakeSql(SqlManagementService):
    write_actions_enabled = False
    perf_snapshot_enabled = True

    def __init__(self):
        self.calls = []

    def scope(self):
        return {"subscriptions": ["sub"], "resource_groups": ["rg"]}

    def inventory(self):
        return SNAPSHOT["inventory"]

    def availability_groups(self, live=True):
        self.calls.append(("ags", live))
        return SNAPSHOT["availability_groups"]

    def plan_patch_install(self, machine):
        raise ValueError(f"Arc machine '{machine}' was not found in the configured scope.")

    def maintenance_windows(self, count=4):
        raise ArmError(500, "InternalServerError")

    def failover(self, target_instance, ag_name, confirm):
        self.calls.append(("failover", target_instance, ag_name, confirm))
        if confirm:
            raise PermissionError("Write actions are disabled.")
        return {"executed": False, "success": None, "next_step": "Call again with confirm=true.", "state": {}}

    def resource_graph(self, query, max_rows=200):
        return {"row_count": 1, "rows": [{"name": "N1"}]}


class FakeUpdate:
    def __init__(self, text="", contents=None):
        self.text, self.contents = text, contents or []


class FakeAgent:
    def __init__(self):
        self.prompts = []

    def create_session(self, session_id):
        return SimpleNamespace(id=session_id)

    async def run(self, prompt, stream, session):
        self.prompts.append((prompt, session.id))
        yield FakeUpdate(contents=[SimpleNamespace(type="function_call", name="sqlha_get_overview")])
        yield FakeUpdate("All ")
        yield FakeUpdate("good.")


@pytest.fixture
def env(monkeypatch):
    monkeypatch.setenv("FOUNDRY_PROJECT_ENDPOINT", "https://x/api/projects/p")
    monkeypatch.setenv("AZURE_AI_MODEL_DEPLOYMENT_NAME", "m")


@pytest.fixture
def ctx(env, tmp_path):
    agent = FakeAgent()
    sql = FakeSql()
    settings = Settings(allowed_hosts=["testserver", "127.0.0.1"], cors_origins=["http://localhost:5173"],
                        ui_dist=tmp_path / "missing")
    app = create_app(settings, sql_service=sql, dashboard_service=DashboardService(lambda: dict(SNAPSHOT)),
                     chat_service=ChatService(agent_factory=lambda: agent), prewarm=False)
    return SimpleNamespace(client=TestClient(app), sql=sql, agent=agent)


def sse(text):
    return [json.loads(line[6:]) for line in text.split("\n\n") if line.startswith("data: ")]


# ------------------------------------------------------------------ health, openapi, middleware

def test_health(ctx):
    body = ctx.client.get("/api/health").json()
    assert body["status"] == "ok" and body["chat_configured"] is True and body["write_actions_enabled"] is False


def test_openapi_documents_every_area_and_client_header(ctx):
    spec = ctx.client.get("/openapi.json").json()
    tags = {t for p in spec["paths"].values() for op in p.values() for t in op.get("tags", [])}
    assert {"Health", "SQL management", "SQL actions", "Dashboard (UI)", "Chat"} <= tags
    assert "ClientHeader" in spec["components"]["securitySchemes"]
    assert ctx.client.get("/docs").status_code == 200


def test_untrusted_host_is_rejected(ctx):
    assert ctx.client.get("/api/health", headers={"Host": "evil.example"}).status_code == 400


def test_cors_allows_only_configured_origin(ctx):
    pre = {"Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "x-sqlha-client,content-type"}
    ok = ctx.client.options("/api/chat/messages", headers={"Origin": "http://localhost:5173", **pre})
    bad = ctx.client.options("/api/chat/messages", headers={"Origin": "https://evil.example", **pre})
    assert ok.headers.get("access-control-allow-origin") == "http://localhost:5173"
    assert "access-control-allow-origin" not in bad.headers


# ------------------------------------------------------------------ SQL management + errors

def test_sql_read_passes_query_params(ctx):
    r = ctx.client.get("/api/sql/availability-groups?live=false")
    assert r.status_code == 200 and r.json()["availability_groups"][0]["name"] == "ag1"
    assert ("ags", False) in ctx.sql.calls


def test_error_mapping(ctx):
    nf = ctx.client.get("/api/sql/patching/plan/NOPE")
    assert nf.status_code == 404 and nf.json()["error"]["code"] == "not_found"
    up = ctx.client.get("/api/sql/maintenance-windows")
    assert up.status_code == 502 and up.json()["error"]["upstream_status"] == 500
    bad = ctx.client.get("/api/sql/patching/history?days=0")
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "validation_error"


def test_post_requires_client_header(ctx):
    r = ctx.client.post("/api/sql/resource-graph", json={"query": "resources"})
    assert r.status_code == 403 and r.json()["error"]["code"] == "forbidden"
    assert ctx.client.post("/api/sql/resource-graph", json={"query": "resources"}, headers=HDR).json()["row_count"] == 1


def test_action_preview_and_disabled_write(ctx):
    prev = ctx.client.post("/api/sql/actions/failover", json={"target_instance": "N2"}, headers=HDR)
    assert prev.status_code == 200 and prev.json()["executed"] is False and "next_step" in prev.json()
    run = ctx.client.post("/api/sql/actions/failover", json={"target_instance": "N2", "confirm": True}, headers=HDR)
    assert run.status_code == 403 and run.json()["error"]["code"] == "write_actions_disabled"
    assert ("failover", "N2", None, True) in ctx.sql.calls


# ------------------------------------------------------------------ dashboard

def test_snapshot_validates_and_refresh(ctx):
    snap = ctx.client.get("/api/dashboard/snapshot").json()
    assert snap["kpis"]["overall"] == "warning" and snap["security"] is None
    assert snap["inventory"]["instances"][0]["vcores"] == "4"  # Azure string values pass through
    assert ctx.client.post("/api/dashboard/refresh").status_code == 403
    r = ctx.client.post("/api/dashboard/refresh", headers=HDR).json()
    assert r["generated_at"] == SNAPSHOT["generated_at"] and r["section_errors"] == {"security": "AuthorizationFailed"}


def test_dashboard_refresh_is_single_flight():
    calls = []

    def slow():
        calls.append(1)
        time.sleep(0.1)
        return {"n": len(calls)}

    svc = DashboardService(slow)
    barrier = threading.Barrier(5)

    def worker():
        barrier.wait()
        svc.refresh()

    threads = [threading.Thread(target=worker) for _ in range(5)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert len(calls) <= 2  # the first collection plus at most one that started before it finished


# ------------------------------------------------------------------ chat

def test_chat_streams_events_and_keeps_session(ctx):
    r = ctx.client.post("/api/chat/messages", json={"message": "status?", "context": "tab=alwayson"}, headers=HDR)
    events = sse(r.text)
    assert r.headers["content-type"].startswith("text/event-stream")
    assert [e["type"] for e in events] == ["session", "tool", "text", "text", "done"]
    sid = events[0]["id"]
    assert "".join(e["delta"] for e in events if e["type"] == "text") == "All good."
    assert ctx.agent.prompts[0] == ("[Dashboard context: tab=alwayson]\nstatus?", sid)
    ctx.client.post("/api/chat/messages", json={"message": "and now?", "session_id": sid}, headers=HDR)
    assert ctx.agent.prompts[1] == ("and now?", sid)
    assert ctx.client.get("/api/chat/status").json()["active_sessions"] == 1
    assert ctx.client.delete(f"/api/chat/sessions/{sid}", headers=HDR).status_code == 204


def test_chat_validation_and_unconfigured(ctx, monkeypatch):
    assert ctx.client.post("/api/chat/messages", json={"message": ""}, headers=HDR).status_code == 422
    assert ctx.client.post("/api/chat/messages", json={"message": "x" * 5000}, headers=HDR).status_code == 422
    assert ctx.client.post("/api/chat/messages", json={"message": "hi", "session_id": "../x"},
                           headers=HDR).status_code == 422
    monkeypatch.delenv("FOUNDRY_PROJECT_ENDPOINT")
    events = sse(ctx.client.post("/api/chat/messages", json={"message": "hi"}, headers=HDR).text)
    assert events[-1]["type"] == "error" and "FOUNDRY_PROJECT_ENDPOINT" in events[-1]["message"]
