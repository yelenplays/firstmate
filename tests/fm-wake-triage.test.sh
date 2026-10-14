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

# run_triage <dir> [<interpreter>] [<triage-args>...]
run_triage() {
  local dir=$1 interpreter=${2:-}
  shift
  [ "$#" -eq 0 ] || shift
  local PATH="$PATH" FM_HOME FM_STATE_OVERRIDE FM_CREW_STATE_BIN FM_CAPTAIN_HOLD_BIN FM_ROOT_OVERRIDE
  PATH="$dir/fakebin:$PATH"
  FM_HOME="$dir"
  FM_STATE_OVERRIDE="$dir/state"
  FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh"
  FM_CAPTAIN_HOLD_BIN="$dir/fakebin/fm-captain-hold.sh"
  FM_ROOT_OVERRIDE="$dir"
  export PATH FM_HOME FM_STATE_OVERRIDE FM_CREW_STATE_BIN FM_CAPTAIN_HOLD_BIN FM_ROOT_OVERRIDE
  if [ -n "$interpreter" ]; then
    "$interpreter" "$TRIAGE" "$@"
  else
    "$TRIAGE" "$@"
  fi
}

seed_fresh_watcher() {
  local dir=$1 pid identity
  sleep 60 >/dev/null 2>&1 &
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

  dir=$(make_case missing-status); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task missing-status "$dir"
  rm "$dir/state/missing-status.status"
  append_wake "$dir/state" stale 'test:missing-status' 'stale: test:missing-status'
  out=$(run_triage "$dir") || fail 'triage failed'
  assert_contains "$out" 'C7 latest task status missing' 'missing latest status must remain actionable'
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

test_meta_classification_fields_must_be_unique_and_well_formed() {
  local dir out
  dir=$(make_case duplicate-kind); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task duplicate "$dir"
  printf 'kind=scout\n' >> "$dir/state/duplicate.meta"
  append_wake "$dir/state" stale 'test:duplicate' 'stale: test:duplicate'
  out=$(run_triage "$dir") || fail 'triage with duplicate kind failed'
  assert_contains "$out" 'C2 task kind is not ship/scout' 'duplicate kind metadata was accepted'
  assert_not_contains "$out" 'WAKE_ACKED:' 'duplicate kind metadata must block auto-ack'
  assert_unacked "$dir"

  dir=$(make_case duplicate-window); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task duplicate "$dir"
  printf 'window=test:duplicate\n' >> "$dir/state/duplicate.meta"
  append_wake "$dir/state" stale 'test:duplicate' 'stale: test:duplicate'
  out=$(run_triage "$dir") || fail 'triage with duplicate identity metadata failed'
  assert_contains "$out" 'C2 stale identity is not exact' 'duplicate identity metadata was accepted'
  assert_not_contains "$out" 'WAKE_ACKED:' 'duplicate identity metadata must block auto-ack'
  assert_unacked "$dir"

  dir=$(make_case malformed-kind); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task malformed "$dir"
  printf 'kind=ship=secondmate\nwindow=test:malformed\n' > "$dir/state/malformed.meta"
  append_wake "$dir/state" stale 'test:malformed' 'stale: test:malformed'
  out=$(run_triage "$dir") || fail 'triage with malformed kind failed'
  assert_contains "$out" 'C2 task kind is not ship/scout' 'unparseable kind metadata was accepted'
  assert_not_contains "$out" 'WAKE_ACKED:' 'unparseable metadata must block auto-ack'
  assert_unacked "$dir"
  pass 'classification metadata must contain unique, well-formed fields'
}

test_status_annotations_require_exact_event_keys_and_verbs() {
  local dir out
  dir=$(make_case status-event-decoy); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task target "$dir"
  printf 'done: historical note says working: but is complete\nworking: resumed\n' > "$dir/state/target.status"
  append_wake "$dir/state" signal target.status 'signal: changed'
  out=$(run_triage "$dir") || fail 'triage with status-event decoy failed'
  assert_contains "$out" 'C7 task has terminal or unread status' 'a done event containing working text was accepted'
  assert_not_contains "$out" 'WAKE_ACKED:' 'a decoy working token must not auto-ack'
  assert_unacked "$dir"

  dir=$(make_case status-key-decoy); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task target "$dir"
  setup_task other "$dir"
  printf 'note: target.status: done: working: this is unrelated free text\n' >> "$dir/state/other.status"
  append_wake "$dir/state" signal target.status 'signal: changed'
  out=$(run_triage "$dir") || fail 'triage with unrelated annotation failed'
  assert_contains "$out" 'ROUTINE (worker verifiably working' 'an unrelated annotation was treated as a target event'
  assert_not_contains "$out" 'C7 presented status event is not working' 'an unrelated annotation was treated as a target event'
  assert_unacked "$dir"
  pass 'status annotations use exact keys and leading event verbs'
}

test_ack_gate_with_and_without_extra_notice() {
  local dir out pid
  dir=$(make_case ack-without-notice); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task routine "$dir"
  pid=$(seed_fresh_watcher "$dir")
  append_wake "$dir/state" stale 'test:routine' 'stale: test:routine'
  out=$(run_triage "$dir") || fail 'routine triage failed'
  assert_not_contains "$out" 'WAKE_ACKED:' 'all-routine rows must remain manual by default'
  assert_contains "$out" 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through' 'manual acknowledgement command was not shown'
  assert_unacked "$dir"
  kill "$pid" 2>/dev/null || true

  dir=$(make_case ack-with-extra-notice); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task routine "$dir"
  setup_task unrelated "$dir"
  pid=$(seed_fresh_watcher "$dir")
  printf 'note: unrelated update\n' >> "$dir/state/unrelated.status"
  append_wake "$dir/state" stale 'test:routine' 'stale: test:routine'
  out=$(run_triage "$dir") || fail 'triage with unrelated notice failed'
  assert_contains "$out" 'UNREAD STATUS' 'extra one-shot notice was not emitted'
  assert_not_contains "$out" 'WAKE_ACKED:' 'an extra notice must block automatic acknowledgement'
  assert_unacked "$dir"
  kill "$pid" 2>/dev/null || true
  pass 'clean routine drains remain manual; extra notices remain visible'
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
  local dir out pid log
  dir=$(make_case routine); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task routine "$dir"
  pid=$(seed_fresh_watcher "$dir")
  append_wake "$dir/state" stale 'test:routine' 'stale: test:routine'
  log="$dir/crew.log"
  out=$(FM_CREW_LOG="$log" run_triage "$dir") || fail "routine triage failed"
  [ "$(wc -l < "$log" | tr -d ' ')" = 1 ] || fail 'crew state was not read exactly once'
  assert_contains "$out" 'ROUTINE (worker verifiably working' 'working task was not classified routine'
  assert_not_contains "$out" 'WAKE_ACKED:' 'all-routine queue must remain manual by default'
  assert_contains "$out" 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through' 'manual acknowledgement command was not shown'
  assert_unacked "$dir"
  [ -s "$dir/state/.wake-triage.last" ] || fail 'full drain output was not retained'
  kill "$pid" 2>/dev/null || true

  dir=$(make_case afk); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task afk "$dir"
  : > "$dir/state/.afk"
  append_wake "$dir/state" stale 'test:afk' 'stale: test:afk'
  out=$(run_triage "$dir") || fail "afk triage failed"
  assert_not_contains "$out" 'WAKE_ACKED:' 'away posture must disable automatic acknowledgement'
  assert_unacked "$dir"
  pass 'all-routine rows remain manual, including while away mode is active'
}

test_empty_recovered_array_under_system_bash() {
  local dir out
  dir=$(make_case empty-recovered)
  install_crew_stub "$dir"
  install_hold_stub "$dir"
  out=$(run_triage "$dir" /bin/bash) || fail 'triage failed with no recovered pending files under /bin/bash'
  assert_contains "$out" 'WAKE TRIAGE:' 'triage did not complete its empty-recovery pass'
  set -- "$dir/state"/.wake-triage.pending.*
  [ ! -e "$1" ] || fail 'unexpected pending output remained'
  pass 'triage completes with no recovered pending files under system bash'
}

test_branch_actor_delegates_to_drain() {
  local dir out
  dir=$(make_case branch); install_crew_stub "$dir"; install_hold_stub "$dir"
  append_wake "$dir/state" heartbeat heartbeat 'heartbeat'
  printf '1\n' > "$dir/state/.branch-eligible-rows"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_SUPERVISION_ACTOR=branch "$TRIAGE" 2>&1 || true)
  assert_contains "$out" 'no branch-eligible row snapshot' 'branch actor must preserve the drain grant requirement'
  assert_not_contains "$out" 'WAKE TRIAGE:' 'branch actor must not reclassify wakes'

  pass 'branch handling remains delegated to the existing drain contract'
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

  dir=$(make_case unrelated-unread-note); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task routine "$dir"
  setup_task unrelated "$dir"
  printf 'note: unrelated captain reply\n' >> "$dir/state/unrelated.status"
  append_wake "$dir/state" stale 'test:routine' 'stale: test:routine'
  out=$(run_triage "$dir") || fail 'triage failed'
  assert_contains "$out" 'UNREAD STATUS' 'unrelated one-shot notice was not surfaced'
  assert_not_contains "$out" 'WAKE_ACKED:' 'unrelated one-shot notice must block acknowledgement'
  assert_unacked "$dir"
  pass 'ambiguous hold results and unread informational status remain actionable'
}

test_malformed_queue_row_is_actionable() {
  local dir out
  dir=$(make_case malformed-queue-row); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task routine "$dir"
  append_wake "$dir/state" stale 'test:routine' 'stale: test:routine'
  printf '1234567890\t2\tstale\ttruncated-key\n' >> "$dir/state/.wake-queue"
  out=$(run_triage "$dir") || fail 'triage failed'
  assert_contains "$out" 'ACT NOW: drain retired malformed queue rows' 'retired malformed row was not classified actionable'
  assert_contains "$out" 'truncated-key' 'malformed row evidence was lost'
  assert_not_contains "$out" 'WAKE_ACKED:' 'malformed row must block acknowledgement'
  assert_unacked "$dir"
  pass 'malformed queue rows remain visible and prevent auto-ack'
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

test_signal_terminates_before_acknowledgement() {
  local dir pid tries
  dir=$(make_case signal-interruption)
  install_crew_stub "$dir"
  cat > "$dir/fakebin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOLD_STARTED"
sleep 2
exit 3
SH
  chmod +x "$dir/fakebin/fm-captain-hold.sh"
  setup_task interrupted "$dir"
  append_wake "$dir/state" stale 'test:interrupted' 'stale: test:interrupted'
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_CAPTAIN_HOLD_BIN="$dir/fakebin/fm-captain-hold.sh" \
    FM_HOLD_STARTED="$dir/hold.started" FM_ROOT_OVERRIDE="$dir" \
    "$TRIAGE" >"$dir/output" 2>&1 &
  pid=$!
  tries=0
  while [ ! -e "$dir/hold.started" ] && [ "$tries" -lt 100 ]; do
    sleep 0.02
    tries=$((tries + 1))
  done
  [ -e "$dir/hold.started" ] || { kill "$pid" 2>/dev/null || true; fail 'triage never reached the hold check'; }
  kill -TERM "$pid" 2>/dev/null || fail 'could not interrupt triage'
  wait "$pid" && fail 'terminated triage continued successfully'
  assert_unacked "$dir"
  set -- "$dir/state"/.wake-triage.pending.*
  [ -f "$1" ] || fail 'signal interruption discarded pending drain output'
  pass 'signals terminate triage before acknowledgement and retain pending output'
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

# Real status lines carry stamps: fm-status writes "working [at=N]: ..." and
# correlated lines add a corr= token. The annotation verb must read through
# both exactly as status_line_verb does, or every real wake reads as unread
# non-working status and nothing is ever routine.
test_stamped_working_status_is_routine() {
  local dir out line
  for line in 'working [at=1792010690]: implementing' \
    'working corr=0123456789abcdef [at=1792010690]: implementing'; do
    dir=$(make_case "stamped-$RANDOM"); install_crew_stub "$dir"; install_hold_stub "$dir"
    setup_task stamped "$dir"
    printf '%s\n' "$line" > "$dir/state/stamped.status"
    append_wake "$dir/state" signal stamped.status 'signal: changed'
    out=$(run_triage "$dir") || fail "triage of a stamped working status failed"
    assert_contains "$out" 'ROUTINE (worker verifiably working' "a stamped working status was not routine: $line"
    assert_not_contains "$out" 'C7' "a stamped working status was read as non-working: $line"
  done

  dir=$(make_case stamped-done); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task stamped "$dir"
  printf 'done [at=1792010690]: merged\n' > "$dir/state/stamped.status"
  append_wake "$dir/state" signal stamped.status 'signal: changed'
  out=$(run_triage "$dir") || fail "triage of a stamped done status failed"
  assert_contains "$out" 'C7' 'a stamped done status was not kept actionable'
  pass 'stamped and correlated working status events are routine; stamped terminal events are not'
}

# absorb_case <name>: a case with one routine working task, a fresh watcher, and
# one stale wake row for it. Prints the case directory; the watcher pid is in
# <dir>/watcher.pid.
absorb_case() {
  local dir
  dir=$(make_case "$1"); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task routine "$dir"
  seed_fresh_watcher "$dir" > "$dir/watcher.pid"
  append_wake "$dir/state" stale 'test:routine' 'stale: test:routine'
  printf '%s\n' "$dir"
}

stop_absorb_watcher() {
  kill "$(cat "$1/watcher.pid")" 2>/dev/null || true
}

test_absorb_acknowledges_an_all_routine_wake() {
  local dir out rc ack
  dir=$(absorb_case absorb-routine)
  rc=0
  out=$(run_triage "$dir" '' --absorb) || rc=$?
  stop_absorb_watcher "$dir"
  [ "$rc" -eq 0 ] || fail "an all-routine wake was not absorbed (rc=$rc): $out"
  assert_contains "$out" 'ROUTINE (worker verifiably working' 'the absorbed presentation was not printed'
  assert_contains "$out" 'WAKE_ACKED: triage acknowledged every row through' 'the absorbed wake printed no WAKE_ACKED line'
  assert_not_contains "$out" 'WAKE_ACK_REQUIRED' 'an absorbed wake still asked for manual acknowledgement'
  [ ! -s "$dir/state/.wake-queue" ] || fail 'an absorbed wake left its row queued'
  case "$(cat "$dir/state/.watcher-down" 2>/dev/null)" in
    pending:*|announced:*) fail 'an absorbed wake left its recovery episode open' ;;
  esac
  [ -s "$dir/state/.wake-triage.last" ] || fail 'the absorbed drain output was not retained'

  dir=$(absorb_case absorb-persistent-decision)
  setup_task other "$dir"
  printf 'needs-decision [key=k1]: choose a lane\n' > "$dir/state/other.status"
  # A first presentation makes the decision old news; the absorb pass then sees
  # only the persistent list, which is not a reason to wake firstmate again.
  run_triage "$dir" > /dev/null || fail 'priming triage failed'
  ack=$(sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run \(.*\)$/\1/p' "$dir/state/.wake-triage.last" | tail -1)
  [ -n "$ack" ] || fail 'the priming triage printed no acknowledgement'
  # shellcheck disable=SC2086 # the printed command is a plain word list
  FM_STATE_OVERRIDE="$dir/state" "$ROOT"/$ack > /dev/null 2>&1 || fail 'the priming acknowledgement failed'
  append_wake "$dir/state" stale 'test:routine' 'stale: test:routine'
  rc=0
  out=$(run_triage "$dir" '' --absorb) || rc=$?
  stop_absorb_watcher "$dir"
  [ "$rc" -eq 0 ] || fail "a persistent open decision of another task kept a routine wake (rc=$rc): $out"
  assert_contains "$out" 'OPEN DECISIONS' 'the persistent decision list was not presented'
  [ ! -s "$dir/state/.wake-queue" ] || fail 'the absorbed wake left its row queued'
  pass '--absorb acknowledges an all-routine wake, persistent open decisions included'
}

test_absorb_retires_routine_rows_of_an_actionable_wake() {
  local dir out rc ack
  dir=$(absorb_case absorb-mixed)
  setup_task finished "$dir"
  printf 'done: merged\n' > "$dir/state/finished.status"
  printf 'pr=https://example.test/pull/1\n' >> "$dir/state/finished.meta"
  append_wake "$dir/state" stale 'test:finished' 'stale: test:finished'
  rc=0
  out=$(run_triage "$dir" '' --absorb) || rc=$?
  stop_absorb_watcher "$dir"
  [ "$rc" -eq 10 ] || fail "a wake with an ACT NOW row did not exit 10 (rc=$rc): $out"
  assert_contains "$out" 'ACT NOW:' 'the actionable row was not presented'
  assert_contains "$out" 'ROUTINE ROWS ACKNOWLEDGED BY TRIAGE:' 'the routine row was not retired'
  assert_not_contains "$out" 'WAKE_ACKED:' 'an actionable wake was reported as absorbed'
  [ "$(awk -F '\t' '{ print $4 }' "$dir/state/.wake-queue")" = test:finished ] \
    || fail "triage did not keep exactly the actionable row queued: $(cat "$dir/state/.wake-queue")"
  ack=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run \(.*\)$/\1/p' | tail -1)
  [ -n "$ack" ] || fail 'the actionable wake printed no acknowledgement command'
  printf '%s\n' "$out" | tail -1 | grep -q '^WAKE_ACK_REQUIRED: ' || fail 'the acknowledgement command is not the last line'
  # shellcheck disable=SC2086 # the printed command is a plain word list
  FM_STATE_OVERRIDE="$dir/state" "$ROOT"/$ack > /dev/null 2>&1 || fail 'the printed acknowledgement failed'
  [ ! -s "$dir/state/.wake-queue" ] || fail 'the printed acknowledgement left the actionable row queued'
  pass '--absorb retires routine rows of an actionable wake and leaves the rest to the printed acknowledgement'
}

test_absorb_fails_closed() {
  local dir out rc
  # An unread one-shot notice of another task needs firstmate.
  dir=$(absorb_case absorb-unread)
  setup_task unrelated "$dir"
  printf 'note: unrelated captain reply\n' >> "$dir/state/unrelated.status"
  rc=0
  out=$(run_triage "$dir" '' --absorb) || rc=$?
  stop_absorb_watcher "$dir"
  [ "$rc" -eq 10 ] || fail "an unread notice did not keep the wake (rc=$rc)"
  assert_contains "$out" 'UNREAD STATUS' 'the unread notice was not presented'
  assert_not_contains "$out" 'WAKE_ACKED:' 'an unread notice was absorbed'
  assert_not_contains "$out" 'ROUTINE ROWS ACKNOWLEDGED' 'an all-routine batch kept for a notice acknowledged rows piecemeal'
  assert_contains "$out" 'WAKE_ACK_REQUIRED: after handling completes run' 'the kept wake lost its acknowledgement command'
  assert_unacked "$dir"

  # A watcher-down banner is never absorbed.
  dir=$(make_case absorb-watcher-down); install_crew_stub "$dir"; install_hold_stub "$dir"
  setup_task routine "$dir"
  append_wake "$dir/state" stale 'test:routine' 'stale: test:routine'
  rc=0
  out=$(run_triage "$dir" '' --absorb) || rc=$?
  [ "$rc" -eq 10 ] || fail "a wake drained without a live watcher was absorbed or failed (rc=$rc): $out"
  assert_unacked "$dir"

  # A new open decision keeps the wake: the status write that raises it queues
  # its own signal row, and that row is never routine.
  dir=$(absorb_case absorb-new-decision)
  setup_task other "$dir"
  printf 'needs-decision [key=k2]: choose a lane\n' >> "$dir/state/other.status"
  append_wake "$dir/state" signal other.status 'signal: changed'
  rc=0
  out=$(run_triage "$dir" '' --absorb) || rc=$?
  stop_absorb_watcher "$dir"
  [ "$rc" -eq 10 ] || fail "a new open decision was absorbed (rc=$rc)"
  assert_contains "$out" 'C4 open decision' 'the new decision row was not kept actionable'
  [ "$(awk -F '\t' '{ print $4 }' "$dir/state/.wake-queue")" = other.status ] \
    || fail "the decision row was not the one left queued: $(cat "$dir/state/.wake-queue")"

  # A row of an ineligible shape stays ACT NOW even for a working task, and an
  # execution check row (queued only for a firstmate-owned obligation) is never
  # routine without its obligation line.
  for row in 'check|execution:routine|check: execution routine (changed)' \
    'check|execution:routine|check: execution routine'; do
    dir=$(absorb_case "absorb-shape-$RANDOM")
    append_wake "$dir/state" "${row%%|*}" "$(printf '%s' "$row" | cut -d'|' -f2)" "${row##*|}"
    rc=0
    out=$(run_triage "$dir" '' --absorb) || rc=$?
    stop_absorb_watcher "$dir"
    [ "$rc" -eq 10 ] || fail "an ineligible or unexplained execution row was absorbed (rc=$rc): $row"
    assert_contains "$out" 'ACT NOW:' "the row was not kept actionable: $row"
    awk -F '\t' '$3 == "check" { found=1 } END { exit !found }' "$dir/state/.wake-queue" \
      || fail "the execution row was acknowledged: $row"
  done

  # Away mode belongs to the away daemon.
  dir=$(absorb_case absorb-afk)
  : > "$dir/state/.afk"
  rc=0
  out=$(run_triage "$dir" '' --absorb) || rc=$?
  stop_absorb_watcher "$dir"
  [ "$rc" -eq 10 ] || fail "--absorb acknowledged while away (rc=$rc)"
  assert_not_contains "$out" 'WAKE_ACKED:' 'away posture was absorbed'
  assert_unacked "$dir"

  # Arguments.
  dir=$(make_case absorb-args); install_crew_stub "$dir"; install_hold_stub "$dir"
  rc=0; run_triage "$dir" '' --absorb extra > /dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "--absorb accepted an extra argument (rc=$rc)"
  rc=0; run_triage "$dir" '' --bogus > /dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "triage accepted an unknown argument (rc=$rc)"
  out=$(run_triage "$dir" '' --help) || fail '--help failed'
  assert_contains "$out" 'Usage: fm-wake-triage.sh [--absorb]' '--help did not print the usage header'
  pass '--absorb keeps every wake that needs firstmate and validates its arguments'
}

test_instruction_wiring() {
  local rendered
  rendered=$("$ROOT/bin/fm-supervision-instructions.sh" --harness claude)
  assert_contains "$rendered" 'bin/fm-wake-triage.sh' 'Claude instructions omit the triage command'
  assert_contains "$rendered" 'ACT NOW' 'Claude instructions omit triage response guidance'
  pass 'Claude instruction renderer exposes the triage interface'
}

test_shellcheck() {
  shellcheck -S warning "$ROOT/bin/fm-wake-triage.sh" "$0" || fail 'shellcheck reported an issue'
  pass 'triage command and tests pass shellcheck'
}

test_nonworking_and_terminal_rows_stay_actionable
test_meta_classification_fields_must_be_unique_and_well_formed
test_status_annotations_require_exact_event_keys_and_verbs
test_ack_gate_with_and_without_extra_notice
test_shape_identity_and_secondmate_fail_closed
test_open_decisions_pauses_holds_and_execution_are_actionable
test_happy_path_and_afk
test_empty_recovered_array_under_system_bash
test_branch_actor_delegates_to_drain
test_reason_specific_and_nonproof_failures
test_unread_note_and_captain_hold_exit_codes
test_malformed_queue_row_is_actionable
test_hidden_duplicate_row_stays_actionable
test_signal_terminates_before_acknowledgement
test_interruption_retains_pending_output
test_stamped_working_status_is_routine
test_absorb_acknowledges_an_all_routine_wake
test_absorb_retires_routine_rows_of_an_actionable_wake
test_absorb_fails_closed
test_instruction_wiring
test_shellcheck
