#!/bin/bash
# =============================================================================
# Phase 2b: Deploy HR Tools Lambda + Create Gateway (raw bedrock-agentcore-control API)
# Maps to: 040_create_deploy/043_gateway
#
# Deploys the HR Tools Lambda + provisions the IAM roles here in bash, then
# hands the Gateway + Lambda target creation to gateway/create_gateway.py
# (boto3 → bedrock-agentcore-control) instead of the `agentcore add gateway`
# CLI. This keeps the step self-contained and explicit about the Lambda, IAM
# role, protocol, and auth, while the gateway API logic lives in Python.
# =============================================================================
set -e

REGION=${AWS_DEFAULT_REGION:-us-west-2}
WORKDIR=~/workshop/hrassistant
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GATEWAY_NAME="hrgateway"
TARGET_NAME="hr-tools"
GW_ROLE_NAME="hrassistant-gateway-role"

FUNCTION_NAME="hr-tools-handler"
LAMBDA_ROLE_NAME="hr-tools-lambda-role"
# Lambda 在运行时从 SSM Parameter Store 读取 Knowledge Base ID（由 01-create-kb.sh
# 的 create_kb.py 写入该参数）。本脚本无需关心具体的 KB ID。
KB_ID_SSM_PARAM="/app/hr/knowledge_base_id"

# -----------------------------------------------------------------------------
# Teardown: `02-create-gateway.sh delete` removes the Gateway + Lambda target
# (the Lambda function and IAM roles are left in place — re-running create
# reuses them). Short-circuits before any deploy logic.
# -----------------------------------------------------------------------------
if [ "${1:-}" = "delete" ] || [ "${1:-}" = "--delete" ]; then
  echo "========================================="
  echo "Phase 2b: Delete Gateway"
  echo "========================================="
  export AWS_DEFAULT_REGION="$REGION"
  python3 -m pip install --user --quiet boto3 botocore 2>/dev/null || true
  python3 "$SCRIPT_DIR/gateway/create_gateway.py" delete --name "$GATEWAY_NAME"
  echo "  ✅ Gateway teardown complete"
  exit 0
fi

echo "========================================="
echo "Phase 2b: Deploy Lambda + Create Gateway"
echo "========================================="

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# -----------------------------------------------------------------------------
# 1. Deploy the HR Tools Lambda (creates the function Gateway will target)
# -----------------------------------------------------------------------------
echo "📦 Deploying HR Tools Lambda ($FUNCTION_NAME)..."
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"

# Lambda execution IAM role (idempotent)
echo "  🔐 Creating Lambda execution role..."
aws iam create-role \
  --role-name "$LAMBDA_ROLE_NAME" \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --region $REGION 2>/dev/null || echo "    Role already exists"

aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess 2>/dev/null || true

# Allow the Lambda to read the KB ID from SSM Parameter Store
aws iam put-role-policy --role-name "$LAMBDA_ROLE_NAME" \
  --policy-name "read-kb-id-ssm" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": \"ssm:GetParameter\",
        \"Resource\": \"arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter${KB_ID_SSM_PARAM}\"
      }
    ]
  }"

# Package the handler
echo "  📦 Packaging Lambda..."
( cd "$SCRIPT_DIR/lambda" && zip -j /tmp/hr-tools-lambda.zip hr_tools_handler.py >/dev/null )

# Create or update the function
echo "  🚀 Deploying function code..."
if aws lambda get-function --function-name "$FUNCTION_NAME" --region $REGION >/dev/null 2>&1; then
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file fileb:///tmp/hr-tools-lambda.zip \
    --region $REGION > /dev/null
  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --environment "Variables={KB_ID_SSM_PARAM=$KB_ID_SSM_PARAM}" \
    --region $REGION > /dev/null 2>&1 || true
  echo "    Updated existing function"
else
  sleep 10  # Wait for role propagation
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.12 \
    --handler hr_tools_handler.lambda_handler \
    --role "$LAMBDA_ROLE_ARN" \
    --zip-file fileb:///tmp/hr-tools-lambda.zip \
    --timeout 30 \
    --memory-size 256 \
    --environment "Variables={KB_ID_SSM_PARAM=$KB_ID_SSM_PARAM}" \
    --region $REGION > /dev/null
  echo "    Created new function"
fi

# Grant SSM read permission to the function's ACTUAL execution role.
# The function may have been pre-created by the workshop-infra CFN stack with a
# different role name (e.g. hr-tools-lambda-role-<region>) than the one this
# script creates above (hr-tools-lambda-role). Resolve the real role from the
# deployed function so the KB-ID lookup works regardless of who created it.
echo "  🔐 Ensuring the function's execution role can read the KB ID from SSM..."
ACTUAL_ROLE_ARN=$(aws lambda get-function-configuration \
  --function-name "$FUNCTION_NAME" --region $REGION \
  --query Role --output text 2>/dev/null)
ACTUAL_ROLE_NAME="${ACTUAL_ROLE_ARN##*/}"
if [ -n "$ACTUAL_ROLE_NAME" ] && [ "$ACTUAL_ROLE_NAME" != "None" ]; then
  aws iam put-role-policy --role-name "$ACTUAL_ROLE_NAME" \
    --policy-name "read-kb-id-ssm" \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {
          \"Effect\": \"Allow\",
          \"Action\": \"ssm:GetParameter\",
          \"Resource\": \"arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter${KB_ID_SSM_PARAM}\"
        }
      ]
    }" 2>/dev/null && echo "    Granted ssm:GetParameter to $ACTUAL_ROLE_NAME"
fi

# Allow AgentCore Gateway to invoke the function
echo "  🔗 Adding Gateway invoke permission..."
aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id agentcore-gateway-invoke \
  --action lambda:InvokeFunction \
  --principal bedrock-agentcore.amazonaws.com \
  --region $REGION 2>/dev/null || echo "    Permission already exists"

# Warn if the KB ID SSM parameter hasn't been created yet (01-create-kb.sh)
if ! aws ssm get-parameter --name "$KB_ID_SSM_PARAM" --region $REGION >/dev/null 2>&1; then
  echo "  ⚠️  SSM 参数 $KB_ID_SSM_PARAM 不存在 —— Lambda 将以 mock 模式运行（返回内置示例 HR 政策，无真实检索）。"
  echo "      如需真实 RAG 检索，请先运行 01-create-kb.sh（它会创建该参数）。"
fi
echo "  ✅ Lambda deployed (KB ID from SSM: $KB_ID_SSM_PARAM)"

# -----------------------------------------------------------------------------
# 2. Resolve the HR Tools Lambda ARN
# -----------------------------------------------------------------------------
echo "🔍 Resolving HR Tools Lambda ARN..."
HR_LAMBDA_ARN=$(aws lambda get-function \
  --function-name "$FUNCTION_NAME" --region $REGION \
  --query "Configuration.FunctionArn" --output text 2>/dev/null || echo "")

if [ -z "$HR_LAMBDA_ARN" ] || [ "$HR_LAMBDA_ARN" = "None" ]; then
  echo "⚠️  Could not read function ARN. Falling back to CloudFormation output."
  HR_LAMBDA_ARN=$(aws cloudformation describe-stacks \
    --stack-name workshop-infra \
    --query "Stacks[0].Outputs[?OutputKey=='HRToolsLambdaArn'].OutputValue" \
    --output text --region $REGION 2>/dev/null || echo "")
fi
if [ -z "$HR_LAMBDA_ARN" ] || [ "$HR_LAMBDA_ARN" = "None" ]; then
  echo "⚠️  No ARN found. Falling back to conventional name."
  HR_LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"
fi
echo "  Lambda ARN: $HR_LAMBDA_ARN"

# -----------------------------------------------------------------------------
# 3. Create the Gateway IAM role + Gateway + Lambda target
#    (boto3, via gateway/create_gateway.py)
#    工具 schema 来自 gateway/hr-tools-schema.json（inline payload）。
#    Gateway 角色的创建与传播等待也在 create_gateway.py 内完成。
# -----------------------------------------------------------------------------
export AWS_DEFAULT_REGION="$REGION"   # create_gateway.py 通过 boto3 session 读取 region

echo "📦 Ensuring Python dependencies (boto3)..."
python3 -m pip install --user --quiet boto3 botocore 2>/dev/null || true

echo "🚀 Creating Gateway IAM role + Gateway + Lambda target via boto3..."
python3 "$SCRIPT_DIR/gateway/create_gateway.py" create \
  --name "$GATEWAY_NAME" \
  --target-name "$TARGET_NAME" \
  --lambda-arn "$HR_LAMBDA_ARN" \
  --role-name "$GW_ROLE_NAME" \
  --schema-file "$SCRIPT_DIR/gateway/hr-tools-schema.json"

# -----------------------------------------------------------------------------
# 4. Restrict the harness tool scope
# -----------------------------------------------------------------------------
if [ -f "$WORKDIR/app/hrassistant/harness.json" ]; then
  echo "🔒 Restricting tool scope..."
  jq '.allowedTools = ["code-interpreter", "@hr-tools/*"]' \
    "$WORKDIR/app/hrassistant/harness.json" > "$WORKDIR/tmp.json" \
    && mv "$WORKDIR/tmp.json" "$WORKDIR/app/hrassistant/harness.json"
fi

echo ""
echo "  Next: Run 03-configure-skills.sh"
