#!/bin/bash
# =============================================================================
# Phase 6: Operational Metrics — Cost & Latency
# Maps to: 080_governance §6.4 成本与延迟
#
# 兑现开篇 decision-first 三指标里的「响应速度」与「成本」：质量已由 THELMA
# 量化，这一步用【同一批已经跑过的 trace】把延迟和每次回答的成本也量出来——
# 不新建任何资源，只是把 Agent 跑的时候已经记进 aws/spans 的数据读出来算一下。
#
# 读什么、怎么算：
#   - 数据源：CloudWatch Logs 的 `aws/spans`（X-Ray Transaction Search 索引的
#     OpenTelemetry span），与 080 §6.1 / 09-run-eval.sh 用的是同一个 log group。
#   - 延迟：取一条 trace 内所有 span 的 (最大结束时间 - 最小开始时间)，即端到端墙钟。
#   - Token：从 span 属性里找 gen_ai.usage.* / *token* 字段，累加 input/output。
#   - 成本：token 数 × 模型单价（Nova 2 Lite，见下方 PRICE_*，价格会变，以官网为准）。
#
# 用法:
#   ./11-cost-latency.sh           # 取最近 N 条含检索的 trace，逐条算延迟+token+成本
#   ./11-cost-latency.sh <trace-id># 只算指定的一条 trace
#
# Prerequisites: 跑过至少一次对话（如 09-run-eval.sh），且 Transaction Search 已开启。
#
# ⚠️  首次在真实环境运行后请核对两件事：
#   1) span 里 token 字段的真实键名（不同 SDK 版本可能叫 gen_ai.usage.input_tokens
#      或 inputTokens 等）——脚本已做多候选兜底，若 token 全 0 按打印的提示调整。
#   2) PRICE_IN / PRICE_OUT 是否是 Nova 2 Lite 当前单价（美元 / 1M tokens）。
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/00-config.sh" ] && source "$SCRIPT_DIR/00-config.sh"

REGION=${AWS_DEFAULT_REGION:-us-west-2}
MODEL_ID="${WORKSHOP_MODEL_ID:-us.amazon.nova-2-lite-v1:0}"
RECENT_N=3                 # 默认算最近多少条 trace
LOOKBACK_SECONDS=7200      # 从 aws/spans 回溯多久（2 小时）
# 严格时间下界（毫秒）：调脚本前 export SINCE_EPOCH_MS=$(($(date +%s) * 1000))
# 用途同 09-run-eval.sh：在"换变量重跑"场景下严格只算本次对话的成本，
# 防止本次 invoke 全失败时静默退化到上一轮的旧 trace。
SINCE_EPOCH_MS="${SINCE_EPOCH_MS:-}"

# --- Nova 2 Lite 单价（美元 / 每 100 万 token）。价格会变动，以 AWS 官网为准。 ---
# 可用环境变量覆盖：PRICE_IN=0.06 PRICE_OUT=0.24 ./11-cost-latency.sh
PRICE_IN="${PRICE_IN:-0.06}"     # 输入 token 单价（$/1M）
PRICE_OUT="${PRICE_OUT:-0.24}"   # 输出 token 单价（$/1M）

echo "========================================="
echo "Phase 6: 成本与延迟（运营指标）"
echo "========================================="
echo "  模型: $MODEL_ID"
echo "  单价: 输入 \$$PRICE_IN / 1M  |  输出 \$$PRICE_OUT / 1M  （$/1M tokens，请核对官网）"
echo ""

# 取最近 N 条「含检索轮次」的 trace id（与 09-run-eval.sh 同款查询）
# 时间下界：优先 SINCE_EPOCH_MS（严格模式）；否则回落到 LOOKBACK_SECONDS。
recent_traces() {
  local n="$1"
  local start_ms
  if [ -n "$SINCE_EPOCH_MS" ]; then
    start_ms="$SINCE_EPOCH_MS"
  else
    start_ms=$(( ($(date +%s) - LOOKBACK_SECONDS) * 1000 ))
  fi
  aws logs filter-log-events --region "$REGION" --log-group-name "aws/spans" \
    --start-time "$start_ms" \
    --filter-pattern '"execute_tool hr-tools___retrieve_hr_policy"' \
    --query "events[].message" --output text 2>/dev/null | tr '\t' '\n' | python3 -c "
import sys, json
seen = {}
for line in sys.stdin:
    line = line.strip()
    if not line.startswith('{'): continue
    try: d = json.loads(line)
    except Exception: continue
    tid = d.get('traceId') or d.get('trace_id')
    ts  = d.get('startTimeUnixNano') or d.get('start_time') or 0
    ts  = int(ts) if str(ts).isdigit() else 0
    if tid and ts >= seen.get(tid, 0):
        seen[tid] = ts
for tid, _ in sorted(seen.items(), key=lambda x: x[1], reverse=True)[:$n]:
    print(tid)
"
}

# 拉一条 trace 的全部 span，算 延迟 + input/output token + 成本，打印一行
analyze_trace() {
  local tid="$1"
  local start_ms
  if [ -n "$SINCE_EPOCH_MS" ]; then
    start_ms="$SINCE_EPOCH_MS"
  else
    start_ms=$(( ($(date +%s) - LOOKBACK_SECONDS) * 1000 ))
  fi
  aws logs filter-log-events --region "$REGION" --log-group-name "aws/spans" \
    --start-time "$start_ms" \
    --filter-pattern "\"$tid\"" \
    --query "events[].message" --output text 2>/dev/null | tr '\t' '\n' | \
  PRICE_IN="$PRICE_IN" PRICE_OUT="$PRICE_OUT" TID="$tid" python3 -c "
import sys, json, os

tid = os.environ['TID']
pin, pout = float(os.environ['PRICE_IN']), float(os.environ['PRICE_OUT'])
min_start, max_end = None, None
tok_in, tok_out = 0, 0

def dig(obj, keys):
    '''在嵌套 dict 里找任一候选键，返回第一个能转成 int 的值'''
    found = 0
    stack = [obj]
    while stack:
        o = stack.pop()
        if isinstance(o, dict):
            for k, v in o.items():
                kl = str(k).lower()
                if any(c in kl for c in keys) and str(v).strip().lstrip('-').isdigit():
                    found = max(found, int(v))
                if isinstance(v, (dict, list)): stack.append(v)
        elif isinstance(o, list):
            stack.extend(o)
    return found

for line in sys.stdin:
    line = line.strip()
    if not line.startswith('{'): continue
    try: d = json.loads(line)
    except Exception: continue
    if (d.get('traceId') or d.get('trace_id')) != tid: continue
    s = d.get('startTimeUnixNano') or d.get('start_time')
    e = d.get('endTimeUnixNano') or d.get('end_time')
    try:
        s = int(s); e = int(e)
        min_start = s if min_start is None else min(min_start, s)
        max_end   = e if max_end   is None else max(max_end, e)
    except Exception: pass
    # token：优先精确键，再退到任何含 'token' 的键
    attrs = d.get('attributes') or d
    ti = dig(attrs, ['input_token','inputtoken','prompt_token'])
    to = dig(attrs, ['output_token','outputtoken','completion_token'])
    if ti or to:
        tok_in += ti; tok_out += to

# 纳秒 → 秒
lat = (max_end - min_start) / 1e9 if (min_start and max_end and max_end > min_start) else 0.0
cost = tok_in / 1_000_000 * pin + tok_out / 1_000_000 * pout
print(f'{tid[:16]}|{lat:.2f}|{tok_in}|{tok_out}|{cost:.6f}')
"
}

if [ -n "$1" ]; then
  ROWS=$(analyze_trace "$1")
else
  echo "🔎 取最近 $RECENT_N 条含检索的 trace..."
  TIDS=$(recent_traces "$RECENT_N")
  if [ -z "$TIDS" ]; then
    if [ -n "$SINCE_EPOCH_MS" ]; then
      echo "  ❌ 严格时间下界 ($SINCE_EPOCH_MS) 之后未找到含检索 trace——本次对话全失败,无成本/延迟可算。"
      exit 1
    fi
    echo "  ⚠️ 最近 ${LOOKBACK_SECONDS}s 内没找到含检索的 trace。请先跑一次对话（如 09-run-eval.sh）。"
    exit 0
  fi
  ROWS=""
  for tid in $TIDS; do
    ROWS="$ROWS$(analyze_trace "$tid")
"
  done
fi

# 打印表格 + 汇总
echo "$ROWS" | PRICE_IN="$PRICE_IN" PRICE_OUT="$PRICE_OUT" python3 -c "
import sys
rows = [r for r in (l.strip() for l in sys.stdin) if r and '|' in r]
if not rows:
    print('  (无数据)'); sys.exit()
print()
print('  %-18s %10s %12s %12s %12s' % ('Trace', '延迟(s)', '输入token', '输出token', '成本(USD)'))
print('  ' + '-'*68)
tot_lat = tot_in = tot_out = 0.0; tot_cost = 0.0; n = 0
for r in rows:
    tid, lat, ti, to, cost = r.split('|')
    lat, ti, to, cost = float(lat), int(ti), int(to), float(cost)
    print('  %-18s %10.2f %12d %12d %12.6f' % (tid, lat, ti, to, cost))
    tot_lat += lat; tot_in += ti; tot_out += to; tot_cost += cost; n += 1
print('  ' + '-'*68)
if n:
    print('  %-18s %10.2f %12d %12d %12.6f' % ('均值/合计', tot_lat/n, int(tot_in/n), int(tot_out/n), tot_cost))
    print()
    print(f'  ▸ 平均每次回答：延迟 {tot_lat/n:.2f}s，成本 \${tot_cost/n:.6f}')
    print(f'  ▸ {n} 次合计成本：\${tot_cost:.6f}')
"

echo ""
echo "✅ 成本与延迟统计完成"
echo ""
echo "ℹ️  若 token 列全是 0：说明你这套 span 的 token 字段键名与脚本候选不符。"
echo "    跑一下下面这条看真实字段名，再按需调整脚本里的候选键："
echo "    aws logs filter-log-events --region $REGION --log-group-name aws/spans \\"
echo "      --start-time \$(( (\$(date +%s) - 3600) * 1000 )) \\"
echo "      --filter-pattern '\"gen_ai\"' --query 'events[0].message' --output text | jq ."
