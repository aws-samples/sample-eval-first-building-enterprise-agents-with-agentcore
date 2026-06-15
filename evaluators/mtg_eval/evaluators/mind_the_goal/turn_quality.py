"""Goal segmentation and turn quality assessment via LLM."""

from __future__ import annotations

import json
import re

from shared.llm_client import LLMClient
from shared.models import Session, TurnQuality, RCOFCode
from evaluators.mind_the_goal.prompts import build_evaluation_prompt


def _parse_evaluation_response(text: str) -> list[dict]:
    """Parse LLM response: extract JSON after <think> tags."""
    # Remove think tags
    cleaned = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()
    # Find JSON
    match = re.search(r"\{.*\}", cleaned, re.DOTALL)
    if not match:
        return []
    try:
        data = json.loads(match.group())
        return data.get("turns", [])
    except json.JSONDecodeError:
        return []


def _extract_think_trace(text: str) -> str:
    match = re.search(r"<think>(.*?)</think>", text, re.DOTALL)
    return match.group(1).strip() if match else ""


def evaluate_session(session: Session, llm: LLMClient) -> tuple[list[dict], list[TurnQuality], str]:
    """Run LLM evaluation on a session. Returns (raw_turns, turn_qualities, think_trace)."""
    turns_data = [
        {
            "turn_number": t.turn_number,
            "user_message": t.user_message,
            "agent_response": t.agent_response,
            "tool_calls": [{"tool_name": tc.tool_name, "output": tc.output} for tc in t.tool_calls],
        }
        for t in session.turns
    ]

    prompt = build_evaluation_prompt(turns_data, dialog_id=session.session_id)
    resp = llm.invoke(prompt, max_tokens=4096)

    think_trace = _extract_think_trace(resp.text)
    raw_turns = _parse_evaluation_response(resp.text)

    turn_qualities = []
    for rt in raw_turns:
        rcof = None
        if rt.get("rcof") and rt["rcof"] != "null":
            try:
                rcof = RCOFCode[rt["rcof"]]
            except KeyError:
                pass
        turn_qualities.append(TurnQuality(
            turn_number=rt.get("turn_number", 0),
            quality=rt.get("quality", "success"),
            rcof=rcof,
            think_trace=think_trace,
        ))

    return raw_turns, turn_qualities, think_trace
