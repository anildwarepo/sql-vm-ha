"""Unit tests for schedule math, AG health evaluation and findings (no Azure access needed).

Run: .venv\\Scripts\\python.exe -m unittest discover -s tests -v
"""

import os
import sys
import time
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlha import schedule, service  # noqa: E402

UTC = timezone.utc


class ScheduleTests(unittest.TestCase):
    def test_weekly_saturday_pacific_dst(self):
        now = datetime(2026, 10, 5, 20, 0, tzinfo=UTC)  # Monday 13:00 PDT
        w = schedule.next_windows("2026-09-25 04:30", "Week Saturday", "02:00", "Pacific Standard Time", 2, now)
        self.assertEqual(w[0]["start_local"], "2026-10-10T04:30:00-07:00")
        self.assertEqual(w[0]["start_utc"], "2026-10-10T11:30:00+00:00")
        self.assertEqual(w[0]["end_utc"], "2026-10-10T13:30:00+00:00")
        self.assertEqual(w[1]["start_local"], "2026-10-17T04:30:00-07:00")

    def test_dst_end_shifts_utc(self):
        now = datetime(2026, 10, 30, 0, 0, tzinfo=UTC)
        w = schedule.next_windows("2026-09-25 04:30", "Week Saturday", "02:00", "Pacific Standard Time", 2, now)
        self.assertEqual(w[0]["start_utc"], "2026-10-31T11:30:00+00:00")  # still PDT
        self.assertEqual(w[1]["start_utc"], "2026-11-07T12:30:00+00:00")  # PST after Nov 1

    def test_daily_and_in_progress(self):
        now = datetime(2026, 10, 5, 22, 0, tzinfo=UTC)  # 15:00 PDT, inside 14:30-16:30
        w = schedule.next_windows("2026-10-05 14:30", "1Day", "02:00", "Pacific Standard Time", 2, now)
        self.assertTrue(w[0]["in_progress"])
        self.assertEqual(w[1]["start_local"], "2026-10-06T14:30:00-07:00")

    def test_every_two_weeks_multiple_days(self):
        now = datetime(2026, 1, 1, tzinfo=UTC)
        w = schedule.next_windows("2026-01-03 01:00", "2Weeks Saturday,Sunday", "01:00", "UTC", 4, now)
        self.assertEqual([x["start_local"][:10] for x in w], ["2026-01-03", "2026-01-04", "2026-01-17", "2026-01-18"])

    def test_month_second_saturday(self):
        now = datetime(2026, 10, 1, tzinfo=UTC)
        w = schedule.next_windows("2026-09-01 01:00", "Month Second Saturday", "03:00", "UTC", 3, now)
        self.assertEqual([x["start_local"][:10] for x in w], ["2026-10-10", "2026-11-14", "2026-12-12"])

    def test_month_last_sunday_offset(self):
        now = datetime(2026, 10, 1, tzinfo=UTC)
        w = schedule.next_windows("2026-09-01 01:00", "Month Last Sunday Offset-3", "01:00", "UTC", 2, now)
        self.assertEqual([x["start_local"][:10] for x in w], ["2026-10-22", "2026-11-26"])  # Thu before last Sunday

    def test_month_days_and_last_day(self):
        now = datetime(2026, 2, 1, tzinfo=UTC)
        w = schedule.next_windows("2026-01-01 00:00", "Month day15,day-1", "01:00", "UTC", 3, now)
        self.assertEqual([x["start_local"][:10] for x in w], ["2026-02-15", "2026-02-28", "2026-03-15"])

    def test_expiration(self):
        now = datetime(2026, 10, 1, tzinfo=UTC)
        w = schedule.next_windows("2026-09-01 01:00", "Day", "01:00", "UTC", 5, now, expiration="2026-10-02 23:59")
        self.assertEqual(len(w), 2)

    def test_duration_formats(self):
        self.assertEqual(schedule.parse_duration("03:55"), timedelta(hours=3, minutes=55))
        self.assertEqual(schedule.parse_duration("PT1H30M"), timedelta(hours=1, minutes=30))


def _view(local, replicas, dbs, collected):
    return {"properties": {"serverName": local, "collectionTimestamp": collected,
                           "replicas": {"value": replicas}, "databases": {"value": dbs}, "info": {}}}


def _rep(name, role, mode="SYNCHRONOUS_COMMIT", connected="CONNECTED", health="HEALTHY"):
    return {"replicaName": name, "configure": {"availabilityModeDescription": mode},
            "state": {"availabilityGroupReplicaRole": role, "connectedStateDescription": connected,
                      "synchronizationHealthDescription": health}}


def _db(name, replica, local, state="SYNCHRONIZED", suspended=None):
    return {"databaseName": name, "replicaName": replica, "isLocal": local,
            "synchronizationStateDescription": state, "isSuspended": suspended}


class AgEvaluationTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.now(UTC)
        self.fresh = self.now.isoformat()
        self.requested = self.now - timedelta(seconds=60)

    def test_healthy_secondary_is_failover_ready(self):
        v = _view("SQL-VM-2", [_rep("SQL-VM-2", "SECONDARY")], [_db("A", "SQL-VM-2", True)], self.fresh)
        ev = service._evaluate_view(v, self.requested)["evaluation"]
        self.assertTrue(ev["healthy"])
        self.assertTrue(ev["failover_ready"])

    def test_primary_is_never_failover_ready(self):
        v = _view("SQL-VM-1", [_rep("SQL-VM-1", "PRIMARY"), _rep("SQL-VM-2", "SECONDARY")],
                  [_db("A", "SQL-VM-1", True), _db("A", "SQL-VM-2", False)], self.fresh)
        ev = service._evaluate_view(v, self.requested)["evaluation"]
        self.assertTrue(ev["healthy"])
        self.assertFalse(ev["failover_ready"])

    def test_stale_data(self):
        old = (self.now - timedelta(minutes=10)).isoformat()
        v = _view("SQL-VM-2", [_rep("SQL-VM-2", "SECONDARY")], [_db("A", "SQL-VM-2", True)], old)
        ev = service._evaluate_view(v, self.requested)["evaluation"]
        self.assertFalse(ev["healthy"])
        self.assertIn("stale", ev["message"])

    def test_sync_secondary_synchronizing_is_unhealthy(self):
        v = _view("SQL-VM-2", [_rep("SQL-VM-2", "SECONDARY")], [_db("A", "SQL-VM-2", True, "SYNCHRONIZING")], self.fresh)
        ev = service._evaluate_view(v, self.requested)["evaluation"]
        self.assertFalse(ev["healthy"])
        self.assertFalse(ev["failover_ready"])

    def test_async_secondary_synchronizing_is_healthy_but_not_failover_ready(self):
        v = _view("DR", [_rep("DR", "SECONDARY", "ASYNCHRONOUS_COMMIT")], [_db("A", "DR", True, "SYNCHRONIZING")], self.fresh)
        ev = service._evaluate_view(v, self.requested)["evaluation"]
        self.assertTrue(ev["healthy"])
        self.assertFalse(ev["failover_ready"])

    def test_primary_with_disconnected_replica(self):
        v = _view("SQL-VM-1", [_rep("SQL-VM-1", "PRIMARY"), _rep("SQL-VM-2", "SECONDARY", connected="DISCONNECTED")],
                  [_db("A", "SQL-VM-1", True), _db("A", "SQL-VM-2", False)], self.fresh)
        ev = service._evaluate_view(v, self.requested)["evaluation"]
        self.assertFalse(ev["healthy"])

    def test_suspended_database(self):
        v = _view("SQL-VM-2", [_rep("SQL-VM-2", "SECONDARY")], [_db("A", "SQL-VM-2", True, suspended=True)], self.fresh)
        self.assertFalse(service._evaluate_view(v, self.requested)["evaluation"]["healthy"])


class RiskTests(unittest.TestCase):
    def _cfg(self, name, target, partner, start_utc, hours=2):
        s = datetime.fromisoformat(start_utc)
        w = {"start_utc": s.isoformat(), "end_utc": (s + timedelta(hours=hours)).isoformat(), "start_local": s.isoformat()}
        return {"id": f"/x/{name}", "name": name, "ag_aware": True, "ag_name": "ag1", "target_node": target,
                "partner_node": partner, "recur_every": "Week Saturday", "start": "2026-01-01 01:00", "next_windows": [w]}

    def test_overlapping_waves_reported_once(self):
        a = self._cfg("mc-1", "N1", "N2", "2026-10-10T08:00:00+00:00")
        b = self._cfg("mc-2", "N2", "N1", "2026-10-10T09:00:00+00:00")
        machines = [{"machine": "N1", "assignments": [{"configuration": "mc-1", "kind": "static"}]},
                    {"machine": "N2", "assignments": [{"configuration": "mc-2", "kind": "static"}]}]
        risks = service._schedule_risks(machines, {"/x/mc-1": a, "/x/mc-2": b})
        overlaps = [r for r in risks if "overlap" in r["title"]]
        self.assertEqual(len(overlaps), 1)
        self.assertEqual(overlaps[0]["severity"], "critical")

    def test_staggered_waves_and_unassigned_host(self):
        a = self._cfg("mc-1", "N1", "N2", "2026-10-10T11:30:00+00:00")
        b = self._cfg("mc-2", "N2", "N1", "2026-10-10T08:00:00+00:00")
        machines = [{"machine": "N1", "assignments": [{"configuration": "mc-1", "kind": "static"}]},
                    {"machine": "N2", "assignments": []}]
        risks = service._schedule_risks(machines, {"/x/mc-1": a, "/x/mc-2": b})
        self.assertFalse([r for r in risks if "overlap" in r["title"] or "apart" in r["title"]])
        self.assertTrue([r for r in risks if "no maintenance schedule" in r["title"]])

    def test_back_to_back_waves_in_reverse_order(self):
        # The user's change: wave 2 (N1) 14:30-16:30, wave 1 (N2) 16:30-18:30 -> touching, not overlapping.
        a = self._cfg("mc-1", "N1", "N2", "2026-10-05T21:30:00+00:00")
        a["wave"], a["preferred_primary"] = "2", "N1"
        b = self._cfg("mc-2", "N2", "N1", "2026-10-05T23:30:00+00:00")
        b["wave"] = "1"
        titles = {r["title"]: r["severity"] for r in service._schedule_risks([], {"/x/mc-1": a, "/x/mc-2": b})}
        self.assertNotIn("AG ag1 waves overlap", titles)
        self.assertEqual(titles.get("AG ag1 waves are only 0 min apart"), "high")
        self.assertEqual(titles.get("AG ag1 waves run in reverse order"), "medium")

    def test_gap_between_40_and_90_is_medium(self):
        a = self._cfg("mc-1", "N1", "N2", "2026-10-10T08:00:00+00:00")
        b = self._cfg("mc-2", "N2", "N1", "2026-10-10T11:00:00+00:00")  # 60 min after a ends
        titles = {r["title"]: r["severity"] for r in service._schedule_risks([], {"/x/mc-1": a, "/x/mc-2": b})}
        self.assertEqual(titles.get("AG ag1 waves are only 60 min apart"), "medium")


class DynamicScopeTests(unittest.TestCase):
    def test_tag_and_rg_filter(self):
        m = {"resourceGroup": "rg-a", "location": "westus", "tags": {"Env": "prod"}}
        self.assertTrue(service._dynamic_scope_matches({"resourceGroups": ["RG-A"], "tagSettings": {"tags": {"Env": ["prod"]}, "filterOperator": "All"}}, m))
        self.assertFalse(service._dynamic_scope_matches({"resourceGroups": ["rg-b"]}, m))
        self.assertFalse(service._dynamic_scope_matches({"resourceTypes": ["microsoft.compute/virtualmachines"]}, m))


class HistoryDedupTests(unittest.TestCase):
    def test_configuration_and_resource_runs_merge(self):
        cfg = "/subscriptions/s/resourcegroups/rg/providers/microsoft.maintenance/maintenanceconfigurations/mc-1"
        raw = [
            {"id": f"{cfg}/providers/microsoft.maintenance/applyupdates/1", "type": "microsoft.maintenance/maintenanceconfigurations/applyupdates",
             "properties": {"maintenanceConfigurationId": cfg, "status": "Cancelled", "startDateTime": "2099-01-01T01:00:00Z"}},
            {"id": "/m/applyupdates/1", "type": "microsoft.maintenance/applyupdates",
             "properties": {"maintenanceConfigurationId": cfg, "status": "Cancelled", "startDateTime": "2099-01-01T01:00:00Z",
                            "errorMessage": "Maintenance cancelled using Cancellation API", "resourceId": "/x/machines/N1"}},
        ]
        with mock.patch.object(service, "_raw_maintenance_runs", return_value=raw), \
             mock.patch.object(service, "_relevant_config_ids", return_value={cfg}), \
             mock.patch.object(service, "_sql_machine_ids", return_value=set()), \
             mock.patch.object(service, "_raw_installations", return_value=[]), \
             mock.patch.object(service, "_machines_by_id", return_value={}):
            runs = service.get_patch_history(days=36500)["maintenance_runs"]
        self.assertEqual(len(runs), 1)
        self.assertIn("Cancellation API", runs[0]["error"])


class RetryPolicyTests(unittest.TestCase):
    def _client(self, responses):
        from sqlha.arm import ArmClient
        from sqlha.config import Settings

        cred = mock.Mock()
        cred.get_token.return_value = mock.Mock(token="t", expires_on=9e12)
        c = ArmClient(Settings(), credential=cred)
        c._session = mock.Mock()
        c._session.request.side_effect = responses
        return c

    def _resp(self, status):
        r = mock.Mock(status_code=status, headers={"Retry-After": "0"}, content=b"{}", text="{}")
        r.json.return_value = {}
        return r

    def test_read_retries_connection_reset_and_5xx(self):
        import requests

        c = self._client([requests.ConnectionError("reset"), self._resp(500), self._resp(200)])
        with mock.patch("sqlha.arm.time.sleep"):
            self.assertEqual(c.post("/x/getDetailView").status_code, 200)
        self.assertEqual(c._session.request.call_count, 3)

    def test_non_idempotent_write_is_not_retried(self):
        import requests

        c = self._client([requests.ConnectionError("reset"), self._resp(200)])
        with mock.patch("sqlha.arm.time.sleep"), self.assertRaises(requests.ConnectionError):
            c.post("/x/failover", retry=False)
        self.assertEqual(c._session.request.call_count, 1)


class FindingsTests(unittest.TestCase):
    def test_upcoming_run_does_not_hide_last_cancelled_run(self):
        snap = {"history": {"maintenance_runs": [
            {"maintenance_configuration": "mc-1", "status": "NotStarted", "start": "2099-01-01T00:00:00Z"},
            {"maintenance_configuration": "mc-1", "status": "Cancelled", "start": "2026-10-03T11:30:00Z", "error": "x"},
        ]}}
        titles = [f["title"] for f in service.build_findings(snap)]
        self.assertIn("Last run of mc-1 was Cancelled", titles)
        snap["findings"] = []
        self.assertEqual(service._kpis(snap)["last_run"]["status"], "Cancelled")


class ConcurrencyTests(unittest.TestCase):
    def test_get_client_is_a_thread_safe_singleton(self):
        import threading

        from sqlha import arm

        created = []
        barrier = threading.Barrier(8)

        class SlowClient:
            def __init__(self):
                created.append(self)
                time.sleep(0.05)

        results = []

        def worker():
            barrier.wait()
            results.append(arm.get_client())

        with mock.patch.object(arm, "_client", None), mock.patch.object(arm, "ArmClient", SlowClient):
            threads = [threading.Thread(target=worker) for _ in range(8)]
            [t.start() for t in threads]
            [t.join() for t in threads]
        self.assertEqual(len(created), 1)
        self.assertEqual(len({id(r) for r in results}), 1)

    def test_cached_is_single_flight(self):
        import threading

        service.clear_cache()
        calls = []
        barrier = threading.Barrier(6)

        def slow():
            calls.append(1)
            time.sleep(0.05)
            return 42

        def worker():
            barrier.wait()
            self.assertEqual(service._cached("single-flight-test", slow), 42)

        threads = [threading.Thread(target=worker) for _ in range(6)]
        [t.start() for t in threads]
        [t.join() for t in threads]
        self.assertEqual(len(calls), 1)
        service.clear_cache()


class AgentBuildTests(unittest.TestCase):
    def test_dashboard_agent_is_read_only(self):
        from sqlha import agent as agent_mod

        captured = {}

        class FakeAgent:
            def __init__(self, **kw):
                captured.update(kw)

        env = {"FOUNDRY_PROJECT_ENDPOINT": "https://x/api/projects/p", "AZURE_AI_MODEL_DEPLOYMENT_NAME": "m"}
        with mock.patch.dict(os.environ, env), mock.patch.object(agent_mod, "Agent", FakeAgent), \
             mock.patch.object(agent_mod, "FoundryChatClient"), mock.patch.object(agent_mod, "DefaultAzureCredential"):
            agent_mod.build_agent(read_only=True, for_dashboard=True)
        names = {t.name for t in captured["tools"]}
        self.assertIn("sqlha_get_performance_snapshot", names)
        self.assertNotIn("sqlha_install_patches", names)
        self.assertNotIn("sqlha_failover_availability_group", names)
        self.assertIn("chat panel", captured["instructions"])
        self.assertIn('<skill name="sql-ha-performance">', captured["instructions"])
        self.assertNotIn('<skill name="sql-ha-patch-orchestration">', captured["instructions"])


class PerfTests(unittest.TestCase):
    def test_decode_and_summarize(self):
        import base64
        import gzip
        import json as _json

        from sqlha import perf

        snap = {"cpu": [{"sql_pct": 90, "other_pct": 5}, {"sql_pct": 70, "other_pct": 5}],
                "counters": {"Page life expectancy": 120, "Memory Grants Pending": 2},
                "sessions": {"blocked_requests": 3}, "os_memory": {"state": "Available physical memory is high"},
                "ag": [{"replica": "N2", "db": "A", "send_queue_kb": 20480, "redo_queue_kb": 0}],
                "io": [{"db": "A", "type": "ROWS", "read_ms": 35.0, "write_ms": 2.0}],
                "volumes": [{"mount": "F:\\", "total_mb": 1000, "free_mb": 50}]}
        blob = base64.b64encode(gzip.compress(_json.dumps(snap).encode())).decode()
        self.assertEqual(perf._decode(f"noise\nSQLHA_PERF:{blob}\n"), snap)
        s = perf._summarize(snap)
        self.assertEqual((s["cpu_sql_pct_now"], s["cpu_sql_pct_avg_30min"], s["cpu_sql_pct_max_30min"]), (90, 80.0, 90))
        text = " | ".join(s["attention"])
        for expected in ("high SQL CPU", "page life expectancy", "memory grants pending", "3 blocked",
                         "AG queue on N2/A", "slow IO A ROWS", "F:\\ 5% free"):
            self.assertIn(expected, text)

    def test_rejects_unsafe_instance_name(self):
        from sqlha import perf

        with self.assertRaises(ValueError):
            perf._run({"id": "/x", "location": "w", "name": "N"}, "X'; rm -rf", 10)


class WriteGuardTests(unittest.TestCase):
    def test_write_disabled(self):
        client = mock.Mock()
        client.settings.enable_write_actions = False
        with mock.patch.object(service, "get_client", return_value=client):
            with self.assertRaises(PermissionError):
                service._require_write()


if __name__ == "__main__":
    unittest.main()
