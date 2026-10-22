#!/usr/bin/env bash
# Behavior tests for the tdd-split ship profile: bin/fm-tdd-split-lib.sh's
# brief contract and test-seat done gate, and bin/fm-tdd-split.sh's handoff,
# which proves the seat's tests fail on the base before it relaunches the task
# onto the implementer, its dispute route back to the seat, and its optional
# mutation gate.
# shellcheck disable=SC2016 # single-quoted commands and code spans expand later, in the brief's shell.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tdd-split)
# The no-mistakes history the test-authoring gate reads stays inside the fixture.
export NM_HOME="$TMP_ROOT/nm-home"
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

tdd_split() {  # <subcommand> <id> [args...]
  local sub=$1 id=$2
  shift 2
  FM_STATE_OVERRIDE="$CASE_STATE" FM_DATA_OVERRIDE="$CASE_DATA" \
    FM_CONTROL_BIN="$TMP_ROOT/$id/fm-control.sh" \
    bash "$ROOT/bin/fm-tdd-split.sh" "$sub" "$id" "$@" 2>&1
}

handoff() {  # <id> [args...]
  tdd_split handoff "$@"
}

# Hands the case's seat over and records what the implementer's relaunch would:
# its banned model. Sets SEAT_HEAD.
to_implementer() {  # <id>
  SEAT_HEAD=$(git -C "$CASE_WT" rev-parse HEAD)
  report "$1" "done: tests-ready $SEAT_HEAD"
  handoff "$1" >/dev/null || fail "the setup handoff of $1 was refused"
  printf '%s\n' test_ban_model=opencode-go/deepseek-v4.1-flash >>"$CASE_META"
  rm -f "$CASE_CONTROL_LOG"
}

# The relaunch the stub fm-control.sh recorded, without its note.
relaunched_onto() {
  sed -n 1,9p "$CASE_CONTROL_LOG" | tr '\n' ' '
}

SEAT_RELAUNCH="relaunch --harness claude --model claude-opus-5-5 --effort medium --note "

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
  [ "$(meta_lines test_ban_since)" = "$head" ] || fail "meta did not start the implementer's test ban at the seat's head"
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

test_mutation_command_is_optional_and_single() {
  local brief="$TMP_ROOT/mutation-brief.md" got
  printf 'Fail-to-pass command: `a`\nMutation command: `mutmut run`\n' >"$brief"
  got=$(fm_tdd_split_mutation_command "$brief") || fail "a single mutation line was not read"
  [ "$got" = 'mutmut run' ] || fail "mutation command read as '$got'"
  printf 'Fail-to-pass command: `a`\n' >"$brief"
  fm_tdd_split_mutation_command "$brief" >/dev/null && fail "a brief without a mutation line declared one"
  printf 'Mutation command: `one`\nMutation command: `two`\n' >"$brief"
  fm_tdd_split_mutation_command "$brief" >/dev/null && fail "two mutation lines were accepted"
  pass "the brief declares at most one mutation command"
}

test_dispute_routes_back_to_the_seat() {
  local out impl_head fix_head status_tail
  new_case dispute
  seat_commit tests/feature.test.sh '[ "$(cat feature.sh 2>/dev/null)" = "echo wrong" ]'
  to_implementer dispute
  seat_commit feature.sh 'echo done'
  impl_head=$(git -C "$CASE_WT" rev-parse HEAD)
  printf 'pr=https://example.test/o/r/pull/9\n' >>"$CASE_META"

  out=$(tdd_split dispute dispute) && fail "a dispute with no open key was accepted"
  assert_contains "$out" "no open blocked [key=test-dispute]" "refusal did not name the missing report"
  report dispute "blocked [key=test-dispute]: tests/feature.test.sh: it expects the wrong output"
  out=$(tdd_split dispute dispute) || fail "an open dispute was refused: $out"
  assert_contains "$out" "dispute accepted at $impl_head" "dispute did not report the head"
  [ "$(relaunched_onto)" = "dispute $SEAT_RELAUNCH" ] || fail "dispute relaunched with: $(relaunched_onto)"
  assert_contains "$(sed -n 10p "$CASE_CONTROL_LOG")" "it expects the wrong output" "seat note did not carry the dispute"
  [ "$(meta_lines tdd_split)" = tests ] || fail "dispute did not record tdd_split=tests"
  [ "$(meta_lines tdd_split_dispute_head)" = "$impl_head" ] || fail "dispute did not record the implementer's head"
  status_tail=$(tail -1 "$CASE_STATE/dispute.status")
  assert_contains "$status_tail" "resolved [key=test-dispute]" "dispute did not close its key"

  # Back on the seat, the implementer's code is not the seat's change, but
  # any new production change is.
  seat_commit tests/feature.test.sh '[ "$(cat feature.sh 2>/dev/null)" = "echo done" ]'
  fix_head=$(git -C "$CASE_WT" rev-parse HEAD)
  fm_dod_accept_ship_done ship no-mistakes "$CASE_WT" "$TMP_ROOT/dispute/repo" \
    "done: tests-ready $fix_head" "$CASE_STATE" dispute "$CASE_META" >/dev/null \
    || fail "the seat's fixed test was refused after a dispute"
  seat_commit other.sh 'echo more'
  out=$(fm_dod_accept_ship_done ship no-mistakes "$CASE_WT" "$TMP_ROOT/dispute/repo" \
    'done: tests-ready' "$CASE_STATE" dispute "$CASE_META")
  [ "$?" -eq 1 ] || fail "a seat production change after a dispute was accepted"
  assert_contains "$out" "not tests since $impl_head: other.sh" "refusal did not measure from the disputed head"
  git -C "$CASE_WT" reset -q --hard "$fix_head"

  # The fixed test passes with the implementer's code, yet the second
  # handoff proves it red on the base alone, and moves the ban baseline.
  report dispute "done: tests-ready $fix_head"
  out=$(handoff dispute) || fail "the post-dispute handoff was refused: $out"
  [ "$(meta_lines test_ban_since)" = "$fix_head" ] || fail "the second handoff left test_ban_since at $(meta_lines test_ban_since)"
  [ -z "$(meta_lines tdd_split_dispute_head)" ] || fail "the second handoff kept tdd_split_dispute_head"
  [ "$(meta_lines tdd_split)" = implement ] || fail "the second handoff did not return to the implementer"
  pass "an accepted dispute sends the task back to the seat, which then hands over again"
}

test_dispute_refusals() {
  local out
  new_case dispute-edit
  seat_commit tests/feature.test.sh '[ -f feature.sh ]'
  to_implementer dispute-edit
  seat_commit tests/feature.test.sh 'true'
  report dispute-edit "blocked [key=test-dispute]: tests/feature.test.sh: too strict"
  out=$(tdd_split dispute dispute-edit) && fail "a dispute after the implementer edited the test was accepted"
  assert_contains "$out" "no test authoring" "refusal did not name the test edit"
  [ ! -e "$CASE_CONTROL_LOG" ] || fail "a refused dispute relaunched the task"

  new_case dispute-dirty
  seat_commit tests/feature.test.sh '[ -f feature.sh ]'
  to_implementer dispute-dirty
  printf 'wip\n' >"$CASE_WT/feature.sh"
  report dispute-dirty "blocked [key=test-dispute]: tests/feature.test.sh: too strict"
  out=$(tdd_split dispute dispute-dirty) && fail "a dispute over uncommitted work was accepted"
  assert_contains "$out" "uncommitted changes" "refusal did not name the uncommitted work"

  new_case dispute-seat
  report dispute-seat "blocked [key=test-dispute]: tests/feature.test.sh: too strict"
  out=$(tdd_split dispute dispute-seat) && fail "a dispute on the test seat was accepted"
  assert_contains "$out" "not a tdd-split ship on its implementer" "refusal did not name the phase"
  pass "a dispute is refused off the implementer, over uncommitted work, or after a test edit"
}

test_mutation_gate() {
  local out rc head
  new_case mutation-none
  seat_commit tests/feature.test.sh '[ -f feature.sh ]'
  to_implementer mutation-none
  report mutation-none "done: PR https://example.test/o/r/pull/3 checks green"
  out=$(tdd_split mutation mutation-none) && fail "the mutation gate ran without a mutation command"
  assert_contains "$out" "declares no single Mutation command:" "refusal did not name the brief contract"

  new_case mutation-pass
  printf 'Mutation command: `[ "$1" = tests/feature.test.sh ] && [ -f feature.sh ]`\n' >>"$CASE_DATA/mutation-pass/brief.md"
  seat_commit tests/feature.test.sh '[ -f feature.sh ]'
  to_implementer mutation-pass
  seat_commit feature.sh 'echo done'
  report mutation-pass "working: implementing"
  out=$(tdd_split mutation mutation-pass) && fail "the mutation gate ran before the implementer's done"
  assert_contains "$out" "has not reported done:" "refusal did not name the missing done"
  report mutation-pass "done: PR https://example.test/o/r/pull/3 checks green"
  out=$(tdd_split mutation mutation-pass) || fail "a passing mutation run was refused: $out"
  assert_contains "$out" "mutation gate passed at $(git -C "$CASE_WT" rev-parse HEAD)" "pass did not name the head"
  [ ! -e "$CASE_CONTROL_LOG" ] || fail "a passing mutation run relaunched the task"

  new_case mutation-fail
  printf 'Mutation command: `echo 3 mutants survived; exit 1`\n' >>"$CASE_DATA/mutation-fail/brief.md"
  seat_commit tests/feature.test.sh '[ -f feature.sh ]'
  to_implementer mutation-fail
  seat_commit feature.sh 'echo done'
  head=$(git -C "$CASE_WT" rev-parse HEAD)
  report mutation-fail "done: PR https://example.test/o/r/pull/3 checks green"
  out=$(tdd_split mutation mutation-fail)
  rc=$?
  [ "$rc" -eq 3 ] || fail "a failing mutation run exited $rc: $out"
  [ "$(relaunched_onto)" = "mutation-fail $SEAT_RELAUNCH" ] || fail "mutation failure relaunched with: $(relaunched_onto)"
  assert_contains "$(sed -n 10p "$CASE_CONTROL_LOG")" "mutants of the implementation survive" "seat note did not explain the mutation failure"
  [ "$(meta_lines tdd_split_dispute_head)" = "$head" ] || fail "mutation failure did not record the implementer's head"
  assert_contains "$(cat "$CASE_DATA/mutation-fail/tdd-split-mutation.log")" "3 mutants survived" "mutation log did not keep the output"

  new_case mutation-broken
  printf 'Mutation command: `no-such-mutation-tool`\n' >>"$CASE_DATA/mutation-broken/brief.md"
  seat_commit tests/feature.test.sh '[ -f feature.sh ]'
  to_implementer mutation-broken
  report mutation-broken "done: PR https://example.test/o/r/pull/3 checks green"
  out=$(tdd_split mutation mutation-broken)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a mutation command that could not run exited $rc"
  assert_contains "$out" "could not run (exit 127)" "refusal did not say the command could not run"
  [ ! -e "$CASE_CONTROL_LOG" ] || fail "a mutation command that could not run relaunched the task"
  pass "the mutation gate passes, sends surviving mutants back to the seat, and refuses a run that proves nothing"
}

# An implementer escalated onto Opus carries no test ban, so the mutation gate
# is the only check that reads the branch's base.
test_mutation_gate_refuses_an_unreadable_base() {
  local out rc
  new_case mutation-no-base
  printf 'Mutation command: `[ "$#" -gt 0 ] || { echo ran with no tests; exit 0; }`\n' >>"$CASE_DATA/mutation-no-base/brief.md"
  seat_commit tests/feature.test.sh '[ -f feature.sh ]'
  to_implementer mutation-no-base
  sed -i.bak '/^test_ban_model=/d' "$CASE_META"
  seat_commit feature.sh 'echo done'
  report mutation-no-base "done: PR https://example.test/o/r/pull/3 checks green"
  git -C "$CASE_WT" update-ref refs/remotes/origin/main \
    "$(git -C "$CASE_WT" commit-tree "$(git -C "$CASE_WT" mktree </dev/null)" -m unrelated)"
  out=$(tdd_split mutation mutation-no-base)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a mutation gate whose base has no merge-base exited $rc: $out"
  assert_contains "$out" "no merge-base" "refusal did not name the unreadable base"
  case "$out" in *"mutation gate passed"*) fail "a mutation run with no test files passed the gate: $out" ;; esac
  [ ! -e "$CASE_CONTROL_LOG" ] || fail "a mutation gate whose base cannot be read relaunched the task"
  pass "the mutation gate refuses, rather than runs without tests, when the branch's base cannot be read"
}

test_check_command_needs_exactly_one_line
test_mutation_command_is_optional_and_single
test_seat_done_gate
test_handoff_relaunches_onto_the_implementer
test_handoff_refuses_tests_that_prove_nothing
test_handoff_refuses_an_unready_seat
test_dispute_routes_back_to_the_seat
test_dispute_refusals
test_mutation_gate
test_mutation_gate_refuses_an_unreadable_base

echo "all fm-tdd-split tests passed"
