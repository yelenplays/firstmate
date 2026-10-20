#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/Users/yelen/.no-mistakes/evidence/01M5D7YE13PRVV1C15C2Y5MH6V
LAB="$ROOT/.live-validation/home"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
mkdir -p "$ROOT/.live-validation"
"$ROOT/bin/fm-lab-home.sh" create "$LAB"
trap 'rm -rf "$ROOT/.live-validation"' EXIT
export FM_HOME="$LAB" FM_SESSION_START_TIMEOUT=110
printf 'ny-trenches\n' > "$LAB/config/theme"
touch "$LAB/config/supervision-host"
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
# Deliberately non-credential opt-in: only local register/pending operations run.
printf 'FMX_PAIRING_TOKEN=disposable-validation-token\n' > "$LAB/.env"
long=$(printf 'measured %s, ' $(seq 1 60))
for i in $(seq 1 13); do
  printf 'kind=ship\n' > "$LAB/state/budget-task-$i.meta"
  printf 'working: step %s %s\n' "$i" "$long" > "$LAB/state/budget-task-$i.status"
done
for i in $(seq 1 11); do
  printf 'needs-decision [key=budget-key-%s]: decision %s %s\n' "$i" "$i" "$long" >> "$LAB/state/budget-task-$((i % 3 + 1)).status"
done
for i in 1 2 3 4 5; do
  jq -nc --arg t "captain turn $i $long" --arg u "budget-captain-$i" '{type:"user",origin:"human",uuid:$u,timestamp:"2026-09-22T22:30:00Z",message:{content:$t}}'
  jq -nc --arg t "reply $i $long" --arg u "budget-firstmate-$i" '{type:"assistant",uuid:$u,timestamp:"2026-09-22T22:31:00Z",message:{content:$t,stop_reason:"end_turn"}}'
done > "$LAB/transcript.jsonl"
"$ROOT/bin/fm-history.sh" capture --transcript "$LAB/transcript.jsonl"
for i in 1 2 3 4 5; do
  jq -n --arg r "req-budget-$i" '{request_id:$r,platform:"discord",context_binding:{version:"ctx1",value:("ctx1_"+$r)},public_safe_summary:"Verify compact recovery",received_at:"2026-10-20T10:00:00Z",followup_expires_at:"2099-10-27T10:00:00Z",reservation_expires_at:"2099-10-27T10:00:00Z"}' > "$LAB/request.json"
  jq -n '{type:"report-ready",project:"firstmate",required_deliverables:["report_path"],completion_policy:"all-required"}' > "$LAB/expected.json"
  jq -n --arg w "budget-task-$i" '{relation_id:"rel-code",work_ref:{home_id:"main",task_id:$w},role:"fulfills",required:true,generation:1}' > "$LAB/relation.json"
  (cd "$LAB"; tasks-axi public-followup add "pf-budget-$i" --request-context-file "$LAB/request.json" --purpose promised-final --expected-final-file "$LAB/expected.json" --expires-at 2099-10-27T10:00:00Z; tasks-axi public-followup bind-work "pf-budget-$i" --relation-file "$LAB/relation.json")
  "$ROOT/bin/fm-public-followup.sh" register "pf-budget-$i" --relation rel-code --work-home main --work-id "budget-task-$i" --generation 1
done
. "$ROOT/bin/fm-wake-lib.sh"
for i in 1 2 3; do fm_wake_append signal "budget-task-$i.status" "signal: OVERSIZED_PAYLOAD_MARKER $long $long $long"; done
"$ROOT/bin/fm-session-start.sh" --reemit --source compact > "$E/compact-live.txt" 2> "$E/compact-live.stderr"
cp "$LAB"/state/reemit-detail/*.txt "$E/compact-uncut.txt"
"$ROOT/bin/fm-public-followup.sh" pending > "$E/commitments-live.txt"
python3 - "$E" <<'PY'
import sys,pathlib,re
p=pathlib.Path(sys.argv[1]); b=(p/'compact-live.txt').read_bytes(); s=b.decode(); d=(p/'compact-uncut.txt').read_text()
print('real compact output bytes:',len(b))
assert len(b)<9000, len(b)
assert '\n●  STARTUP TRUNCATED' not in s
assert s.index('Condensed operating rules') < s.index('WAKE QUEUE')
assert 'never kill the watcher' in s
assert 'WAKE_ACK_REQUIRED acknowledgement' in s
assert 'extension already owns watcher continuity' in s
assert len(re.findall(r'^WAKE_ACK_REQUIRED: .*--ack-through [0-9]+ --recovery-generation [A-Za-z0-9._-]+$',s,re.M)) == 1
assert 'OVERSIZED_PAYLOAD_MARKER' in d and 'budget-key-11' in d
assert 'Public commitments' in s
pending=(p/'commitments-live.txt').read_text()
for i in range(1,6): assert f'unresolved pf-budget-{i} state=pending-work' in pending
print('PASS: condensed rules first, whole ack, retained wake/decision detail, five commitments reachable')
PY
ack=$(python3 - "$E/compact-live.txt" <<'PY'
import sys
for s in open(sys.argv[1]):
    if s.startswith('WAKE_ACK_REQUIRED: after handling completes run '): print(s.split(' run ',1)[1].strip())
PY
)
bash -c "$ack" > "$E/compact-ack.txt" 2>&1
printf 'PASS: printed acknowledgement executed\n'
# Multilingual oversized rows must remain byte bounded and valid UTF-8.
for i in 1 2 3; do fm_wake_append signal "budget-task-$i.status" "signal: $(printf '請選擇方案 %s，測試修復狀態。' $(seq 1 60))"; done
"$ROOT/bin/fm-session-start.sh" --reemit --source compact > "$E/compact-multilingual-live.txt" 2> "$E/compact-multilingual-live.stderr"
python3 - "$E/compact-multilingual-live.txt" <<'PY'
import sys
b=open(sys.argv[1],'rb').read(); b.decode('utf-8',errors='strict'); print('multilingual bytes:',len(b)); assert len(b)<9000
PY
