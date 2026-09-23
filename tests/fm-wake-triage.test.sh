#!/usr/bin/env bash
# Regression coverage for the one-rule wake triage command.
set -u
# shellcheck source=tests/wake-helpers.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TRIAGE="$ROOT/bin/fm-wake-triage.sh"
# shellcheck disable=SC2034 # Used by make_case from tests/wake-helpers.sh.
TMP_ROOT=$(fm_test_tmproot fm-wake-triage)
FM_SUPERVISION_MODEL=autoarm
export FM_SUPERVISION_MODEL

setup_task() {
  local id=$1 dir=$2 kind=${3:-ship}
  printf 'kind=%s\nwindow=test:%s\n' "$kind" "$id" > "$dir/state/$id.meta"
  printf 'working: implementing\n' > "$dir/state/$id.status"
}

install_crew_stub() {
  local dir=$1
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
id=${1:-}
key=$(printf '%s' "$id" | tr -c 'A-Za-z0-9' '_')
var="FM_FAKE_CREW_STATE_$key"
printf '%s\n' "${!var:-${FM_FAKE_CREW_STATE:-state: working · source: pane · busy}}"
printf '%s\n' "$id" >> "${FM_CREW_LOG:-/dev/null}"
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"
}

install_hold_stub() {
  local dir=$1
  cat > "$dir/fakebin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
exit "${FM_FAKE_HOLD_EXIT:-3}"
SH
  chmod +x "$dir/fakebin/fm-captain-hold.sh"
}

run_triage() {
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_CAPTAIN_HOLD_BIN="$dir/fakebin/fm-captain-hold.sh" \
    FM_ROOT_OVERRIDE="$dir" "$TRIAGE"
}

seed_fresh_watcher() {
  local dir=$1 pid identity
  sleep 60 &
  pid=$!
  identity=$(FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid") || fail 'could not identify fixture watcher'
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\\n' "$dir" > "$dir/state/.watch.lock/fm-home"
  printf '%s\\n' 'watch_under_test' > "$dir/state/.watch.lock/watcher-path"
  printf '%s\\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
  touch "$dir/state/.last-watcher-beat"
  printf '%s\\n' "$pid"
}

assert_unacked() {
  [ -s "$1/state/.wake-queue" ] || fail "ACT NOW row was acknowledged"
}

# T1-T8, T10-T11, T13-T20 and T23 cover each unsafe downgrade family with a
# real drain and durable queue row; absence of proof always means ACT NOW.
test_nonworking_and_terminal_rows_stay_actionable() {
  local dir out
  dir=$(make_case done-row); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task done-task "$dir"
  printf 'done: checks passed\n' > "$dir/state/done-task.status"
  printf 'pr=https://example.test/pull/1\n' >> "$dir/state/done-task.meta"
  append_wake "$dir/state" stale 'test:done-task' 'stale: test:done-task'
  out=$(run_triage "$dir") || fail "triage command failed"
  assert_contains "$out" 'ACT NOW:' 'done task must remain actionable'
  assert_unacked "$dir"
  dir=$(make_case parked-row); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task parked "$dir"
  append_wake "$dir/state" stale 'test:parked' 'stale: test:parked'
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · done'
  out=$(run_triage "$dir") || fail "triage failed"
  unset FM_FAKE_CREW_STATE
  assert_contains "$out" 'C3 crew not working' 'parked task must be actionable'
  assert_unacked "$dir"
  pass 'terminal and parked tasks are never auto-acknowledged'
}

test_shape_identity_and_secondmate_fail_closed() {
  local dir out log
  dir=$(make_case malformed); install_crew_stub "$dir"; install_hold_stub "$dir"
  append_wake "$dir/state" stale 'test:missing' 'stale: test:missing'
  out=$(run_triage "$dir") || fail "triage failed"
  assert_contains "$out" 'C2 stale identity is not exact' 'unknown stale identity must be actionable'
  assert_unacked "$dir"

  dir=$(make_case secondmate); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task remote "$dir" secondmate
  log="$dir/crew.log"
  append_wake "$dir/state" signal remote.status 'signal: changed'
  out=$(FM_CREW_LOG="$log" run_triage "$dir") || fail "triage failed"
  assert_contains "$out" 'C2 task kind is not ship/scout' 'secondmate is never routine'
  [ ! -s "$log" ] || fail "secondmate crew state was queried"
  assert_unacked "$dir"
  pass 'invalid identity and secondmate rows are actionable without guessing'
}

test_open_decisions_pauses_holds_and_execution_are_actionable() {
  local dir out
  dir=$(make_case decision); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task decision "$dir"
  printf 'needs-decision [key=k]: choose\nworking: resumed\n' > "$dir/state/decision.status"
  append_wake "$dir/state" stale 'test:decision' 'stale: test:decision'
  out=$(run_triage "$dir") || fail "triage failed"
  assert_contains "$out" 'C4 open decision' 'buried open decision must prevent auto-ack'
  assert_unacked "$dir"

  dir=$(make_case paused); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task paused "$dir"
  printf 'paused: waiting\n' > "$dir/state/paused.status"
  append_wake "$dir/state" stale 'test:paused' 'stale: test:paused'
  out=$(run_triage "$dir") || fail "triage failed"
  assert_contains "$out" 'C5 paused/captain-held' 'paused task must remain actionable'
  assert_unacked "$dir"

  dir=$(make_case held); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task held "$dir"
  append_wake "$dir/state" stale 'test:held' 'stale: test:held'
  out=$(FM_FAKE_HOLD_EXIT=0 run_triage "$dir") || fail "triage failed"
  assert_contains "$out" 'C6 captain hold' 'captain-held task must remain actionable'
  assert_unacked "$dir"
  pass 'open decisions, declared pauses, and captain holds prevent auto-ack'
}

test_happy_path_and_afk() {
  local dir out pid
  dir=$(make_case routine); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task routine "$dir"
  pid=$(seed_fresh_watcher "$dir")
  append_wake "$dir/state" stale 'test:routine' 'stale: test:routine'
  out=$(run_triage "$dir") || fail "routine triage failed"
  assert_contains "$out" 'ROUTINE (worker verifiably working' 'working task was not classified routine'
  assert_contains "$out" 'WAKE_ACKED:' 'all-routine queue was not acknowledged'
  [ ! -s "$dir/state/.wake-queue" ] || fail 'all-routine queue was not consumed'
  [ -s "$dir/state/.wake-triage.last" ] || fail 'full drain output was not retained'
  kill "$pid" 2>/dev/null || true

  dir=$(make_case afk); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task afk "$dir"
  : > "$dir/state/.afk"
  append_wake "$dir/state" stale 'test:afk' 'stale: test:afk'
  out=$(run_triage "$dir") || fail "afk triage failed"
  assert_not_contains "$out" 'WAKE_ACKED:' 'away posture must disable automatic acknowledgement'
  assert_unacked "$dir"
  pass 'all-routine rows auto-ack, except while away mode is active'
}

test_branch_actor_and_static_guards() {
  local dir out
  dir=$(make_case branch); install_crew_stub "$dir"; install_hold_stub "$dir"
  append_wake "$dir/state" heartbeat heartbeat 'heartbeat'
  printf '1\n' > "$dir/state/.branch-eligible-rows"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_SUPERVISION_ACTOR=branch "$TRIAGE" 2>&1 || true)
  assert_contains "$out" 'no branch-eligible row snapshot' 'branch actor must preserve the drain grant requirement'
  assert_not_contains "$out" 'WAKE TRIAGE:' 'branch actor must not reclassify wakes'

  assert_not_contains "$(<"$TRIAGE")" 'jev' 'triage command must not call Jev'
  assert_not_contains "$(<"$TRIAGE")" 'curl' 'triage command must not make network calls'
  pass 'branch handling remains delegated and classifier has no Jev/network dependency'
}

test_reason_specific_and_nonproof_failures() {
  local dir out
  for payload in \
    'stale: test:reason (declared wait recheck)' \
    'stale: test:reason (writing its worktree)' \
    'stale: test:reason (demand-deep-inspection)'; do
    dir=$(make_case "reason-$RANDOM"); install_crew_stub "$dir"; install_hold_stub "$dir"
    setup_task reason "$dir"
    append_wake "$dir/state" stale 'test:reason' "$payload"
    out=$(run_triage "$dir") || fail 'triage failed'
    assert_contains "$out" 'ACT NOW:' 'qualified stale reason was auto-dismissed'
    assert_unacked "$dir"
  done

  dir=$(make_case source-status-log); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task source "$dir"
  append_wake "$dir/state" stale 'test:source' 'stale: test:source'
  export FM_FAKE_CREW_STATE='state: working · source: status-log · historical'
  out=$(run_triage "$dir") || fail 'triage failed'
  unset FM_FAKE_CREW_STATE
  assert_contains "$out" 'C3 crew not working' 'status-log is not working proof'
  assert_unacked "$dir"

  dir=$(make_case source-unknown); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task unknown "$dir"
  append_wake "$dir/state" stale 'test:unknown' 'stale: test:unknown'
  export FM_FAKE_CREW_STATE='state: unknown · source: fm-spawn · seeded'
  out=$(run_triage "$dir") || fail 'triage failed'
  unset FM_FAKE_CREW_STATE
  assert_contains "$out" 'C3 crew not working' 'spawn seed is not working proof'
  assert_unacked "$dir"
  pass 'stale reason variants and non-proof state sources stay actionable'
}

test_unread_note_and_captain_hold_exit_codes() {
  local dir out
  dir=$(make_case hold-two); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task held "$dir"
  append_wake "$dir/state" stale 'test:held' 'stale: test:held'
  out=$(FM_FAKE_HOLD_EXIT=2 run_triage "$dir") || fail 'triage failed'
  assert_contains "$out" 'C6 captain hold' 'ambiguous captain-hold result must be actionable'
  assert_unacked "$dir"

  dir=$(make_case unread-note); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task note "$dir"
  printf 'note: captain reply\n' >> "$dir/state/note.status"
  append_wake "$dir/state" signal note.status 'signal: changed'
  out=$(run_triage "$dir") || fail 'triage failed'
  assert_contains "$out" 'C7' 'unread note must prevent routine dismissal'
  assert_unacked "$dir"
  pass 'ambiguous hold results and unread informational status remain actionable'
}

test_hidden_duplicate_row_stays_actionable() {
  local dir out
  dir=$(make_case hidden-row); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task dedupe "$dir"
  append_wake "$dir/state" stale 'test:dedupe' 'stale: test:dedupe (possible wedge, escalation 1)'
  append_wake "$dir/state" stale 'test:dedupe' 'stale: test:dedupe'
  out=$(run_triage "$dir") || fail 'triage failed'
  assert_contains "$out" 'HIDDEN QUEUE ROWS' 'dedupe-hidden row was not presented'
  assert_contains "$out" 'possible wedge, escalation 1' 'hidden wedge reason was lost'
  assert_unacked "$dir"
  pass 'dedupe-hidden rows remain actionable and visible'
}

test_interruption_retains_pending_output() {
  local dir out
  dir=$(make_case interruption); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task interrupted "$dir"
  append_wake "$dir/state" stale 'test:interrupted' 'stale: test:interrupted'
  run_triage "$dir" >&- 2>/dev/null && fail 'closed output unexpectedly succeeded'
  set -- "$dir/state"/.wake-triage.pending.*
  [ -f "$1" ] || fail 'interrupted output was not retained'
  assert_unacked "$dir"
  out=$(run_triage "$dir") || fail 'recovery triage failed'
  assert_contains "$out" 'RECOVERED DRAIN OUTPUT' 'recovery output was not replayed'
  assert_not_contains "$out" 'WAKE_ACKED:' 'recovered output must disable automatic acknowledgement'
  assert_unacked "$dir"
  pass 'interrupted triage output survives and is replayed before manual acknowledgement'
}

test_instruction_wiring() {
  local rendered
  rendered=$("$ROOT/bin/fm-supervision-instructions.sh" --harness claude)
  assert_contains "$rendered" 'bin/fm-wake-triage.sh' 'Claude instructions omit the triage command'
  assert_contains "$(<"$ROOT/docs/supervision-protocols/claude.md")" 'ACT NOW, NOTICES and STANDING' 'Claude protocol lacks triage response guidance'
  assert_contains "$(<"$ROOT/bin/fm-claude-stop-autoarm.sh")" 'fallback: bin/fm-wake-drain.sh' 'auto-arm fallback is missing'
  pass 'Claude-only instruction surfaces name wake triage'
}

test_shellcheck() {
  shellcheck -S warning "$ROOT/bin/fm-wake-triage.sh" "$0" || fail 'shellcheck reported an issue'
  pass 'triage command and tests pass shellcheck'
}

test_nonworking_and_terminal_rows_stay_actionable
test_shape_identity_and_secondmate_fail_closed
test_open_decisions_pauses_holds_and_execution_are_actionable
test_happy_path_and_afk
test_branch_actor_and_static_guards
test_reason_specific_and_nonproof_failures
test_unread_note_and_captain_hold_exit_codes
test_hidden_duplicate_row_stays_actionable
test_interruption_retains_pending_output
test_instruction_wiring
test_shellcheck
