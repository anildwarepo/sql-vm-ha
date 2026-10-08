"""Runtime settings, read from environment variables."""

from __future__ import annotations

import os
from dataclasses import dataclass, field


def _csv(name: str) -> list[str]:
    return [v.strip() for v in os.environ.get(name, "").split(",") if v.strip()]


def _flag(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in ("1", "true", "yes", "on")


@dataclass
class Settings:
    # Empty subscription list = every subscription the identity can read.
    subscription_ids: list[str] = field(default_factory=lambda: _csv("SQLHA_SUBSCRIPTION_IDS"))
    # Empty resource group list = no resource group filter.
    resource_groups: list[str] = field(default_factory=lambda: _csv("SQLHA_RESOURCE_GROUPS"))
    # Patch, assessment and failover tools refuse to run unless this is true.
    enable_write_actions: bool = field(default_factory=lambda: _flag("SQLHA_ENABLE_WRITE_ACTIONS"))
    arm_endpoint: str = field(
        default_factory=lambda: os.environ.get("SQLHA_ARM_ENDPOINT", "https://management.azure.com").rstrip("/")
    )
    # Data older than this (seconds) from getDetailView is reported as stale, matching the runbooks.
    ag_fresh_seconds: int = field(default_factory=lambda: int(os.environ.get("SQLHA_AG_FRESH_SECONDS", "60")))
    # Live performance snapshots run a fixed read-only DMV script on the host with Arc Run Command.
    enable_perf_snapshot: bool = field(default_factory=lambda: _flag("SQLHA_ENABLE_PERF_SNAPSHOT", True))


def get_settings() -> Settings:
    return Settings()
