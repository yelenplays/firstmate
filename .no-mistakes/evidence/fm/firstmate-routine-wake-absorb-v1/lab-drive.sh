#!/usr/bin/env bash
# Live drive of bin/fm-wake-triage.sh delivery-before-commit, against a
# disposable lab home minted by bin/fm-lab-home.sh. Run from the gate worktree.
# Usage: lab-drive.sh <worktree>
set -u
WT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux" "$LAB/bin"
holder=
watcher=
cleanup() {
  [ -z "$holder" ] || kill "$holder" 2>/dev/null
  [ -z "$watcher" ] || kill "$watcher" 2>/dev/null
  rm -rf "$LAB"
}
trap cleanup EXIT
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
export FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" FM_CREW_STATE_NO_FORGE=1 FM_SUPERVISION_MODEL=autoarm
S="$LAB/state"
TRIAGE="$WT/bin/fm-wake-triage.sh"

say() { printf '\n### %s\n' "$*"; }
show_state() {
  printf -- '- pending files: %s\n' "$(cd "$S" && ls .wake-triage.pending.* 2>/dev/null | wc -l | tr -d ' ')"
  printf -- '- .wake-triage.last: %s\n' "$([ -s "$S/.wake-triage.last" ] && echo present || echo absent)"
  printf -- '- queued wake rows: %s\n' "$(awk 'END{print NR+0}' "$S/.wake-queue" 2>/dev/null || echo 0)"
}
wake() { bash -c '. "$1"; fm_wake_append "$2" "$3" "$4"' _ "$WT/bin/fm-wake-lib.sh" "$@"; }
task() {  # <id>
  printf 'kind=ship\nwindow=fmlab:%s\n' "$1" > "$S/$1.meta"
  printf 'working: implementing\n' > "$S/$1.status"
}
# Deliver triage's stdout into a pipe whose reader is already gone: the
# realistic handoff failure (reader died / hook capture lost).
broken_pipe() {
  python3 -I -c '
import os, subprocess, sys
r, w = os.pipe(); os.close(r)
p = subprocess.run(sys.argv[1:], stdout=w, stderr=subprocess.DEVNULL, restore_signals=True)
os.close(w)
sys.exit(p.returncode if p.returncode >= 0 else 128 - p.returncode)
' "$@"
}
reset_state() {
  rm -rf "$S"; mkdir -p "$S"
}
seed_watcher() {
  sleep 600 >/dev/null 2>&1 &
  watcher=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$WT/bin/fm-wake-lib.sh" "$watcher")
  mkdir -p "$S/.watch.lock"
  printf '%s\n' "$watcher" > "$S/.watch.lock/pid"
  printf '%s\n' "$LAB" > "$S/.watch.lock/fm-home"
  printf '%s\n' 'watch_under_test' > "$S/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$S/.watch.lock/pid-identity"
  touch "$S/.last-watcher-beat"
}
cat > "$LAB/bin/crew-working" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: pane · busy\n'
SH
chmod +x "$LAB/bin/crew-working"

echo "lab home: $LAB"; ls -a "$LAB"

say "S1 --absorb, actionable wake with a one-shot unread note, handoff into a dead reader"
reset_state
task alpha; task beta
printf 'note: captain answer for beta - use option B\n' >> "$S/beta.status"
wake stale fmlab:alpha 'stale: fmlab:alpha'
rc=0; broken_pipe "$TRIAGE" --absorb || rc=$?
echo "triage rc=$rc (handoff failed)"; show_state
p=$(cd "$S" && ls .wake-triage.pending.* 2>/dev/null | head -1)
echo "- retained pending holds the one-shot note: $(grep -c 'option B' "$S/$p" 2>/dev/null)"
say "S1 retry: next triage replays it and does not absorb"
rc=0; out=$("$TRIAGE" --absorb 2>&1) || rc=$?
echo "triage rc=$rc"
printf '%s\n' "$out" | grep -E '^(WAKE TRIAGE|RECOVERED DRAIN OUTPUT|WAKE_ACKED|WAKE_ACK_REQUIRED|ACT NOW)|option B' | sed 's/^/  | /'
show_state

say "S2 manual triage (no --absorb), closed stdout"
reset_state
task gamma
wake stale fmlab:gamma 'stale: fmlab:gamma'
rc=0; "$TRIAGE" >&- 2>/dev/null || rc=$?
echo "triage rc=$rc"; show_state
rc=0; out=$("$TRIAGE" 2>&1) || rc=$?
echo "retry rc=$rc"
printf '%s\n' "$out" | grep -E '^(WAKE TRIAGE|RECOVERED DRAIN OUTPUT|WAKE_ACKED|WAKE_ACK_REQUIRED)' | sed 's/^/  | /'
show_state

say "S3 adversarial: recovered output + queue lock held (no WAKE_ACK_REQUIRED) + closed stdout"
reset_state
task delta; task eps
printf 'note: one-shot answer for eps\n' >> "$S/eps.status"
wake stale fmlab:delta 'stale: fmlab:delta'
rc=0; "$TRIAGE" --absorb >&- 2>/dev/null || rc=$?
echo "first triage rc=$rc"; show_state
rec=$(cd "$S" && ls .wake-triage.pending.* | head -1)
bash -c '. "$1"; fm_lock_acquire_wait "$2" || exit 1; echo ready > "$3"; exec sleep 120' _ "$WT/bin/fm-wake-lib.sh" "$S/.wake-queue.lock" "$LAB/ready" &
holder=$!
for _ in $(seq 1 100); do [ -s "$LAB/ready" ] && break; sleep 0.05; done
echo "queue lock holder ready: $(cat "$LAB/ready" 2>/dev/null)"
rc=0; FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 /bin/bash "$TRIAGE" --absorb >&- 2>/dev/null || rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; holder=
echo "contended replay rc=$rc (stock /bin/bash)"; show_state
echo "- original recovered file still present: $([ -f "$S/$rec" ] && echo yes || echo no)"
echo "- it still carries the one-shot note: $(grep -c 'one-shot answer for eps' "$S/$rec")"
for f in "$S"/.wake-triage.pending.*; do [ "$f" = "$S/$rec" ] && continue; echo "- new pending: $(grep -c 'WAKE DRAIN SKIPPED: queue lock remains held' "$f") skipped-drain line, $(grep -c WAKE_ACK_REQUIRED "$f") ack lines"; done
rc=0; out=$("$TRIAGE" --absorb 2>&1) || rc=$?
echo "uncontended retry rc=$rc"
printf '%s\n' "$out" | grep -E '^(RECOVERED DRAIN OUTPUT|WAKE_ACKED|WAKE_ACK_REQUIRED)|one-shot answer' | sed 's/^/  | /'
show_state

say "S4 --absorb all-routine wake (crew probe reports working), handoff into a dead reader"
reset_state
seed_watcher
task routine
wake stale fmlab:routine 'stale: fmlab:routine'
rc=0; FM_CREW_STATE_BIN="$LAB/bin/crew-working" broken_pipe "$TRIAGE" --absorb || rc=$?
echo "triage rc=$rc"; show_state
wake stale fmlab:routine 'stale: fmlab:routine'
rc=0; out=$(FM_CREW_STATE_BIN="$LAB/bin/crew-working" "$TRIAGE" --absorb 2>&1) || rc=$?
echo "next wake rc=$rc"
printf '%s\n' "$out" | grep -E '^(WAKE TRIAGE|RECOVERED DRAIN OUTPUT|WAKE_ACKED|WAKE_ACK_REQUIRED|ROUTINE)' | sed 's/^/  | /'
show_state

say "S5 --absorb all-routine wake delivered normally (happy path)"
rc=0; wake stale fmlab:routine 'stale: fmlab:routine'
out=$(FM_CREW_STATE_BIN="$LAB/bin/crew-working" "$TRIAGE" --absorb 2>&1) || rc=$?
echo "triage rc=$rc"
printf '%s\n' "$out" | grep -E '^(WAKE TRIAGE|RECOVERED DRAIN OUTPUT|WAKE_ACKED|WAKE_ACK_REQUIRED)' | sed 's/^/  | /'
show_state
echo; echo "teardown: removing $LAB"
