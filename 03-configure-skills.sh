#!/bin/bash
# =============================================================================
# Phase 2c: Configure Skills
# Maps to: 040_create_deploy/044_skills
#
# Writes SKILL.md files locally and uploads them to S3. Skills are mounted into
# the Harness session via BYO Filesystem (configured in 04-deploy.sh).
# =============================================================================
set -e

REGION=${AWS_DEFAULT_REGION:-us-west-2}

echo "========================================="
echo "Phase 2c: Configure Skills"
echo "========================================="

# Write Skill files
echo "📝 Writing Skill files..."
mkdir -p ~/workshop/skills/deep-policy-analysis
mkdir -p ~/workshop/skills/leave-calculator

cat > ~/workshop/skills/deep-policy-analysis/SKILL.md << 'EOF'
---
name: deep-policy-analysis
description: Provide detailed analysis of HR policies with cross-references, exceptions, and specific examples
---
# Deep Policy Analysis

When user needs detailed policy interpretation, execute these steps:

1. Retrieve the relevant policy document via hr-tools
2. Identify applicable sections and any exceptions
3. Cross-reference with related policies (e.g., leave policy + benefits policy)
4. Provide specific examples relevant to the employee's situation
5. Cite exact policy sections and effective dates

## Output Format

- Policy name and version
- Applicable sections (quoted)
- Exceptions and special cases
- Cross-references to related policies
- Concrete examples for the employee's situation
EOF

cat > ~/workshop/skills/leave-calculator/SKILL.md << 'EOF'
---
name: leave-calculator
description: Calculate leave balances, plan optimal leave schedules, and check eligibility for various leave types
---
# Leave Calculator

Help employees plan their leave by:

1. Check current leave balance via hr-tools (check_leave_balance)
2. Calculate remaining days by leave type
3. Suggest optimal scheduling (avoid peak periods, consider team coverage)
4. Verify eligibility for special leave types (marriage, parental, bereavement)

## Output Format

| Leave Type | Entitled | Used | Remaining |
|-----------|----------|------|-----------|
| Annual    | 15 days  | 5    | 10        |
| Sick      | 10 days  | 2    | 8         |
| ...       | ...      | ...  | ...       |

Include recommendations for optimal scheduling.
EOF

# Upload to S3
echo "📤 Uploading Skills to S3..."
SKILLS_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name workshop-infra \
  --query 'Stacks[0].Outputs[?OutputKey==`SkillsBucketName` || OutputKey==`DataBucketName`].OutputValue | [0]' \
  --output text --region $REGION 2>/dev/null || echo "")

if [ -n "$SKILLS_BUCKET" ] && [ "$SKILLS_BUCKET" != "None" ]; then
  aws s3 cp ~/workshop/skills/deep-policy-analysis/SKILL.md s3://$SKILLS_BUCKET/skills/deep-policy-analysis/SKILL.md
  aws s3 cp ~/workshop/skills/leave-calculator/SKILL.md s3://$SKILLS_BUCKET/skills/leave-calculator/SKILL.md
  echo "  ✅ Uploaded to: s3://$SKILLS_BUCKET/skills/"
else
  echo "❌ No S3 bucket found (workshop-infra stack not deployed?)"
  exit 1
fi

echo ""
echo "✅ Skills configured"
echo "  Next: Run 04-deploy.sh"
