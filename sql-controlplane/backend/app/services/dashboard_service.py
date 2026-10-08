"""Dashboard service: caches the full snapshot the UI renders and refreshes it on demand."""

from __future__ import annotations

import threading
import time
from collections.abc import Callable
from typing import Any

from sqlha import service

Collector = Callable[[], dict[str, Any]]


def _collect() -> dict[str, Any]:
    service.clear_cache()
    return service.get_dashboard_snapshot(live_ag=True)


class DashboardService:
    def __init__(self, collector: Collector = _collect) -> None:
        self._collector = collector
        self._snapshot: dict[str, Any] | None = None
        self._duration = 0.0
        self._lock = threading.Lock()
        self._generation = 0

    @property
    def has_snapshot(self) -> bool:
        return self._snapshot is not None

    def get(self) -> dict[str, Any]:
        """The cached snapshot; collects one on first use."""
        return self._snapshot if self._snapshot is not None else self.refresh()

    def refresh(self) -> dict[str, Any]:
        """Collect a fresh snapshot. Concurrent callers share one collection instead of starting several."""
        started_generation = self._generation
        with self._lock:
            if self._generation != started_generation and self._snapshot is not None:
                return self._snapshot  # another request refreshed while we waited
            t0 = time.perf_counter()
            snap = self._collector()
            self._duration = round(time.perf_counter() - t0, 1)
            self._snapshot = snap
            self._generation += 1
            return snap

    @property
    def last_duration(self) -> float:
        return self._duration
