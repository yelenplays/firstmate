#!/usr/bin/env bash
# Behavior tests for bin/fm-queue-ready.sh and its heartbeat caller in
# bin/fm-wake-drain.sh. Fixtures are real tasks-axi backlogs in a temp home;
# no case makes a model or network call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

HELPER="$ROOT/bin/fm-queue-ready.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-queue-ready)
HOME_DIR="$TMP_ROOT/home"
PAST=2000-01-01
FUTURE=2999-01-01

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is required for these tests"

fresh_home() {
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  : > "$HOME_DIR/data/backlog.md"
}

axi() {  # <tasks-axi args...>
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi "$@" --file data/backlog.md) >/dev/null \
    || fail "tasks-axi $* failed"
}

run_ready() {
  FM_HOME="$HOME_DIR" "$HELPER" "$@"
}

test_help_and_usage() {
  local out code=0
  out=$(run_ready --help) || fail "--help must exit 0"
  assert_contains "$out" 'advisory next-work line' "--help prints the header"
  run_ready --bogus >/dev/null 2>&1 || code=$?
  expect_code 2 "$code" "an unexpected argument is a usage error"
  pass "--help prints usage and a bad argument exits 2"
}

test_empty_backlog_is_silent() {
  local out
  fresh_home
  out=$(run_ready) || fail "empty backlog must exit 0"
  assert_equals '' "$out" "an empty backlog prints nothing"
  pass "an empty backlog prints nothing"
}

test_structured_readiness() {
  local out before after
  fresh_home
  axi add plain 'Ship, with commas, in the title' --kind ship --repo firstmate
  axi add blocker 'Open blocker' --kind ship --repo firstmate
  axi add blocked 'Waits on the blocker' --kind ship --repo firstmate
  axi block blocked --by blocker
  axi hold blocker --reason 'parked indefinitely' --kind parked
  axi add gate-open 'Deferred until a past date' --kind scout --repo firstmate
  axi hold gate-open --reason 'wait for launch' --kind parked --until "$PAST"
  axi add gate-shut 'Deferred until a future date' --kind scout --repo firstmate
  axi hold gate-shut --reason 'wait for launch' --kind parked --until "$FUTURE"
  axi add captain-held 'Captain call' --kind ship --repo firstmate
  axi hold captain-held --reason 'captain decision pending' --kind captain
  axi add captain-expired 'Captain call past its date' --kind ship --repo firstmate
  axi hold captain-expired --reason 'captain decision pending' --kind captain --until "$PAST"
  axi add decision 'Captain decision item' --kind captain --repo firstmate
  before=$(cksum < "$HOME_DIR/data/backlog.md")
  out=$(run_ready) || fail "readiness must exit 0"
  after=$(cksum < "$HOME_DIR/data/backlog.md")
  assert_equals 'QUEUE READY (advisory, never dispatch): 2 ready: plain, gate-open' "$out" \
    "only unblocked, ungated, non-captain items are ready"
  assert_equals "$before" "$after" "the check never changes the backlog"
  pass "readiness requires cleared blockers, a passed time gate, and no captain hold"
}

test_cleared_blocker_makes_item_ready() {
  local out
  fresh_home
  axi add first 'Blocker' --kind ship --repo firstmate
  axi add second 'Dependent' --kind ship --repo firstmate
  axi block second --by first
  out=$(run_ready)
  assert_equals 'QUEUE READY (advisory, never dispatch): 1 ready: first' "$out" \
    "an open blocker keeps its dependent out"
  axi start first
  axi "done" first
  out=$(run_ready)
  assert_equals 'QUEUE READY (advisory, never dispatch): 1 ready: second' "$out" \
    "a finished blocker releases its dependent"
  pass "a dependent becomes ready once its blocker is done"
}

test_long_ready_set_is_capped() {
  local out i
  fresh_home
  for i in 1 2 3 4 5 6 7; do
    axi add "item-$i" "Item $i" --kind ship --repo firstmate
  done
  out=$(run_ready)
  assert_equals 'QUEUE READY (advisory, never dispatch): 7 ready: item-1, item-2, item-3, item-4, item-5 (+2 more)' \
    "$out" "at most five ids are named"
  pass "a long ready set names five ids and counts the rest"
}

test_unreadable_backlog_is_silent() {
  local out
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR"
  out=$(run_ready 2>&1) || fail "a missing backlog must exit 0"
  assert_equals '' "$out" "a missing backlog prints nothing"
  pass "a missing backlog prints nothing and exits 0"
}

test_drain_prints_line_only_on_heartbeat() {
  local dir state out err
  fresh_home
  axi add ready-1 'Ship a widget' --kind ship --repo firstmate
  dir=$(make_case drain-ready)
  state="$HOME_DIR/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat append failed"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "heartbeat drain failed"
  assert_contains "$(cat "$out")" 'QUEUE READY (advisory, never dispatch): 1 ready: ready-1' \
    "a heartbeat drain prints the ready line"
  ack_drain_err "$state" "$err" >/dev/null || fail "heartbeat drain ack failed"
  append_wake "$state" signal task.status 'signal: task.status' || fail "signal append failed"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "signal drain failed"
  assert_not_contains "$(cat "$out")" 'QUEUE READY' "a non-heartbeat drain prints no ready line"
  ack_drain_err "$state" "$err" >/dev/null || fail "signal drain ack failed"
  append_wake "$dir/state" heartbeat heartbeat heartbeat || fail "foreign heartbeat append failed"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$dir/state" "$DRAIN" > "$out" 2> "$err" \
    || fail "foreign-state drain failed"
  assert_contains "$(cat "$out")" 'heartbeat' "the foreign heartbeat row is presented"
  assert_not_contains "$(cat "$out")" 'QUEUE READY' \
    "a drain over another state directory never reads this home's backlog"
  pass "the drain prints its own home's ready line only on a heartbeat row"
}

test_drain_bounds_a_hung_backlog_read() {
  local dir state out err started elapsed
  fresh_home
  dir=$(make_case drain-hung)
  state="$HOME_DIR/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$dir/fakebin/tasks-axi"
  chmod +x "$dir/fakebin/tasks-axi"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat append failed"
  started=$(date +%s)
  PATH="$dir/fakebin:$PATH" FM_QUEUE_READY_TIMEOUT=1 FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "hung-read drain failed"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 15 ] || fail "a hung backlog read held the drain for ${elapsed}s"
  assert_contains "$(cat "$out")" 'heartbeat' "the heartbeat row is still presented"
  assert_not_contains "$(cat "$out")" 'QUEUE READY' "a hung read prints no ready line"
  pass "a hung backlog read is bounded and never blocks the drain"
}

test_help_and_usage
test_empty_backlog_is_silent
test_structured_readiness
test_cleared_blocker_makes_item_ready
test_long_ready_set_is_capped
test_unreadable_backlog_is_silent
test_drain_prints_line_only_on_heartbeat
test_drain_bounds_a_hung_backlog_read
