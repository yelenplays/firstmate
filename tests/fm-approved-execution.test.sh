#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/environment.sh"
fm_test_sanitize_environment
# End-user stall: approval recorded, finished scout, repeated notification acks,
# but no implementation owner. Fixtures contain no private incident material.
set -eu
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# Bare assertions, pipelines, helper calls and waits must identify their failure
# before the shared EXIT trap removes the fixture evidence.
set -E
trap 'printf "FAIL: %s:%s: %s (exit %s)\n" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" "$?" >&2' ERR
command -v tasks-axi >/dev/null || { echo 'skip: tasks-axi not found'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-approved-execution)
home=$(make_case approved-scout)
mkdir -p "$home/data" "$home/config"
export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state"
export FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh"
export FM_BACKEND=tmux FM_EXECUTION_SCAN_INTERVAL=0
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
EXEC="$ROOT/bin/fm-task-execution.sh"
TASKS=$(command -v tasks-axi)
tasks() { "$TASKS" "$@" --file "$home/data/backlog.md"; }
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
tasks-axi add approved-scout 'Implement accepted feature after research' --kind scout --start --file "$home/data/backlog.md" --body 'Implementation explicitly approved; research complete.' >/dev/null
printf 'kind=scout\nwindow=fake\nworktree=%s\n' "$home" > "$home/state/approved-scout.meta"
printf 'done: research complete; implementation required\n' > "$home/state/approved-scout.status"
# Explicit semantic intake, never chat or status parsing.
"$EXEC" approve approved-scout --basis captain-approved
for _round in 1 2; do
  append_wake "$home/state" signal approved-scout.status "$home/state/approved-scout.status"
  "$ROOT/bin/fm-wake-drain.sh" > "$home/drain" 2> "$home/err"
  ack_drain_err "$home/state" "$home/err"
done
"$ROOT/bin/fm-wake-drain.sh" > "$home/drain" 2> "$home/err"
if ! grep -q 'approved-scout.*scout is not a confirmed active implementation owner' "$home/drain"; then
  printf 'FAIL: approved scout did not retain its firstmate-owned next action\n' >&2
  exit 1
fi
printf 'PASS: approved scout cannot disappear after acknowledgements\n'
"$EXEC" show approved-scout | grep -q 'verify status, then promote or dispatch' \
  || fail 'finished approved scout did not report an actionable status check'

# Independent approvals all stay actionable, without an arbitrary concurrency cap.
for id in independent-a independent-b independent-c; do
  tasks add "$id" 'Independent approved change' --kind ship >/dev/null
  "$EXEC" approve "$id" --basis accepted-intent
  "$EXEC" show "$id" | grep -q 'firstmate.*implementation owner missing'
done
tasks add parked-project 'Unrelated parked project' --kind ship >/dev/null
if "$EXEC" scan | grep -q parked-project; then fail 'unapproved parked work was enrolled'; fi
# Legacy prose (including a consent-sounding note) cannot enroll unrelated work.
tasks update parked-project --body 'Approved! Ship now! done: implementation' >/dev/null
if "$EXEC" scan | grep -q parked-project; then fail 'prose fabricated implementation approval'; fi

# Holds and true dependencies retain their actual owner; no dispatch is performed.
tasks hold independent-a --reason 'Captain decision pending' --kind captain >/dev/null
"$EXEC" show independent-a | grep -q 'captain.*answer-recorded-hold'
tasks hold independent-b --reason 'Provider maintenance' --kind external --until 2099-01-01 >/dev/null
"$EXEC" show independent-b | grep -q 'external.*recheck-at-2099-01-01'
tasks block independent-c --by parked-project >/dev/null
"$EXEC" show independent-c | grep -q 'dependency.*wait-for-parked-project'
tasks 'done' parked-project >/dev/null
"$EXEC" show independent-c | grep -q 'firstmate.*implementation owner missing'

# Typed approval release arms before unhold, while a plain release does not.
tasks add release-work 'Resume implementation' --kind scout >/dev/null
tasks hold release-work --reason 'Implementation consent' --kind captain >/dev/null
printf 'Proceed within this task intent.\n' > "$home/answer"
(cd "$home" && "$ROOT/bin/fm-captain-hold.sh" answer release-work --decision-file "$home/answer" --release --execute) >/dev/null
"$EXEC" show release-work | grep -q 'implementation owner missing'
tasks add negative-answer 'Separate knowledge-only decision' --kind scout >/dev/null
tasks hold negative-answer --reason 'Read consent' --kind captain >/dev/null
(cd "$home" && "$ROOT/bin/fm-captain-hold.sh" answer negative-answer --decision-file "$home/answer" --release) >/dev/null
if "$EXEC" scan | grep -q negative-answer; then fail 'plain release fabricated implementation consent'; fi

# A genuinely active bounded scout can finish the authorized research, but a
# finished report, a stale working line, or a promotion alone is not implementation.
FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' "$EXEC" show approved-scout | grep -q 'worker.*finish-authorized-research'
printf 'working: stale acknowledgement\n' >> "$home/state/approved-scout.status"
"$EXEC" show approved-scout | grep -q 'verify status, then promote or dispatch'
ln -s "$ROOT/bin" "$home/bin"
mkdir -p "$home/data/approved-scout"
cat > "$home/data/approved-scout/brief.md" <<'EOF'
# Task
## Captain's intent
Implement the accepted feature after research.

## Firstmate spec
Promote this scout into a ship task under the recorded delivery contract.
EOF
FM_ROOT_OVERRIDE="$home" PATH="$home/fakebin:$PATH" "$ROOT/bin/fm-promote.sh" approved-scout --mode no-mistakes --yolo on > "$home/promotion"
"$EXEC" show approved-scout | grep -q 'implementation owner unconfirmed'

# Real isolated repository + generation-bound worker acknowledgement. Neither
# a shell's existence, a launch seed, wrong cwd, nor an old token is a receipt.
mkdir -p "$home/project" "$home/worker"
fm_git_identity fmtest fmtest@example.invalid
git -C "$home/worker" init -q
printf 'kind=ship\nwindow=fake\nworktree=%s\nproject=%s\nspawn_gen=s1\nharness=pi\nmode=no-mistakes\n' "$home/worker" "$home/project" > "$home/state/approved-scout.meta"
token=$("$EXEC" attempt approved-scout)
"$EXEC" show approved-scout | grep -q 'owner unconfirmed'
if "$EXEC" started approved-scout "$token" 2>/dev/null; then fail 'firstmate cwd accepted as worker receipt'; fi
(cd "$home/worker" && "$EXEC" started approved-scout "$token")
"$EXEC" confirmed approved-scout
FM_FAKE_CREW_STATE='state: working · source: status-log · old note' "$EXEC" show approved-scout | grep -q 'firstmate.*verify-idle'
FM_FAKE_CREW_STATE='state: unknown · source: none · endpoint dead' "$EXEC" show approved-scout | grep -q 'firstmate.*recover-or-escalate'
FM_FAKE_CREW_STATE='state: working · source: run-step · running review' "$EXEC" show approved-scout | grep -q 'worker.*continue-validation'
FM_FAKE_CREW_STATE='state: done · source: status-log · implementation committed' "$EXEC" show approved-scout | grep -q 'firstmate.*continue-selected-validation'
printf 'pr=https://github.com/example/fixture/pull/1\n' >> "$home/state/approved-scout.meta"
FM_FAKE_CREW_STATE='state: done · source: run-step · checks passed' "$EXEC" show approved-scout | grep -q 'firstmate.*verify-landing'
FM_FAKE_CREW_STATE='state: parked · source: run-step · decision needed' "$EXEC" show approved-scout | grep -q 'firstmate.*configured-authority'
FM_FAKE_CREW_STATE='state: paused · source: status-log · external wait' "$EXEC" show approved-scout | grep -q 'firstmate.*concrete-external-dependency'
new_token=$("$EXEC" attempt approved-scout)
if (cd "$home/worker" && "$EXEC" started approved-scout "$token") 2>/dev/null; then fail 'old receipt survived new handoff'; fi
if "$EXEC" confirmed approved-scout; then fail 'unconfirmed relaunch counted as processing'; fi
(cd "$home/worker" && "$EXEC" started approved-scout "$new_token")
# Receipt durability after a new process, and rejection after a changed incarnation.
"$EXEC" confirmed approved-scout
printf 'spawn_gen=s2\n' >> "$home/state/approved-scout.meta"
if "$EXEC" confirmed approved-scout; then fail 'old incarnation receipt accepted'; fi
if (cd "$home/worker" && "$EXEC" started approved-scout "$new_token") 2>/dev/null; then fail 'old handoff token rebound to a newer incarnation'; fi

# A backlog completion, including a finished scout, is not landing evidence.
tasks 'done' independent-b >/dev/null
"$EXEC" show independent-b | grep -q 'firstmate.*reconcile-recorded-completion'
# A missing backlog item remains a reconciliation issue, not a cleanup trigger.
tasks rm independent-c >/dev/null
"$EXEC" show independent-c | grep -q 'reconcile-missing-backlog-item'
[ -e "$home/state/independent-c.execution" ] || fail 'scan removed an orphaned approval automatically'

# The real watcher reuses its queue; acknowledgment cannot retire the obligation.
# No live backend lifecycle or external service is used by this fixture.
PATH="$home/fakebin:$PATH" FM_EXECUTION_REMIND=0 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 "$ROOT/bin/fm-watch.sh" > "$home/watch" 2> "$home/watch.err" &
pid=$!
wait_for_exit "$pid" 150 || { kill "$pid" 2>/dev/null || true; fail "watcher failed to surface approved work: stdout=$(<"$home/watch"); stderr=$(<"$home/watch.err")"; }
wait "$pid"
grep -q 'unfinished-execution' "$home/watch" \
  || fail "watcher surfaced a different notification: stdout=$(<"$home/watch"); stderr=$(<"$home/watch.err")"
"$ROOT/bin/fm-wake-drain.sh" > "$home/drain" 2> "$home/err"
ack_drain_err "$home/state" "$home/err"
# Advancing the old reminder clock must not resurface an unchanged action.
# Across a fresh process and queue acknowledgement, obligations remain readable.
FM_EXECUTION_REMIND=0 "$EXEC" notify > "$home/dedup"
[ ! -s "$home/dedup" ] || fail 'unchanged execution re-fired after acknowledgement'
[ -f "$home/state/approved-scout.execution" ] || fail 'dedup retired the obligation'
# Restart the REAL watcher after the acknowledged unfinished-execution wake.
# It must keep supervising instead of delivering rearm-resurface or another
# execution wake merely because time passed. A changed incarnation wakes once.
for status in "$home/state"/*.status; do
  prime_status_seen "$home/state" "$status"
done
scan_before=$(<"$home/state/.execution-scan-at")
PATH="$home/fakebin:$PATH" FM_EXECUTION_REMIND=0 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 "$ROOT/bin/fm-watch.sh" > "$home/watch-repeat" 2> "$home/watch-repeat.err" &
pid=$!
observed=0
for _poll in $(seq 1 200); do
  scan_after=$(<"$home/state/.execution-scan-at")
  if [ "$scan_after" -ge "$((scan_before + 2))" ]; then observed=1; break; fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
done
if [ "$observed" != 1 ] || ! kill -0 "$pid" 2>/dev/null || grep -q 'check:' "$home/watch-repeat"; then
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  fail "unchanged restart resurfaced or stopped supervising: stdout=$(<"$home/watch-repeat"); stderr=$(<"$home/watch-repeat.err")"
fi
printf 'spawn_gen=s3\n' >> "$home/state/approved-scout.meta"
wait_for_exit "$pid" 150 || { kill "$pid" 2>/dev/null || true; fail "changed execution did not wake restarted watcher: stdout=$(<"$home/watch-repeat"); stderr=$(<"$home/watch-repeat.err")"; }
wait "$pid"
grep -q 'unfinished-execution' "$home/watch-repeat" \
  || fail "incarnation change did not wake execution: stdout=$(<"$home/watch-repeat"); stderr=$(<"$home/watch-repeat.err")"
"$ROOT/bin/fm-wake-drain.sh" > "$home/drain" 2> "$home/err"
ack_drain_err "$home/state" "$home/err"
# A new event with the SAME owner/action is nevertheless a real change.
printf 'blocked [key=new-block]: a new impediment\n' >> "$home/state/approved-scout.status"
"$EXEC" notify > "$home/notifications"
grep -q approved-scout "$home/notifications" || fail 'new status did not notify'
"$ROOT/bin/fm-wake-drain.sh" > "$home/drain" 2> "$home/err"
ack_drain_err "$home/state" "$home/err"
"$EXEC" notify > "$home/dedup"
[ ! -s "$home/dedup" ] || fail 'changed execution notified more than once'
printf 'resolved [key=new-block]: impediment cleared\n' >> "$home/state/approved-scout.status"
"$EXEC" notify > "$home/notifications"
grep -q approved-scout "$home/notifications" || fail 'decision closure did not notify'
"$ROOT/bin/fm-wake-drain.sh" > "$home/drain" 2> "$home/err"
grep -q 'approved-scout.*owner unconfirmed' "$home/drain"
ack_drain_err "$home/state" "$home/err"
# Changes in owner are recorded even while no firstmate wake is due.
tasks hold approved-scout --reason 'Captain selection' --kind captain >/dev/null
"$EXEC" notify > "$home/notifications"
[ ! -s "$home/notifications" ] || fail 'captain-owned hold raised an execution wake'
tasks unhold approved-scout >/dev/null
"$EXEC" notify > "$home/notifications"
grep -q approved-scout "$home/notifications" || fail 'owner returning from captain did not notify'
"$ROOT/bin/fm-wake-drain.sh" > "$home/drain" 2> "$home/err"
ack_drain_err "$home/state" "$home/err"
# A reconciled blocked/done state change with identical next action also wakes.
printf 'spawn_gen=s1\n' >> "$home/state/approved-scout.meta"
FM_FAKE_CREW_STATE='state: parked · source: run-step · decision needed' "$EXEC" notify > "$home/notifications"
grep -q approved-scout "$home/notifications"
"$ROOT/bin/fm-wake-drain.sh" > "$home/drain" 2> "$home/err"
ack_drain_err "$home/state" "$home/err"
FM_FAKE_CREW_STATE='state: blocked · source: run-step · same next action' "$EXEC" notify > "$home/notifications"
grep -q approved-scout "$home/notifications" || fail 'changed reconciled state with unchanged action did not notify'
FM_FAKE_CREW_STATE='state: blocked · source: run-step · different volatile detail' "$EXEC" notify > "$home/dedup"
[ ! -s "$home/dedup" ] || fail 'volatile crew detail resurfaced unchanged execution'
"$ROOT/bin/fm-wake-drain.sh" > "$home/drain" 2> "$home/err"
ack_drain_err "$home/state" "$home/err"
for kind in ship task scout; do
  printf 'kind=%s\n' "$kind" >> "$home/state/approved-scout.meta"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 2 finding(s) · run: run-a' "$EXEC" notify > "$home/notifications"
  grep -q approved-scout "$home/notifications" || fail "$kind parked baseline did not notify"
  "$ROOT/bin/fm-wake-drain.sh" > "$home/drain" 2> "$home/err"
  ack_drain_err "$home/state" "$home/err"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 3 finding(s) · volatile note changed · run: run-a' "$EXEC" notify > "$home/dedup"
  [ ! -s "$home/dedup" ] || fail "$kind unchanged run/gate resurfaced on volatile detail"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at test: 3 finding(s) · run: run-a' "$EXEC" notify > "$home/notifications"
  grep -q approved-scout "$home/notifications" || fail "$kind changed parked gate did not notify"
  "$ROOT/bin/fm-wake-drain.sh" > "$home/drain" 2> "$home/err"
  ack_drain_err "$home/state" "$home/err"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at test: 3 finding(s) · run: run-a' "$EXEC" notify > "$home/dedup"
  [ ! -s "$home/dedup" ] || fail "$kind changed parked gate notified more than once"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at test: 3 finding(s) · run: run-b' "$EXEC" notify > "$home/notifications"
  grep -q approved-scout "$home/notifications" || fail "$kind changed run identity did not notify"
  "$ROOT/bin/fm-wake-drain.sh" > "$home/drain" 2> "$home/err"
  ack_drain_err "$home/state" "$home/err"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at test: 3 finding(s) · run: run-b' "$EXEC" notify > "$home/dedup"
  [ ! -s "$home/dedup" ] || fail "$kind changed run identity notified more than once"
done
# Supervision remains required with no endpoint at all, across process restart.
rm "$home/state/approved-scout.meta"
FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_supervision_needed "$2"' _ "$ROOT/bin/fm-supervision-lib.sh" "$home/state"
# Explicit enrollment never crosses homes.
other=$(make_case other-home)
FM_HOME="$other" FM_STATE_OVERRIDE="$other/state" "$EXEC" scan > "$home/other"
[ ! -s "$home/other" ] || fail 'approval leaked to another home'
if FM_HOME="$home" FM_STATE_OVERRIDE="$other/state" "$EXEC" approve independent-a --basis captain-approved 2>/dev/null; then
  fail 'inherited cross-home state override accepted for approval'
fi
[ ! -e "$other/state/independent-a.execution" ] || fail 'cross-home approval mutated another home'
# Generic task workers receive the same generation-bound receipt as ships.
tasks add task-receipt 'Process a bounded task' --kind task >/dev/null
"$EXEC" approve task-receipt --basis captain-approved
mkdir -p "$home/task-worker"
git -C "$home/task-worker" init -q
printf 'kind=task\nwindow=fake\nworktree=%s/task-worker\nproject=%s/project\nspawn_gen=task-gen\nharness=pi\n' "$home" "$home" > "$home/state/task-receipt.meta"
task_token=$(FM_HOME="$home" "$EXEC" attempt task-receipt --spawn-gen task-gen)
(cd "$home/task-worker" && FM_HOME="$home" "$EXEC" started task-receipt "$task_token")
FM_HOME="$home" "$EXEC" confirmed task-receipt

printf 'PASS: authority, fan-out, waits, promotion, receipts, restart, handoff and watcher transitions\n'
