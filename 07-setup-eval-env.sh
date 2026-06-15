#!/bin/bash
# =============================================================================
# Phase 4 (pre): Setup Evaluation Environment
# Maps to: 060_golden_set_eval (Phase 4 - Golden Set Batch Evaluation)
#
# 评估飞轮（Phase 4-6）依赖三项环境前置，本脚本一次性配好：
#   1. uv —— managed code-based evaluator 打包 Python 依赖必需
#   2. CloudWatch Transaction Search —— Agent 的 OTel trace span 必须落到
#      CloudWatch 才能被评估服务读取（否则 run eval 报 "No session spans found"）
#   3. (评估器执行角色权限在 08-create-evaluators.sh 部署后配置)
# =============================================================================
set -e

REGION=${AWS_DEFAULT_REGION:-us-west-2}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "========================================="
echo "Phase 4 (pre): Setup Evaluation Environment"
echo "========================================="
echo "  Region: $REGION"
echo "  Account: $ACCOUNT_ID"

# -----------------------------------------------------------------------------
# 1. 安装 uv（code-based evaluator 打包依赖所需）
# -----------------------------------------------------------------------------
echo ""
echo "📦 Checking uv (required for evaluator packaging)..."
if command -v uv >/dev/null 2>&1; then
  echo "  uv already installed: $(uv --version)"
else
  echo "  Installing uv..."
  python3 -m pip install --user --quiet uv 2>/dev/null || pip3 install --user --quiet uv
  export PATH="$HOME/.local/bin:$PATH"
  hash -r
  echo "  ✅ uv installed: $(uv --version)"
  echo "  ⚠️  Ensure ~/.local/bin is on PATH for subsequent scripts:"
  echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# -----------------------------------------------------------------------------
# 2. 启用 CloudWatch Transaction Search
#    Agent runtime 的 OTel span 默认导出失败（400），评估服务读不到 trace。
#    需把 X-Ray trace 段目标改为 CloudWatchLogs + 授权 X-Ray 写 aws/spans。
# -----------------------------------------------------------------------------
echo ""
echo "🔭 Enabling CloudWatch Transaction Search..."

CURRENT_DEST=$(aws xray get-trace-segment-destination --region $REGION \
  --query 'Destination' --output text 2>/dev/null || echo "none")

if [ "$CURRENT_DEST" = "CloudWatchLogs" ]; then
  echo "  Transaction Search already enabled (destination: CloudWatchLogs)"
else
  echo "  Creating CloudWatch Logs resource policy for X-Ray..."
  POLICY_DOC=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "xray.amazonaws.com"},
    "Action": ["logs:PutLogEvents", "logs:CreateLogStream"],
    "Resource": [
      "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:aws/spans:*",
      "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/aws/application-signals/data:*"
    ],
    "Condition": {
      "ArnLike": {"aws:SourceArn": "arn:aws:xray:${REGION}:${ACCOUNT_ID}:*"},
      "StringEquals": {"aws:SourceAccount": "${ACCOUNT_ID}"}
    }
  }]
}
JSON
)
  aws logs put-resource-policy --region $REGION \
    --policy-name TransactionSearchXRayAccess \
    --policy-document "$POLICY_DOC" >/dev/null
  echo "  Setting trace segment destination to CloudWatchLogs..."
  aws xray update-trace-segment-destination --region $REGION \
    --destination CloudWatchLogs >/dev/null
  echo "  Setting span indexing sampling to 100%..."
  aws xray update-indexing-rule --region $REGION \
    --name Default --rule '{"Probabilistic":{"DesiredSamplingPercentage":100.0}}' >/dev/null || true

  echo "  ⏳ Waiting for Transaction Search to become ACTIVE..."
  for i in $(seq 1 20); do
    S=$(aws xray get-trace-segment-destination --region $REGION --query 'Status' --output text 2>/dev/null)
    [ "$S" = "ACTIVE" ] && { echo "  ✅ Transaction Search ACTIVE"; break; }
    sleep 15
  done
fi

echo ""
echo "✅ Evaluation environment ready"
echo "  - uv: $(command -v uv >/dev/null 2>&1 && uv --version || echo 'see PATH note above')"
echo "  - Transaction Search: $(aws xray get-trace-segment-destination --region $REGION --query 'Status' --output text 2>/dev/null)"
echo ""
echo "  ⚠️  IMPORTANT: 启用 Transaction Search 后，需重新跑一次对话生成新 trace"
echo "      （之前的对话 trace 未落库）。运行 06-test-conversation.sh 即可。"
echo "  Next: Run 08-create-evaluators.sh"
