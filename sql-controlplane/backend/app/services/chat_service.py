"""Chat service: the read-only SQL HA agent (Agent Framework + Foundry model) with in-memory conversations."""

from __future__ import annotations

import os
import time
import uuid
from collections import OrderedDict
from collections.abc import AsyncIterator, Callable
from typing import Any

REQUIRED_SETTINGS = ("FOUNDRY_PROJECT_ENDPOINT", "AZURE_AI_MODEL_DEPLOYMENT_NAME")


def _default_agent_factory() -> Any:
    from sqlha.agent import build_agent  # imported lazily: pulls in the Agent Framework stack

    return build_agent(read_only=True, for_dashboard=True)


class ChatNotConfiguredError(RuntimeError):
    pass


class ChatService:
    def __init__(self, agent_factory: Callable[[], Any] = _default_agent_factory, max_sessions: int = 50) -> None:
        self._factory = agent_factory
        self._agent: Any = None
        self._sessions: OrderedDict[str, Any] = OrderedDict()
        self._max_sessions = max_sessions

    # ------------------------------------------------------------ status

    @staticmethod
    def missing_settings() -> list[str]:
        return [v for v in REQUIRED_SETTINGS if not os.environ.get(v)]

    def status(self) -> dict[str, Any]:
        missing = self.missing_settings()
        return {
            "configured": not missing,
            "model": os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME"),
            "project_endpoint": os.environ.get("FOUNDRY_PROJECT_ENDPOINT"),
            "active_sessions": len(self._sessions),
            "read_only": True,
            "missing_settings": missing,
        }

    # ------------------------------------------------------------ sessions

    def _agent_instance(self) -> Any:
        if self._agent is None:
            if self.missing_settings():
                raise ChatNotConfiguredError(
                    f"Chat is not configured: set {', '.join(self.missing_settings())} in sql-controlplane/.env.")
            self._agent = self._factory()
        return self._agent

    def _session(self, agent: Any, session_id: str) -> Any:
        session = self._sessions.get(session_id)
        if session is None:
            session = agent.create_session(session_id=session_id)
            self._sessions[session_id] = session
            while len(self._sessions) > self._max_sessions:
                self._sessions.popitem(last=False)
        self._sessions.move_to_end(session_id)
        return session

    def end_session(self, session_id: str) -> bool:
        return self._sessions.pop(session_id, None) is not None

    # ------------------------------------------------------------ streaming

    async def stream(self, message: str, session_id: str | None = None,
                     context: str | None = None) -> AsyncIterator[dict[str, Any]]:
        """Yield chat events: session, tool*, text*, then done or error."""
        session_id = session_id or uuid.uuid4().hex
        started = time.perf_counter()
        yield {"type": "session", "id": session_id}
        try:
            agent = self._agent_instance()
            session = self._session(agent, session_id)
            prompt = f"[Dashboard context: {context}]\n{message}" if context else message
            async for update in agent.run(prompt, stream=True, session=session):
                for content in update.contents or []:
                    if getattr(content, "type", "") == "function_call" and getattr(content, "name", None):
                        yield {"type": "tool", "name": content.name}
                if update.text:
                    yield {"type": "text", "delta": update.text}
            yield {"type": "done", "seconds": round(time.perf_counter() - started, 1)}
        except Exception as exc:  # surfaced in the chat panel
            yield {"type": "error", "message": f"{type(exc).__name__}: {exc}"}
