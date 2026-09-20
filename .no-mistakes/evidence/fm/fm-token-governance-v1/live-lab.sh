#!/usr/bin/env bash
# Isolated live drive of the spend-governance CLIs. Writes transcripts under
# this evidence directory. Exit 0 only when every live check passed.
set -u
ROOT="/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M2ZAZ1YHFX1Q25BX9EN05MVS"
EVID="/Users/yelen/.no-mistakes/evidence/01M2ZAZ1YHFX1Q25BX9EN05MVS"
LEDGER="$ROOT/bin/fm-spend-ledger.py"
SPEND="$ROOT/bin/fm-procevent-spend.sh"
PROVISION="$ROOT/bin/fm-pi-role-agents.py"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-token-gov-live.XXXXXX")
HOME_DIR="$LAB/home"
STATE="$HOME_DIR/state"
SESSIONS="$LAB/sessions"
PI_DIR="$LAB/pi-config"
FAILS=0

cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$STATE" "$SESSIONS" "$HOME_DIR/config" "$PI_DIR/agents" "$EVID"

log() { printf '%s\n' "$*" | tee -a "$EVID/live-lab.log"; }
fail() { log "FAIL: $1"; FAILS=$((FAILS + 1)); }
ok() { log "PASS: $1"; }

json_field() {
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"
}

make_session_dir() {
  local cwd=$1 encoded
  encoded="--$(printf '%s' "${cwd#/}" | tr '/\\:' '---')--"
  mkdir -p "$SESSIONS/$encoded"
  printf '%s\n' "$SESSIONS/$encoded"
}

write_header() {
  printf '{"type":"session","version":3,"id":"%s","timestamp":"%s","cwd":"%s"}\n' \
    "$2" "$4" "$3" > "$1"
}

append_effort() {
  printf '{"type":"thinking_level_change","id":"x","parentId":null,"timestamp":"%s","thinkingLevel":"%s"}\n' \
    "$2" "$3" >> "$1"
}

append_message() {
  local file=$1 iso=$2 provider=$3 model=$4 tokens=$5
  printf '{"type":"message","timestamp":"%s","message":{"role":"assistant","provider":"%s","model":"%s","usage":{"input":%s,"output":10,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":%s,"cost":{"input":0,"output":0.01,"cacheRead":0,"cacheWrite":0,"total":0.01}}}}\n' \
    "$iso" "$provider" "$model" "$tokens" "$tokens" >> "$file"
}

write_meta() {
  printf 'endpoint_task_id=%s\nworktree=%s\nspawn_gen=%s\nharness=%s\nkind=ship\neffort=%s\n' \
    "$1" "$2" "$3" "$4" "${5:-medium}" > "$STATE/$1.meta"
}

EPOCH=$(python3 -c 'import datetime; print(int(datetime.datetime(2026,9,15,tzinfo=datetime.timezone.utc).timestamp()))')
NOW_ISO=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')
RESETS=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')

# --- 1. ledger reports task cost including nested subagent --------------------
write_meta task-a /work/alpha "s${EPOCH}.1.aa" pi high
DIR_ALPHA=$(make_session_dir /work/alpha)
DIR_OTHER=$(make_session_dir /work/other)
S1=$DIR_ALPHA/2026-09-16T10-00-00-000Z_aaaaaaaa-0000-0000-0000-000000000001.jsonl
write_header "$S1" "aaaaaaaa-0000-0000-0000-000000000001" /work/alpha "2026-09-16T10:00:00.000Z"
append_effort "$S1" "2026-09-16T10:00:05.000Z" high
append_message "$S1" "2026-09-16T10:01:00.000Z" openai-codex gpt-6-astra 1000
append_message "$S1" "2026-09-16T10:02:00.000Z" openai-codex gpt-6-astra 2000
append_effort "$S1" "2026-09-16T10:03:00.000Z" max
append_message "$S1" "2026-09-16T10:04:00.000Z" xai grok-4 500
CHILD=$DIR_OTHER/2026-09-16T10-05-00-000Z_cccccccc-0000-0000-0000-0000000000cc.jsonl
write_header "$CHILD" "cccccccc-0000-0000-0000-0000000000cc" /work/other "2026-09-16T10:05:00.000Z"
append_effort "$CHILD" "2026-09-16T10:05:05.000Z" medium
append_message "$CHILD" "2026-09-16T10:06:00.000Z" openai-codex gpt-6-astra 400
mkdir -p "$DIR_ALPHA/artifacts/aaaaaaaa-0000-0000-0000-000000000001"
printf '{"fm-orchestrated-worker":{"sessionFile":"%s","sessionId":"cccccccc-0000-0000-0000-0000000000cc"}}\n' \
  "$CHILD" > "$DIR_ALPHA/artifacts/aaaaaaaa-0000-0000-0000-000000000001/subagent-registry.json"

TASK_DOC=$("$LEDGER" --state "$STATE" --sessions-root "$SESSIONS" task task-a)
printf '%s\n' "$TASK_DOC" > "$EVID/ledger-task-a.json"
status=$(json_field "$TASK_DOC" "d['status']")
tokens=$(json_field "$TASK_DOC" "d['totals']['tokens']")
nested=$(json_field "$TASK_DOC" "d['totals']['nestedSessions']")
codex=$(json_field "$TASK_DOC" "d['byLane']['codex']['tokens']")
partial=$(json_field "$TASK_DOC" "d.get('partial')")
if [ "$status" = ok ] && [ "$tokens" = 3900 ] && [ "$nested" = 1 ] && [ "$codex" = 3400 ] && [ "$partial" = False ]; then
  ok "ledger reports nested Pi task cost (3900 tokens, 1 nested, complete)"
else
  fail "ledger task-a unexpected: status=$status tokens=$tokens nested=$nested codex=$codex partial=$partial"
fi

# --- 2. empty spend is empty, never a fabricated zero that looks complete -----
write_meta task-empty /work/empty "s${EPOCH}.1.ee" pi medium
EMPTY_DOC=$("$LEDGER" --state "$STATE" --sessions-root "$SESSIONS" task task-empty)
printf '%s\n' "$EMPTY_DOC" > "$EVID/ledger-task-empty.json"
empty_status=$(json_field "$EMPTY_DOC" "d['status']")
empty_tokens=$(json_field "$EMPTY_DOC" "d['totals']['tokens']")
if [ "$empty_status" = empty ]; then
  ok "ledger empty task is status=empty (tokens field=$empty_tokens, not treated as a complete zero)"
else
  fail "empty task status=$empty_status"
fi

# Poll against the real ledger: empty must not fire a ceiling.
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_SPEND_SESSIONS="$SESSIONS" \
  "$SPEND" poll --task task-empty --ceiling 5000 --interval 0.05 \
  > "$LAB/empty-poll.out" 2>"$LAB/empty-poll.err" &
empty_pid=$!
sleep 0.6
kill "$empty_pid" 2>/dev/null
wait "$empty_pid" 2>/dev/null
cp "$LAB/empty-poll.out" "$EVID/empty-poll.out"
cp "$LAB/empty-poll.err" "$EVID/empty-poll.err"
if [ ! -s "$LAB/empty-poll.out" ]; then
  ok "empty ledger poll kept watching (no ceiling/zero fire)"
else
  fail "empty ledger poll produced a capture: $(cat "$LAB/empty-poll.out")"
fi

# --- 3. unmeasured Codex harness is not armed --------------------------------
printf '%s\n' '{"taskCeilingTokens":5000,"pollIntervalSeconds":7}' > "$HOME_DIR/config/spend-ceilings.json"
write_meta t-codex /work/codex "s${EPOCH}.1.cc" codex high
ARM_CODEX=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$SPEND" arm --task t-codex 2>&1) || true
printf '%s\n' "$ARM_CODEX" > "$EVID/arm-codex.txt"
if printf '%s\n' "$ARM_CODEX" | grep -Fq 'unmeasured harness' \
  && [ ! -e "$STATE/procevent/spend-task-t-codex.source" ]; then
  ok "arm skips unmeasured Codex harness"
else
  fail "codex arm output: $ARM_CODEX"
fi

write_meta t-pi /work/alpha "s${EPOCH}.1.pp" pi medium
ARM_PI=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$SPEND" arm --task t-pi 2>&1) || true
printf '%s\n' "$ARM_PI" > "$EVID/arm-pi.txt"
if printf '%s\n' "$ARM_PI" | grep -Fq 'armed: spend-task-t-pi' \
  && [ -f "$STATE/procevent/spend-task-t-pi.source" ]; then
  ok "arm registers a measured Pi task"
else
  fail "pi arm output: $ARM_PI"
fi

# Default poll argv must not pass --scan-budget. Wrap the real ledger.
WRAPPER="$LAB/ledger-wrap.py"
python3 - "$WRAPPER" "$LAB/ledger-argv.log" "$LEDGER" <<'PY'
import pathlib, sys
wrapper, log, real = sys.argv[1], sys.argv[2], sys.argv[3]
pathlib.Path(wrapper).write_text(
    "#!/usr/bin/env python3\n"
    "import os, sys\n"
    f"open({log!r}, 'a').write(' '.join(sys.argv[1:]) + chr(10))\n"
    f"os.execv({sys.executable!r}, [{sys.executable!r}, {real!r}, *sys.argv[1:]])\n"
)
PY
chmod +x "$WRAPPER"
write_meta t-argv /work/alpha "s${EPOCH}.1.aa" pi medium
: > "$LAB/ledger-argv.log"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_SPEND_SESSIONS="$SESSIONS" \
  FM_SPEND_LEDGER="$WRAPPER" \
  "$SPEND" poll --task t-argv --ceiling 999999 --interval 0.05 \
  > "$LAB/argv-poll.out" 2>"$LAB/argv-poll.err" &
argv_pid=$!
sleep 0.8
kill "$argv_pid" 2>/dev/null
wait "$argv_pid" 2>/dev/null
cp "$LAB/ledger-argv.log" "$EVID/poll-ledger-argv.log"
cp "$LAB/argv-poll.err" "$EVID/argv-poll.err"
if grep -q -- '--scan-budget' "$LAB/ledger-argv.log"; then
  fail "default poll passed --scan-budget: $(cat "$LAB/ledger-argv.log")"
elif grep -q 'task t-argv' "$LAB/ledger-argv.log"; then
  ok "default ceiling poll invokes ledger task without a scan budget"
else
  fail "default poll did not invoke ledger: log=$(cat "$LAB/ledger-argv.log") err=$(cat "$LAB/argv-poll.err")"
fi

# --- 4. partial scan is not treated as a complete under-ceiling total ---------
# Seed a small bound session and cache it, then add a huge new session. A scan
# budget that has already elapsed (-1) leaves uncached growth remaining, so the
# document stays partial with the cached undercount.
PARTIAL_SESS="$LAB/partial-sessions"
PARTIAL_STATE="$LAB/partial-state"
mkdir -p "$PARTIAL_STATE" "$PARTIAL_SESS"
printf 'endpoint_task_id=t-partial\nworktree=/work/partial\nspawn_gen=s%s.1.pa\nharness=pi\nkind=ship\neffort=medium\n' \
  "$EPOCH" > "$PARTIAL_STATE/t-partial.meta"
encoded="--$(printf '%s' "work/partial" | tr '/\\:' '---')--"
mkdir -p "$PARTIAL_SESS/$encoded"
PDIR="$PARTIAL_SESS/$encoded"
PSMALL=$PDIR/2026-09-16T11-00-00-000Z_p1111111-0000-0000-0000-000000000001.jsonl
write_header "$PSMALL" "p1111111-0000-0000-0000-000000000001" /work/partial "2026-09-16T11:00:00.000Z"
append_effort "$PSMALL" "2026-09-16T11:00:05.000Z" medium
append_message "$PSMALL" "2026-09-16T11:01:00.000Z" openai-codex gpt-6-astra 100
"$LEDGER" --state "$PARTIAL_STATE" --sessions-root "$PARTIAL_SESS" task t-partial >/dev/null
PHUGE=$PDIR/2026-09-16T11-10-00-000Z_p2222222-0000-0000-0000-000000000002.jsonl
write_header "$PHUGE" "p2222222-0000-0000-0000-000000000002" /work/partial "2026-09-16T11:10:00.000Z"
append_effort "$PHUGE" "2026-09-16T11:10:05.000Z" max
append_message "$PHUGE" "2026-09-16T11:11:00.000Z" openai-codex gpt-6-astra 99999
PARTIAL_DOC=$("$LEDGER" --state "$PARTIAL_STATE" --sessions-root "$PARTIAL_SESS" task t-partial --scan-budget=-1)
printf '%s\n' "$PARTIAL_DOC" > "$EVID/ledger-task-partial.json"
p_status=$(json_field "$PARTIAL_DOC" "d['status']")
p_partial=$(json_field "$PARTIAL_DOC" "d.get('partial')")
p_tokens=$(json_field "$PARTIAL_DOC" "d['totals']['tokens']")
if [ "$p_status" = ok ] && [ "$p_partial" = True ] && [ "$p_tokens" = 100 ]; then
  ok "ledger with an elapsed scan budget reports partial=true undercount (100 of 100099)"
else
  fail "partial document unexpected: status=$p_status partial=$p_partial tokens=$p_tokens"
fi

# Poller with an elapsed scan budget must keep watching, not fire on the undercount.
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$PARTIAL_STATE" FM_SPEND_SESSIONS="$PARTIAL_SESS" \
  "$SPEND" poll --task t-partial --ceiling 5000 --interval 0.05 --scan-budget -1 \
  > "$LAB/partial-poll.out" 2>"$LAB/partial-poll.err" &
partial_pid=$!
sleep 0.6
kill "$partial_pid" 2>/dev/null
wait "$partial_pid" 2>/dev/null
cp "$LAB/partial-poll.out" "$EVID/partial-poll.out"
cp "$LAB/partial-poll.err" "$EVID/partial-poll.err"
if [ ! -s "$LAB/partial-poll.out" ]; then
  ok "partial undercount did not fire the 5000-token ceiling"
else
  fail "partial poll fired: $(cat "$LAB/partial-poll.out")"
fi

# Complete (no budget) poll against the same files must fire.
COMPLETE_POLL=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$PARTIAL_STATE" FM_SPEND_SESSIONS="$PARTIAL_SESS" \
  "$SPEND" poll --task t-partial --ceiling 5000 --interval 1 2>"$LAB/complete-poll.err") || true
printf '%s\n' "$COMPLETE_POLL" > "$EVID/complete-ceiling-poll.out"
cp "$LAB/complete-poll.err" "$EVID/complete-poll.err"
if printf '%s\n' "$COMPLETE_POLL" | grep -qx 'status: ceiling' \
  && printf '%s\n' "$COMPLETE_POLL" | grep -qx 'observed_tokens: 100099'; then
  ok "complete poll fires ceiling at 100099 tokens"
else
  fail "complete poll did not fire as expected: out=$COMPLETE_POLL err=$(cat "$LAB/complete-poll.err")"
fi

# --- 5. predict calibrates only weekly windows --------------------------------
cat > "$STATE/quota-mixed.json" <<EOF
{"schema":"quota-axi.v5","providers":[
 {"provider":"codex","windows":[{"id":"weekly","kind":"weekly","resetsAt":"$RESETS","percentRemaining":40,"pace":{"burnMultiple":2.0}}]},
 {"provider":"daily","windows":[{"id":"daily","kind":"daily","resetsAt":"$RESETS","percentRemaining":40,"pace":{"burnMultiple":2.0}}]},
 {"provider":"unmeasured","windows":[],"availability":[]}
]}
EOF
PREDICT=$("$LEDGER" --state "$STATE" --sessions-root "$SESSIONS" predict --quota "$STATE/quota-mixed.json")
printf '%s\n' "$PREDICT" > "$EVID/predict-mixed.json"
pred_status=$(json_field "$PREDICT" "d['status']")
has_daily=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print("daily" in d.get("providers",{}))' "$PREDICT")
has_unmeasured=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print("unmeasured" in d.get("providers",{}))' "$PREDICT")
has_codex=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print("codex" in d.get("providers",{}))' "$PREDICT")
kind=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("providers",{}).get("codex",{}).get("windowKind"))' "$PREDICT")
if [ "$pred_status" = ok ] && [ "$has_codex" = True ] && [ "$has_daily" = False ] && [ "$has_unmeasured" = False ] && [ "$kind" = weekly ]; then
  ok "predict calibrates weekly codex and skips daily/unmeasured providers"
else
  fail "predict mixed unexpected: status=$pred_status codex=$has_codex daily=$has_daily unmeasured=$has_unmeasured kind=$kind"
fi

# Live quota-axi snapshot: only weekly kind is present and is calibrated.
quota-axi --json --provider codex > "$EVID/quota-axi-codex.json"
LIVE_PRED=$("$LEDGER" --state "$STATE" --sessions-root "$SESSIONS" predict --quota "$EVID/quota-axi-codex.json")
printf '%s\n' "$LIVE_PRED" > "$EVID/predict-live-quota.json"
live_kind=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("providers",{}).get("codex",{}).get("windowKind"))' "$LIVE_PRED")
live_consumed=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("providers",{}).get("codex",{}).get("percentConsumed"))' "$LIVE_PRED")
if [ "$live_kind" = weekly ]; then
  ok "predict against live quota-axi snapshot calibrates the Codex weekly window (consumed=$live_consumed)"
else
  fail "live predict windowKind=$live_kind"
fi

# --- 6. ceiling autohandle stop-and-report against isolated control ----------
CONTROL_COUNT="$LAB/control-count"
CONTROL_ARGS="$LAB/control-args"
cat > "$LAB/fm-control.sh" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$CONTROL_COUNT" ] || read -r count < "$CONTROL_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$CONTROL_COUNT"
printf '%s %s\n' "$1" "$2" >> "$CONTROL_ARGS"
SH
chmod +x "$LAB/fm-control.sh"
write_meta t-stop /work/alpha "s${EPOCH}.1.st" pi medium
mkdir -p "$STATE/procevent-inbox"
cat > "$STATE/procevent-inbox/spend-task-t-stop.1.result" <<'EOF'
spend: test
status: ceiling
task: t-stop
observed_tokens: 100099
ceiling_tokens: 5000
EOF
printf 'spend\n' > "$STATE/procevent-inbox/spend-task-t-stop.1.adapter"
AUTO=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_CONTROL="$LAB/fm-control.sh" \
  CONTROL_COUNT="$CONTROL_COUNT" CONTROL_ARGS="$CONTROL_ARGS" \
  "$SPEND" autohandle spend-task-t-stop 1 "$STATE/procevent-inbox/spend-task-t-stop.1.result" 2>&1) || true
printf '%s\n' "$AUTO" > "$EVID/autohandle-stop.txt"
{
  echo "control_count=$(cat "$CONTROL_COUNT" 2>/dev/null)"
  echo "control_args=$(cat "$CONTROL_ARGS" 2>/dev/null)"
  echo "--- spend-stop ---"
  cat "$STATE/t-stop.spend-stop" 2>/dev/null
  echo "--- status ---"
  cat "$STATE/t-stop.status" 2>/dev/null
} > "$EVID/autohandle-state.txt"
if [ "$(cat "$CONTROL_COUNT")" = 1 ] \
  && grep -qx 't-stop exit' "$CONTROL_ARGS" \
  && [ -f "$STATE/procevent-inbox/spend-task-t-stop.1.handled" ]; then
  ok "autohandle delivers control exit and acknowledges the ceiling capture"
else
  fail "autohandle did not stop: $(cat "$EVID/autohandle-state.txt")"
fi

# --- 7. provisioned orchestrated roles do not pin thinking --------------------
PROV_OUT=$(HOME="$LAB/prov-home" PI_CODING_AGENT_DIR="$PI_DIR" python3 "$PROVISION" 2>&1) || {
  fail "provisioner failed: $PROV_OUT"
  PROV_OUT=""
}
printf '%s\n' "$PROV_OUT" > "$EVID/provisioner.out"
python3 - "$PI_DIR" "$EVID/provisioned-roles.json" <<'PY'
import json, sys
from pathlib import Path
agents = Path(sys.argv[1]) / "agents"
out = {}
ok = True
roles = ["explorer", "researcher", "worker", "tester", "reviewer", "integrator"]
for role in roles:
    path = agents / f"fm-orchestrated-{role}.md"
    text = path.read_text()
    front = {}
    block = text.split("---\n")[1]
    for line in block.splitlines():
        if ": " in line:
            k, v = line.split(": ", 1)
            front[k] = v
    rec = {
        "path": str(path),
        "name": front.get("name"),
        "model": front.get("model"),
        "has_thinking": "thinking" in front,
        "thinking": front.get("thinking"),
        "session-mode": front.get("session-mode"),
    }
    out[role] = rec
    if rec["has_thinking"] or rec["name"] != f"fm-orchestrated-{role}" or rec["session-mode"] != "standalone":
        ok = False
Path(sys.argv[2]).write_text(json.dumps(out, indent=2) + "\n")
sys.exit(0 if ok else 1)
PY
if [ $? -eq 0 ]; then
  ok "provisioned six role definitions omit thinking (task effort is not pinned max)"
else
  fail "provisioned role definitions still pin thinking; see provisioned-roles.json"
fi

# --- summary ------------------------------------------------------------------
log "fails=$FAILS lab=$LAB"
if [ "$FAILS" -ne 0 ]; then
  exit 1
fi
exit 0
