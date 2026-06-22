#!/bin/bash
# =============================================================================
# Optional Lab B: Judge Stability（评委稳定性检验）
# Maps to: 085_optional_labs/087_judge_stability
#
# 回答 CXO 必问的一句："你这个 AI 裁判(THELMA)自己靠谱吗？会不会瞎打分？"
# 轻量检验：对【同一条 trace】用 THELMA 连打 N 次，看分数稳不稳。
#   - 分数每次都差不多 → 裁判可重复、可信
#   - 分数忽高忽低     → 裁判不稳定，结论别太当真（小模型尤其容易这样）
#
# ⚠️  这是【可选延伸】。它只是"重复性(repeatability)"这一项轻量检验，
#     生产环境推荐的并行做法是【人工样本校准】（见文档 notes）。
#
# ⚠️  关于 Nova：本 workshop 默认 judge 用 Nova 2 Lite（小模型）。小模型做
#     LLM-as-judge 时一致性通常不如大模型，分数抖动可能偏大——这正是这个
#     检验要暴露的，也提醒生产里 judge 最好用更强的模型或加人工校准。
#
# 用法:
#   ./13-judge-stability.sh                  # 取最近 1 条含检索 trace，连打 3 次
#   ./13-judge-stability.sh <trace-id> [N]   # 指定 trace，打 N 次（默认 3）
#
# Prerequisites: 08-create-evaluators.sh 完成；至少有一条含检索的 trace。
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION=${AWS_DEFAULT_REGION:-us-west-2}
LOOKBACK_SECONDS=7200
RUNS="${2:-3}"

echo "========================================="
echo "Optional Lab B: 评委稳定性检验"
echo "========================================="

RT_ARN=$(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
  --query "agentRuntimes[?contains(agentRuntimeName,'hrassistant')].agentRuntimeArn" \
  --output text 2>/dev/null | head -1)
[ -z "$RT_ARN" -o "$RT_ARN" = "None" ] && { echo "❌ 未找到 hrassistant runtime"; exit 1; }

THELMA_ARN=$(aws bedrock-agentcore-control list-evaluators --region "$REGION" \
  --query "evaluators[?contains(evaluatorId,'thelma_rag_quality')].evaluatorArn" --output text 2>/dev/null | head -1)
[ -z "$THELMA_ARN" -o "$THELMA_ARN" = "None" ] && { echo "❌ 未找到 THELMA evaluator"; exit 1; }

# 取一条 trace（含其 session）
pick_one() {
  aws logs filter-log-events --region "$REGION" --log-group-name "aws/spans" \
    --start-time $(( ($(date +%s) - LOOKBACK_SECONDS) * 1000 )) \
    --filter-pattern '"execute_tool hr-tools___retrieve_hr_policy"' \
    --query "events[].message" --output text 2>/dev/null | tr '\t' '\n' | python3 -c "
import sys, json
best=None; bts=-1
for line in sys.stdin:
    line=line.strip()
    if not line.startswith('{'): continue
    try: d=json.loads(line)
    except Exception: continue
    tid=d.get('traceId') or d.get('trace_id')
    sid=(d.get('attributes') or {}).get('session.id') or d.get('session_id') or ''
    ts=d.get('startTimeUnixNano') or d.get('start_time') or 0
    ts=int(ts) if str(ts).isdigit() else 0
    if tid and ts>bts: bts=ts; best=(tid,sid)
if best: print(f'{best[0]}|{best[1]}')
"
}

if [ -n "$1" ]; then
  TID="$1"; SID=""
else
  ROW=$(pick_one)
  [ -z "$ROW" ] && { echo "⚠️ 最近 ${LOOKBACK_SECONDS}s 没有含检索的 trace，请先跑一次对话（09-run-eval.sh）。"; exit 0; }
  TID="${ROW%%|*}"; SID="${ROW#*|}"
fi
echo "  目标 trace: ${TID:0:16}  （连打 $RUNS 次 THELMA）"

# 跑一次 THELMA，只取 value
run_once() {
  local args=(--runtime-arn "$RT_ARN" --evaluator-arn "$THELMA_ARN" --region "$REGION" --days 1 --json)
  if [ -n "$SID" ]; then args+=(--session-id "$SID" --trace-id "$TID"); else args+=(--trace-id "$TID"); fi
  npx agentcore run eval "${args[@]}" 2>/dev/null | grep -E '^\{' | python3 -c "
import sys, json
try: d=json.load(sys.stdin)
except Exception: print(''); sys.exit()
try:
    for s in d['run']['results'][0]['sessionScores']:
        if s.get('label') in ('Skipped',): continue
        print(s.get('value')); break
except Exception: print('')
"
}

VALUES=()
for i in $(seq 1 "$RUNS"); do
  echo "  第 $i 次..."
  v=$(run_once)
  echo "    value = ${v:-（无结果，可能 spans 未索引，稍后重试）}"
  [ -n "$v" ] && VALUES+=("$v")
  sleep 5
done

echo ""
printf '%s\n' "${VALUES[@]}" | python3 -c "
import sys
xs=[float(x) for x in sys.stdin if x.strip()]
if len(xs)<2:
    print('  数据不足，无法判断稳定性（拿到 %d 个有效分）。' % len(xs)); sys.exit()
mean=sum(xs)/len(xs)
var=sum((x-mean)**2 for x in xs)/len(xs)
std=var**0.5
print(f'  分数: {xs}')
print(f'  均值={mean:.3f}  标准差={std:.3f}  极差={max(xs)-min(xs):.3f}')
print()
if std<=0.03:
    print('  ✅ 稳定：多次打分高度一致，这个裁判在重复性上可信。')
elif std<=0.08:
    print('  ⚠️ 一般：有一定抖动，结论可用但别抠小数点。')
else:
    print('  ❌ 不稳：抖动明显。小模型(如 Nova 2 Lite)做 judge 容易这样——')
    print('     生产里建议 judge 换更强模型，并配人工样本校准（见文档）。')
"

echo ""
echo "✅ 稳定性检验完成"
echo ""
echo "ℹ️  这只是「重复性」一项。生产环境推荐的并行做法是【人工样本校准】："
echo "    准备一批人工标注好对错的对话，跑 THELMA，算它和人判断的吻合率(TPR/TNR)，"
echo "    确认这把尺子和专家对齐——这才是真正证明裁判可信的方式。"
