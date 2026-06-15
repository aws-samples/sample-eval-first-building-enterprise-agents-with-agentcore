#!/bin/bash
# =============================================================================
# Phase 4b: Golden-set Conversations + On-Demand Evaluation
# Maps to: 060_golden_set_eval/063_run_eval
#
# 一站式：跑 content 文档里的【三个代表性问题】（绩效 / 福利 / 病假），各产生
# 一条含检索的 trace，等索引完成后，对这三条跑 THELMA + Mind the Goal 评估并
# 打印分数。分数即与 063_run_eval 文档对应。
#
# 为什么逐条评、而不是 --days 全量评：
#   THELMA 是 TRACE 级评估器。用 `--days N` 把最近 N 天所有 trace 一次性灌给
#   评估服务时，里面混入大量纯 HTTP/工具噪声 trace（无检索轮次），评估器对
#   它们只能判 Skipped，结果不可控、噪声淹没真实分数。Workshop 里我们只关心
#   这几次真实对话，所以逐条用 --trace-id 评，范围明确、结果稳定。
#
# 用法:
#   ./09-run-eval.sh                              # 跑 3 个 golden 问题 → 评估这 3 条 trace（默认）
#   ./09-run-eval.sh --eval-only [N]              # 跳过对话，只评最近 N 条含检索的 trace（默认 3）
#   ./09-run-eval.sh <trace-id> [session-id]      # 只评指定 trace (THELMA)；强烈建议同时给 session-id
#   ./09-run-eval.sh <session-id> session         # 评指定 session (MtG)
#
# Prerequisites: 04-deploy.sh + 05-setup-memory.sh + 07-setup-eval-env.sh +
#                08-create-evaluators.sh（Transaction Search 必须已开启）
# =============================================================================
set -e

REGION=${AWS_DEFAULT_REGION:-us-west-2}
WORKDIR=~/workshop/hrassistant
ACTOR_ID="employee-001"
RECENT_N=3                 # 默认评估最近多少条 trace
LOOKBACK_SECONDS=7200      # 从 aws/spans 回溯多久找最近的 trace（2 小时）
INDEX_POLL_SECONDS=10      # 轮询 aws/spans 的间隔
INDEX_WAIT_MAX_SECONDS=150 # 等待 trace 索引的超时上限（兜底）
RESPONSE_TRUNCATE=300      # 打印 Agent 回答时截断到多少字符
INVOKE_LOG_DIR="$WORKDIR/agentcore/.cli/logs/invoke"   # agentcore invoke 日志目录
SESSION_IO_JSON="/tmp/agentcore-session-io.json"        # session_id → {query,response} 映射缓存

# content 063_run_eval 中的三个 golden 问题（顺序与文档一致：绩效 / 福利 / 病假）
GOLDEN_QUERIES=(
  "Can you explain the performance review process and the scoring criteria used?"
  "How do I enroll in benefits, and what is the benefits enrollment process?"
  "Do I need a medical certificate for sick leave, and what is the process?"
)
GOLDEN_LABELS=("绩效 performance review" "福利 benefits enrollment" "病假 sick leave")

echo "========================================="
echo "Phase 4b: Golden-set Conversations + Evaluation"
echo "========================================="

# ---- 跑三个 golden 问题，产生含检索的 trace ----
run_golden_conversations() {
  echo ""
  echo "🗣️  运行三个 golden 问题（绩效 / 福利 / 病假）..."
  cd "$WORKDIR"
  for i in "${!GOLDEN_QUERIES[@]}"; do
    local Q="${GOLDEN_QUERIES[$i]}" L="${GOLDEN_LABELS[$i]}"
    local SID="session-$(cat /proc/sys/kernel/random/uuid)-$(date +%s)"
    echo ""
    echo "─── Q$((i+1)) [$L] ───"
    echo "    \"$Q\"   (session: $SID)"
    npx agentcore invoke --session-id "$SID" --actor-id "$ACTOR_ID" --stream "$Q" \
      2>&1 | grep -vE 'PythonDeprecationWarning|warnings.warn|boto3 will no longer|upgrade to Python|More information can' || true
    echo ""
  done
  # 轮询等待 trace 落库 + 索引完成（而非固定 sleep）：每 10s 查一次 aws/spans，
  # 直到出现至少 want 条含检索的 trace，或达到超时上限兜底。
  local want="${#GOLDEN_QUERIES[@]}"
  echo ""
  echo "⏳ 轮询 aws/spans，等待 $want 条含检索 trace 落库并索引（最多 ${INDEX_WAIT_MAX_SECONDS}s）..."
  local waited=0 found=0
  while [ "$waited" -lt "$INDEX_WAIT_MAX_SECONDS" ]; do
    sleep "$INDEX_POLL_SECONDS"
    waited=$(( waited + INDEX_POLL_SECONDS ))
    found=$(recent_retrieve_traces "$want" | grep -c . || true)
    echo "    [$waited s] 已索引含检索 trace: $found/$want"
    [ "$found" -ge "$want" ] && { echo "  ✅ trace 已就绪"; return 0; }
  done
  echo "  ⚠️  超时（仅 $found/$want 条就绪），继续评估已就绪的部分。"
}

# 解析已部署的 runtime ARN
RT_ARN=$(aws bedrock-agentcore-control list-agent-runtimes --region $REGION \
  --query "agentRuntimes[?contains(agentRuntimeName,'hrassistant')].agentRuntimeArn" \
  --output text 2>/dev/null | head -1)
[ -z "$RT_ARN" -o "$RT_ARN" = "None" ] && { echo "❌ 未找到 hrassistant runtime，请先 04-deploy.sh"; exit 1; }
echo "  Runtime: $RT_ARN"

# 解析 evaluator ARN
get_ev_arn() {
  aws bedrock-agentcore-control list-evaluators --region $REGION \
    --query "evaluators[?contains(evaluatorId,'$1')].evaluatorArn" --output text 2>/dev/null | head -1
}
THELMA_ARN=$(get_ev_arn "thelma_rag_quality")
MTG_ARN=$(get_ev_arn "mtg_goal_success")

# 扫描 agentcore invoke 日志，构建 session_id → {query, response} 映射，写入缓存。
# 每个 invoke 日志含结构化的 sessionId / prompt / response，按 sessionId 关联最可靠。
# query/response 直接取自实际 invoke（而非脚本常量），保证是真实发生的内容。
build_session_io_map() {
  python3 -c "
import json, glob, os, re
log_dir = os.path.expanduser('$INVOKE_LOG_DIR')
mapping = {}
for path in sorted(glob.glob(os.path.join(log_dir, '*.log')), key=os.path.getmtime):
    try:
        txt = open(path, encoding='utf-8', errors='replace').read()
    except Exception:
        continue
    dec = json.JSONDecoder()
    sid = q = r = None
    # 日志里嵌着多个 JSON 块（REQUEST / RESPONSE），逐个解析取字段
    for m in re.finditer(r'\{', txt):
        try:
            obj, _ = dec.raw_decode(txt[m.start():])
        except Exception:
            continue
        if isinstance(obj, dict):
            if obj.get('sessionId'): sid = obj['sessionId']
            if obj.get('prompt'):    q   = obj['prompt']
            if obj.get('response'):  r   = obj['response']
    if sid:
        # 同一 session 后写覆盖先写（取该 session 最新一次 invoke）
        mapping[sid] = {'query': q or mapping.get(sid, {}).get('query'),
                        'response': r or mapping.get(sid, {}).get('response')}
open('$SESSION_IO_JSON', 'w', encoding='utf-8').write(json.dumps(mapping))
" 2>/dev/null || echo '{}' > "$SESSION_IO_JSON"
}

# 跑单次评估并打印 query + 截断 response + 分数（接受 --trace-id / --session-id 等参数）
run_eval() {
  local label="$1" ev_arn="$2"; shift 2
  echo ""
  echo "🔬 $label"
  # spans 索引最终一致：刚生成的 trace 可能尚未对 evaluator framework 可见，
  # 表现为 "No session spans found for agent ...". 重试若干次以覆盖索引延迟。
  local out="" attempt
  for attempt in 1 2 3; do
    out=$(npx agentcore run eval --runtime-arn "$RT_ARN" --evaluator-arn "$ev_arn" \
      --region $REGION "$@" --days 1 --json 2>/dev/null | grep -E '^\{')
    if echo "$out" | grep -q '"success":true'; then break; fi
    if echo "$out" | grep -q 'No session spans found'; then
      [ $attempt -lt 3 ] && { echo "    (spans not indexed yet, retry in 20s ${attempt}/3)"; sleep 20; continue; }
    fi
    break
  done
  echo "$out" | python3 -c "
import sys, json, os
TRUNC = $RESPONSE_TRUNCATE
# 载入 session_id → {query,response} 映射（可能不存在，如 --eval-only 模式）
try:
    io_map = json.load(open('$SESSION_IO_JSON', encoding='utf-8'))
except Exception:
    io_map = {}
try:
    d = json.load(sys.stdin)
except Exception:
    print('  (无结果或解析失败)'); sys.exit()
if not d.get('success', True):
    print('  ERROR:', d.get('error')); sys.exit()
for s in d['run']['results'][0]['sessionScores']:
    lbl = s.get('label')
    if lbl in ('Skipped',): continue
    sid = s.get('sessionId', '')
    io = io_map.get(sid, {})
    q, r = io.get('query'), io.get('response')
    if q:
        print(f'  Query:    {q}')
    if r:
        r1 = ' '.join(r.split())  # 压平换行，便于单行截断展示
        if len(r1) > TRUNC: r1 = r1[:TRUNC] + ' …[截断]'
        print(f'  Response: {r1}')
    print(f\"  Score:    trace={s.get('traceId','?')[:16]} value={s.get('value')} [{lbl}]\")
    if s.get('explanation'): print(f\"     {s['explanation']}\")
"
}

# 从 aws/spans 取最近 N 条“含检索轮次”的 trace（去重，按时间倒序）
# 输出每行 "trace_id|session_id"，供 THELMA(按 trace) 与 MtG(按 session) 共用。
recent_retrieve_traces() {
  local n="$1"
  aws logs filter-log-events --region $REGION --log-group-name "aws/spans" \
    --start-time $(( ($(date +%s) - LOOKBACK_SECONDS) * 1000 )) \
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
    sid = (d.get('attributes') or {}).get('session.id') or d.get('session_id') or ''
    ts  = d.get('startTimeUnixNano') or d.get('start_time') or 0
    ts  = int(ts) if str(ts).isdigit() else 0
    if tid and ts >= seen.get(tid, (0, ''))[0]:
        seen[tid] = (ts, sid)
for tid, (ts, sid) in sorted(seen.items(), key=lambda x: x[1][0], reverse=True)[:$n]:
    print(f'{tid}|{sid}')
"
}

# 构建 session_id → {query,response} 映射（供 run_eval 打印）。
# 即便 --eval-only / 指定 trace 模式，只要 invoke 日志还在就能关联到。
build_session_io_map

if [ "$2" = "session" ]; then
  # 指定 session → MtG
  run_eval "Mind the Goal (GSR) — session $1" "$MTG_ARN" --session-id "$1"
elif [[ "$1" =~ ^[0-9a-f]{16,}$ ]]; then
  # 指定 trace → THELMA。可选第二参为同 trace 的 session-id（推荐传，框架 trace-only
  # 路径不走 session 索引，会报 "No session spans found"）。
  if [ -n "$2" ]; then
    run_eval "THELMA (RAG quality) — trace $1" "$THELMA_ARN" --session-id "$2" --trace-id "$1"
  else
    run_eval "THELMA (RAG quality) — trace $1" "$THELMA_ARN" --trace-id "$1"
  fi
else
  # 默认：先跑三个 golden 问题产生 trace，再评估这几条。
  # 传 --eval-only [N] 则跳过对话，直接评最近 N 条已有的含检索 trace。
  if [ "$1" = "--eval-only" ]; then
    N="${2:-$RECENT_N}"
    echo "  (--eval-only：跳过对话，直接评最近 $N 条 trace)"
  else
    run_golden_conversations
    N=${#GOLDEN_QUERIES[@]}
  fi

  echo ""
  echo "🔎 取最近 $N 条含检索的 trace..."
  ROWS=$(recent_retrieve_traces "$N")
  if [ -z "$ROWS" ]; then
    echo "  ⚠️  最近 ${LOOKBACK_SECONDS}s 内未找到含检索的 trace。"
    echo "      若用了 --eval-only，请先不带参数运行本脚本（会自动跑 3 个对话）。"
    exit 0
  fi
  echo "$ROWS" | sed 's/^/    - /'

  echo ""
  echo "═══ THELMA (RAG quality) — $N 条 trace ═══"
  i=0
  for row in $ROWS; do
    i=$((i+1))
    tid="${row%%|*}"
    sid="${row#*|}"
    # 同时传 --session-id + --trace-id：trace-id 锁定那一轮，session-id 让 framework
    # 能在 spans 索引中定位到对应 session（仅传 trace-id 时 framework 报
    # "No session spans found for agent ..."，因为 trace-only 路径不走 session 索引）。
    if [ -n "$sid" ]; then
      run_eval "THELMA — trace #$i ${tid:0:16}" "$THELMA_ARN" --session-id "$sid" --trace-id "$tid"
    else
      run_eval "THELMA — trace #$i ${tid:0:16}" "$THELMA_ARN" --trace-id "$tid"
    fi
  done

  echo ""
  echo "═══ Mind the Goal (GSR) — 对应 session（去重）═══"
  # 提取去重后的 session_id，逐个评 MtG
  SESSIONS=$(for row in $ROWS; do sid="${row#*|}"; [ -n "$sid" ] && echo "$sid"; done | awk '!seen[$0]++')
  if [ -z "$SESSIONS" ]; then
    echo "  (未能从 span 解析出 session id，跳过 MtG)"
  else
    j=0
    for sid in $SESSIONS; do
      j=$((j+1))
      run_eval "Mind the Goal — session #$j ${sid:0:24}" "$MTG_ARN" --session-id "$sid"
    done
  fi
fi

echo ""
echo "✅ Evaluation complete"
