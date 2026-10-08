"""Models for the chat API."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=4000, examples=["Who is the primary and is everything synchronized?"])
    session_id: str | None = Field(None, max_length=64, pattern=r"^[A-Za-z0-9_-]+$",
                                   description="Omit to start a new conversation; reuse the id from the session event")
    context: str | None = Field(None, max_length=300, examples=["tab=alwayson, node=SQL-VM-2"],
                                description="What the user is looking at in the UI")


class ChatEvent(BaseModel):
    """One Server-Sent Event (`data: <json>`) in the /api/chat/messages stream."""

    type: Literal["session", "tool", "text", "done", "error"]
    id: str | None = Field(None, description="session: conversation id")
    name: str | None = Field(None, description="tool: tool being called")
    delta: str | None = Field(None, description="text: next chunk of the answer (Markdown)")
    seconds: float | None = Field(None, description="done: total time")
    message: str | None = Field(None, description="error: what went wrong")


class ChatStatus(BaseModel):
    configured: bool
    model: str | None = None
    project_endpoint: str | None = None
    active_sessions: int
    read_only: bool = True
    missing_settings: list[str] = []
