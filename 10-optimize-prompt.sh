#!/bin/bash
# =============================================================================
# Phase 5: Optimize System Prompt + Re-evaluate
# Maps to: 070_optimization/071_optimize_prompt + 072_reevaluate
#
# ADLC 飞轮的闭环步骤：
#   1. 写入加了【抗幻觉约束】的优化版 System Prompt（针对 Phase 4 的 GR↓ / RP↓ 诊断）
#   2. agentcore deploy 重新部署（Prompt 是 Harness 配置的一部分）
#   3. 用【与 Phase 4 完全相同的三个 golden 问题】重新对话（v2 session），产生新 trace
#   4. 轮询等待这些 v2 trace 落库 + 索引
#   5. 对【优化后的 v2 trace】重跑评估并打印分数（复用 09-run-eval.sh --eval-only）
#
# 与优化前对比（GR/SP2/RP 升降）由你对照 content 072 的表格判断：脚本只负责产出
# 优化后的分数。绩效/福利（检索好）应明显提升；病假（检索失效）改 Prompt 救不了，
# 仍 Fail——这正印证 Phase 4 的诊断。
#
# Prerequisites: 04-deploy.sh + 05-setup-memory.sh + 08-create-evaluators.sh
# 用法: ./10-optimize-prompt.sh
# =============================================================================
set -e

REGION=${AWS_DEFAULT_REGION:-us-west-2}
WORKDIR=~/workshop/hrassistant
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTOR_ID="user-emp-v2"

# 与 Phase 4 / 09-run-eval.sh 完全相同的三个 golden 问题（保持文本一致才能公平对比）
GOLDEN_QUERIES=(
  "Can you explain the performance review process and the scoring criteria used?"
  "How do I enroll in benefits, and what is the benefits enrollment process?"
  "Do I need a medical certificate for sick leave, and what is the process?"
)
GOLDEN_LABELS=("绩效 performance review" "福利 benefits enrollment" "病假 sick leave")

echo "========================================="
echo "Phase 5: Optimize Prompt + Re-evaluate"
echo "========================================="

cd "$WORKDIR"

# -----------------------------------------------------------------------------
# Step 1: 写入优化版 System Prompt（相比基线，仅在「重要原则」新增前 5 条抗幻觉约束）
# -----------------------------------------------------------------------------
echo ""
echo "📝 Step 1: 写入优化后的 System Prompt（content 071 原文，含抗幻觉约束）..."
# 与 content 071 一致的中文优化 Prompt。实测：Prompt 语言与中文 KB 政策文档一致时，
# 「严格基于检索 + 忽略无关内容 + 简洁聚焦」这几条抗幻觉约束最见效（检索质量好的
# 绩效/福利问题，GR 与 RP 明显提升）。相比英文 Prompt 少一层语言切换，接地对齐更顺。
# 「## 重要原则」段前 5 条即抗幻觉约束，针对 Phase 4 的 GR↓ / RP↓ 诊断。
cat > app/hrassistant/system-prompt.md << 'PROMPT'
你是一位专业的企业HR助手。你的职责是帮助员工解答人力资源相关问题并协助处理HR事务。

## 能力范围
- 解答HR政策问题（年假、病假、调休、薪资结构、福利等）
- 协助休假申请流程
- 解释薪资结构和福利制度
- 指导入职/离职流程
- 解答绩效评估相关问题

## 工具使用
- 通过 hr-tools 查询知识库获取政策文档
- 通过 hr-tools 执行HR操作（查询余额、提交申请等）

## 输出格式
每次回答应包含：
- 清晰的结构化答案
- 引用具体的政策条款和文档来源
- 如涉及流程，给出步骤化指引
- 如涉及计算，展示计算过程

## 重要原则
- **严格基于检索内容回答**：你的回答必须完全来自 hr-tools 检索到的政策文档。
- **不要使用你自己的常识或训练知识编造政策细节**（如具体天数、流程步骤、审批层级）。
- 如果检索结果中**没有**与问题相关的内容，明确告知"知识库中暂无相关政策"，并建议联系 HR，**不要猜测或编造**。
- 检索结果中如混有与当前问题**无关**的内容，忽略它们，只引用真正相关的部分。
- 回答应**简洁聚焦**：只包含直接回答问题所需的内容，避免堆砌无关政策或冗余信息。
- 如果你了解员工的部门、职级等上下文，必须结合具体情况作答
- 如果你记得员工之前的偏好或查询历史，主动应用而非重新询问
- 始终引用答案来自哪份政策文档
- 涉及敏感信息（薪资、绩效）时，确认 actorId 隔离
PROMPT
echo "  ✅ 已写入 app/hrassistant/system-prompt.md"

# -----------------------------------------------------------------------------
# Step 2: 重新部署（Prompt 是 Harness 配置的一部分，约 3-5 分钟）
# -----------------------------------------------------------------------------
echo ""
echo "🚀 Step 2: 重新部署 Harness（应用新 Prompt，约 3-5 分钟）..."
npx agentcore deploy --yes 2>&1 | tail -5

# 等 Harness 离开 CREATING/UPDATING，避免随后 invoke 撞上更新中状态
HARNESS_ID=$(python3 -c "
import json
with open('agentcore/.cli/deployed-state.json') as f:
    st = json.load(f)
for n, info in st.get('targets',{}).get('default',{}).get('resources',{}).get('harnesses',{}).items():
    if 'harnessId' in info: print(info['harnessId']); break
" 2>/dev/null)
if [ -n "$HARNESS_ID" ]; then
  echo "  ⏳ 等待 Harness 就绪..."
  for i in $(seq 1 40); do
    S=$(AWS_DEFAULT_REGION=$REGION python3 -c "
import boto3
c = boto3.client('bedrock-agentcore-control', region_name='$REGION')
try:
    r = c.get_harness(harnessId='$HARNESS_ID'); print((r.get('harness',r)).get('status','UNKNOWN'))
except Exception: print('UNKNOWN')
" 2>/dev/null || echo UNKNOWN)
    [ "$S" = "READY" ] || [ "$S" = "ACTIVE" ] && { echo "  ✅ Harness $S"; break; }
    sleep 10
  done
fi

# -----------------------------------------------------------------------------
# Step 3: 用相同的三个问题重新对话（v2 session），产生优化后的 trace
# -----------------------------------------------------------------------------
echo ""
echo "🗣️  Step 3: 用优化后的 Agent 重新跑三个 golden 问题（v2）..."
for i in "${!GOLDEN_QUERIES[@]}"; do
  Q="${GOLDEN_QUERIES[$i]}" ; L="${GOLDEN_LABELS[$i]}"
  SID="v2-$(cat /proc/sys/kernel/random/uuid)-$(date +%s)"
  echo ""
  echo "─── Q$((i+1)) [$L] ───"
  echo "    \"$Q\"   (session: $SID)"
  npx agentcore invoke --session-id "$SID" --actor-id "$ACTOR_ID" --stream "$Q" \
    2>&1 | grep -vE 'PythonDeprecationWarning|warnings.warn|boto3 will no longer|upgrade to Python|More information can' || true
  echo ""
done

# -----------------------------------------------------------------------------
# Step 4 + 5: 评估优化后的 v2 trace 并打印分数
#   复用 09-run-eval.sh --eval-only：它会轮询取最近 3 条含检索的 trace（即刚跑的
#   v2 三条，按时间倒序），逐 trace 跑 THELMA、逐 session 跑 Mind the Goal，
#   并打印 Query + 截断 Response + 分数。
# -----------------------------------------------------------------------------
echo ""
echo "🔬 Step 4+5: 评估优化后的对话（v2 trace）..."
echo "   （等待 span 索引后评估，复用 09-run-eval.sh）"
# 先等待这三条 v2 trace 索引完成，再评估，确保评的是 v2 而非旧 trace
echo "   ⏳ 等待 v2 trace 落库 + 索引..."
for i in $(seq 1 15); do
  CNT=$(aws logs filter-log-events --region $REGION --log-group-name "aws/spans" \
    --start-time $(( ($(date +%s) - 600) * 1000 )) \
    --filter-pattern '"execute_tool hr-tools___retrieve_hr_policy"' \
    --query "events[].message" --output text 2>/dev/null | tr '\t' '\n' | grep -c 'traceId' 2>/dev/null || echo 0)
  echo "     [$((i*10))s] 近 10 分钟含检索 span: $CNT"
  [ "${CNT:-0}" -ge 3 ] && break
  sleep 10
done

"$SCRIPT_DIR/09-run-eval.sh" --eval-only 3

echo ""
echo "========================================="
echo "✅ Phase 5 完成：Prompt 已优化、重新部署、重新评估"
echo "========================================="
echo ""
echo "对照 content 072 的对比表解读："
echo "  - 绩效 / 福利（检索质量好）→ GR / SP2 / RP 应明显提升（Prompt 优化奏效）"
echo "  - 病假（SP1=1.0 假象、SP2≈0 检索失效）→ 仍 Fail（改 Prompt 救不了，根因在 KB）"
echo "  这正印证了 Phase 4 THELMA 诊断的准确性：精准区分「该改 Prompt」vs「该改检索」。"
