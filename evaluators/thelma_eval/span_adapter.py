"""把 AgentCore 的 session_spans（ADOT span dict）转成 THELMA 要的 (query, sources, response)。

依据探针实测的真实结构（execute_tool span + chat span）：

execute_tool span（hr-tools___retrieve_hr_policy）:
  span_events[].body.input.messages[].content.content   = '{"query": "..."}'
  span_events[].body.output.messages[].content.message  = '[{"text":"{...{answer, sources}...}"}]'

chat / agent span:
  gen_ai.choice 事件或 span_events 里的 assistant 文本 = agent 最终回复
"""
from __future__ import annotations

import json
import re


RETRIEVE_TOOL_MARKERS = ("retrieve_hr_policy", "retrieve", "knowledge", "kb_")


def _safe_json(s):
    """尽力把字符串解析成 JSON；失败返回 None。"""
    if not isinstance(s, str):
        return s
    try:
        return json.loads(s)
    except Exception:
        return None


def _deep_extract_answer(message_str: str) -> str:
    """从层层嵌套的 tool output message 里抽出检索的源文本（answer 字段）。

    结构：'[{"text": "{\\"statusCode\\":200,\\"body\\":\\"{\\\\\\"answer\\\\\\": \\"...\\"}\\"}"}]'
    逐层解析；任何一层失败就回退到正则兜底。
    """
    # 第一层：[{"text": "..."}]
    outer = _safe_json(message_str)
    text_blob = None
    if isinstance(outer, list) and outer and isinstance(outer[0], dict):
        text_blob = outer[0].get("text")
    elif isinstance(outer, dict):
        text_blob = outer.get("text") or outer.get("body")
    if text_blob is None:
        text_blob = message_str

    # 第二层：{"statusCode":200,"body":"{...}"}
    lvl2 = _safe_json(text_blob)
    body = None
    if isinstance(lvl2, dict):
        body = lvl2.get("body", lvl2)
    else:
        body = text_blob

    # 第三层：{"answer":"...","sources":[...]}
    lvl3 = _safe_json(body) if isinstance(body, str) else body
    if isinstance(lvl3, dict) and "answer" in lvl3:
        return str(lvl3["answer"])

    # 兜底：正则直接抠 answer
    m = re.search(r'\\*"answer\\*"\s*:\s*\\*"(.+?)\\*"\s*,\s*\\*"sources', message_str, re.S)
    if m:
        return m.group(1).encode().decode("unicode_escape", errors="replace")
    return ""


def _get_attr(span: dict, key: str):
    return (span.get("attributes") or {}).get(key)


def _msg_text(m, prefer="content"):
    """从一条 message 里取文本，兼容 m 为 str / content 为 str 或 dict 的各种情况。"""
    if isinstance(m, str):
        return m
    if not isinstance(m, dict):
        return ""
    c = m.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, dict):
        if prefer == "message":
            return c.get("message") or c.get("text") or c.get("content") or ""
        return c.get("content") or c.get("text") or c.get("message") or ""
    # content 缺失时退到 m 本身的 text/message
    return m.get("text") or m.get("message") or ""


def _iter_span_events(span: dict):
    for e in (span.get("span_events") or []):
        body = e.get("body") or {}
        yield body


def _is_retrieve_tool(span: dict) -> bool:
    name = (span.get("name") or "")
    tool = _get_attr(span, "gen_ai.tool.name") or ""
    blob = f"{name} {tool}".lower()
    return any(m in blob for m in RETRIEVE_TOOL_MARKERS)


def extract_turns_for_trace(session_spans: list, target_trace_id: str | None) -> list[dict]:
    """从 session_spans 抽出（属于 target_trace_id 的）一个或多个轮次。

    返回 [{"query":..., "sources":[...], "response":...}, ...]
    THELMA 是 turn 级：每个含 retrieve 工具的轮次产出一条。
    """
    spans = [s for s in session_spans if isinstance(s, dict)]
    if target_trace_id:
        filtered = [s for s in spans
                    if s.get("trace_id") == target_trace_id or s.get("traceId") == target_trace_id]
        if filtered:
            spans = filtered

    # 1) 收集 retrieve 工具调用 → (query, source_text)
    retrievals = []
    for s in spans:
        if not _is_retrieve_tool(s):
            continue
        query, source_text = "", ""
        for body in _iter_span_events(s):
            if not isinstance(body, dict):
                continue
            inp_obj = body.get("input")
            inp = inp_obj.get("messages") or [] if isinstance(inp_obj, dict) else []
            for m in inp:
                raw = _msg_text(m)
                q = _safe_json(raw)
                if isinstance(q, dict) and "query" in q:
                    query = str(q["query"])
            out_obj = body.get("output")
            out = out_obj.get("messages") or [] if isinstance(out_obj, dict) else []
            for m in out:
                msg = _msg_text(m, prefer="message")
                if msg:
                    source_text = _deep_extract_answer(msg)
        if query or source_text:
            retrievals.append({"query": query, "source_text": source_text})

    # 2) agent 最终回复：从 chat/agent span 的 assistant 文本取
    response = _extract_agent_response(spans)

    # 3) 组装 turn：把每次检索的 source 作为一条 THELMA turn
    turns = []
    for r in retrievals:
        sources = [r["source_text"]] if r["source_text"] else []
        turns.append({
            "query": r["query"],
            "sources": sources,
            "response": response,
        })
    return turns


def _extract_agent_response(spans: list) -> str:
    """从 chat / LLM span 抽 agent 的最终文本回复（自然语言，非工具调用消息）。

    要点：
    - agent 的最终回复在最后一次 LLM/chat span 的 assistant 输出里，是纯文本。
    - 工具调用/工具结果消息（含 toolUse/toolResult、或形如 JSON 的 statusCode/answer）
      不是给用户的回复，必须排除。
    - 按 span 时间取**最后一个** assistant 文本，而非最长文本（最长往往是工具结果 JSON）。
    """
    import json as _json

    candidates = []  # (start_time, text)
    for s in spans:
        name = (s.get("name") or "").lower()
        scope = (s.get("scope") or {}).get("name", "").lower()
        if "chat" not in name and "llm" not in name and "invoke_model" not in name and "strands" not in scope:
            continue
        st = s.get("start_time") or s.get("startTimeUnixNano") or ""
        for body in _iter_span_events(s):
            if not isinstance(body, dict):
                continue
            out = body.get("output")
            if not isinstance(out, dict):
                continue
            for m in out.get("messages") or []:
                txt = _assistant_plain_text(m)
                if txt:
                    candidates.append((str(st), txt))

    # 兜底：gen_ai.choice 属性
    for s in spans:
        ch = _get_attr(s, "gen_ai.choice")
        if isinstance(ch, str):
            t = _strip_if_tool_payload(ch)
            if t:
                candidates.append((str(s.get("start_time") or ""), t))

    if not candidates:
        return ""
    # 取时间最晚的（agent 的最终自然语言回复）
    candidates.sort(key=lambda x: x[0])
    return candidates[-1][1]


def _looks_like_tool_payload(txt: str) -> bool:
    """判断一段文本是不是工具调用/结果消息（而非给用户的自然语言回复）。"""
    if not isinstance(txt, str):
        return True
    head = txt.lstrip()[:80]
    markers = ('"toolResult"', '"toolUse"', '"statusCode"', '\\"answer\\"',
               '"answer":', 'tooluse_', '"toolUseId"')
    return any(mk in txt[:200] for mk in markers) or head.startswith('[{"tool')


def _strip_if_tool_payload(txt: str) -> str:
    return "" if _looks_like_tool_payload(txt) else txt


def _assistant_plain_text(m) -> str:
    """从一条 message 取 assistant 的纯文本回复；工具消息返回空。"""
    if isinstance(m, str):
        return _strip_if_tool_payload(m)
    if not isinstance(m, dict):
        return ""
    if m.get("role") not in (None, "assistant"):
        return ""
    c = m.get("content")
    if isinstance(c, str):
        return _strip_if_tool_payload(c)
    if isinstance(c, list):
        # content 是块列表：拼接其中的 text 块，跳过 toolUse 块
        parts = []
        for blk in c:
            if isinstance(blk, dict):
                if "toolUse" in blk or "toolResult" in blk:
                    continue
                t = blk.get("text") or ""
                if t:
                    parts.append(t)
            elif isinstance(blk, str):
                parts.append(blk)
        return _strip_if_tool_payload(" ".join(parts))
    if isinstance(c, dict):
        if "toolUse" in c or "toolResult" in c:
            return ""
        t = c.get("text") or c.get("content") or c.get("message") or ""
        return _strip_if_tool_payload(t if isinstance(t, str) else "")
    return ""
