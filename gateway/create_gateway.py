#!/usr/bin/env python3
# =============================================================================
# AgentCore Gateway + Lambda target management (raw bedrock-agentcore-control API)
# Maps to: 040_create_deploy/043_gateway
#
# 把 Gateway IAM 角色、Gateway、Lambda Target 的创建/删除从 02-create-gateway.sh
# 抽到这里，用 boto3 直接调用 bedrock-agentcore-control / iam，逻辑更清晰也更易复用。
#
# Lambda 部署仍由 02-create-gateway.sh 负责；本脚本接收 Lambda ARN、Gateway 角色名
# 与工具 schema 文件，完成 IAM 角色、Gateway、Target 三步。
#
# 用法:
#   python3 create_gateway.py create \
#       --name hrgateway --target-name hr-tools \
#       --lambda-arn <arn> --role-name hrassistant-gateway-role \
#       --schema-file hr-tools-schema.json
#
#   python3 create_gateway.py delete --name hrgateway
# =============================================================================

import argparse
import json
import os
import sys
import time

import boto3


def get_region() -> str:
    """Resolve region from the boto3 session, falling back to env / default."""
    region = boto3.session.Session().region_name
    return region or os.environ.get("AWS_DEFAULT_REGION", "us-west-2")


REGION = get_region()

gateway_client = boto3.client("bedrock-agentcore-control", region_name=REGION)
iam_client = boto3.client("iam", region_name=REGION)
sts_client = boto3.client("sts", region_name=REGION)
ssm_client = boto3.client("ssm", region_name=REGION)

# SSM param storing the Gateway ARN (consumed when creating the AgentCore harness)
SSM_GATEWAY_ARN_PARAM = "/app/hr/gateway_arn"


def ensure_gateway_role(role_name: str, lambda_arn: str) -> str:
    """Create (or update) the Gateway IAM role and return its ARN.

    The agentcore CLI used to create this automatically; the raw API needs an
    explicit roleArn. The role trusts bedrock-agentcore and is allowed to invoke
    the HR Tools Lambda (GATEWAY_IAM_ROLE credential provider).
    """
    account_id = sts_client.get_caller_identity()["Account"]
    role_arn = f"arn:aws:iam::{account_id}:role/{role_name}"

    trust_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {"Service": "bedrock-agentcore.amazonaws.com"},
                "Action": "sts:AssumeRole",
                "Condition": {"StringEquals": {"aws:SourceAccount": account_id}},
            }
        ],
    }

    print(f"🔐 Ensuring Gateway IAM role ({role_name})...")
    try:
        iam_client.create_role(
            RoleName=role_name,
            AssumeRolePolicyDocument=json.dumps(trust_policy),
            Description="Allows AgentCore Gateway to invoke the HR Tools Lambda",
        )
        print("  Role created.")
        created = True
    except iam_client.exceptions.EntityAlreadyExistsException:
        print("  Role already exists, updating trust policy...")
        iam_client.update_assume_role_policy(
            RoleName=role_name, PolicyDocument=json.dumps(trust_policy)
        )
        created = False

    # Permission: invoke the HR Tools Lambda
    invoke_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": "lambda:InvokeFunction",
                "Resource": lambda_arn,
            }
        ],
    }
    iam_client.put_role_policy(
        RoleName=role_name,
        PolicyName="invoke-hr-tools-lambda",
        PolicyDocument=json.dumps(invoke_policy),
    )

    print(f"  Gateway Role ARN: {role_arn}")

    # IAM role/policy changes need time to propagate before the gateway can use them.
    print("⏳ Waiting for IAM role/policy to propagate...")
    time.sleep(15)

    return role_arn


def load_tool_schema(schema_file: str) -> list:
    """Load the inline MCP tool schema (the Lambda target's tool definitions)."""
    if not os.path.exists(schema_file):
        print(f"❌ Tool schema file not found: {schema_file}", file=sys.stderr)
        sys.exit(1)
    with open(schema_file) as f:
        return json.load(f)


def find_gateway_id(gateway_name: str) -> str:
    """Return the gatewayId for a gateway name, or None if it doesn't exist."""
    items = gateway_client.list_gateways(maxResults=100).get("items", [])
    for item in items:
        if item.get("name") == gateway_name:
            return item.get("gatewayId")
    return None


def wait_for_gateway_ready(gateway_id: str, max_retries: int = 30, delay: int = 5):
    """Block until the gateway reaches READY/ACTIVE (or fail loudly)."""
    print("⏳ Waiting for Gateway to be READY...")
    for attempt in range(max_retries):
        status = gateway_client.get_gateway(gatewayIdentifier=gateway_id).get("status")
        if status in ("READY", "ACTIVE"):
            print(f"  ✅ Gateway is {status}")
            return
        if status in ("FAILED", "DELETING", "DELETED"):
            raise RuntimeError(f"Gateway entered terminal status: {status}")
        print(f"    status: {status} ({attempt + 1}/{max_retries})")
        time.sleep(delay)
    raise RuntimeError(f"Gateway not READY after {max_retries * delay}s")


def find_target_id(gateway_id: str, target_name: str) -> str:
    """Return the targetId for a target name on a gateway, or None."""
    items = gateway_client.list_gateway_targets(
        gatewayIdentifier=gateway_id, maxResults=100
    ).get("items", [])
    for item in items:
        if item.get("name") == target_name:
            return item.get("targetId")
    return None


def create(args):
    """Create the Gateway IAM role, the Gateway, and its Lambda target (idempotent)."""
    tool_schema = load_tool_schema(args.schema_file)

    # 1. Gateway IAM role (trusts bedrock-agentcore, may invoke the Lambda)
    role_arn = ensure_gateway_role(args.role_name, args.lambda_arn)

    # 2. Gateway (reuse if it already exists)
    print(f"🚀 Creating Gateway ({args.name}) in {REGION}...")
    gateway_id = find_gateway_id(args.name)
    if gateway_id:
        print(f"  Gateway already exists: {gateway_id} (reusing)")
    else:
        resp = gateway_client.create_gateway(
            name=args.name,
            description="HR assistant tools gateway",
            roleArn=role_arn,
            protocolType="MCP",
            authorizerType="AWS_IAM",
        )
        gateway_id = resp["gatewayId"]
        print(f"  Gateway created: {gateway_id}")

    wait_for_gateway_ready(gateway_id)

    gw = gateway_client.get_gateway(gatewayIdentifier=gateway_id)
    gateway_url = gw["gatewayUrl"]
    gateway_arn = gw["gatewayArn"]

    # Persist the Gateway ARN for the next step (AgentCore harness creation)
    ssm_client.put_parameter(
        Name=SSM_GATEWAY_ARN_PARAM,
        Description=f"{args.name} gateway arn",
        Value=gateway_arn,
        Type="String",
        Overwrite=True,
    )
    print(f"  Saved Gateway ARN to SSM: {SSM_GATEWAY_ARN_PARAM}")

    # 3. Lambda target: MCP -> Lambda -> inline tool schema (idempotent)
    print(f"🔗 Adding Lambda target ({args.target_name})...")
    target_id = find_target_id(gateway_id, args.target_name)
    if target_id:
        print(f"  Target already exists: {target_id} (skipping)")
    else:
        target_config = {
            "mcp": {
                "lambda": {
                    "lambdaArn": args.lambda_arn,
                    "toolSchema": {"inlinePayload": tool_schema},
                }
            }
        }
        resp = gateway_client.create_gateway_target(
            gatewayIdentifier=gateway_id,
            name=args.target_name,
            description="HR tools backed by Lambda",
            targetConfiguration=target_config,
            credentialProviderConfigurations=[
                {"credentialProviderType": "GATEWAY_IAM_ROLE"}
            ],
        )
        target_id = resp["targetId"]
        print(f"  Target created: {target_id}")

    print("\n=========================================")
    print("✅ Gateway ready!")
    print("=========================================")
    print(f"  Gateway name:    {args.name}")
    print(f"  Gateway ID:      {gateway_id}")
    print(f"  Gateway ARN:     {gateway_arn}")
    print(f"  Gateway URL:     {gateway_url}")
    print(f"  Region:          {REGION}")
    print(f"  Target name:     {args.target_name}")
    print(f"  Target ID:       {target_id}")
    print(f"  Lambda ARN:      {args.lambda_arn}")
    print(f"  Gateway role:    {role_arn}")
    print(f"  Protocol:        MCP")
    print(f"  Authorizer:      AWS_IAM")
    print("=========================================")


def delete(args):
    """Delete the Gateway and all of its targets (idempotent)."""
    gateway_id = find_gateway_id(args.name)
    if not gateway_id:
        print(f"  Gateway '{args.name}' not found — nothing to delete.")
        return

    print(f"🗑️  Deleting all targets for gateway: {gateway_id}")
    items = gateway_client.list_gateway_targets(
        gatewayIdentifier=gateway_id, maxResults=100
    ).get("items", [])
    for item in items:
        target_id = item["targetId"]
        gateway_client.delete_gateway_target(
            gatewayIdentifier=gateway_id, targetId=target_id
        )
        print(f"  ✅ Target {target_id} delete requested")

    # delete_gateway_target 是异步的：target 还没真正消失就删 gateway 会报
    # "has targets associated with it"。轮询直到目标列表清空再删 gateway。
    if items:
        print("  ⏳ Waiting for targets to be fully deleted...")
        for _ in range(30):
            remaining = gateway_client.list_gateway_targets(
                gatewayIdentifier=gateway_id, maxResults=100
            ).get("items", [])
            if not remaining:
                break
            time.sleep(5)
        else:
            print("  ⚠️  Targets still present after wait; delete_gateway may fail.")

    print(f"🗑️  Deleting gateway: {gateway_id}")
    gateway_client.delete_gateway(gatewayIdentifier=gateway_id)
    print(f"✅ Gateway {args.name} ({gateway_id}) deleted")

    try:
        ssm_client.delete_parameter(Name=SSM_GATEWAY_ARN_PARAM)
        print(f"🧹 Removed SSM parameter {SSM_GATEWAY_ARN_PARAM}")
    except ssm_client.exceptions.ParameterNotFound:
        pass


def main():
    parser = argparse.ArgumentParser(description="AgentCore Gateway management")
    sub = parser.add_subparsers(dest="mode", required=True)

    p_create = sub.add_parser("create", help="Create the gateway and Lambda target")
    p_create.add_argument("--name", required=True, help="Gateway name")
    p_create.add_argument("--target-name", required=True, help="Lambda target name")
    p_create.add_argument("--lambda-arn", required=True, help="HR Tools Lambda ARN")
    p_create.add_argument(
        "--role-name", required=True, help="Gateway IAM role name (created if absent)"
    )
    p_create.add_argument(
        "--schema-file", required=True, help="Path to the inline MCP tool schema JSON"
    )
    p_create.set_defaults(func=create)

    p_delete = sub.add_parser("delete", help="Delete the gateway and its targets")
    p_delete.add_argument("--name", required=True, help="Gateway name")
    p_delete.set_defaults(func=delete)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
