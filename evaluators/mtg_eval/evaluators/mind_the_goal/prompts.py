"""Mind the Goal prompt templates from paper Appendix D."""

EVALUATION_SYSTEM_PROMPT = "You are a helpful AI assistant. You will act as a judge to evaluate quality of employee experience chatbot."

EVALUATION_TEMPLATE = """{system_prompt}
You are provided with a dialog from an employee chatbot.
Output the JSON for every turn, reasoning inside <think>...</think> tags
but printing *only* the JSON after your reasoning.

output format:
{{
  dialog_id: xx,
  turns: [
    {{turn_number: 1, is_new_goal: yes/no, quality: success/failure, rcof: E1-E7 | null}},
    {{turn_number: 2, is_new_goal: yes/no, quality: success/failure, rcof: E1-E7 | null}},
    ...
  ]
}}
where
  is_new_goal in {{yes,no}} - compare adjacent user turns
  quality in {{success,failure}} - based on response + follow-ups
  rcof in {{E1-E7}} if failure else null

RCOF codes:
  E1 Language Understanding Failure - misinterprets question
  E2 Refusal to Answer - unwarranted refusal
  E3 Incorrect Retrieval - irrelevant docs retrieved
  E4 Retrieval Failure - no docs retrieved
  E5 System Error - blank / truncated response
  E6 Incorrect Routing - wrong domain/department
  E7 Out-of-Domain Query - capability not supported

input:
{dialog}"""


def format_dialog(turns: list[dict]) -> str:
    """Format conversation turns into a readable dialog string."""
    lines = []
    for t in turns:
        lines.append(f"Turn {t['turn_number']}:")
        lines.append(f"  Employee: {t['user_message']}")
        lines.append(f"  Assistant: {t['agent_response']}")
        if t.get("tool_calls"):
            for tc in t["tool_calls"]:
                lines.append(f"  [Tool: {tc['tool_name']} → {tc.get('output', {}).get('status', 'unknown')}]")
        lines.append("")
    return "\n".join(lines)


def build_evaluation_prompt(turns: list[dict], dialog_id: str = "1") -> str:
    dialog_text = format_dialog(turns)
    return EVALUATION_TEMPLATE.format(
        system_prompt=EVALUATION_SYSTEM_PROMPT,
        dialog=dialog_text,
    )
