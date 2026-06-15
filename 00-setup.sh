#!/bin/bash
# =============================================================================
# Phase 0: Environment Setup
# Maps to: 020_prerequisites + 040_create_deploy/041_connect
# =============================================================================
set -e

echo "========================================="
echo "Phase 0: Environment Setup"
echo "========================================="

# Verify tools
echo "🔍 Verifying tools..."
npx agentcore --version || { echo "❌ agentcore CLI not found. Run: npm i -g @aws/agentcore@preview"; exit 1; }
node --version || { echo "❌ Node.js not found"; exit 1; }
aws --version || { echo "❌ AWS CLI not found"; exit 1; }

REGION=${AWS_DEFAULT_REGION:-us-west-2}
echo "  Region: $REGION"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "  Account: $ACCOUNT_ID"

# Create workshop directory
mkdir -p ~/workshop/skills/deep-policy-analysis
mkdir -p ~/workshop/skills/leave-calculator

echo ""
echo "✅ Environment ready"
echo "  Next: Run 01-create-kb.sh"
