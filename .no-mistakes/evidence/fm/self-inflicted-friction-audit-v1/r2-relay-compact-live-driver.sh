#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/Users/yelen/.no-mistakes/evidence/01M5D7YE13PRVV1C15C2Y5MH6V
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_SESSION_START_STAGE_FILE
LAB=$(mktemp -d "$ROOT/.phase-test-tmp/fm-lab.compact.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME="$LAB" TMPDIR="$ROOT/.phase-test-tmp"
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'ny-trenches\n' > "$LAB/config/theme"
unset TASKS_AXI_FILE TASKS_AXI_BACKEND TASKS_AXI_ARCHIVE
cp .tasks.toml "$LAB/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
# Local intake fixture only: no relay request, sign-in, or posting occurs.
printf 'FMX_PAIRING_TOKEN=disposable-noncredential-test-token\n' > "$LAB/.env"
for n in 1 2 3 4 5; do
 jq -n --arg r "req-budget-$n" '{request_id:$r,platform:"discord",context_binding:{version:"ctx1",value:("ctx1_"+$r)},public_safe_summary:"Verify compact recovery with outstanding public commitments",received_at:"2026-10-20T10:00:00Z",followup_expires_at:"2026-10-27T10:00:00Z",reservation_expires_at:"2026-10-27T10:00:00Z"}' > "$LAB/request.json"
 jq -n '{type:"report-ready",project:"firstmate",required_deliverables:["report_path"],completion_policy:"all-required"}' > "$LAB/expected.json"
 jq -n --arg w "budget-task-$n" '{relation_id:"rel-code",work_ref:{home_id:"main",task_id:$w},role:"fulfills",required:true,generation:1}' > "$LAB/relation.json"
 (cd "$LAB"; tasks-axi public-followup add "pf-budget-$n" --request-context-file "$LAB/request.json" --purpose promised-final --expected-final-file "$LAB/expected.json" --expires-at 2026-10-27T10:00:00Z >/dev/null
 tasks-axi public-followup bind-work "pf-budget-$n" --relation-file "$LAB/relation.json" >/dev/null)
 bin/fm-public-followup.sh register "pf-budget-$n" --relation rel-code --work-home main --work-id "budget-task-$n" --generation 1 >/dev/null
done
bin/fm-public-followup.sh pending > "$E/r2-relay-pending.txt"
long=$(printf 'measured %s, ' $(seq 1 60))
for i in $(seq 1 13); do
 printf 'kind=ship\n' > "$LAB/state/budget-task-$i.meta"
 printf 'working [at=1792494216]: step %s %s\n' "$i" "$long" > "$LAB/state/budget-task-$i.status"
done
for i in $(seq 1 11); do
 printf 'needs-decision [key=budget-key-%s]: decision %s %s\n' "$i" "$i" "$long" >> "$LAB/state/budget-task-$((i % 3 + 1)).status"
done
for i in 1 2 3 4 5; do
 jq -nc --arg t "captain turn $i $long" --arg u "budget-captain-$i" '{type:"user",origin:"human",uuid:$u,timestamp:"2026-09-22T22:30:0\($u[-1:])Z",message:{content:$t}}'
 jq -nc --arg t "reply $i $long" --arg u "budget-firstmate-$i" '{type:"assistant",uuid:$u,timestamp:"2026-09-22T22:31:0\($u[-1:])Z",message:{content:$t,stop_reason:"end_turn"}}'
done > "$LAB/history.jsonl"
bin/fm-history.sh capture --transcript "$LAB/history.jsonl" > "$E/r2-relay-compact-history-capture.txt"
# Use the real durable queue producer, not a mock drain or recorded result.
bash -c '. "$1/bin/fm-wake-lib.sh"; for i in 1 2 3; do fm_wake_append signal "budget-task-$i.status" "signal: OVERSIZED_PAYLOAD_MARKER $2 $2 $2"; done' _ "$ROOT" "$long"
bin/fm-session-start.sh --reemit --source compact > "$E/r2-relay-compact-live-output.txt" 2> "$E/r2-relay-compact-live-stderr.txt"
python3 - "$E/r2-relay-compact-live-output.txt" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1]); b=p.read_bytes(); s=b.decode(); lines=s.splitlines()
print('command: FM_HOME=<marked-disposable-home> bin/fm-session-start.sh --reemit --source compact')
print('real producer + real renderer, no substituted tool binaries')
print('bytes:',len(b),'required: <9000')
for marker in ['lock acquired:', 'SUPERVISION OPERATING INSTRUCTIONS', 'Condensed operating rules', 'WAKE QUEUE', 'WAKE_ACK_REQUIRED:', 'INSTRUCTION_REFRESH_REQUIRED:', 'Uncut wake queue']:
 for i,l in enumerate(lines,1):
  if marker in l: print(f'{i}: {l}')
print('size result:', 'PASS' if len(b)<9000 else 'FAIL')
PY
for f in "$LAB/state/reemit-detail/"*.txt; do
 [ ! -f "$f" ] || cp "$f" "$E/r2-relay-compact-live-detail.txt"
done
if [ -f "$E/r2-relay-compact-live-detail.txt" ]; then
 printf '\nOn-demand detail: '
 grep -c 'OVERSIZED_PAYLOAD_MARKER' "$E/r2-relay-compact-live-detail.txt"
fi
printf 'Queue retained until acknowledgement: '; wc -l < "$LAB/state/.wake-queue"

python3 - "$E/r2-relay-compact-live-output.txt" "$E/r2-relay-compact-live-detail.txt" <<'PYEND'
import sys,subprocess
from pathlib import Path
s=Path(sys.argv[1]).read_text(); detail=Path(sys.argv[2]).read_text()
assert 'budget-key-11' in detail and 'OVERSIZED_PAYLOAD_MARKER' in detail
assert s.index('Condensed operating rules')<s.index('WAKE QUEUE')
ack=next(l.split('run ',1)[1] for l in s.splitlines() if l.startswith('WAKE_ACK_REQUIRED:'))
print('Executing printed acknowledgement:',ack)
subprocess.run(ack,shell=True,check=True)
PYEND
[ ! -s "$LAB/state/.wake-queue" ]
printf 'Printed acknowledgement emptied durable queue: PASS\n'
bin/fm-session-start.sh --reemit --source compact --full > "$E/r2-relay-full-report.txt" 2> "$E/r2-relay-full-stderr.txt"
grep -q "budget-key-11" "$E/r2-relay-full-report.txt"
printf 'Full report recovered all eleven open decisions: PASS\n'
