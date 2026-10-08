# Copyright (c) Microsoft. All rights reserved.
"""SQL HA agent: monitors and patches SQL Server Always On AGs managed by Azure Arc (Foundry hosted agent)."""

from agent_framework_foundry_hosting import ResponsesHostServer
from dotenv import load_dotenv

from sqlha.agent import build_agent

load_dotenv()


def main() -> None:
    ResponsesHostServer(build_agent()).run()


if __name__ == "__main__":
    main()
