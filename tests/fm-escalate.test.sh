#!/usr/bin/env bash
# Behavior tests for bin/fm-escalate.sh, the model escalation ladder: it counts
# the current incarnation's failed rounds from cross-review verdicts and
# recorded failures, relaunches one step stronger after two, and hands a task
# already on the top step to the captain.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-escalate)
fm_git_identity fmtest fmtest@example.invalid
NOW=$(date -u +%s)

# An escalation case: a worker copy, a task record on <harness>/<model>/<effort>
# whose incarnation started 100 seconds ago, and a stub bin/fm-control.sh that
# records its arguments. Sets CASE_STATE, CASE_DATA, CASE_WT, CASE_META,
# CASE_CONTROL_LOG.
new_case() {  # <id> <harness> <model> <effort>
  local id=$1 dir="$TMP_ROOT/$1"
  CASE_STATE="$dir/state"
  CASE_DATA="$dir/data"
  CASE_WT="$dir/wt"
  CASE_META="$CASE_STATE/$id.meta"
  CASE_CONTROL_LOG="$dir/control.log"
  mkdir -p "$CASE_STATE" "$CASE_DATA/$id"
  fm_git_worktree "$dir/repo" "$CASE_WT" "fm/$id"
  printf '%s\n' kind=ship mode=no-mistakes "worktree=$CASE_WT" base_branch=main \
    "harness=$2" "model=$3" "effort=$4" "spawn_gen=s$((NOW - 100)).123.abc" >"$CASE_META"
  cat >"$dir/fm-control.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$CASE_CONTROL_LOG"
EOF
  chmod +x "$dir/fm-control.sh"
}

escalate() {  # <subcommand> <id> [args...]
  local sub=$1 id=$2
  shift 2
  FM_STATE_OVERRIDE="$CASE_STATE" FM_DATA_OVERRIDE="$CASE_DATA" \
    FM_CONTROL_BIN="$TMP_ROOT/$id/fm-control.sh" \
    bash "$ROOT/bin/fm-escalate.sh" "$sub" "$id" "$@" 2>&1
}

# Commits a change in the case's worker copy, as a round of work.
work_round() {  # <n>
  printf 'round %s\n' "$1" >"$CASE_WT/work.txt"
  git -C "$CASE_WT" add work.txt
  git -C "$CASE_WT" commit -q -m "round $1"
}

review_record() {  # <id> <epoch> <head> <verdict> <accepted>
  jq -cn --arg at "$(date -u -r "$2" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$2" +%Y-%m-%dT%H:%M:%SZ)" \
    --arg head "$3" --arg verdict "$4" --argjson accepted "$5" \
    '{at: $at, head: $head, verdict: $verdict, accepted: $accepted}' >>"$CASE_DATA/$1/cross-review.jsonl"
}

value() {  # <key> <check-output>
  printf '%s\n' "$2" | sed -n "s/^$1=//p"
}

test_two_failed_rounds_escalate_a_cheap_model_to_sonnet() {
  local out
  new_case cheap opencode opencode-go/deepseek-v4.1-flash medium
  printf '%s\n' tdd_split=implement tdd_split_impl_harness=opencode \
    tdd_split_impl_model=opencode-go/deepseek-v4.1-flash tdd_split_impl_effort=medium >>"$CASE_META"
  work_round 1
  out=$(escalate record-failure cheap --reason "done refused: tests changed") || fail "record-failure failed: $out"
  [ "$(value failed_rounds "$out")" = 1 ] || fail "one failure counted as: $out"
  out=$(escalate record-failure cheap --reason "same head again")
  [ "$(value failed_rounds "$out")" = 1 ] || fail "a second failure on the same head counted as a new round: $out"
  [ "$(value action "$out")" = none ] || fail "one failed round asked for: $out"

  work_round 2
  escalate record-failure cheap --reason "review failed" >/dev/null
  out=$(escalate check cheap)
  [ "$(value failed_rounds "$out")" = 2 ] || fail "two heads counted as: $out"
  [ "$(value action "$out")" = relaunch ] || fail "two failed rounds asked for: $out"
  [ "$(value next_model "$out")" = claude-sonnet-5-5 ] && [ "$(value next_effort "$out")" = medium ] \
    || fail "deepseek's next step was: $out"

  out=$(escalate run cheap) || fail "the escalation run failed: $out"
  assert_contains "$out" "relaunched onto claude/claude-sonnet-5-5 (medium)" "run did not report the relaunch"
  [ "$(sed -n 1,9p "$CASE_CONTROL_LOG" | tr '\n' ' ')" = "cheap relaunch --harness claude --model claude-sonnet-5-5 --effort medium --note " ] \
    || fail "relaunch arguments were: $(tr '\n' ' ' <"$CASE_CONTROL_LOG")"
  assert_contains "$(sed -n 10p "$CASE_CONTROL_LOG")" "2 rounds" "relaunch note did not name the failed rounds"
  [ "$(sed -n 's/^tdd_split_impl_model=//p' "$CASE_META")" = claude-sonnet-5-5 ] \
    || fail "the tdd-split implementer was not moved to the escalated step: $(cat "$CASE_META")"
  pass "two failed rounds on a cheap model relaunch it onto Sonnet medium"
}

test_sonnet_escalates_to_opus_and_opus_to_the_captain() {
  local out rc
  new_case sonnet claude claude-sonnet-5-5 medium
  work_round 1
  escalate record-failure sonnet --reason one >/dev/null
  work_round 2
  out=$(escalate record-failure sonnet --reason two)
  [ "$(value next_model "$out")" = claude-opus-5-5 ] && [ "$(value next_effort "$out")" = medium ] \
    || fail "Sonnet's next step was: $out"

  new_case opus claude claude-opus-5-5 medium
  work_round 1
  escalate record-failure opus --reason one >/dev/null
  work_round 2
  escalate record-failure opus --reason two >/dev/null
  out=$(escalate run opus)
  rc=$?
  [ "$rc" -eq 3 ] || fail "two failed rounds on Opus exited $rc: $out"
  [ "$(value action "$out")" = captain ] || fail "two failed rounds on Opus asked for: $out"
  assert_contains "$(value reason "$out")" "top of the escalation ladder" "captain reason did not say why"
  [ ! -e "$CASE_CONTROL_LOG" ] || fail "Opus at the top of the ladder was relaunched"
  pass "Sonnet escalates to Opus medium, and Opus goes to the captain"
}

test_an_unlisted_model_escalates_to_opus_never_down() {
  local model out
  for model in gemini-3.5-pro gpt-6-luna; do
    new_case "unlisted-$model" codex "$model" high
    work_round 1
    escalate record-failure "unlisted-$model" --reason one >/dev/null
    work_round 2
    out=$(escalate record-failure "unlisted-$model" --reason two)
    [ "$(value action "$out")" = relaunch ] || fail "two failed rounds on $model asked for: $out"
    [ "$(value next_model "$out")" = claude-opus-5-5 ] && [ "$(value next_effort "$out")" = medium ] \
      || fail "$model, which may be stronger than Sonnet, stepped to: $out"
  done
  pass "a model the ladder does not list as cheap escalates to Opus medium, never down to Sonnet"
}

test_rounds_count_only_this_incarnations_failures() {
  local out head_a head_b
  new_case counted opencode zhipu/glm-5.2 medium
  work_round 1
  head_a=$(git -C "$CASE_WT" rev-parse HEAD)
  work_round 2
  head_b=$(git -C "$CASE_WT" rev-parse HEAD)
  review_record counted $((NOW - 500)) "$head_a" failure true
  review_record counted $((NOW - 10)) "$head_a" failure false
  review_record counted $((NOW - 10)) "$head_b" success true
  printf '%s\n' "{\"at\":\"x\",\"head\":\"$head_b\",\"reason\":\"old\",\"spawn_gen\":\"s1.1.old\"}" \
    >>"$CASE_DATA/counted/rounds.jsonl"
  out=$(escalate check counted)
  [ "$(value failed_rounds "$out")" = 0 ] \
    || fail "an earlier incarnation's, a rejected, or a passing record counted: $out"

  review_record counted $((NOW - 10)) "$head_a" failure true
  escalate record-failure counted --head "$head_b" --reason "pipeline gave up" >/dev/null
  out=$(escalate check counted)
  [ "$(value failed_rounds "$out")" = 2 ] || fail "a review failure and a recorded failure counted as: $out"
  [ "$(value heads "$out")" = "$head_a,$head_b" ] || fail "failed heads were: $out"
  [ "$(value action "$out")" = relaunch ] || fail "two counted rounds on GLM asked for: $out"
  pass "only accepted failures and recorded failures since the incarnation began count"
}

test_usage_errors() {
  local out
  new_case usage claude claude-sonnet-5-5 medium
  out=$(escalate record-failure usage) && fail "record-failure without a reason was accepted"
  out=$(escalate check usage --reason x) && fail "check accepted record-failure options"
  out=$(escalate check missing-task) && fail "a task with no record was checked"
  assert_contains "$out" "has no task record" "missing-record refusal did not say so"
  pass "malformed calls are refused"
}

test_two_failed_rounds_escalate_a_cheap_model_to_sonnet
test_sonnet_escalates_to_opus_and_opus_to_the_captain
test_an_unlisted_model_escalates_to_opus_never_down
test_rounds_count_only_this_incarnations_failures
test_usage_errors

echo "all fm-escalate tests passed"
