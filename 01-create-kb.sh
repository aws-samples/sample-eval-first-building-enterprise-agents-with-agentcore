#!/bin/bash
# =============================================================================
# Phase 0b: Create Bedrock Knowledge Base (for real RAG retrieval)
# Run AFTER 00-setup.sh, BEFORE 02-create-gateway.sh (which deploys the Lambda)
#
# 从零创建一个真实的 Bedrock Knowledge Base，供 hr-tools Lambda 做政策检索。
# 本脚本只做两件事，全部交给 knowledge-base/ 下的 Python 脚本完成：
#   1. generate_hr_docs.py  —— 生成 HR 政策 markdown 文档到 ~/workshop/knowledge-base/
#   2. create_kb.py         —— 创建 KB（S3 Vectors + IAM）并灌库
#
# create_kb.py 中已写死全部配置（KB 名称、hr/ 前缀、文档路径，数据桶取自
# workshop-infra CFN 栈的 DataBucketName 输出），无需配置文件或命令行参数。
#
# 前置条件：运行环境（如 EC2 实例角色）已具备所需 IAM 权限
#   （cloudformation / bedrock-agent / s3 / s3vectors / iam / ssm / sts）。
#
# create_kb.py 结束会打印完整的 Knowledge Base 详情（ID / 数据位置 / 向量库 /
# 嵌入模型 / 维度 / Vector Store Type 等）。
# =============================================================================
set -e

REGION=${AWS_DEFAULT_REGION:-us-west-2}
export AWS_DEFAULT_REGION="$REGION"   # create_kb.py 通过 boto3 session 读取 region
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KB_DIR="$SCRIPT_DIR/knowledge-base"
DOCS_DIR="$HOME/workshop/knowledge-base"   # 必须与 create_kb.py 中的 DOCS_PATH 一致

echo "========================================="
echo "Phase 2a: Create Bedrock Knowledge Base"
echo "========================================="
echo "  Region: $REGION"
echo "  KB scripts: $KB_DIR"
echo "  Docs dir: $DOCS_DIR"

# -----------------------------------------------------------------------------
# 0. 依赖
# -----------------------------------------------------------------------------
echo ""
echo "📦 Installing Python dependencies..."
python3 -m pip install --user --quiet --break-system-packages boto3 botocore retrying 2>/dev/null || \
  python3 -m pip install --user --quiet boto3 botocore retrying 2>/dev/null || true

# -----------------------------------------------------------------------------
# 1. 生成 HR 政策文档（写入 ~/workshop/knowledge-base/）
# -----------------------------------------------------------------------------
echo ""
echo "📝 Generating HR policy documents into $DOCS_DIR ..."
mkdir -p "$DOCS_DIR"
python3 "$KB_DIR/generate_hr_docs.py" "$DOCS_DIR"

# -----------------------------------------------------------------------------
# 2. 创建 KB 并灌库（S3 Vectors + IAM 角色 + ingestion）
#    create_kb.py 在结束时会打印完整的 Knowledge Base 详情。
# -----------------------------------------------------------------------------
echo ""
echo "🧠 Creating Bedrock Knowledge Base + ingesting documents..."
python3 "$KB_DIR/create_kb.py" --mode create

echo ""
echo "  Next: 02-create-gateway.sh ..."
