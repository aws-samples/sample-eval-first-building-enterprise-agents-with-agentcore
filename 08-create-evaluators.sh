#!/bin/bash
# =============================================================================
# Phase 4a: Create Custom Evaluators (THELMA + Mind the Goal)
# Maps to: 060_golden_set_eval
#
# 注册并部署两个自定义 code-based evaluator：
#   - thelma_rag_quality (TRACE级)  : RAG 6维质量,主分 Groundedness
#   - mtg_goal_success   (SESSION级): 目标达成率 GSR + 失败归因 RCOF
#
# 注意三个已知 CLI 行为（脚本已规避）：
#   1. `agentcore add evaluator` 注册时会用 scaffold 覆盖 lambda_function.py
#      和 pyproject.toml → 脚本注册后从 evaluators/ 源码还原
#   2. evaluator 代码更新后 deploy 需清 .cache 才会重建
#   3. evaluator 执行角色默认无 Bedrock 权限 → 部署后手动补
# =============================================================================
set -e

REGION=${AWS_DEFAULT_REGION:-us-west-2}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
WORKDIR=~/workshop/hrassistant
# evaluator 源码随 workshop 提供；脚本目录的 evaluators/ 是权威副本
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/evaluators"

# judge 模型等全局配置集中在 00-config.sh（单一可配置来源）
source "$SCRIPT_DIR/00-config.sh"

echo "========================================="
echo "Phase 4a: Create Custom Evaluators"
echo "========================================="

cd $WORKDIR

# -----------------------------------------------------------------------------
# 把 evaluator 源码放到项目下（codeLocation 相对 ~/workshop/hrassistant）
# -----------------------------------------------------------------------------
mkdir -p evaluators
for ev in thelma_eval mtg_eval; do
  cp -r "$SRC_DIR/$ev" evaluators/
done
echo "📁 Evaluator source copied to $WORKDIR/evaluators/"

# -----------------------------------------------------------------------------
# 注册 + 还原代码（规避 CLI scaffold 覆盖）
# -----------------------------------------------------------------------------
register_evaluator() {
  local name="$1" level="$2" srcdir="$3" codeloc="$4"
  echo ""
  echo "🔧 Registering evaluator: $name ($level)"

  # config 文件只含 config 层（CLI 要求）
  cat > /tmp/${name}-config.json <<JSON
{
  "codeBased": {
    "managed": {
      "codeLocation": "$codeloc",
      "entrypoint": "lambda_function.handler",
      "timeoutSeconds": 180
    }
  }
}
JSON

  local out
  out=$(npx agentcore add evaluator --name "$name" --level "$level" \
    --type code-based --config /tmp/${name}-config.json --json 2>&1 | tail -1)
  if echo "$out" | grep -q '"success":true'; then
    echo "  registered (new)"
  elif echo "$out" | grep -qi "already exists"; then
    echo "  already registered (will redeploy latest code)"
  else
    echo "  $out"
  fi

  # CLI scaffold 会重建 codeLocation 目录，丢掉 shared/、evaluators/ 子模块。
  # 整个目录覆盖回去（含 shared/ 与 evaluators/），保证 Lambda 打包完整。
  # 只 cp lambda_function.py + pyproject.toml 不够：deploy 出去的 Lambda 会
  # 在 cold start 报 "No module named 'shared'"。
  rm -rf "evaluators/$srcdir"
  cp -r "$SRC_DIR/$srcdir" evaluators/
  echo "  ✅ $name source ready (full tree restored)"
}

register_evaluator "thelma_rag_quality" "TRACE"   "thelma_eval" "evaluators/thelma_eval"
register_evaluator "mtg_goal_success"   "SESSION" "mtg_eval"    "evaluators/mtg_eval"

# -----------------------------------------------------------------------------
# 部署（清缓存确保用最新代码）
# -----------------------------------------------------------------------------
echo ""
echo "🚀 Deploying evaluators (clearing build cache first)..."
rm -rf agentcore/.cache/thelma_rag_quality agentcore/.cache/mtg_goal_success 2>/dev/null || true
npx agentcore deploy --yes 2>&1 | tail -3

# -----------------------------------------------------------------------------
# 补 Bedrock 权限到 evaluator 执行角色（LLM-judge 必需）
# -----------------------------------------------------------------------------
echo ""
echo "🔐 Granting Bedrock permissions to evaluator roles..."
cat > /tmp/eval-bedrock-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
    "Resource": [
      "arn:aws:bedrock:*::foundation-model/*",
      "arn:aws:bedrock:*:${ACCOUNT_ID}:inference-profile/*"
    ]
  }]
}
JSON

for FN in hrassistant-eval-thelma_rag_quality hrassistant-eval-mtg_goal_success; do
  ROLE=$(aws lambda get-function-configuration --function-name "$FN" --region $REGION \
    --query Role --output text 2>/dev/null | sed 's/.*role\///')
  if [ -n "$ROLE" ]; then
    aws iam put-role-policy --role-name "$ROLE" \
      --policy-name EvaluatorBedrockInvoke \
      --policy-document file:///tmp/eval-bedrock-policy.json 2>/dev/null && \
      echo "  ✅ $FN → $ROLE"
  fi
done

# -----------------------------------------------------------------------------
# 注入 judge 模型环境变量（覆盖 lambda_function.py 默认值，由 00-config.sh 统一控制）
#   THELMA lambda 读 THELMA_MODEL，MTG lambda 读 MTG_MODEL。
# -----------------------------------------------------------------------------
echo ""
echo "🧠 Setting judge model on evaluator Lambdas ($WORKSHOP_JUDGE_MODEL)..."
aws lambda update-function-configuration \
  --function-name hrassistant-eval-thelma_rag_quality --region $REGION \
  --environment "Variables={THELMA_MODEL=$WORKSHOP_JUDGE_MODEL}" >/dev/null 2>&1 && \
  echo "  ✅ thelma_rag_quality THELMA_MODEL=$WORKSHOP_JUDGE_MODEL" || \
  echo "  ⚠️  failed to set THELMA_MODEL (lambda will fall back to its default)"
aws lambda update-function-configuration \
  --function-name hrassistant-eval-mtg_goal_success --region $REGION \
  --environment "Variables={MTG_MODEL=$WORKSHOP_JUDGE_MODEL}" >/dev/null 2>&1 && \
  echo "  ✅ mtg_goal_success MTG_MODEL=$WORKSHOP_JUDGE_MODEL" || \
  echo "  ⚠️  failed to set MTG_MODEL (lambda will fall back to its default)"

echo ""
echo "✅ Evaluators created and deployed"
echo "  - thelma_rag_quality (TRACE)"
echo "  - mtg_goal_success (SESSION)"
echo "  Next: Run 09-run-eval.sh (批量评估)"
