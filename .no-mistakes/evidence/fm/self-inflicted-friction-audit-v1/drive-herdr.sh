#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/Users/yelen/.no-mistakes/evidence/01M5D7YE13PRVV1C15C2Y5MH6V
ORIGINAL_PATH=$PATH
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
LAB="$ROOT/.live-herdr"
"$ROOT/bin/fm-lab-home.sh" create "$LAB"
export FM_HOME="$LAB" FM_HERDR_LAB_STATE_DIR="$LAB/lab-state"
SESSION=$(bin/fm-herdr-lab.sh name friction-check)
export ROOT ORIGINAL_PATH SESSION
cleanup() {
  rc=$?
  if env PATH="$ORIGINAL_PATH" "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION" >> "$E/herdr-cleanup.txt" 2>&1; then
    printf 'PASS: %s removed; default fleet tripwire unchanged\n' "$SESSION" >> "$E/herdr-cleanup.txt"
    rm -rf "$LAB"
  else
    printf 'Cleanup refused: retain original tripwire at %s\n' "$FM_HERDR_LAB_STATE_DIR" >> "$E/herdr-cleanup.txt"
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
bin/fm-herdr-lab.sh provision "$SESSION"
lab() { env PATH="$ORIGINAL_PATH" "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" "$@"; }
mkdir -p "$LAB/transport" "$LAB/agent"
cat > "$LAB/transport/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[n-2]}" = --session ] && [ "${args[n-1]}" = "$SESSION" ]; then
  unset 'args[n-1]' 'args[n-2]'
fi
for arg in "${args[@]}"; do case "$arg" in --session|--session=*) exit 9;; esac; done
exec env PATH="$ORIGINAL_PATH" "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" "${args[@]}"
SH
chmod +x "$LAB/transport/herdr"
# Real pi, empty disposable agent state; no inference or authentication claim.
cat > "$LAB/trust.ts" <<'TS'
export default function (pi: any) { pi.on('project_trust', () => ({ trusted: 'yes', remember: false })); }
TS
CREATE=$(lab workspace create --cwd "$ROOT" --label friction-check --no-focus)
printf '%s\n' "$CREATE" > "$E/herdr-created.json"
PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id')
CMD=$(printf 'env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME=%q PI_CODING_AGENT_DIR=%q pi -e %q --no-context-files --no-session' "$LAB" "$LAB/agent" "$LAB/trust.ts")
lab pane run "$PANE" "$CMD" > "$E/herdr-launch.json"
ready=0
for i in $(seq 1 30); do
  lab agent get "$PANE" > "$E/herdr-agent-before.json" 2>&1 || true
  state=$(jq -r '.result.agent.agent_status // empty' "$E/herdr-agent-before.json")
  case "$state" in idle|blocked|done) ready=1; break;; esac
  sleep 0.5
done
lab pane read "$PANE" > "$E/herdr-pane-before.txt"
[ "$ready" = 1 ] || { echo 'real pi did not register'; exit 1; }
lab pane run "$PANE" /quit > "$E/herdr-quit.json"
gone=0
for i in $(seq 1 30); do
  lab agent get "$PANE" > "$E/herdr-agent-after.json" 2>&1 || true
  code=$(jq -r '.error.code // empty' "$E/herdr-agent-after.json")
  [ "$code" != agent_not_found ] || { gone=1; break; }
  sleep 0.5
done
[ "$gone" = 1 ] || { echo 'real pi did not exit'; exit 1; }
export PATH="$LAB/transport:$ORIGINAL_PATH"
git init -q "$LAB/project"
printf 'kind=ship\nharness=pi\nbackend=herdr\nworktree=%s\nwindow=%s:%s\nterminal=%s:%s\n' "$LAB/project" "$SESSION" "$PANE" "$SESSION" "$PANE" > "$LAB/state/dead-task.meta"
printf 'working: before agent exit\n' > "$LAB/state/dead-task.status"
"$ROOT/bin/fm-send.sh" dead-task 'Verify the durable record survives an exited target' > "$E/dead-send.stdout" 2> "$E/dead-send.stderr"
printf 'fm-send exit=0\n'
grep '^recorded-not-delivered:' "$E/dead-send.stdout"
cp "$LAB"/state/dead-task.inbox/*.msg "$E/" # durable record is public scenario evidence
lab pane read "$PANE" > "$E/herdr-pane-after.txt"
# Trace real production probes, without changing their inputs, results or timing.
cat > "$LAB/transport/trace-probe" <<'PY'
#!/usr/bin/env python3
import os,sys,time,json,subprocess
kind=os.path.basename(sys.argv[0]).split('-')[0]
real=os.path.join(os.environ['ROOT'],'bin','fm-crew-state.sh' if kind=='crew' else 'fm-captain-hold.sh')
def log(event):
    fd=os.open(os.environ['PROBE_LOG'],os.O_WRONLY|os.O_APPEND|os.O_CREAT,0o600)
    os.write(fd,(json.dumps({'kind':kind,'args':sys.argv[1:],'event':event,'time':time.monotonic_ns(),'pid':os.getpid()})+'\n').encode()); os.close(fd)
log('start')
r=subprocess.run([real,*sys.argv[1:]])
log('end')
sys.exit(r.returncode)
PY
chmod +x "$LAB/transport/trace-probe"
ln -s trace-probe "$LAB/transport/crew-probe"
ln -s trace-probe "$LAB/transport/hold-probe"
export FM_CREW_STATE_BIN="$LAB/transport/crew-probe" FM_CAPTAIN_HOLD_BIN="$LAB/transport/hold-probe" PROBE_LOG="$E/real-probes.jsonl"
: > "$PROBE_LOG"
. "$ROOT/bin/fm-wake-lib.sh"
for i in 1 2 3; do
  cp "$LAB/state/dead-task.meta" "$LAB/state/probe-$i.meta"
  printf 'working: actual probe validation\n' > "$LAB/state/probe-$i.status"
  fm_wake_append signal "probe-$i.status" "signal: probe-$i.status"
done
"$ROOT/bin/fm-wake-triage.sh" > "$E/triage-live.txt" 2> "$E/triage-live.stderr"
python3 - "$E" <<'PY'
import sys,pathlib,json
p=pathlib.Path(sys.argv[1]); rows=[json.loads(s) for s in (p/'real-probes.jsonl').read_text().splitlines()]
assert len(rows)==12,rows
crew=sorted([r for r in rows if r['kind']=='crew'],key=lambda r:r['time'])
active=set(); peak=0
for r in crew:
    if r['event']=='start': active.add(r['pid']); peak=max(peak,len(active))
    else: active.remove(r['pid'])
assert peak>=2,(peak,rows)
s=(p/'triage-live.txt').read_text(); assert 'ACT NOW:' in s and 'C3 crew not working' in s and 'WAKE_ACKED:' not in s
print(f'PASS: six real production probes completed; concurrent crew probes peaked at {peak}; exited agents stayed ACT NOW, no acknowledgement')
PY
[ -s "$LAB/state/.wake-queue" ]
printf 'PASS: durable wake queue remains nonempty\n'
