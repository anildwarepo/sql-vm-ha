"""Local stdio MCP server exposing the SQL HA tools to VS Code / GitHub Copilot.

Run:  python -m sqlha.mcp_server     (needs sqlha-core installed with the `mcp` extra)
"""

from __future__ import annotations

import os

import requests
from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

from .tools import TOOLS, _guard

mcp = FastMCP(
    "sqlha",
    instructions=(
        "Monitor and patch SQL Server Always On availability groups running on AWS (or any cloud) and managed "
        "through Azure Arc and Azure Update Manager. Start with sqlha_get_overview. Write tools default to "
        "confirm=false (preview); only pass confirm=true after the user explicitly approves."
    ),
)

for spec in TOOLS:
    mcp.add_tool(
        spec.fn,
        name=spec.name,
        description=spec.fn.__doc__,
        annotations=ToolAnnotations(
            title=spec.name.replace("sqlha_", "").replace("_", " ").capitalize(),
            readOnlyHint=spec.read_only,
            destructiveHint=spec.destructive,
            idempotentHint=spec.read_only,
            openWorldHint=True,
        ),
    )


@mcp.tool(
    name="sqlha_get_control_plane",
    annotations=ToolAnnotations(title="Control plane status", readOnlyHint=True, openWorldHint=False),
)
def sqlha_get_control_plane() -> str:
    """Whether the SQL control plane (React UI + FastAPI backend) is running locally, with its UI, API and Swagger
    URLs, or the command to start it. Use when the user asks for the dashboard or a visual view."""
    api = os.environ.get("SQLHA_CONTROLPLANE_API", "http://127.0.0.1:8000").rstrip("/")
    ui = os.environ.get("SQLHA_CONTROLPLANE_UI", "http://127.0.0.1:5173").rstrip("/")

    def run() -> dict:
        try:
            health = requests.get(f"{api}/api/health", timeout=3).json()
            running = True
        except requests.RequestException:
            health, running = None, False
        return {
            "running": running,
            "ui_url": ui,
            "api_url": api,
            "swagger_url": f"{api}/docs",
            "health": health,
            "start_command": None if running else "python sql-controlplane/run_all.py   (from the repository root)",
        }

    return _guard(run)


def main() -> None:
    mcp.run("stdio")


if __name__ == "__main__":
    main()
