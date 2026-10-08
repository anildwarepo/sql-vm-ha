"""Chat: the read-only SQL HA agent, streamed as Server-Sent Events."""

from __future__ import annotations

import json
from collections.abc import AsyncIterator

from fastapi import APIRouter, Path
from fastapi.responses import StreamingResponse

from ...schemas.chat import ChatRequest, ChatStatus
from ..deps import ChatDep, ClientGuard

router = APIRouter(prefix="/api/chat", tags=["Chat"])

STREAM_DOC = {
    200: {
        "description": "Server-Sent Events. Each event is `data: <ChatEvent JSON>`: `session` (conversation id) "
                       "first, then `tool` and `text` events, then `done` or `error`.",
        "content": {"text/event-stream": {"example": 'data: {"type": "session", "id": "6f1c..."}\n\n'
                                                     'data: {"type": "tool", "name": "sqlha_get_availability_groups"}\n\n'
                                                     'data: {"type": "text", "delta": "SQL-VM-1 is the primary"}\n\n'
                                                     'data: {"type": "done", "seconds": 9.4}\n\n'}},
    }
}


@router.get("/status", response_model=ChatStatus, summary="Whether the chat agent is configured")
def status(chat=ChatDep) -> dict:
    return chat.status()


@router.post("/messages", dependencies=[ClientGuard], responses=STREAM_DOC, response_class=StreamingResponse,
             summary="Ask a question; the answer streams back")
async def send_message(body: ChatRequest, chat=ChatDep) -> StreamingResponse:
    async def events() -> AsyncIterator[bytes]:
        async for event in chat.stream(body.message.strip(), body.session_id, body.context):
            yield f"data: {json.dumps(event, default=str)}\n\n".encode()

    return StreamingResponse(events(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"})


@router.delete("/sessions/{session_id}", status_code=204, dependencies=[ClientGuard],
               summary="Forget a conversation")
def end_session(session_id: str = Path(max_length=64, pattern=r"^[A-Za-z0-9_-]+$"), chat=ChatDep) -> None:
    chat.end_session(session_id)
