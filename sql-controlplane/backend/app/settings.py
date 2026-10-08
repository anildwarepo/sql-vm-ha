"""Backend settings, read from environment variables (and the control plane's .env file)."""

from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path

from dotenv import load_dotenv
from pydantic import BaseModel, Field

BACKEND_DIR = Path(__file__).resolve().parents[1]
CONTROLPLANE_DIR = BACKEND_DIR.parent


def load_env_files() -> None:
    """Load SQLHA_ENV_FILE or sql-controlplane/.env. Existing environment variables always win."""
    explicit = os.environ.get("SQLHA_ENV_FILE")
    for candidate in ([Path(explicit)] if explicit else []) + [CONTROLPLANE_DIR / ".env"]:
        if candidate.is_file():
            load_dotenv(candidate, override=False)
            return


def _csv(name: str, default: str) -> list[str]:
    return [v.strip() for v in os.environ.get(name, default).split(",") if v.strip()]


class Settings(BaseModel):
    host: str = Field(default_factory=lambda: os.environ.get("SQLHA_API_HOST", "127.0.0.1"))
    port: int = Field(default_factory=lambda: int(os.environ.get("SQLHA_API_PORT", "8000")))
    # Browser origins allowed to call the API (the Vite dev server). Same-origin production builds need none.
    cors_origins: list[str] = Field(
        default_factory=lambda: _csv("SQLHA_CORS_ORIGINS", "http://localhost:5173,http://127.0.0.1:5173"))
    # Host headers accepted; blocks DNS-rebinding attacks against the local API.
    allowed_hosts: list[str] = Field(default_factory=lambda: _csv("SQLHA_ALLOWED_HOSTS", "127.0.0.1,localhost"))
    # Built React app served at / when present (run_all.py --prod).
    ui_dist: Path = Field(default_factory=lambda: Path(os.environ.get("SQLHA_UI_DIST",
                                                                      CONTROLPLANE_DIR / "frontend" / "dist")))
    chat_max_sessions: int = Field(default_factory=lambda: int(os.environ.get("SQLHA_CHAT_MAX_SESSIONS", "50")))
    chat_max_chars: int = 4000


@lru_cache
def get_settings() -> Settings:
    load_env_files()
    return Settings()
