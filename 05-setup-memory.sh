#!/bin/bash
# =============================================================================
# Phase 2e: Setup Memory Retrieval
# Maps to: 040_create_deploy/045_deploy (setup-memory.sh)
#
# Configures Memory retrieval on the Harness so that each invoke automatically
# fetches the user's preferences and facts from Memory.
#
# Prerequisites: 04-deploy.sh (Harness deployed via agentcore deploy)
# =============================================================================
set -e

REGION=${AWS_DEFAULT_REGION:-us-west-2}
WORKDIR=~/workshop/hrassistant

echo "========================================="
echo "Phase 2e: Configure Memory Retrieval"
echo "========================================="

cd $WORKDIR

# ---- Get IDs from deployed state ----
echo "🔍 Getting resource info from deployed state..."

HARNESS_ID=$(python3 -c "
import json
with open('agentcore/.cli/deployed-state.json') as f:
    state = json.load(f)
targets = state.get('targets', {}).get('default', {}).get('resources', {})
harnesses = targets.get('harnesses', {})
for name, info in harnesses.items():
    if 'harnessId' in info:
        print(info['harnessId'])
        break
" 2>/dev/null)

MEMORY_ARN=$(python3 -c "
import json
with open('agentcore/.cli/deployed-state.json') as f:
    state = json.load(f)
targets = state.get('targets', {}).get('default', {}).get('resources', {})
memories = targets.get('memories', {})
for name, info in memories.items():
    if 'memoryArn' in info:
        print(info['memoryArn'])
        break
" 2>/dev/null)

MEMORY_ID=$(echo "$MEMORY_ARN" | awk -F'/' '{print $NF}')

if [ -z "$HARNESS_ID" ] || [ -z "$MEMORY_ID" ]; then
  echo "❌ Could not find Harness or Memory IDs. Run 04-deploy.sh first."
  exit 1
fi

echo "  Harness: $HARNESS_ID"
echo "  Memory:  $MEMORY_ID"

# ---- Get Memory strategy IDs ----
echo "🔍 Getting Memory strategies..."

STRATEGIES=$(python3 << PYEOF
import boto3, json
client = boto3.client("bedrock-agentcore-control", region_name="$REGION")
resp = client.get_memory(memoryId="$MEMORY_ID")
mem = resp.get("memory", resp)
strategies = mem.get("strategies", [])
result = {}
for s in strategies:
    result[s["type"]] = s["strategyId"]
print(json.dumps(result))
PYEOF
)

PREF_STRATEGY=$(echo "$STRATEGIES" | python3 -c "import json,sys; print(json.load(sys.stdin).get('USER_PREFERENCE',''))")
SEMANTIC_STRATEGY=$(echo "$STRATEGIES" | python3 -c "import json,sys; print(json.load(sys.stdin).get('SEMANTIC',''))")

echo "  User Preference Strategy: $PREF_STRATEGY"
echo "  Semantic Strategy: $SEMANTIC_STRATEGY"

if [ -z "$PREF_STRATEGY" ] || [ -z "$SEMANTIC_STRATEGY" ]; then
  echo "❌ Could not find Memory strategies."
  exit 1
fi

# ---- Wait for the HARNESS (agent) to leave CREATING before updating ----
# 04-deploy.sh returns once the deploy command finishes, but the AgentCore agent
# may still be CREATING for a short while. update_harness operates on the harness
# (agent), NOT the runtime — and the two reach READY at different times: the
# Runtime can report READY while the agent is still CREATING, which makes
# update_harness fail with "Cannot update agent ... while it is CREATING."
# Therefore poll the HARNESS status (get_harness), not the runtime status.
echo "⏳ Waiting for Harness to be READY (up to 5 min)..."
for i in $(seq 1 30); do
  HR_STATUS=$(AWS_DEFAULT_REGION=$REGION python3 -c "
import boto3
c = boto3.client('bedrock-agentcore-control', region_name='$REGION')
try:
    resp = c.get_harness(harnessId='$HARNESS_ID')
    h = resp.get('harness', resp)
    print(h.get('status','UNKNOWN'))
except Exception:
    print('UNKNOWN')
" 2>/dev/null || echo "UNKNOWN")
  if [ "$HR_STATUS" = "READY" ] || [ "$HR_STATUS" = "ACTIVE" ]; then
    echo "  Harness is $HR_STATUS."
    break
  fi
  echo "    status: $HR_STATUS ($i/30)"
  sleep 10
done

# ---- Configure Memory retrieval on Harness via boto3 ----
echo "⚙️  Configuring Memory retrieval..."

python3 << PYEOF
import boto3, json, botocore

client = boto3.client("bedrock-agentcore-control", region_name="$REGION")

memory_config = {
    "optionalValue": {
        "agentCoreMemoryConfiguration": {
            "arn": "$MEMORY_ARN",
            "actorId": "{actorId}",
            "retrievalConfig": {
                "/users/{actorId}/preferences": {
                    "strategyId": "$PREF_STRATEGY",
                    "topK": 20,
                },
                "/users/{actorId}/facts": {
                    "strategyId": "$SEMANTIC_STRATEGY",
                    "topK": 10,
                },
            },
        }
    }
}

try:
    client.update_harness(harnessId="$HARNESS_ID", memory=memory_config)
    print("  ✅ Memory retrieval configured")
except botocore.parsers.ResponseParserError:
    # SDK may fail parsing the response but the API call succeeds
    print("  ✅ Memory retrieval configured (response parse warning ignored)")
except Exception as e:
    print(f"  ❌ Failed: {e}")
    raise
PYEOF

# ---- IAM permissions ----
echo "🔐 Configuring IAM permissions..."

aws iam attach-role-policy \
  --role-name hrassistant_hrassistant \
  --policy-arn "arn:aws:iam::aws:policy/BedrockAgentCoreFullAccess" 2>/dev/null || true

# Gateway role (created by 02-create-gateway.sh, not in CDK)
aws iam attach-role-policy \
  --role-name hrassistant-gateway-role \
  --policy-arn "arn:aws:iam::aws:policy/BedrockAgentCoreFullAccess" 2>/dev/null || true

echo "⏳ Waiting for Harness update (60s)..."
sleep 60

# ---- Verify ----
echo "🔍 Verifying Harness status..."
sleep 10
STATUS=$(AWS_DEFAULT_REGION=$REGION python3 -c "
import boto3
client = boto3.client('bedrock-agentcore-control', region_name='$REGION')
resp = client.get_agent_runtime(agentRuntimeId='$(python3 -c "
import json
with open('agentcore/.cli/deployed-state.json') as f:
    state = json.load(f)
targets = state.get('targets', {}).get('default', {}).get('resources', {})
harnesses = targets.get('harnesses', {})
for name, info in harnesses.items():
    if 'runtimeId' in info:
        print(info['runtimeId'])
        break
" 2>/dev/null)')
print(resp.get('status','UNKNOWN'))
" 2>/dev/null || echo "UNKNOWN")

echo ""
echo "✅ Memory retrieval configured! (Harness: $STATUS)"
echo ""
echo "  - /users/{actorId}/preferences → User preferences (top 20)"
echo "  - /users/{actorId}/facts → Facts (top 10)"
echo ""
echo "  Next: Run 06-test-conversation.sh"
