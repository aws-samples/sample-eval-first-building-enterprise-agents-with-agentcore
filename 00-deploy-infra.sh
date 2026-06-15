#!/bin/bash
# =============================================================================
# Phase 0a: Deploy Workshop Infrastructure (CloudFormation)
# Run AFTER 00-setup.sh, BEFORE 00b-create-kb.sh
#
# 部署 workshop-infra CloudFormation 栈：VPC + 私有子网 + NAT + 安全组、
# Data S3 桶 + Access Point、以及 EC2 工作环境（通过 SSM 连接）。
#
# 模板位于 cfn/workshop-infra.yaml（已修复 S3 ACL 与 Lambda/DLQ 时序两个部署问题）。
#
# 说明：若使用 Workshop Studio 提供的临时账号，本栈已由平台预置，可跳过本步。
# 自有账号需运行本脚本。
# =============================================================================
set -e

REGION=${AWS_DEFAULT_REGION:-us-west-2}
STACK_NAME=${INFRA_STACK_NAME:-workshop-infra}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 模板优先用与脚本同级的 cfn/（独立发布布局），回退到 ../cfn/（workshop 仓库布局）
if [ -f "$SCRIPT_DIR/cfn/workshop-infra.yaml" ]; then
  TEMPLATE="$SCRIPT_DIR/cfn/workshop-infra.yaml"
else
  TEMPLATE="$SCRIPT_DIR/../cfn/workshop-infra.yaml"
fi
# 可选：传入已建好的 KB ID，会作为 Lambda 的 KNOWLEDGE_BASE_ID 参数
KB_ID=${HR_KB_ID:-""}

echo "========================================="
echo "Phase 0a: Deploy Workshop Infrastructure"
echo "========================================="
echo "  Region: $REGION | Stack: $STACK_NAME"
echo "  Template: $TEMPLATE"

[ -f "$TEMPLATE" ] || { echo "❌ 模板不存在: $TEMPLATE"; exit 1; }

# 已存在则跳过
if aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  echo "  栈已存在，跳过创建。如需更新请先删除或用 update-stack。"
else
  # Resolve AgentCore-compatible AZs for this region
  # AgentCore supported AZ IDs (from official docs):
  #   us-east-1: use1-az1, use1-az2, use1-az4
  #   us-east-2: use2-az1, use2-az2, use2-az3
  #   us-west-2: usw2-az1, usw2-az2, usw2-az3
  echo "  🔍 Resolving AgentCore-compatible availability zones..."

  case "$REGION" in
    us-east-1) SUPPORTED_AZ_IDS="use1-az1 use1-az2" ;;
    us-east-2) SUPPORTED_AZ_IDS="use2-az1 use2-az2" ;;
    us-west-2) SUPPORTED_AZ_IDS="usw2-az1 usw2-az2" ;;
    *) echo "❌ Unknown region $REGION — update supported AZ list in this script"; exit 1 ;;
  esac

  AZ_ID_1=$(echo "$SUPPORTED_AZ_IDS" | awk '{print $1}')
  AZ_ID_2=$(echo "$SUPPORTED_AZ_IDS" | awk '{print $2}')

  AZ1=$(aws ec2 describe-availability-zones --region "$REGION" \
    --query "AvailabilityZones[?ZoneId=='$AZ_ID_1'].ZoneName | [0]" --output text)
  AZ2=$(aws ec2 describe-availability-zones --region "$REGION" \
    --query "AvailabilityZones[?ZoneId=='$AZ_ID_2'].ZoneName | [0]" --output text)

  if [ -z "$AZ1" ] || [ "$AZ1" = "None" ] || [ -z "$AZ2" ] || [ "$AZ2" = "None" ]; then
    echo "❌ Could not resolve AZ names for IDs: $AZ_ID_1, $AZ_ID_2"
    exit 1
  fi
  echo "  AZ1=$AZ1 ($AZ_ID_1)  AZ2=$AZ2 ($AZ_ID_2)"

  echo "🚀 Creating stack (VPC/NAT/S3/EC2, ~5-8 min)..."
  aws cloudformation create-stack --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --template-body "file://$TEMPLATE" \
    --parameters "ParameterKey=AZ1,ParameterValue=$AZ1" "ParameterKey=AZ2,ParameterValue=$AZ2" \
    --capabilities CAPABILITY_NAMED_IAM >/dev/null
  echo "  ⏳ Waiting for stack create complete..."
  aws cloudformation wait stack-create-complete --region "$REGION" --stack-name "$STACK_NAME"
fi

echo ""
echo "✅ Infrastructure ready. Stack outputs:"
aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}' --output table

echo ""
echo "  Next: 01-create-kb.sh（建知识库）..."
