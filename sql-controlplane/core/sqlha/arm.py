"""Minimal Azure Resource Manager and Resource Graph client."""

from __future__ import annotations

import threading
import time
from typing import Any

import requests
from azure.identity import DefaultAzureCredential

from .config import Settings, get_settings

API_HYBRID_COMPUTE = "2024-07-10"
API_ARC_DATA = "2026-01-01"
API_AUTOMATION = "2023-11-01"
API_MAINTENANCE = "2023-04-01"
API_RESOURCE_GRAPH = "2022-10-01"


class ArmError(RuntimeError):
    def __init__(self, status: int, message: str, body: Any = None):
        super().__init__(f"ARM {status}: {message}")
        self.status = status
        self.body = body


class ArmClient:
    def __init__(self, settings: Settings | None = None, credential: Any = None):
        self.settings = settings or get_settings()
        self._credential = credential or DefaultAzureCredential(exclude_interactive_browser_credential=True)
        self._token: str | None = None
        self._expires = 0.0
        self._lock = threading.Lock()
        self._session = requests.Session()

    def _headers(self) -> dict[str, str]:
        with self._lock:
            if not self._token or time.time() > self._expires - 300:
                tok = self._credential.get_token(f"{self.settings.arm_endpoint}/.default")
                self._token, self._expires = tok.token, float(tok.expires_on)
        return {"Authorization": f"Bearer {self._token}", "Content-Type": "application/json"}

    def _url(self, path: str) -> str:
        return path if path.startswith("https://") else f"{self.settings.arm_endpoint}{path}"

    def request(self, method: str, path: str, body: Any = None, timeout: int = 60, retry: bool = True,
                attempts: int = 4) -> requests.Response:
        """Send an ARM request. Transient failures (connection resets, 429, 5xx) are retried up to `attempts`
        times when `retry` is true; callers pass retry=False for non-idempotent actions such as patch install and
        AG failover."""
        attempts = max(1, attempts) if retry else 1
        for attempt in range(1, attempts + 1):
            try:
                resp = self._session.request(method, self._url(path), headers=self._headers(), json=body, timeout=timeout)
            except (requests.ConnectionError, requests.Timeout):
                if attempt == attempts:
                    raise
                time.sleep(2 ** attempt)
                continue
            if attempt < attempts and resp.status_code in (429, 500, 502, 503, 504):
                time.sleep(min(int(resp.headers.get("Retry-After", 2 ** attempt)), 30))
                continue
            break
        if resp.status_code >= 400:
            try:
                payload = resp.json()
                err = payload.get("error", payload)
                message = err.get("message") or resp.text
            except ValueError:
                payload, message = resp.text, resp.text
            raise ArmError(resp.status_code, message, payload)
        return resp

    def get(self, path: str) -> Any:
        resp = self.request("GET", path)
        return resp.json() if resp.content else {}

    def post(self, path: str, body: Any = None, retry: bool = True, attempts: int = 4) -> requests.Response:
        return self.request("POST", path, body if body is not None else {}, retry=retry, attempts=attempts)

    def graph(self, query: str, max_rows: int = 5000) -> list[dict[str, Any]]:
        """Run a Resource Graph query, scoped to the configured subscriptions, and follow paging."""
        body: dict[str, Any] = {"query": query, "options": {"resultFormat": "objectArray", "$top": 1000}}
        if self.settings.subscription_ids:
            body["subscriptions"] = self.settings.subscription_ids
        rows: list[dict[str, Any]] = []
        while True:
            resp = self.request(
                "POST", f"/providers/Microsoft.ResourceGraph/resources?api-version={API_RESOURCE_GRAPH}", body
            )
            data = resp.json()
            rows.extend(data.get("data", []))
            token = data.get("$skipToken")
            if not token or len(rows) >= max_rows:
                return rows
            body["options"]["$skipToken"] = token

    def scope_filter(self, id_column: str = "id") -> str:
        """KQL fragment that limits results to the configured resource groups (matched on the resource id)."""
        if not self.settings.resource_groups:
            return ""
        clauses = " or ".join(
            f"tolower({id_column}) contains '/resourcegroups/{g.lower()}/'" for g in self.settings.resource_groups
        )
        return f"| where {clauses}"


_client: ArmClient | None = None
_client_lock = threading.Lock()


def get_client() -> ArmClient:
    # Thread-safe: parallel dashboard sections must share one client, or each one starts its own credential
    # chain (e.g. one `az account get-access-token` per thread), which made cold starts take 20-100 s.
    global _client
    if _client is None:
        with _client_lock:
            if _client is None:
                _client = ArmClient()
    return _client
