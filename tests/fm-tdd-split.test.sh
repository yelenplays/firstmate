#!/usr/bin/env bash
# Behavior tests for the tdd-split ship profile: bin/fm-tdd-split-lib.sh's
# brief contract and test-seat done gate, and bin/fm-tdd-split.sh's handoff,
# which proves the seat's tests fail on the base before it relaunches the task
# onto the implementer.
# shellcheck disable=SC2016 # single-quoted commands and code spans expand later, in the brief's shell.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tdd-split)
fm_git_identity fmtest fmtest@example.invalid

RED_COMMAND='for t; do bash "$t" || exit 1; done'

# A tdd-split case: a worker copy on fm/<id> with origin/main fetched, a seat
# meta, a brief declaring <command>, and a stub bin/fm-control.sh that records
# its arguments. Sets CASE_STATE, CASE_DATA, CASE_WT, CASE_META, CASE_CONTROL_LOG.
new_case() {  # <id> [<command>]
  local id=$1 command=${2-$RED_COMMAND} dir="$TMP_ROOT/$1"
  CASE_STATE="$dir/state"
  CASE_DATA="$dir/data"
  CASE_WT="$dir/wt"
  CASE_META="$CASE_STATE/$id.meta"
  CASE_CONTROL_LOG="$dir/control.log"
  mkdir -p "$CASE_STATE" "$CASE_DATA/$id"
  fm_git_worktree "$dir/repo" "$CASE_WT" "fm/$id"
  git -C "$CASE_WT" fetch -q origin
  printf '%s\n' kind=ship mode=no-mistakes "worktree=$CASE_WT" base_branch=main \
    harness=claude model=claude-opus-5-5 effort=medium tdd_split=tests \
    tdd_split_impl_harness=opencode tdd_split_impl_model=opencode-go/deepseek-v4.1-flash \
    tdd_split_impl_effort=medium >"$CASE_META"
  printf '# Brief\n\n## Captain'"'"'s intent\nAdd feature.sh.\n\nFail-to-pass command: `%s`\n' "$command" \
    >"$CASE_DATA/$id/brief.md"
  cat >"$dir/fm-control.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$CASE_CONTROL_LOG"
exit \${STUB_CONTROL_RC:-0}
EOF
  chmod +x "$dir/fm-control.sh"
}

# Commits <path> with <content> in the case's worker copy.
seat_commit() {  # <path> <content>
  mkdir -p "$(dirname "$CASE_WT/$1")"
  printf '%s\n' "$2" >"$CASE_WT/$1"
  git -C "$CASE_WT" add -- "$1"
  git -C "$CASE_WT" commit -q -m "add $1"
}

report() {  # <id> <line>
  printf '%s\n' "$2" >>"$CASE_STATE/$1.status"
}

handoff() {  # <id> [args...]
  local id=$1
  shift
  FM_STATE_OVERRIDE="$CASE_STATE" FM_DATA_OVERRIDE="$CASE_DATA" \
    FM_CONTROL_BIN="$TMP_ROOT/$id/fm-control.sh" \
    bash "$ROOT/bin/fm-tdd-split.sh" handoff "$id" "$@" 2>&1
}

meta_lines() {  # <key>
  sed -n "s/^$1=//p" "$CASE_META"
}

test_check_command_needs_exactly_one_line() {
  local brief="$TMP_ROOT/brief.md" got
  printf 'Intro.\nFail-to-pass command: `bash tests/x.test.sh`\n' >"$brief"
  got=$(fm_tdd_split_check_command "$brief") || fail "a single fail-to-pass line was not read"
  [ "$got" = 'bash tests/x.test.sh' ] || fail "fail-to-pass command read as '$got'"

  printf 'Intro.\n```\nFail-to-pass command: `fenced`\n```\nFail-to-pass command: `real`\n' >"$brief"
  got=$(fm_tdd_split_check_command "$brief") || fail "a fenced example blocked the real line"
  [ "$got" = real ] || fail "a fenced example was read as the command: '$got'"

  printf 'Fail-to-pass command: `one`\nFail-to-pass command: `two`\n' >"$brief"
  fm_tdd_split_check_command "$brief" >/dev/null && fail "two fail-to-pass lines were accepted"
  printf 'Fail-to-pass command: bash tests/x.test.sh\n' >"$brief"
  fm_tdd_split_check_command "$brief" >/dev/null && fail "a command outside a code span was accepted"
  printf 'No command here.\n' >"$brief"
  fm_tdd_split_check_command "$brief" >/dev/null && fail "a brief without the line was accepted"
  fm_tdd_split_check_command "$TMP_ROOT/missing.md" >/dev/null && fail "a missing brief was accepted"
  pass "the brief declares exactly one fail-to-pass command"
}

test_seat_done_gate() {
  local reason rc
  new_case gate
  reason=$(fm_dod_accept_ship_done ship no-mistakes "$CASE_WT" "$TMP_ROOT/gate/repo" \
    'done: PR https://example.test/o/r/pull/1 checks green' "$CASE_STATE" gate "$CASE_META")
  rc=$?
  [ "$rc" -eq 1 ] || fail "the test seat's ship done was accepted"
  assert_contains "$reason" "done: tests-ready <sha>" "refusal did not name the seat's report"

  reason=$(fm_dod_accept_ship_done ship no-mistakes "$CASE_WT" "$TMP_ROOT/gate/repo" \
    'done: tests-ready' "$CASE_STATE" gate "$CASE_META")
  [ "$?" -eq 1 ] || fail "tests-ready with no committed test was accepted"
  assert_contains "$reason" "committed no tests" "empty-seat refusal did not say so"

  seat_commit tests/feature.test.sh '[ -f feature.sh ]'
  fm_dod_accept_ship_done ship no-mistakes "$CASE_WT" "$TMP_ROOT/gate/repo" \
    "done: tests-ready $(git -C "$CASE_WT" rev-parse HEAD)" "$CASE_STATE" gate "$CASE_META" >/dev/null \
    || fail "a committed failing test was refused at tests-ready"

  printf 'draft\n' >"$CASE_WT/tests/draft.test.sh"
  reason=$(fm_dod_accept_ship_done ship no-mistakes "$CASE_WT" "$TMP_ROOT/gate/repo" \
    'done: tests-ready' "$CASE_STATE" gate "$CASE_META")
  [ "$?" -eq 1 ] || fail "tests-ready with an uncommitted test was accepted"
  assert_contains "$reason" "uncommitted changes" "dirty-seat refusal did not say so"
  rm -f "$CASE_WT/tests/draft.test.sh"

  seat_commit feature.sh 'echo done'
  reason=$(fm_dod_accept_ship_done ship no-mistakes "$CASE_WT" "$TMP_ROOT/gate/repo" \
    'done: tests-ready' "$CASE_STATE" gate "$CASE_META")
  [ "$?" -eq 1 ] || fail "tests-ready with production code was accepted"
  assert_contains "$reason" "not tests: feature.sh" "refusal did not name the production file"

  sed -i.bak 's/^tdd_split=tests$/tdd_split=implement/' "$CASE_META"
  fm_dod_accept_ship_done ship no-mistakes "$CASE_WT" "$TMP_ROOT/gate/repo" \
    'done: fixed' "$CASE_STATE" gate "$CASE_META" >/dev/null \
    || fail "the implementer's done was held to the seat's gate"
  pass "the test seat may only report committed tests as tests-ready"
}

test_handoff_relaunches_onto_the_implementer() {
  local out head note
  new_case ok
  seat_commit tests/feature.test.sh 'touch side-effect; [ -f feature.sh ]'
  head=$(git -C "$CASE_WT" rev-parse HEAD)
  report ok "done: tests-ready $head"
  out=$(handoff ok) || fail "a red handoff was refused: $out"
  assert_contains "$out" "handed over at $head to opencode/opencode-go/deepseek-v4.1-flash" "handoff did not report the implementer"
  [ "$(sed -n 1,9p "$CASE_CONTROL_LOG" | tr '\n' ' ')" = "ok relaunch --harness opencode --model opencode-go/deepseek-v4.1-flash --effort medium --note " ] \
    || fail "relaunch arguments were: $(tr '\n' ' ' <"$CASE_CONTROL_LOG")"
  note=$(sed -n 10p "$CASE_CONTROL_LOG")
  assert_contains "$note" "$head" "relaunch note did not name the seat's head"
  [ "$(meta_lines tdd_split)" = implement ] || fail "meta did not record tdd_split=implement: $(cat "$CASE_META")"
  [ "$(meta_lines tdd_split_tests)" = "$head" ] || fail "meta did not record the handed-over tests"
  [ ! -e "$CASE_WT/side-effect" ] || fail "the red run wrote into the worker copy"
  assert_contains "$(cat "$CASE_DATA/ok/tdd-split-red.log")" "head=$head exit=1" "red log did not record the run"
  out=$(handoff ok) && fail "a second handoff on the implementer was accepted"
  assert_contains "$out" "not a tdd-split ship on its test seat" "repeat handoff refusal did not name the phase"
  pass "handoff proves the tests red on the base and relaunches onto the implementer"
}

test_handoff_refuses_tests_that_prove_nothing() {
  local out
  new_case green
  seat_commit tests/feature.test.sh 'true'
  report green "done: tests-ready"
  out=$(handoff green) && fail "tests passing on the base were handed over"
  assert_contains "$out" "pass on the base" "green refusal did not say so"
  [ ! -e "$CASE_CONTROL_LOG" ] || fail "a green handoff relaunched the task"
  [ "$(meta_lines tdd_split)" = tests ] || fail "a refused handoff left the seat phase"

  new_case missing 'no-such-command-fm-tdd-split "$@"'
  seat_commit tests/feature.test.sh 'false'
  report missing "done: tests-ready"
  out=$(handoff missing) && fail "a command that could not run was taken as red"
  assert_contains "$out" "could not run (exit 127)" "exit-127 refusal did not say so"

  new_case slow 'sleep 5'
  seat_commit tests/feature.test.sh 'false'
  report slow "done: tests-ready"
  out=$(handoff slow --timeout 1) && fail "a timed-out command was taken as red"
  assert_contains "$out" "hit its 1s bound" "timeout refusal did not say so"
  pass "handoff refuses a run that is green, cannot run, or times out"
}

test_handoff_refuses_an_unready_seat() {
  local out
  new_case early
  seat_commit tests/feature.test.sh 'false'
  report early "working: writing tests"
  out=$(handoff early) && fail "a seat that has not reported tests-ready was handed over"
  assert_contains "$out" "has not reported done: tests-ready" "refusal did not name the missing report"

  new_case mixed
  seat_commit tests/feature.test.sh '[ -f feature.sh ]'
  seat_commit feature.sh 'echo half'
  report mixed "done: tests-ready"
  out=$(handoff mixed) && fail "a seat that changed production code was handed over"
  assert_contains "$out" "not tests: feature.sh" "refusal did not name the production file"

  new_case nocmd
  printf '# Brief\n' >"$CASE_DATA/nocmd/brief.md"
  seat_commit tests/feature.test.sh 'false'
  report nocmd "done: tests-ready"
  out=$(handoff nocmd) && fail "a brief without a fail-to-pass command was handed over"
  assert_contains "$out" "declares no single Fail-to-pass command:" "refusal did not name the brief contract"

  new_case failed-relaunch
  seat_commit tests/feature.test.sh 'false'
  report failed-relaunch "done: tests-ready"
  out=$(STUB_CONTROL_RC=1 handoff failed-relaunch) && fail "a failed relaunch reported success"
  assert_contains "$out" "handoff can be run again" "failed-relaunch refusal did not say it can be retried"
  [ "$(meta_lines tdd_split)" = tests ] || fail "a failed relaunch left the seat phase"
  pass "handoff refuses a seat that is not ready to hand over"
}

test_check_command_needs_exactly_one_line
test_seat_done_gate
test_handoff_relaunches_onto_the_implementer
test_handoff_refuses_tests_that_prove_nothing
test_handoff_refuses_an_unready_seat

echo "all fm-tdd-split tests passed"
