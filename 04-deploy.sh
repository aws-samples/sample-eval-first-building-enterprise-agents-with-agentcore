#!/bin/bash
# =============================================================================
# Phase 2d: Create Harness + Deploy
# Maps to: 040_create_deploy/045_create_harness
#
# Creates the Harness project via agentcore CLI. Gateway is NOT created inside
# the project — it already exists (02-create-gateway.sh), referenced by ARN.
# This avoids CDK deploying a duplicate Gateway and eliminates the two-pass
# deploy requirement.
#
# Prerequisites:
#   - 00-deploy-infra.sh (VPC, S3, EC2)
#   - 01-create-kb.sh (Knowledge Base — Lambda reads KB ID from SSM)
#   - 02-create-gateway.sh (Gateway + Lambda deployed, ARN in SSM)
#   - 03-configure-skills.sh (Skills uploaded to S3)
# =============================================================================
set -e

REGION=${AWS_DEFAULT_REGION:-us-west-2}
WORKDIR=~/workshop
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 模型 ID 等全局配置集中在 00-config.sh（单一可配置来源）
source "$SCRIPT_DIR/00-config.sh"

echo "========================================="
echo "Phase 2d: Create Harness + Deploy"
echo "========================================="

# ---- Step 1: Read infrastructure outputs ----
echo "🔍 Reading infrastructure config..."

SUBNETS=$(aws cloudformation describe-stacks \
  --stack-name workshop-infra \
  --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnets'].OutputValue" \
  --output text --region $REGION 2>/dev/null || echo "")

SG=$(aws cloudformation describe-stacks \
  --stack-name workshop-infra \
  --query "Stacks[0].Outputs[?OutputKey=='SecurityGroupId'].OutputValue" \
  --output text --region $REGION 2>/dev/null || echo "")

SKILLS_AP_ARN=$(aws cloudformation describe-stacks \
  --stack-name workshop-infra \
  --query 'Stacks[0].Outputs[?OutputKey==`SkillsAccessPointArn` || OutputKey==`DataAccessPointArn`].OutputValue | [0]' \
  --output text --region $REGION 2>/dev/null || echo "")

GATEWAY_ARN=$(aws ssm get-parameter --name /app/hr/gateway_arn --region $REGION \
  --query "Parameter.Value" --output text 2>/dev/null || echo "")

echo "  Subnets: $SUBNETS"
echo "  Security Group: $SG"
echo "  Skills AP: $SKILLS_AP_ARN"
echo "  Gateway ARN: $GATEWAY_ARN"

if [ -z "$GATEWAY_ARN" ] || [ "$GATEWAY_ARN" = "None" ]; then
  echo "❌ Gateway ARN not found in SSM. Run 02-create-gateway.sh first."
  exit 1
fi

# ---- Step 2: Write system prompt ----
echo "📝 Writing system prompt..."
cat > $WORKDIR/system-prompt.txt << 'PROMPT'
You are a professional enterprise HR assistant. Your role is to help employees with all HR-related inquiries and operations.

## Capabilities
1. Answer HR policy questions — Leave policies, attendance rules, benefits, compliance guidelines
2. Help with leave applications — Guide employees through leave request procedures
3. Explain salary structure — Base pay, bonuses, deductions, pay grades
4. Guide onboarding/offboarding — New hire checklists, exit procedures

## Tool Usage
- Use hr-tools to query the HR knowledge base and execute HR operations
- Do not use shell to directly call external APIs (all external data access must go through hr-tools)

## Output Format
- Provide clear, structured answers
- Always cite which policy document the answer comes from
- For procedural questions, provide step-by-step guidance

## Important Principles
- If you know the employee's department or role context, tailor your answers
- If you remember previous interactions, proactively apply that context
- Always cite policy document sources
PROMPT

# ---- Step 3: Create Harness project ----
echo "🚀 Creating Harness project..."
cd $WORKDIR
rm -rf hrassistant

CREATE_ARGS="--name hrassistant --model-provider bedrock --model-id $WORKSHOP_MODEL_ID --memory longAndShortTerm --max-iterations 30 --max-tokens 8192 --timeout 300 --skip-git"

if [ -n "$SUBNETS" ] && [ "$SUBNETS" != "None" ]; then
  CREATE_ARGS="$CREATE_ARGS --network-mode VPC --subnets $SUBNETS --security-groups $SG"
else
  CREATE_ARGS="$CREATE_ARGS --network-mode PUBLIC"
fi

npx agentcore create $CREATE_ARGS
cd hrassistant

# ---- Step 4: Add tools ----

echo "🔧 Adding Gateway tool (external, by ARN)..."
npx agentcore add tool --harness hrassistant \
  --type agentcore_gateway \
  --name hr-tools \
  --gateway-arn "$GATEWAY_ARN"

# ---- Step 5: Copy system prompt ----
cp $WORKDIR/system-prompt.txt app/hrassistant/system-prompt.md

# ---- Step 6: Restrict allowed tools ----
echo "🔒 Restricting tool scope..."
cat app/hrassistant/harness.json | \
  jq '.allowedTools = ["@hr-tools/*"]' > tmp.json && \
  mv tmp.json app/hrassistant/harness.json

# ---- Step 7: Configure Skills + filesystem ----
if [ -n "$SKILLS_AP_ARN" ] && [ "$SKILLS_AP_ARN" != "None" ]; then
  echo "🔧 Configuring Skills filesystem..."
  cat app/hrassistant/harness.json | \
    jq --arg arn "$SKILLS_AP_ARN" \
    '.environment.agentCoreRuntimeEnvironment.filesystemConfigurations = [{"mountPath": "/mnt/skills", "s3FilesAccessPoint": {"accessPointArn": $arn}}]' \
    > tmp.json && mv tmp.json app/hrassistant/harness.json

  cat app/hrassistant/harness.json | \
    jq '.skills = ["/mnt/skills/skills/deep-policy-analysis/SKILL.md", "/mnt/skills/skills/leave-calculator/SKILL.md"]' \
    > tmp.json && mv tmp.json app/hrassistant/harness.json
else
  echo "⚠️  WARNING: No Skills Access Point ARN found in workshop-infra outputs"
  echo "    (looked for SkillsAccessPointArn / DataAccessPointArn)."
  echo "    Skills will NOT be mounted — the agent will deploy WITHOUT skills."
fi

# ---- Step 8: Configure deployment target ----
echo "📋 Configuring deployment target..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
cat > agentcore/aws-targets.json << EOF
[
  {
    "name": "default",
    "region": "$REGION",
    "account": "$ACCOUNT_ID"
  }
]
EOF

# ---- Step 9: Deploy (single pass — no gateway in CDK) ----
echo "🚀 Deploying (Memory + Harness, ~5-8 min)..."
npx agentcore deploy --yes

# ---- Step 10: Verify ----
echo ""
echo "🔍 Verifying..."
npx agentcore status

echo ""
echo "✅ Harness deployed!"
echo "  Next: Run 05-setup-memory.sh"
