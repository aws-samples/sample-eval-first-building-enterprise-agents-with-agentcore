"""THELMA code-based evaluator for AgentCore (TRACE level).

把一条 trace 的 retrieve 工具调用 + agent 回复抽出来，跑 THELMA 6 维 RAG 质量评估，
按 qa-eval UI 的口径输出：value=Groundedness（头号防幻觉指标），label 按阈值 Pass/Fail，
explanation 含全部 6 维 + 诊断。
"""
import os
import sys

# 让 evaluators.thelma / shared 可导入（包根就是本文件所在目录）
sys.path.insert(0, os.path.dirname(__file__))

from bedrock_agentcore.evaluation.custom_code_based_evaluators import (
    custom_code_based_evaluator,
    EvaluatorInput,
    EvaluatorOutput,
)

from shared.llm_client import LLMClient
from shared.embedding_client import EmbeddingClient
from evaluators.thelma.metrics import evaluate_turn_detailed
from evaluators.thelma.interplay import diagnose
from span_adapter import extract_turns_for_trace

REGION = os.environ.get("THELMA_REGION", "us-west-2")
JUDGE_MODEL = os.environ.get("THELMA_MODEL", "us.amazon.nova-2-lite-v1:0")
EMBED_MODEL = os.environ.get("THELMA_EMBED_MODEL", "amazon.titan-embed-text-v2:0")
GR_PASS_THRESHOLD = float(os.environ.get("THELMA_GR_THRESHOLD", "0.7"))

_llm = None
_embed = None


def _clients():
    global _llm, _embed
    if _llm is None:
        _llm = LLMClient(model_id=JUDGE_MODEL, region=REGION)
        _embed = EmbeddingClient(model_id=EMBED_MODEL, region=REGION)
    return _llm, _embed


@custom_code_based_evaluator()
def handler(input: EvaluatorInput, context) -> EvaluatorOutput:
    turns = extract_turns_for_trace(input.session_spans, input.target_trace_id)
    # 只评有检索来源的轮次（THELMA 要 sources）
    rag_turns = [t for t in turns if t.get("sources") and t.get("query")]
    if not rag_turns:
        return EvaluatorOutput(
            value=None, label="Skipped",
            explanation="该 trace 无含检索来源的轮次，THELMA 跳过（纯工具/无 RAG 轮次）。",
        )

    t = rag_turns[0]  # TRACE 级：评该 trace 的检索轮次
    try:
        llm, embed = _clients()
        scores, evidence = evaluate_turn_detailed(
            query=t["query"], sources=t["sources"], response=t["response"],
            llm=llm, embed_fn=embed.embed, skip_sp2=False,  # 打开 SP2（原子事实级检索精度）
            # SP2 比 SP1 贵，但只有它能暴露「块内夹带脏事实」——即一个 chunk 里既有相关
            # 政策正文、又混入无关的 HR-MultiWOZ FAQ。SP1（块级）对这种情况判满分，
            # 会掩盖 KB 质量问题；SP2（事实级）才能让「需要清理知识库」的 insight 浮现。
        )
    except Exception as e:
        import traceback
        print("[THELMA] EXCEPTION:", traceback.format_exc())  # 排错用，保留
        return EvaluatorOutput(
            value=None, label="Error",
            errorCode="THELMA_EVAL_FAILED", errorMessage=str(e)[:500],
        )

    gr = round(scores.groundedness, 3)
    label = "Pass" if gr >= GR_PASS_THRESHOLD else "Fail"

    diags = diagnose(scores)
    diag_txt = "; ".join(f"{d.pattern}->{d.component_to_improve}" for d in diags) if diags else "无"

    explanation = (
        f"THELMA 7 维 (query: {t['query'][:40]}): "
        f"GR(接地/防幻觉)={gr} | "
        f"SP1(块级检索精度)={scores.source_precision_chunk:.2f} | "
        f"SP2(事实级检索精度)={scores.source_precision_fact:.2f} | "
        f"SQC(源覆盖)={scores.source_query_coverage:.2f} | "
        f"RP(响应精度)={scores.response_precision:.2f} | "
        f"RQC(响应覆盖)={scores.response_query_coverage:.2f} | "
        f"SD(去重)={scores.response_self_distinctness:.2f}. "
        f"诊断: {diag_txt}"
    )
    return EvaluatorOutput(value=gr, label=label, explanation=explanation[:2000])
