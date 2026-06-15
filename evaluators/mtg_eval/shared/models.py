"""Data models for conversations and evaluation results."""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any, Optional


# --- Conversation Models ---

@dataclass
class Source:
    doc_id: str
    doc_name: str
    content: str
    snippet: str = ""
    similarity_score: float = 0.0


@dataclass
class ToolCall:
    tool_name: str
    input: dict[str, Any] = field(default_factory=dict)
    output: dict[str, Any] = field(default_factory=dict)


@dataclass
class Turn:
    turn_number: int
    user_message: str
    agent_response: str
    retrieved_sources: list[Source] = field(default_factory=list)
    tool_calls: list[ToolCall] = field(default_factory=list)
    latency_ms: int = 0

    @property
    def has_sources(self) -> bool:
        return len(self.retrieved_sources) > 0


@dataclass
class Session:
    session_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    timestamp: str = field(default_factory=lambda: datetime.utcnow().isoformat() + "Z")
    turns: list[Turn] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)


# --- Evaluation Models ---

class RCOFCode(Enum):
    """Root Cause of Failure taxonomy (Section 4.3 of Mind the Goal paper)."""
    E1 = "Language Understanding Failure"
    E2 = "Refusal to Answer"
    E3 = "Incorrect Retrieval"
    E4 = "Retrieval Failure"
    E5 = "System Error"
    E6 = "Incorrect Routing"
    E7 = "Out-of-Domain Query"


@dataclass
class TurnQuality:
    turn_number: int
    quality: str  # "success" or "failure"
    rcof: Optional[RCOFCode] = None
    rationale: str = ""
    think_trace: str = ""


@dataclass
class Goal:
    goal_id: int
    turns: list[int]
    description: str = ""
    quality: str = ""  # "success" or "failure"
    rcof: Optional[RCOFCode] = None
    failed_turn: Optional[int] = None
    rationale: str = ""


@dataclass
class THELMAScores:
    source_precision_chunk: float = 0.0
    source_precision_fact: float = 0.0
    source_query_coverage: float = 0.0
    response_precision: float = 0.0
    response_query_coverage: float = 0.0
    response_self_distinctness: float = 0.0
    groundedness: float = 0.0


@dataclass
class THELMADiagnosis:
    pattern: str = ""
    interpretation: str = ""
    component_to_improve: str = ""
