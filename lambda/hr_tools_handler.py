"""
HR Tools Lambda Handler for AgentCore Gateway.

Handles tool calls routed from AgentCore Gateway:
- retrieve_hr_policy: Query Bedrock Knowledge Base for HR policy documents
- check_leave_balance: Mock - return employee leave balance
- submit_leave_request: Mock - submit a leave request
- query_salary_info: Mock - return salary structure info
"""

import json
import logging
import os
import uuid
from datetime import datetime

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION", "us-west-2")
# SSM parameter holding the Knowledge Base ID (written by create_kb.py).
# Override the parameter name via env if needed.
KB_ID_SSM_PARAM = os.environ.get("KB_ID_SSM_PARAM", "/app/hr/knowledge_base_id")

# Cache the resolved KB ID across warm invocations.
_kb_id_cache = None


def get_kb_id():
    """Resolve the Knowledge Base ID from SSM Parameter Store (cached).

    Falls back to the KNOWLEDGE_BASE_ID env var if the parameter is missing.
    """
    global _kb_id_cache
    # Only a non-empty value is cached. A failed first lookup (e.g. IAM perms
    # not yet propagated) must NOT poison the cache — otherwise a warm container
    # would return "" forever and never retry once permissions are in place.
    if _kb_id_cache:
        return _kb_id_cache

    kb_id = ""
    try:
        ssm = boto3.client("ssm", region_name=REGION)
        kb_id = ssm.get_parameter(Name=KB_ID_SSM_PARAM)["Parameter"]["Value"]
    except Exception as e:
        logger.warning("Could not read KB ID from SSM %s: %s", KB_ID_SSM_PARAM, e)
        kb_id = os.environ.get("KNOWLEDGE_BASE_ID", "")

    if kb_id:
        _kb_id_cache = kb_id  # cache only on success
    return kb_id


def lambda_handler(event, context):
    """Main handler - routes to appropriate tool based on Gateway context."""
    logger.info("EVENT: %s", json.dumps(event, default=str))
    logger.info("CONTEXT client_context: %s", getattr(context, "client_context", None))

    # Get tool name from Gateway context
    tool_name = ""
    if context and hasattr(context, "client_context") and context.client_context:
        cc = context.client_context
        custom = getattr(cc, "custom", None) or {}
        if isinstance(custom, str):
            import ast

            try:
                custom = ast.literal_eval(custom)
            except Exception:
                custom = json.loads(custom) if custom else {}
        logger.info("CUSTOM context: %s", custom)
        # Try both camelCase variants
        tool_name = custom.get(
            "bedrockAgentCoreToolName", custom.get("bedrockagentcoreToolName", "")
        )

    # Fallback: check event body for tool name
    if not tool_name:
        body = event if isinstance(event, dict) else json.loads(event.get("body", "{}"))
        tool_name = body.get("name", body.get("tool_name", ""))

    # Strip gateway prefix (e.g., "hr-tools___check_leave_balance" -> "check_leave_balance")
    if "___" in tool_name:
        tool_name = tool_name.split("___", 1)[1]

    logger.info("Resolved tool_name: %s", tool_name)

    # Arguments come directly as the event from Gateway
    arguments = event

    # Route to tool
    handlers = {
        "retrieve_hr_policy": handle_retrieve_hr_policy,
        "check_leave_balance": handle_check_leave_balance,
        "submit_leave_request": handle_submit_leave_request,
        "query_salary_info": handle_query_salary_info,
    }

    handler = handlers.get(tool_name)
    if not handler:
        return {
            "statusCode": 400,
            "body": json.dumps(
                {
                    "error": f"Unknown tool: {tool_name}. Available: {list(handlers.keys())}"
                }
            ),
        }

    try:
        result = handler(arguments)
        return {"statusCode": 200, "body": json.dumps(result, ensure_ascii=False)}
    except Exception as e:
        return {"statusCode": 500, "body": json.dumps({"error": str(e)})}


def handle_retrieve_hr_policy(args):
    """Retrieve HR policy from Bedrock Knowledge Base."""
    query = args.get("query", "")

    kb_id = get_kb_id()

    client = boto3.client("bedrock-agent-runtime", region_name=REGION)

    response = client.retrieve(
        knowledgeBaseId=kb_id,
        retrievalQuery={"text": query},
        retrievalConfiguration={"vectorSearchConfiguration": {"numberOfResults": 3}},
    )

    results = []
    for item in response.get("retrievalResults", []):
        results.append(
            {
                "content": item.get("content", {}).get("text", ""),
                "source": item.get("location", {})
                .get("s3Location", {})
                .get("uri", "unknown"),
                "score": item.get("score", 0),
            }
        )

    if not results:
        return {
            "answer": "No relevant policy documents found for your query.",
            "sources": [],
        }

    return {
        "answer": "\n\n".join([r["content"] for r in results]),
        "sources": [r["source"] for r in results],
    }


def handle_check_leave_balance(args):
    """Mock: Check employee leave balance."""
    employee_id = args.get("employee_id", "unknown")
    leave_type = args.get("leave_type", "all")

    balances = {
        "annual": {"entitled": 15, "used": 5, "remaining": 10},
        "sick": {"entitled": 10, "used": 2, "remaining": 8},
        "personal": {"entitled": 5, "used": 1, "remaining": 4},
    }

    if leave_type == "all":
        return {"employee_id": employee_id, "balances": balances}
    elif leave_type in balances:
        return {
            "employee_id": employee_id,
            "leave_type": leave_type,
            **balances[leave_type],
        }
    else:
        return {"error": f"Unknown leave type: {leave_type}"}


def handle_submit_leave_request(args):
    """Mock: Submit a leave request."""
    return {
        "status": "submitted",
        "confirmation_id": f"LV-{datetime.now().strftime('%Y')}-{uuid.uuid4().hex[:4].upper()}",
        "employee_id": args.get("employee_id", "unknown"),
        "leave_type": args.get("leave_type", "annual"),
        "start_date": args.get("start_date", ""),
        "end_date": args.get("end_date", ""),
        "message": "Leave request submitted. Pending manager approval.",
        "estimated_approval_time": "1-2 business days",
    }


def handle_query_salary_info(args):
    """Mock: Query salary structure information."""
    return {
        "salary_structure": {
            "base_salary_ratio": "60-70% of total package",
            "performance_bonus": "20-30% of total package, paid quarterly",
            "annual_bonus": "1-3 months base salary, based on performance rating",
            "review_cycle": "Annual in April",
            "review_basis": "Performance rating + market benchmarking",
        },
        "note": "Specific salary details are confidential. Contact HR for your personal package.",
    }
