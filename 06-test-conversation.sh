#!/bin/bash
# =============================================================================
# Phase 3: First Conversation
# Maps to: 050_first_eval
# =============================================================================
set -e

WORKDIR=~/workshop/hrassistant

echo "========================================="
echo "Phase 3: First Conversation with HR Agent"
echo "========================================="

cd $WORKDIR

SESSION_1="session-$(cat /proc/sys/kernel/random/uuid)-$(date +%s)"
export SESSION_1

echo "📋 Session ID: $SESSION_1"
echo ""
echo "🗣️  Asking about annual leave policy..."
echo ""

INVOKE_OUT=$(npx agentcore invoke \
  --session-id "$SESSION_1" \
  --actor-id "employee-001" \
  --stream \
  "I'd like to know about the annual leave policy. How many days am I entitled to and what's the application process?" 2>&1)
echo "$INVOKE_OUT"

# `agentcore invoke` returns exit 0 even when the model call fails inside the
# stream (e.g. AccessDeniedException for an un-subscribed model). Detect that
# explicitly so the user isn't told "success" while the agent is unusable.
if echo "$INVOKE_OUT" | grep -qiE "AccessDeniedException|Model access is denied|^Error:|aws-marketplace:Subscribe"; then
  echo ""
  echo "❌ The agent could not complete the conversation."
  echo "   If you see 'Model access is denied' / 'aws-marketplace:Subscribe',"
  echo "   the Bedrock model configured in 00-config.sh (WORKSHOP_MODEL_ID) is not"
  echo "   enabled for this account. Enable it in the Bedrock console (Model access)"
  echo "   and retry in ~5 min. (Default Amazon Nova models need no extra enablement.)"
  exit 1
fi

echo ""
echo "========================================="
echo "✅ First conversation complete"
echo ""
echo "Notice: The answer is GENERIC — the Agent doesn't know your tenure,"
echo "department, or specific leave balance yet."
echo ""
echo "Session saved as: SESSION_1=$SESSION_1"
