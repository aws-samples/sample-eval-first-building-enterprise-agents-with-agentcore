"""把 AgentCore 的 session_spans 重建成 qa-eval 的 Session（多轮 Turn）。

Mind the Goal 是 SESSION 级，只需每轮的：
  turn_number / user_message / agent_response / tool_calls(tool_name + output.status)
不需要 retrieved_sources（与 THELMA 互补）。

按 trace_id 把 span 分组（每个用户轮 = 一个 trace），每组抽一个 Turn。
"""
from __future__ import annotations

import json
import re

from shared.models import Session, Turn, ToolCall


def _safe_json(s):
    if not isinstance(s, str):
        return s
    try:
        return json.loads(s)
    except Exception:
        return None


def _attr(span, key):
    a = span.get("attributes") or {}
    return a.get(key) if isinstance(a, dict) else None


def _iter_bodies(span):
    for e in (span.get("span_events") or []):
        if isinstance(e, dict):
            b = e.get("body")
            if isinstance(b, dict):
                yield b


def _looks_like_tool_payload(txt):
    if not isinstance(txt, str):
        return True
    markers = ('"toolResult"', '"toolUse"', '"statusCode"', '\\"answer\\"',
               '"answer":', 'tooluse_', '"toolUseId"')
    return any(mk in txt[:200] for mk in markers) or txt.lstrip()[:80].startswith('[{"tool')


def _unwrap_text_blocks(txt):
    """若文本本身是 '[{"text": "..."}]' 形式，解出里面的纯文本拼接。否则原样返回。"""
    if not isinstance(txt, str):
        return ""
    s = txt.lstrip()
    if s.startswith("[") and '"text"' in s[:30]:
        parsed = _safe_json(txt)
        if isinstance(parsed, list):
            parts = [b.get("text", "") for b in parsed
                     if isinstance(b, dict) and "toolUse" not in b and "toolResult" not in b]
            if parts:
                return " ".join(p for p in parts if p)
    return txt


def _assistant_text(m):
    """从 message 取 assistant 纯文本回复，排除工具消息，并脱掉 [{"text":...}] 外壳。"""
    raw = ""
    if isinstance(m, str):
        raw = "" if _looks_like_tool_payload(m) and not m.lstrip().startswith('[{"text"') else m
    elif isinstance(m, dict):
        if m.get("role") not in (None, "assistant"):
            return ""
        c = m.get("content")
        if isinstance(c, str):
            raw = c
        elif isinstance(c, list):
            parts = []
            for blk in c:
                if isinstance(blk, dict):
                    if "toolUse" in blk or "toolResult" in blk:
                        continue
                    if blk.get("text"):
                        parts.append(blk["text"])
                elif isinstance(blk, str):
                    parts.append(blk)
            raw = " ".join(parts)
        elif isinstance(c, dict):
            if "toolUse" in c or "toolResult" in c:
                return ""
            t = c.get("text") or c.get("content") or c.get("message") or ""
            raw = t if isinstance(t, str) else ""
    # 脱壳：[{"text":"..."}] → 纯文本
    unwrapped = _unwrap_text_blocks(raw)
    # 脱壳后若仍是工具载荷则丢弃
    return "" if _looks_like_tool_payload(unwrapped) else unwrapped


def _user_message(m):
    """从 message 取用户输入文本（仅 role=user），处理嵌套 content.content 和 [{"text"}] 壳。"""
    if isinstance(m, str):
        return _unwrap_text_blocks(m)
    if not isinstance(m, dict) or m.get("role") != "user":
        return ""  # 只认明确的 user 角色，避免抓到 system/tool
    c = m.get("content")
    raw = ""
    if isinstance(c, str):
        raw = c
    elif isinstance(c, dict):
        # 常见嵌套：content.content
        inner = c.get("content") or c.get("text") or c.get("message") or ""
        raw = inner if isinstance(inner, str) else ""
    elif isinstance(c, list):
        parts = [b.get("text", "") for b in c if isinstance(b, dict) and b.get("text")]
        raw = " ".join(parts)
    return _unwrap_text_blocks(raw)


def _trace_key(span):
    return span.get("trace_id") or span.get("traceId") or "single"


def _start(span):
    return str(span.get("start_time") or span.get("startTimeUnixNano") or "")


def _build_turn(turn_number, spans):
    """从同一 trace 的 spans 抽一个 Turn。"""
    user_msg, agent_resp = "", ""
    tool_calls = []
    resp_candidates = []  # (start_time, text)

    for s in spans:
        name = (s.get("name") or "").lower()
        scope = (s.get("scope") or {}).get("name", "").lower()
        is_llm = ("chat" in name or "llm" in name or "invoke_model" in name or "strands" in scope)

        for body in _iter_bodies(s):
            # 输入侧找 user message（仅 role=user，已脱壳）
            inp = body.get("input")
            if isinstance(inp, dict):
                for m in inp.get("messages") or []:
                    um = _user_message(m)
                    if um and not _looks_like_tool_payload(um):
                        # 取最早出现的 user 消息（本轮用户输入），而非最长
                        if not user_msg:
                            user_msg = um
            # 输出侧找 assistant 回复
            if is_llm:
                out = body.get("output")
                if isinstance(out, dict):
                    for m in out.get("messages") or []:
                        at = _assistant_text(m)
                        if at:
                            resp_candidates.append((_start(s), at))

        # 工具调用（tool_name + status）
        tname = _attr(s, "gen_ai.tool.name")
        if tname:
            status = _attr(s, "gen_ai.tool.status") or "unknown"
            tool_calls.append(ToolCall(tool_name=tname, input={}, output={"status": status}))

    if resp_candidates:
        resp_candidates.sort(key=lambda x: x[0])
        agent_resp = resp_candidates[-1][1]

    return Turn(
        turn_number=turn_number,
        user_message=user_msg,
        agent_response=agent_resp,
        retrieved_sources=[],
        tool_calls=tool_calls,
    )


def rebuild_session(session_spans, session_id="agentcore-session"):
    """把 session_spans 重建成 Session（按 trace 分轮）。"""
    spans = [s for s in session_spans if isinstance(s, dict)]
    # 按 trace 分组
    groups = {}
    for s in spans:
        groups.setdefault(_trace_key(s), []).append(s)
    # 按各组最早 span 时间排序 → 轮次顺序
    ordered = sorted(groups.items(), key=lambda kv: min((_start(s) for s in kv[1]), default=""))

    session = Session()
    session.session_id = session_id
    turns = []
    n = 1
    for _, grp in ordered:
        turn = _build_turn(n, grp)
        # 只保留有实质内容的轮次
        if turn.user_message or turn.agent_response or turn.tool_calls:
            turns.append(turn)
            n += 1
    session.turns = turns
    return session
