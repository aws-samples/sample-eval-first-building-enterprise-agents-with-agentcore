#!/bin/bash
# =============================================================================
# Optional Lab A: Multi-Model Comparison（多模型成本/质量权衡）
# Maps to: 085_optional_labs/086_compare_models
#
# 回答 CXO 最爱问的一句："能不能换个更便宜/更快的模型，质量还过得去？"
# 做法：把当前 Harness 的模型【非破坏性地】换成对比模型、重新部署、用同一套
# 3 个 golden 问题重跑 + 用同一个 THELMA 评估，再和 Phase 4 基线对比 质量/成本/延迟。
# 把"换模型"从拍脑袋变成看数据。
#
# 【为什么不重跑 04-deploy.sh 来换模型】
#   04-deploy.sh 开头会 `rm -rf hrassistant`，那会连带删掉 08 建好的评估器项目，
#   导致随后没有 THELMA/MtG 可评。所以这里【不重建项目】，只在 harness.json 里把
#   模型 ID 字符串替换掉再 deploy，评估器原样保留。
#
# ⚠️  可选延伸，不在 2 小时主线内。含两次重新部署（换模型 + 还原），约 10-15 分钟。
#
# ⚠️  需在 test 环境先验证一次：
#   - 模型 ID 是否确实写在 app/hrassistant/harness.json 里（脚本会检查，找不到就报错退出，
#     不会静默空跑）。若 CLI 把模型存在别处（如 agentcore/ 配置），按报错提示调整替换目标。
#   - `agentcore deploy` 是否能让改后的模型生效。
#
# 用法:
#   ./12-compare-models.sh                          # 默认对比模型 = Nova Pro（同家更大、tool-use 稳）
#   ./12-compare-models.sh us.amazon.nova-pro-v1:0  # 等价默认值
#   ./12-compare-models.sh us.anthropic.claude-haiku-4-5-20251001-v1:0  # 想试别家也可
#
# ⚠️ 不建议直接用 Nova Micro 这一档作对比：在 Strands ToolUse 严格协议下经常报
#    `Model produced invalid sequence as part of ToolUse`，三次对话全失败、无数据。
#    小模型 tool-use 不稳本身是评估的有用结论，但不适合放在 demo 首发。
#
# Prerequisites: 已完成 Phase 2-4（Harness 部署 + 评估器就绪）。
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/00-config.sh" ] && source "$SCRIPT_DIR/00-config.sh"

REGION=${AWS_DEFAULT_REGION:-us-west-2}
WORKDIR=~/workshop/hrassistant
HARNESS_JSON="$WORKDIR/app/hrassistant/harness.json"
BASELINE_MODEL="${WORKSHOP_MODEL_ID:-us.amazon.nova-2-lite-v1:0}"
# 默认对比模型选 Nova Pro：同家更大的模型，tool-use 协议稳定，能产出 trace 做对比。
# 不要用 Nova Micro 这一档：Micro/Haiku 这种小模型在 Strands ToolUse 严格协议下经常
# 报 `Model produced invalid sequence as part of ToolUse`，三次对话全失败、没数据可比。
# 这本身也是一种评估结论（"小模型搭不上当前 Agent 拓扑"），但不适合放在演示首发。
# 想自选别的模型：./12-compare-models.sh us.xxx.xxx-v1:0
COMPARE_MODEL="${1:-us.amazon.nova-pro-v1:0}"

echo "========================================="
echo "Optional Lab A: 多模型对比"
echo "========================================="
echo "  基线模型(Phase 4): $BASELINE_MODEL"
echo "  对比模型(本次):     $COMPARE_MODEL"
echo ""
echo "  本脚本会：在 harness.json 里把模型换成对比模型 → 重新部署 → 重跑 3 个 golden"
echo "  问题并评估 → 算成本/延迟 → 自动还原回基线模型。约 10-15 分钟（不删评估器）。"
echo ""

[ -f "$HARNESS_JSON" ] || { echo "❌ 找不到 $HARNESS_JSON，请先完成 Phase 2 部署。"; exit 1; }

# 校验：基线模型 ID 必须确实出现在 harness.json 里，否则替换无意义 → 直接报错退出
if ! grep -q "$BASELINE_MODEL" "$HARNESS_JSON"; then
  echo "❌ 在 harness.json 里没找到基线模型 ID（$BASELINE_MODEL）。"
  echo "   说明 CLI 可能把模型配置存在了别处。请在 test 环境确认模型 ID 写在哪个文件，"
  echo "   再把本脚本的替换目标 (HARNESS_JSON) 改成那个文件。已中止，未做任何改动。"
  exit 1
fi

read -p "  继续？(y/N) " ok
[ "$ok" = "y" ] || [ "$ok" = "Y" ] || { echo "已取消。"; exit 0; }

cd "$WORKDIR"

# 退出时（无论成功/失败/中断）把模型还原回基线并重新部署
restore_model() {
  if grep -q "$COMPARE_MODEL" "$HARNESS_JSON"; then
    echo ""
    echo "♻️  还原模型回 $BASELINE_MODEL 并重新部署..."
    python3 - "$HARNESS_JSON" "$COMPARE_MODEL" "$BASELINE_MODEL" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding='utf-8').read()
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
PY
    npx agentcore deploy --yes 2>&1 | tail -3 || true
    echo "  ✅ 已还原为基线模型"
  fi
}
trap restore_model EXIT

# -----------------------------------------------------------------------------
# Step 1: 把 harness.json 里的模型 ID 替换为对比模型，重新部署
# -----------------------------------------------------------------------------
echo ""
echo "🔧 Step 1: 切换模型到 $COMPARE_MODEL 并重新部署（约 3-5 分钟）..."
python3 - "$HARNESS_JSON" "$BASELINE_MODEL" "$COMPARE_MODEL" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding='utf-8').read()
n = s.count(old)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
print(f'  已在 harness.json 替换 {n} 处模型 ID')
PY
npx agentcore deploy --yes 2>&1 | tail -5

# -----------------------------------------------------------------------------
# Step 2: 重跑 3 个 golden 问题 + 评估（复用 09-run-eval.sh）
# 关键：通过 SINCE_EPOCH_MS 严格限定时间下界，防止本次 invoke 失败（如 ToolUse
# 报错）时 09 静默拿到上一轮 v2-* 的旧 trace 产出"看似成功但完全错误"的对比数据。
# -----------------------------------------------------------------------------
echo ""
echo "🗣️  Step 2: 用对比模型重跑 3 个 golden 问题并评估..."
export SINCE_EPOCH_MS=$(( $(date +%s) * 1000 ))   # 本次切换模型完成时刻
echo "   (严格时间下界 SINCE_EPOCH_MS=$SINCE_EPOCH_MS — 评估只接受此后产生的 trace)"
"$SCRIPT_DIR/09-run-eval.sh"

# -----------------------------------------------------------------------------
# Step 3: 成本/延迟（11 默认 Nova 2 Lite 单价；对比模型单价不同，用 PRICE_* 覆盖）
# -----------------------------------------------------------------------------
echo ""
echo "💰 Step 3: 对比模型的成本与延迟..."
echo "   （注意：11 默认用 Nova 2 Lite 单价；对比模型单价不同，可用 PRICE_IN/PRICE_OUT 覆盖）"
"$SCRIPT_DIR/11-cost-latency.sh" || true

echo ""
echo "========================================="
echo "✅ 对比数据已产出（退出时模型自动还原为基线）"
echo "========================================="
echo ""
echo "怎么读：把上面对比模型的 THELMA 分数 / 延迟 / 成本，与 Phase 4 基线"
echo "（content 063 的表，$BASELINE_MODEL）并排比："
echo "  - 质量分掉了多少？（GR / Pass 率）   - 省了多少钱、快了多少？"
echo "质量基本不掉而成本下降 → 换便宜模型划算；质量明显下滑 → 贵模型的钱花得值。"
echo "这就是用数据做模型选型，而非拍脑袋。"
