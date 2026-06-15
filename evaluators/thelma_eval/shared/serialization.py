"""JSON serialization/deserialization for conversation logs."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from shared.models import Session, Turn, Source, ToolCall


def session_to_dict(session: Session) -> dict:
    return {
        "session_id": session.session_id,
        "timestamp": session.timestamp,
        "turns": [
            {
                "turn_number": t.turn_number,
                "user_message": t.user_message,
                "agent_response": t.agent_response,
                "retrieved_sources": [
                    {"doc_id": s.doc_id, "doc_name": s.doc_name, "content": s.content,
                     "snippet": s.snippet, "similarity_score": s.similarity_score}
                    for s in t.retrieved_sources
                ],
                "tool_calls": [
                    {"tool_name": tc.tool_name, "input": tc.input, "output": tc.output}
                    for tc in t.tool_calls
                ],
                "latency_ms": t.latency_ms,
            }
            for t in session.turns
        ],
        "metadata": session.metadata,
    }


def dict_to_session(d: dict) -> Session:
    turns = []
    for t in d["turns"]:
        sources = [Source(**s) for s in t.get("retrieved_sources", [])]
        tool_calls = [ToolCall(**tc) for tc in t.get("tool_calls", [])]
        turns.append(Turn(
            turn_number=t["turn_number"],
            user_message=t["user_message"],
            agent_response=t["agent_response"],
            retrieved_sources=sources,
            tool_calls=tool_calls,
            latency_ms=t.get("latency_ms", 0),
        ))
    return Session(
        session_id=d["session_id"],
        timestamp=d.get("timestamp", ""),
        turns=turns,
        metadata=d.get("metadata", {}),
    )


def save_session(session: Session, path: str | Path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        json.dump(session_to_dict(session), f, indent=2)


def load_session(path: str | Path) -> Session:
    with open(path) as f:
        return dict_to_session(json.load(f))


def load_sessions(directory: str | Path) -> list[Session]:
    directory = Path(directory)
    return [load_session(p) for p in sorted(directory.glob("*.json")) if "_eval" not in p.stem]
