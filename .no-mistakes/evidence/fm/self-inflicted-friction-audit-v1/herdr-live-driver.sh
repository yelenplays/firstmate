#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/Users/yelen/.no-mistakes/evidence/01M5D7YE13PRVV1C15C2Y5MH6V
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_SESSION_START_STAGE_FILE HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID
LAB=$(mktemp -d "$ROOT/.phase-test-tmp/fm-lab.herdr.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME="$LAB" FM_HERDR_LAB_STATE_DIR="$LAB/lab-state" TMPDIR="$ROOT/.phase-test-tmp"
export LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh" LAB_ORIGINAL_PATH="$PATH"
SESSION=$("$LAB_HELPER" name friction)
export LAB_SESSION="$SESSION" LAB_AUDIT="$E/herdr-transport-calls.txt"
cleanup() {
 rc=$?
 "$LAB_HELPER" teardown "$SESSION" >> "$E/herdr-live-cleanup.txt" 2>&1 || rc=1
 rm -rf "$LAB"
 exit "$rc"
}
# Provision itself owns prepare; it must create and record a non-default session.
"$LAB_HELPER" provision "$SESSION" > "$E/herdr-live-provision.txt" 2>&1 || { rm -rf "$LAB"; exit 20; }
trap cleanup EXIT
lab() { env PATH="$LAB_ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
mkdir -p "$LAB/transport" "$LAB/project"
printf '# Live dead-target lab\n' > "$LAB/project/AGENTS.md"
# Pure forwarding transport: every product Herdr call still crosses the real lab helper.
cat > "$LAB/transport/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ] && [ "${args[$((n-1))]}" = "$LAB_SESSION" ]; then
 unset 'args[n-1]' 'args[n-2]'
fi
printf '%q ' "${args[@]}" >> "$LAB_AUDIT"; printf '\n' >> "$LAB_AUDIT"
exec env PATH="$LAB_ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" "${args[@]}"
SH
chmod +x "$LAB/transport/herdr"
CREATE=$(lab workspace create --cwd "$LAB/project" --label friction-check --no-focus)
printf '%s\n' "$CREATE" > "$E/herdr-live-workspace.json"
PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id')
# Viewer helper sizes its pty at 120x40 before the TUI starts and drains it.
"$LAB_HELPER" viewer start "$SESSION" > "$E/herdr-live-viewer.txt" 2>&1
CMD=$(printf 'env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME=%q pi --no-extensions --no-context-files --no-session' "$LAB")
lab pane run "$PANE" "$CMD" > "$E/herdr-pi-launch.txt"
# Accept trust only for this session, never persist user/global trust.
for i in $(seq 1 20); do
 view=$(lab pane read "$PANE" --lines 200 2>/dev/null || true)
 if [[ "$view" == *'Trust project folder?'* ]]; then
  lab pane send-keys "$PANE" down >/dev/null
  lab pane send-keys "$PANE" down >/dev/null
  lab pane send-keys "$PANE" enter >/dev/null
  break
 fi
 sleep 0.5
done
ready=0
for i in $(seq 1 30); do
 lab agent get "$PANE" > "$E/herdr-pi-start-state.json" 2>&1 || true
 if jq -e '.result.agent.agent == "pi" and (.result.agent.agent_status == "idle" or .result.agent.agent_status == "done")' "$E/herdr-pi-start-state.json" >/dev/null 2>&1; then ready=1; break; fi
 sleep 1
done
lab pane read "$PANE" --lines 200 > "$E/herdr-pi-start-pane.json" 2>&1 || true
[ "$ready" = 1 ] || { printf 'Pi did not become registered idle within 30s\n'; exit 21; }
lab pane run "$PANE" /quit > "$E/herdr-pi-quit.txt"
gone=0
for i in $(seq 1 15); do
 lab agent get "$PANE" > "$E/herdr-pi-exited-state.json" 2>&1 || true
 lab pane process-info --pane "$PANE" > "$E/herdr-pi-exited-process.json" 2>&1 || true
 if ! grep -q '"name":"pi"' "$E/herdr-pi-exited-process.json"; then gone=1; break; fi
 sleep 0.5
done
lab pane read "$PANE" --lines 200 > "$E/herdr-pi-exited-pane.txt"
[ "$gone" = 1 ] || { printf 'Pi did not exit to shell\n'; exit 22; }
export PATH="$LAB/transport:$LAB_ORIGINAL_PATH"
for id in probe-a probe-b probe-c; do
 printf 'backend=herdr\nwindow=%s:%s\nherdr_session=%s\nherdr_pane_id=%s\nkind=ship\nharness=pi\nworktree=%s\n' "$SESSION" "$PANE" "$SESSION" "$PANE" "$LAB/project" > "$LAB/state/$id.meta"
 printf 'working: verifying task\n' > "$LAB/state/$id.status"
done
# stderr is discarded exactly as the original failure report describes.
rc=0
bin/fm-send.sh probe-a 'Record this instruction for the recovered worker.' > "$E/dead-target-stdout.txt" 2>/dev/null || rc=$?
printf 'fm-send exit=%s\n' "$rc"
[ "$rc" = 0 ] && grep -q '^recorded-not-delivered:' "$E/dead-target-stdout.txt"
cp "$LAB/state/probe-a.inbox/001.msg" "$E/dead-target-inbox.txt"
lab pane read "$PANE" --lines 200 > "$E/dead-target-shell-pane.json"
# Record real producer writes and trace actual crew/hold processes (no simulated results).
bash -c '. "$1/bin/fm-wake-lib.sh"; for id in probe-a probe-b probe-c; do fm_wake_append stale "$2:$3" "stale: $2:$3"; done' _ "$ROOT" "$SESSION" "$PANE"
# Use signal rows instead: each names its own task even though the dead physical pane is shared.
bash -c '. "$1/bin/fm-wake-lib.sh"; for id in probe-a probe-b probe-c; do fm_wake_append signal "$id.status" "signal: changed"; done' _ "$ROOT"
export LIVE_ROOT="$ROOT" PROBE_TIMES="$E/triage-live-probe-times.jsonl"
cat > "$LAB/transport/crew" <<'SH'
#!/usr/bin/env bash
python3 -c 'import json,time,sys; print(json.dumps(dict(event="start",kind="crew",task=sys.argv[1],time=time.monotonic())))' "$1" >> "$PROBE_TIMES"
"$LIVE_ROOT/bin/fm-crew-state.sh" "$@"
rc=$?
python3 -c 'import json,time,sys; print(json.dumps(dict(event="end",kind="crew",task=sys.argv[1],time=time.monotonic())))' "$1" >> "$PROBE_TIMES"
exit "$rc"
SH
cat > "$LAB/transport/hold" <<'SH'
#!/usr/bin/env bash
python3 -c 'import json,time,sys; print(json.dumps(dict(event="start",kind="hold",task=sys.argv[1],time=time.monotonic())))' "$2" >> "$PROBE_TIMES"
"$LIVE_ROOT/bin/fm-captain-hold.sh" "$@"
rc=$?
python3 -c 'import json,time,sys; print(json.dumps(dict(event="end",kind="hold",task=sys.argv[1],time=time.monotonic())))' "$2" >> "$PROBE_TIMES"
exit "$rc"
SH
chmod +x "$LAB/transport/crew" "$LAB/transport/hold"
FM_CREW_STATE_BIN="$LAB/transport/crew" FM_CAPTAIN_HOLD_BIN="$LAB/transport/hold" bin/fm-wake-triage.sh > "$E/triage-live-output.txt" 2> "$E/triage-live-stderr.txt"
python3 - "$PROBE_TIMES" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
crew=[r for r in rows if r['kind']=='crew']
starts=[r['time'] for r in crew if r['event']=='start']; ends=[r['time'] for r in crew if r['event']=='end']
assert len(starts)==3 and len(ends)==3,rows
assert max(starts)<min(ends),rows
print('All three real crew-state processes started before the first completed: PASS')
PY
grep -q '3 act now' "$E/triage-live-output.txt"
grep -q 'WAKE_ACK_REQUIRED:' "$E/triage-live-output.txt"
[ -s "$LAB/state/.wake-queue" ]
printf 'Dead endpoints remain ACT NOW; durable queue retained; printed acknowledgement required: PASS\n'
