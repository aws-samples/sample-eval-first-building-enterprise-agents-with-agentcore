#!/bin/bash
# =============================================================================
# Workshop 全局配置 — 单一可配置来源 (Single Source of Truth)
#
# 其它脚本通过 `source 00-config.sh` 引入这些变量。要把整个 workshop 切换到
# 另一个模型，只需改这里的 WORKSHOP_MODEL_ID / WORKSHOP_JUDGE_MODEL 一处。
#
# 说明：
#   - WORKSHOP_MODEL_ID  : Agent 本体模型（04-deploy.sh 创建 Harness 时使用）
#   - WORKSHOP_JUDGE_MODEL: 评估器 LLM-as-judge 模型（08 注入到 evaluator Lambda
#                           的 THELMA_MODEL / MTG_MODEL 环境变量）
#   - 二者默认相同；如需 judge 用更强模型，单独改 WORKSHOP_JUDGE_MODEL 即可。
#
# 选型说明：默认用 Amazon Nova（us.amazon.nova-*），它在所有账户默认可用、
#   无需在 Bedrock 控制台单独启用 model access / marketplace 订阅，避免 workshop
#   首次对话因模型未订阅而 AccessDenied。换成 Anthropic Claude 等第三方模型时，
#   需确保账户已启用对应 model access。
# =============================================================================

# 允许外部用环境变量覆盖（不写死，便于 CI / 个性化切换）
export WORKSHOP_MODEL_ID="${WORKSHOP_MODEL_ID:-us.amazon.nova-2-lite-v1:0}"
export WORKSHOP_JUDGE_MODEL="${WORKSHOP_JUDGE_MODEL:-$WORKSHOP_MODEL_ID}"
export WORKSHOP_EMBED_MODEL="${WORKSHOP_EMBED_MODEL:-amazon.titan-embed-text-v2:0}"
