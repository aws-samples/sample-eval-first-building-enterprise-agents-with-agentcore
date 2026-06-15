#!/bin/bash
# =============================================================================
# Cleanup: Destroy all workshop resources
# Run this from static/scripts/ to clean up everything the workshop created.
#
# 删除顺序按依赖反向（先删依赖方，再删被依赖方），关键约束：
#   - 必须先用 DeleteHarness 删 Harness（会级联删 Runtime），Runtime 删掉后 VPC ENI
#     才会释放；agentcore CLI 没有 destroy 子命令，不能靠它清理。
#   - 独立 Gateway / KB 不在 AgentCore CFN 栈里，必须单独删。
#   - CFN 管的 S3 桶开了 Versioning + ObjectLock，删栈前必须按版本清空，否则栈删不掉
#   - Lambda(VPC) + AgentCore runtime 会留下托管 ENI，由 AWS 异步回收，期间子网/SG/VPC
#     删不掉 → 删栈可能失败。本脚本用 --retain-resources 让栈先删完，残留的网络资源
#     由 AWS 在 ENI 回收后自动清理，无需人工干预，也不产生费用。
#
# 失败不中断：单项删除失败打印 ⚠️ 后继续，确保尽量多的资源被清理。
# =============================================================================
# 注意：本脚本会逐项失败继续，因此不使用 set -e。

REGION=${AWS_DEFAULT_REGION:-us-west-2}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR=~/workshop/hrassistant
STACK_NAME=${INFRA_STACK_NAME:-workshop-infra}
GATEWAY_NAME="hrgateway"
GW_ROLE_NAME="hrassistant-gateway-role"

echo "========================================="
echo "Workshop Cleanup"
echo "========================================="
echo "Region: $REGION"
echo "Stack:  $STACK_NAME"
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)

# -----------------------------------------------------------------------------
# Step 1: Destroy the AgentCore Harness + Runtime (releases the VPC ENIs)
#   注意：agentcore CLI 没有 `destroy` 子命令。Harness/Runtime 是通过 API 创建、
#   不在 AgentCore CFN 栈里，必须用 DeleteHarness 删——它会【级联删除】它管理的
#   Agent Runtime（直接 delete-agent-runtime 会被拒，提示 "Use DeleteHarness"）。
#   这一步【最关键】：那个 READY 的 Runtime 以 VPC 模式挂在 workshop-infra 的子网/SG
#   上，不先删它，它占住的 ENI 不会释放，后面删 workshop-infra 栈就会卡住。
#   Memory 与两个自定义 evaluator 在 AgentCore CFN 栈里，由 Step 1b 删栈一并回收。
# -----------------------------------------------------------------------------
echo "🗑️  Step 1: Deleting AgentCore Harness + Runtime (releases VPC ENIs)..."
for HID in $(aws bedrock-agentcore-control list-harnesses --region $REGION \
  --query "harnesses[?starts_with(harnessName,'hrassistant')].harnessId" --output text 2>/dev/null); do
  aws bedrock-agentcore-control delete-harness --harness-id "$HID" --region $REGION >/dev/null 2>&1 && \
    echo "  ✅ delete-harness $HID 已提交（将级联删除其 Runtime）" || \
    echo "  ⚠️  delete-harness $HID 失败（可能已删除）"
done
# 等 Harness + Runtime 真正消失，ENI 才会开始回收
echo "  ⏳ 等待 Harness/Runtime 删除完成（ENI 随后异步回收）..."
for i in $(seq 1 40); do
  HLEFT=$(aws bedrock-agentcore-control list-harnesses --region $REGION \
    --query "harnesses[?starts_with(harnessName,'hrassistant')].harnessId" --output text 2>/dev/null)
  RLEFT=$(aws bedrock-agentcore-control list-agent-runtimes --region $REGION \
    --query "agentRuntimes[?starts_with(agentRuntimeName,'harness_hrassistant')].agentRuntimeId" --output text 2>/dev/null)
  [ -z "$HLEFT" ] && [ -z "$RLEFT" ] && { echo "  ✅ Harness 和 Runtime 已删除"; break; }
  sleep 15
done

# Step 1b: Delete the AgentCore CFN stack (Memory + custom evaluators + harness role)
echo "  🗑️  Deleting AgentCore CFN stack (Memory, evaluators, roles)..."
if aws cloudformation describe-stacks --stack-name AgentCore-hrassistant-default --region $REGION >/dev/null 2>&1; then
  aws cloudformation delete-stack --stack-name AgentCore-hrassistant-default --region $REGION 2>/dev/null
  aws cloudformation wait stack-delete-complete \
    --stack-name AgentCore-hrassistant-default --region $REGION 2>/dev/null && \
    echo "  ✅ AgentCore CFN stack deleted" || echo "  ⚠️  AgentCore stack deletion timed out, check console"
else
  echo "  ⚠️  AgentCore CFN stack not found (already deleted)"
fi

# Stale evaluator log groups can block a later redeploy ("LogGroup AlreadyExists").
for FUNC in hrassistant-eval-thelma_rag_quality hrassistant-eval-mtg_goal_success; do
  aws logs delete-log-group --log-group-name "/aws/lambda/$FUNC" --region $REGION 2>/dev/null && \
    echo "  ✅ log group /aws/lambda/$FUNC deleted" || true
done

# -----------------------------------------------------------------------------
# Step 2: Delete the standalone Gateway (+ targets + SSM param) and its role
#   由 02-create-gateway.sh 经 boto3 创建，不在 AgentCore CFN 栈里，Step 1 删 Harness
#   也不会连带删它。用同一份 Python 删（其 delete 会等 target 真正删完再删 gateway，
#   避免 "has targets associated" 时序竞争），确保 target/gateway/SSM 一起清。
#   放在 Step 1 之后：Harness 删除后才不再引用 gateway，删起来更干净。
# -----------------------------------------------------------------------------
echo ""
echo "🗑️  Step 2: Deleting standalone Gateway ($GATEWAY_NAME)..."
if [ -f "$SCRIPT_DIR/gateway/create_gateway.py" ]; then
  AWS_DEFAULT_REGION="$REGION" python3 "$SCRIPT_DIR/gateway/create_gateway.py" \
    delete --name "$GATEWAY_NAME" 2>&1 || echo "  ⚠️  Gateway delete failed (may already be gone)"
else
  echo "  ⚠️  gateway/create_gateway.py not found, skipping Gateway delete"
fi
# Gateway IAM role (inline policy + role)
for P in $(aws iam list-role-policies --role-name "$GW_ROLE_NAME" --query "PolicyNames[]" --output text 2>/dev/null); do
  aws iam delete-role-policy --role-name "$GW_ROLE_NAME" --policy-name "$P" 2>/dev/null
done
for PA in $(aws iam list-attached-role-policies --role-name "$GW_ROLE_NAME" --query "AttachedPolicies[*].PolicyArn" --output text 2>/dev/null); do
  aws iam detach-role-policy --role-name "$GW_ROLE_NAME" --policy-arn "$PA" 2>/dev/null
done
aws iam delete-role --role-name "$GW_ROLE_NAME" 2>/dev/null && \
  echo "  ✅ Gateway role $GW_ROLE_NAME deleted" || echo "  ⚠️  Gateway role not found"

# -----------------------------------------------------------------------------
# Step 3: Delete the Knowledge Base (KB + data source + S3 Vectors + IAM + SSM)
#   create_kb.py --mode delete 会一次性删除 KB、data source、S3 Vectors 桶/索引、
#   KB 执行角色与策略，并删除 SSM 参数 /app/hr/knowledge_base_id。
# -----------------------------------------------------------------------------
echo ""
echo "🗑️  Step 3: Deleting Knowledge Base (+ S3 Vectors + IAM + SSM)..."
if [ -f "$SCRIPT_DIR/knowledge-base/create_kb.py" ]; then
  AWS_DEFAULT_REGION="$REGION" python3 "$SCRIPT_DIR/knowledge-base/create_kb.py" \
    --mode delete 2>&1 || echo "  ⚠️  KB delete failed (may already be gone)"
else
  echo "  ⚠️  knowledge-base/create_kb.py not found; trying API fallback..."
  KB_ID=$(aws bedrock-agent list-knowledge-bases --region $REGION \
    --query "knowledgeBaseSummaries[?contains(name,'hr') || contains(name,'workshop')].knowledgeBaseId | [0]" \
    --output text 2>/dev/null)
  if [ -n "$KB_ID" ] && [ "$KB_ID" != "None" ]; then
    for DS_ID in $(aws bedrock-agent list-data-sources --knowledge-base-id "$KB_ID" --region $REGION \
      --query "dataSourceSummaries[*].dataSourceId" --output text 2>/dev/null); do
      aws bedrock-agent delete-data-source --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" --region $REGION 2>/dev/null
    done
    aws bedrock-agent delete-knowledge-base --knowledge-base-id "$KB_ID" --region $REGION 2>/dev/null && \
      echo "  ⚠️  KB $KB_ID deleted via fallback — S3 Vectors bucket/index may remain, check console" || true
  fi
  aws ssm delete-parameter --name /app/hr/knowledge_base_id --region $REGION 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# Step 4: Delete the standalone hr-tools Lambda role (no region suffix)
#   02-create-gateway.sh 无条件创建过 hr-tools-lambda-role（无 region 后缀）。
#   CFN 版的函数 hr-tools-handler 与角色 hr-tools-lambda-role-<region> 随栈一起删，
#   这里只清理这个游离在 CFN 之外的同名无后缀角色。
# -----------------------------------------------------------------------------
echo ""
echo "🗑️  Step 4: Cleaning up standalone Lambda role (hr-tools-lambda-role)..."
ROLE_NAME="hr-tools-lambda-role"
for P in $(aws iam list-role-policies --role-name "$ROLE_NAME" --query "PolicyNames[]" --output text 2>/dev/null); do
  aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$P" 2>/dev/null
done
for PA in $(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query "AttachedPolicies[*].PolicyArn" --output text 2>/dev/null); do
  aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$PA" 2>/dev/null
done
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null && \
  echo "  ✅ IAM role $ROLE_NAME deleted" || echo "  ⚠️  $ROLE_NAME not found (only created if 02 ran standalone)"

# -----------------------------------------------------------------------------
# Step 5: EMPTY the CFN-managed S3 buckets  — MUST happen BEFORE deleting the stack
#   桶开了 Versioning(+ SkillsBucket 还有 ObjectLock)，CloudFormation 无法删非空桶。
#   `aws s3 rm --recursive` 只删当前版本，会留下旧版本/delete-marker 导致删栈失败，
#   因此用 s3api delete-objects 把所有 version + delete-marker 删干净（分页处理）。
#   注意：ObjectLock 在 COMPLIANCE 模式下保留期内无法删除——本栈用的是默认（无显式
#   保留期），通常可删；若仍删不掉会在删栈阶段报错，按提示到控制台处理保留对象。
#   桶本身留给 CloudFormation 删（删栈时一并回收），这里只负责清空。
# -----------------------------------------------------------------------------
echo ""
echo "🗑️  Step 5: Emptying S3 buckets (all versions) before stack deletion..."
empty_versioned_bucket() {
  local BUCKET="$1"
  aws s3api head-bucket --bucket "$BUCKET" --region $REGION >/dev/null 2>&1 || { return 0; }
  echo "  Emptying s3://$BUCKET ..."
  while :; do
    # 一次性列出当前页的所有 version + delete-marker，交给 Python 拼成 delete-objects 的入参。
    local RAW BATCH COUNT
    RAW=$(aws s3api list-object-versions --bucket "$BUCKET" --region $REGION \
      --max-items 1000 --output json 2>/dev/null)
    [ -z "$RAW" ] && break
    BATCH=$(echo "$RAW" | python3 -c '
import sys, json
d = json.load(sys.stdin)
objs = [{"Key": v["Key"], "VersionId": v["VersionId"]}
        for v in (d.get("Versions") or []) + (d.get("DeleteMarkers") or [])]
print(json.dumps({"Objects": objs, "Quiet": True}))
' 2>/dev/null)
    COUNT=$(echo "$BATCH" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["Objects"]))' 2>/dev/null)
    [ -z "$COUNT" ] && COUNT=0
    if [ "$COUNT" -eq 0 ]; then break; fi
    local DELFILE
    DELFILE=$(mktemp)
    echo "$BATCH" > "$DELFILE"
    aws s3api delete-objects --bucket "$BUCKET" --region $REGION \
      --delete "file://$DELFILE" >/dev/null 2>&1 || {
        echo "    ⚠️  delete-objects 失败（可能有 ObjectLock 保留对象，需到控制台处理）"
        rm -f "$DELFILE"; break; }
    rm -f "$DELFILE"
  done
  echo "  ✅ s3://$BUCKET emptied (bucket itself deleted with the stack)"
}
empty_versioned_bucket "workshop-skills-${ACCOUNT_ID}-${REGION}"
empty_versioned_bucket "workshop-skills-logs-${ACCOUNT_ID}-${REGION}"

# -----------------------------------------------------------------------------
# Step 6: Delete the CloudFormation infrastructure stack
#   删栈通常会卡在网络资源：HR Tools Lambda(VPC) 与 AgentCore runtime 留下的托管
#   ENI（agentic_ai / ela-attach 类型，无权 detach/delete）由 AWS 异步回收（约
#   20-40 min），期间子网/SG/VPC 删不掉。
#
#   收尾策略（实战教训）：
#   - 不能用一次 `wait stack-delete-complete` 判断：它要轮询约 30 分钟才超时返回，
#     期间栈一直是 DELETE_IN_PROGRESS，而 --retain-resources 只在栈真正进入
#     DELETE_FAILED 时才被接受（IN_PROGRESS 调用会被 ValidationError 拒绝）。
#   - 因此这里【主动轮询】栈状态，直到 ① 栈消失(干净删完) 或 ② 转 DELETE_FAILED。
#   - 转 FAILED 后，用【当前快照】里 ResourceStatus=='DELETE_FAILED' 的资源做保留
#     列表——务必用 describe-stack-resources（当前状态），不要用 describe-stack-events
#     （历史事件里含栈名本身/已 DELETE_COMPLETE 的项，会导致 "must be in a valid
#     state / Do not specify DELETE_COMPLETE" 报错）。
#   - 保留后栈立即进 DELETE_COMPLETE，栈名释放可复用；残留的 VPC/子网/SG 在 ENI
#     回收后由 AWS 自动清理，无需人工干预，也不产生费用。
# -----------------------------------------------------------------------------
echo ""
echo "🗑️  Step 6: Deleting CloudFormation stack ($STACK_NAME)..."
if ! aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION >/dev/null 2>&1; then
  echo "  ⚠️  Stack $STACK_NAME not found (already deleted)"
else
  aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION
  echo "  ⏳ 轮询栈删除状态（卡在 ENI 时会转 DELETE_FAILED，最多等约 ${CLEANUP_DELETE_WAIT_MIN:-40} 分钟）..."
  MAXLOOPS=$(( ${CLEANUP_DELETE_WAIT_MIN:-40} * 2 ))   # 30s 一轮
  STACK_STATE=""
  for _ in $(seq 1 "$MAXLOOPS"); do
    STACK_STATE=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION \
      --query "Stacks[0].StackStatus" --output text 2>/dev/null)
    if [ -z "$STACK_STATE" ] || [ "$STACK_STATE" = "None" ]; then
      STACK_STATE="GONE"; break
    fi
    [ "$STACK_STATE" = "DELETE_FAILED" ] && break
    sleep 30
  done

  if [ "$STACK_STATE" = "GONE" ]; then
    echo "  ✅ Stack deleted cleanly (ENI 已回收，无残留)"
  elif [ "$STACK_STATE" = "DELETE_FAILED" ]; then
    echo "  ⚠️  删栈卡在网络资源（ENI 回收中）。用 --retain-resources 保留收尾。"
    # 实战教训：retain 列表必须包含【所有尚未 DELETE_COMPLETE 的资源】，而不只是当前
    # DELETE_FAILED 的。否则会出现：第一次只有子网/SG 是 FAILED，retain 它们后 CFN 才
    # 去删 VPC，VPC 因子网仍在而再次卡住，栈又转 FAILED——徒增一轮等待。一次性把
    # 子网/SG/VPC 全保留，栈才能立即 DELETE_COMPLETE、栈名当场释放。
    RETAIN=$(aws cloudformation describe-stack-resources --stack-name $STACK_NAME --region $REGION \
      --query "StackResources[?ResourceStatus!='DELETE_COMPLETE'].LogicalResourceId" \
      --output text 2>/dev/null | tr '\t' '\n' | sort -u | tr '\n' ' ')
    if [ -z "$RETAIN" ]; then
      echo "  ⚠️  未能识别需保留的资源，请到控制台检查栈状态。"
    else
      echo "  保留(待 AWS 自动回收)的资源: $RETAIN"
      RETAIN_FILE=~/workshop/.cleanup-retained-resources.txt
      aws cloudformation describe-stack-resources --stack-name $STACK_NAME --region $REGION \
        --query "StackResources[?ResourceStatus!='DELETE_COMPLETE'].{Logical:LogicalResourceId,Physical:PhysicalResourceId,Type:ResourceType}" \
        --output table > "$RETAIN_FILE" 2>/dev/null
      echo "  📄 保留资源物理 ID 已写入 $RETAIN_FILE"
      aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION --retain-resources $RETAIN
      aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $REGION 2>/dev/null && \
        echo "  ✅ 栈已删除（网络资源暂时保留，栈名已可复用）" || \
        echo "  ⚠️  retain 删栈仍超时，请到控制台检查。"
    fi
  else
    echo "  ⚠️  等待超时（栈仍 $STACK_STATE）。ENI 尚未回收完，稍后重跑本脚本或到控制台检查。"
  fi
fi

# -----------------------------------------------------------------------------
# Step 7 (optional): Roll back account-level X-Ray Transaction Search changes
#   07-setup-eval-env.sh 把 X-Ray trace 段目标改为 CloudWatchLogs 并把采样调到 100%，
#   这些是账户级改动、会持续产生费用。默认跳过（可能与账户其他用途共享），
#   设 CLEANUP_XRAY=1 才回滚。
# -----------------------------------------------------------------------------
echo ""
if [ "${CLEANUP_XRAY:-0}" = "1" ]; then
  echo "🗑️  Step 7: Rolling back X-Ray Transaction Search (CLEANUP_XRAY=1)..."
  aws xray update-trace-segment-destination --region $REGION --destination XRay >/dev/null 2>&1 && \
    echo "  ✅ trace segment destination reset to XRay" || echo "  ⚠️  reset failed"
  aws xray update-indexing-rule --region $REGION --name Default \
    --rule '{"Probabilistic":{"DesiredSamplingPercentage":5.0}}' >/dev/null 2>&1 || true
  aws logs delete-resource-policy --policy-name TransactionSearchXRayAccess --region $REGION 2>/dev/null && \
    echo "  ✅ resource policy TransactionSearchXRayAccess deleted" || true
else
  echo "⏭️  Step 7: Skipping X-Ray rollback (set CLEANUP_XRAY=1 to roll back 100% sampling & destination)."
fi

# -----------------------------------------------------------------------------
# Step 8: Clean up local workshop project directory
# -----------------------------------------------------------------------------
echo ""
echo "🗑️  Step 8: Cleaning up local files..."
rm -rf ~/workshop/hrassistant
echo "  ✅ Local workshop/hrassistant removed"

echo ""
echo "========================================="
echo "✅ Cleanup pass complete!"
echo "========================================="
echo ""
echo "已尝试清理："
echo "  - AgentCore 项目 (Harness, Memory, evaluators)"
echo "  - 独立 Gateway + 角色 + SSM 参数"
echo "  - Knowledge Base (+ S3 Vectors + IAM + SSM)"
echo "  - 游离 hr-tools-lambda-role"
echo "  - S3 桶内容（按版本清空）"
echo "  - CloudFormation 栈 (VPC/EC2/Lambda/S3 桶/角色)"
echo "  - 本地文件"
echo ""
echo "ℹ️  若 Step 6 走了 --retain-resources：VPC/子网/SG 暂时保留在账户中，等 Lambda/"
echo "    AgentCore 的托管 ENI 由 AWS 异步回收后会自动清理，无需人工干预，也不产生费用。"
echo "    保留资源清单见 ~/workshop/.cleanup-retained-resources.txt"
