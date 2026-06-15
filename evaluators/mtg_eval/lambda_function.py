"""Mind the Goal code-based evaluator for AgentCore (SESSION level).

把整个 session 的多轮对话重建出来，跑 Mind the Goal：分段目标 → 判定每轮成败 →
计算目标达成率 GSR + 失败归因 RCOF 分布。

输出映射：
  value       = GSR / 100   (0~1)
  label       = Pass(GSR>=阈值) / Fail
  explanation = 目标数/成功数/GSR + RCOF 分布
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

from bedrock_agentcore.evaluation.custom_code_based_evaluators import (
    custom_code_based_evaluator,
    EvaluatorInput,
    EvaluatorOutput,
)

from shared.llm_client import LLMClient
from evaluators.mind_the_goal.turn_quality import evaluate_session
from evaluators.mind_the_goal.segmentation import segment_goals
from evaluators.mind_the_goal.gsr import build_summary
from session_adapter import rebuild_session

REGION = os.environ.get("MTG_REGION", "us-west-2")
JUDGE_MODEL = os.environ.get("MTG_MODEL", "us.amazon.nova-2-lite-v1:0")
GSR_PASS_THRESHOLD = float(os.environ.get("MTG_GSR_THRESHOLD", "80"))  # 百分比

_llm = None


def _client():
    global _llm
    if _llm is None:
        _llm = LLMClient(model_id=JUDGE_MODEL, region=REGION)
    return _llm


@custom_code_based_evaluator()
def handler(input: EvaluatorInput, context) -> EvaluatorOutput:
    session = rebuild_session(input.session_spans)
    if not session.turns:
        return EvaluatorOutput(
            value=None, label="Skipped",
            explanation="该 session 无可评估的对话轮次。",
        )

    try:
        llm = _client()
        raw_turns, turn_qualities, _ = evaluate_session(session, llm)
        goals = segment_goals(raw_turns, turn_qualities)
        summary = build_summary(goals)
    except Exception as e:
        import traceback
        print("[MTG] EXCEPTION:", traceback.format_exc())
        return EvaluatorOutput(
            value=None, label="Error",
            errorCode="MTG_EVAL_FAILED", errorMessage=str(e)[:500],
        )

    gsr = summary.get("gsr", 0.0)  # 百分比
    total = summary.get("total_goals", 0)
    succ = summary.get("successful_goals", 0)
    rcof = summary.get("rcof_distribution", {}) or {}
    label = "Pass" if gsr >= GSR_PASS_THRESHOLD else "Fail"

    rcof_txt = "; ".join(f"{k}:{v}" for k, v in rcof.items()) if rcof else "无失败"
    explanation = (
        f"Mind the Goal: GSR={gsr:.1f}% ({succ}/{total} 目标达成), "
        f"轮次数={len(session.turns)}. 失败归因: {rcof_txt}"
    )
    return EvaluatorOutput(value=round(gsr / 100.0, 3), label=label,
                           explanation=explanation[:2000])
