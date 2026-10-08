"""Builds the SQL HA agent (Agent Framework) for the Foundry hosted agent and the control-plane chat."""

from __future__ import annotations

import os
import re
from pathlib import Path

from agent_framework import Agent, tool
from agent_framework.foundry import FoundryChatClient
from azure.identity import DefaultAzureCredential

from .tools import TOOLS

LOCAL_ONLY_SKILLS = {"sql-ha-dashboard"}


def _skill_dirs() -> list[Path]:
    """SQLHA_SKILLS_DIR, else the nearest `skills/` (hosted agent package) or `.github/skills/` (repo) above this file."""
    dirs = [Path(os.environ["SQLHA_SKILLS_DIR"])] if os.environ.get("SQLHA_SKILLS_DIR") else []
    for parent in Path(__file__).resolve().parents:
        dirs += [parent / "skills", parent / ".github" / "skills"]
    return dirs

BASE_INSTRUCTIONS = """\
You are the SQL HA agent. You monitor, patch and report on SQL Server instances that run on AWS (or any other
cloud/on-premises host) and are managed from Azure through Azure Arc (SQL Server enabled by Azure Arc), Azure
Update Manager and Microsoft Defender for Cloud. The instances form Windows Server Failover Cluster Always On
availability groups (one primary, one or more secondaries).

Ground rules:
- Answer only from tool results. Call sqlha_get_overview first for broad questions, then drill down with the
  specific tools. Never invent KBs, builds, dates, metrics or states. Say when data is stale or unavailable.
- Always state times with the time zone (maintenance windows are defined in a Windows time zone; also give UTC).
- Lead with the answer, then the evidence. Use compact tables for multi-row data. Flag risks with severity.
- Write tools (sqlha_trigger_patch_assessment, sqlha_enable_periodic_assessment, sqlha_install_patches,
  sqlha_failover_availability_group) must first be called with confirm=false to preview. Show the preview, ask the
  user for explicit approval, and only then call again with confirm=true. Never patch or reboot the current AG
  primary, never patch both replicas of an AG at the same time, and never fail over to a replica that is not
  failover-ready.
- If a write tool returns write_actions_disabled, explain that the operator must set SQLHA_ENABLE_WRITE_ACTIONS=true
  on the agent, and provide the equivalent manual steps instead.
"""

DASHBOARD_INSTRUCTIONS = """\

You are answering inside the SQL HA control plane's chat panel. Keep answers short (a few sentences or one compact
table) unless the user asks for detail. You only have read-only tools here: you can't patch, assess or fail over.
For those, give the steps and point the user to the Actions section of the node panel (or the sql-ha-agent in VS
Code). Performance snapshots (sqlha_get_performance_snapshot) take 20-40 seconds, so call them only for performance
questions.
Each user message may start with [Dashboard context: ...] describing the tab and node the user is looking at; use
it to resolve "this node", "here" and similar references.
"""


def load_skills(exclude: set[str] | None = None) -> str:
    skip = LOCAL_ONLY_SKILLS | (exclude or set())
    seen: set[str] = set()
    parts: list[str] = []
    for root in _skill_dirs():
        if not root.is_dir():
            continue
        for skill_md in sorted(root.glob("sql-ha-*/SKILL.md")):
            name = skill_md.parent.name
            if name in seen or name in skip:
                continue
            seen.add(name)
            body = re.sub(r"^---\n.*?\n---\n", "", skill_md.read_text(encoding="utf-8"), count=1, flags=re.S)
            parts.append(f"\n\n<skill name=\"{name}\">\n{body.strip()}\n</skill>")
    return "".join(parts)


def build_agent(read_only: bool = False, for_dashboard: bool = False) -> Agent:
    """Hosted agent: all tools. Dashboard chat: read-only tools and shorter, panel-friendly answers."""
    client = FoundryChatClient(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        model=os.environ["AZURE_AI_MODEL_DEPLOYMENT_NAME"],
        credential=DefaultAzureCredential(exclude_interactive_browser_credential=True),
    )
    approval = os.environ.get("SQLHA_WRITE_APPROVAL_MODE", "never_require")
    tools = [
        tool(spec.fn, name=spec.name, description=spec.fn.__doc__,
             approval_mode="never_require" if spec.read_only else approval)
        for spec in TOOLS
        if spec.hosted and (spec.read_only or not read_only)
    ]
    instructions = BASE_INSTRUCTIONS + (DASHBOARD_INSTRUCTIONS if for_dashboard else "")
    # The patch-orchestration skill describes write workflows that the read-only chat can't perform.
    instructions += load_skills(exclude={"sql-ha-patch-orchestration"} if read_only else None)
    return Agent(
        client=client,
        name="sql-ha-agent",
        instructions=instructions,
        tools=tools,
        # History is kept by the hosting infrastructure (hosted) or the in-memory session (dashboard).
        default_options={"store": False},
    )
