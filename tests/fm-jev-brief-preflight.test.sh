#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-brief-preflight.sh, its deterministic rule
# (fm_brief_preflight_verdict in bin/fm-dod-lib.sh), and its spawn caller.
# A recording fake curl on PATH proves no case makes a network call, even with
# a Jev key configured.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TOOL="$ROOT/bin/fm-jev-brief-preflight.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF_TOOL="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-brief-preflight)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
BRIEF="$TMP_ROOT/brief.md"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'
TASK_ID='pager-off-by-one'
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$LOG"

unset TYPESAFE_API_KEY OPENROUTER_API_KEY TYPESAFE_API_KEY_PRIVATE \
  OPENROUTER_API_KEY_PRIVATE JEV_ROUTE JEV_MODEL JEV_TIMEOUT \
  JEV_CONFIDENCE_FLOOR JEV_STATE_MAX_BYTES FM_JEV_BRIEF_PREFLIGHT

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_CURL_LOG:?}/argv"
exit 7
SH
chmod +x "$FAKEBIN/curl"
export FAKE_CURL_LOG="$LOG"

# Jev's recorded answers on the full grid of structural facts the preflight
# reads: kind, has_task, has_definition_of_done, has_captain_intent,
# has_firstmate_spec. Jev answered missing_acceptance on all 16 rows without a
# definition of done and need_human on all 16 rows with one.
GRID='ship|false|false|false|false|missing_acceptance
ship|false|false|false|true|missing_acceptance
ship|false|false|true|false|missing_acceptance
ship|false|false|true|true|missing_acceptance
ship|false|true|false|false|need_human
ship|false|true|false|true|need_human
ship|false|true|true|false|need_human
ship|false|true|true|true|need_human
ship|true|false|false|false|missing_acceptance
ship|true|false|false|true|missing_acceptance
ship|true|false|true|false|missing_acceptance
ship|true|false|true|true|missing_acceptance
ship|true|true|false|false|need_human
ship|true|true|false|true|need_human
ship|true|true|true|false|need_human
ship|true|true|true|true|need_human
scout|false|false|false|false|missing_acceptance
scout|false|false|false|true|missing_acceptance
scout|false|false|true|false|missing_acceptance
scout|false|false|true|true|missing_acceptance
scout|false|true|false|false|need_human
scout|false|true|false|true|need_human
scout|false|true|true|false|need_human
scout|false|true|true|true|need_human
scout|true|false|false|false|missing_acceptance
scout|true|false|false|true|missing_acceptance
scout|true|false|true|false|missing_acceptance
scout|true|false|true|true|missing_acceptance
scout|true|true|false|false|need_human
scout|true|true|false|true|need_human
scout|true|true|true|false|need_human
scout|true|true|true|true|need_human'

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

record_path() {
  printf '%s' "$HOME_DIR/state/${1:-$TASK_ID}.jev-brief-preflight.jsonl"
}

# Every run carries a Jev key so a regression back to a model call would reach
# the recording fake curl.
run_preflight() {
  local __exit=$1 __out=$2 __err=$3
  shift 3
  local _out _errfile _code
  _errfile="$TMP_ROOT/stderr"
  reset_log
  rm -f "$(record_path)"
  _code=0
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=$TS_KEY \
    "$TOOL" "$@" 2> "$_errfile") || _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$_errfile")"
}

# write_grid_brief <has_task> <has_dod> <has_intent> <has_spec>
# Writes a brief with exactly the requested structure. Intent and spec live
# under # Task, so they are reachable only when has_task is true.
write_grid_brief() {
  local has_task=$1 has_dod=$2 has_intent=$3 has_spec=$4
  {
    printf 'You are a crewmate.\n\n'
    if [ "$has_task" = true ]; then
      printf '# Task\n'
      if [ "$has_intent" = true ]; then printf "## Captain's intent\nFix the pager.\n\n"; fi
      if [ "$has_spec" = true ]; then printf '## Firstmate spec\nChange only pager.sh.\n\n'; fi
      printf 'Fix the off-by-one in pager.sh.\n\n'
    fi
    if [ "$has_dod" = true ]; then
      printf '# Definition of done\nDelivery contract: mode=direct-PR\nThe pager returns one page per call.\n'
    fi
  } > "$BRIEF"
}

make_spawn_home() {  # <name>
  local name=$1 home projects fakebin
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  git -C "$projects/proj" init -q || fail "could not initialize project fixture"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  cp "$FAKEBIN/curl" "$fakebin/curl"
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

write_spawn_brief() {  # <home> <id> <intent> <spec> [dod]
  local home=$1 id=$2 intent=$3 spec=$4 dod=${5:-yes}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\n%s\n\n## Firstmate spec\n%s\n\n' \
      "$intent" "$spec"
    if [ "$dod" = yes ]; then
      printf '# Definition of done\nDelivery contract: mode=direct-PR\nThe change is observable and tests cover it.\n'
    else
      printf '# Notes\nDelivery contract: mode=direct-PR\n'
    fi
  } > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  reset_log
  FAKE_CURL_LOG="$LOG" TYPESAFE_API_KEY=$TS_KEY \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_usage_requires_brief_and_task() {
  local code out err
  run_preflight code out err
  expect_code 2 "$code" "missing args exit 2"
  assert_contains "$err" 'Usage:' "usage is printed"
  run_preflight code out err --brief "$BRIEF"
  expect_code 2 "$code" "missing task exits 2"
  run_preflight code out err --brief "$BRIEF" --task "$TASK_ID/../escape"
  expect_code 2 "$code" "path-like task id is refused"
  pass "usage requires --brief and --task and refuses a path-like id"
}

test_rule_matches_recorded_jev_grid() {
  local kind task dod intent spec expected got rows=0
  while IFS='|' read -r kind task dod intent spec expected; do
    [ -n "$kind" ] || continue
    got=$(fm_brief_preflight_verdict "$kind" "$task" "$dod" "$intent" "$spec")
    assert_equals "$expected" "$got" \
      "kind=$kind task=$task dod=$dod intent=$intent spec=$spec matches Jev"
    rows=$((rows + 1))
  done <<<"$GRID"
  assert_equals 32 "$rows" "the grid covers all 32 combinations"
  pass "the deterministic rule reproduces Jev's 32 recorded grid answers"
}

test_reachable_grid_through_the_script() {
  local kind task dod intent spec expected code out err rows=0
  while IFS='|' read -r kind task dod intent spec expected; do
    [ -n "$kind" ] || continue
    if [ "$task" = false ] && { [ "$intent" = true ] || [ "$spec" = true ]; }; then
      continue
    fi
    write_grid_brief "$task" "$dod" "$intent" "$spec"
    run_preflight code out err --brief "$BRIEF" --task "$TASK_ID" --kind "$kind"
    expect_code 0 "$code" "grid row exits 0"
    jq -e --arg verdict "$expected" --arg kind "$kind" \
      '.verdict == $verdict and .kind == $kind and .block == false
       and .shadow == true and .rule == "deterministic"' \
      "$(record_path)" >/dev/null \
      || fail "kind=$kind task=$task dod=$dod intent=$intent spec=$spec expected $expected: $(cat "$(record_path)")"
    if [ "$expected" = missing_acceptance ]; then
      assert_contains "$err" 'is missing acceptance criteria or definition of done' "$expected warns"
    else
      assert_equals '' "$err" "$expected stays silent"
    fi
    assert_absent "$LOG/argv" "grid row makes no network call"
    rows=$((rows + 1))
  done <<<"$GRID"
  assert_equals 20 "$rows" "every structurally reachable grid row ran"
  pass "every reachable grid row gives Jev's recorded verdict through the script"
}

test_complete_brief_is_silent_and_records_need_human() {
  local code out err
  write_grid_brief true true true true
  run_preflight code out err --brief "$BRIEF" --task "$TASK_ID" --kind ship --mode direct-PR
  expect_code 0 "$code" "complete preflight exits 0"
  [ -z "$out" ] || fail "preflight must be silent on stdout, got '$out'"
  assert_equals '' "$err" "need_human stays silent"
  jq -e '. == {
    purpose: "brief-preflight", task: "pager-off-by-one", kind: "ship",
    mode: "direct-PR", verdict: "need_human", missing: "", surfaced: false,
    shadow: true, block: false, rule: "deterministic"
  }' "$(record_path)" >/dev/null || fail "record shape: $(cat "$(record_path)")"
  assert_absent "$LOG/argv" "a configured key still makes no network call"
  pass "a brief with a definition of done records need_human silently and offline"
}

test_missing_dod_warns_and_records() {
  local code out err
  write_grid_brief true false true true
  run_preflight code out err --brief "$BRIEF" --task "$TASK_ID" --kind ship
  expect_code 0 "$code" "missing definition of done exits 0"
  assert_contains "$err" "warning: brief preflight: $BRIEF is missing acceptance criteria or definition of done (missing_acceptance); spawn continues" \
    "the warning names the missing element"
  jq -e '.verdict == "missing_acceptance" and .surfaced == true and .block == false
    and .missing == "acceptance criteria or definition of done"' \
    "$(record_path)" >/dev/null || fail "missing DoD record: $(cat "$(record_path)")"
  pass "a missing definition of done warns, records, and never blocks"
}

test_off_and_unrecognized_metadata_write_nothing() {
  local code out err
  write_grid_brief true false true true
  FM_JEV_BRIEF_PREFLIGHT=off run_preflight code out err --brief "$BRIEF" --task "$TASK_ID" --kind ship
  expect_code 0 "$code" "off exits 0"
  assert_absent "$(record_path)" "off writes no record"
  assert_equals '' "$err" "off is silent"
  run_preflight code out err --brief "$BRIEF" --task "$TASK_ID" --mode private-content
  expect_code 0 "$code" "unrecognized mode exits 0"
  assert_absent "$(record_path)" "unrecognized mode writes no record"
  printf '# Task\nFix it.\n# Definition of done\nDelivery contract: mode=weird\n' > "$BRIEF"
  run_preflight code out err --brief "$BRIEF" --task "$TASK_ID"
  assert_absent "$(record_path)" "unrecognized recorded delivery writes no record"
  pass "off and unrecognized delivery metadata skip the check"
}

test_record_keeps_brief_content_local() {
  local code out err
  printf '# Task\nGH_TOKEN=secret private page content\n# Definition of done\nDelivery contract: mode=direct-PR\n' > "$BRIEF"
  run_preflight code out err --brief "$BRIEF" --task "$TASK_ID"
  assert_not_contains "$(cat "$(record_path)")" 'secret' "brief text never enters the record"
  assert_not_contains "$(cat "$(record_path)")" 'private page content' "page content never enters the record"
  pass "the record carries structural facts only"
}

test_spawn_records_and_proceeds() {
  local rec home proj fakebin out
  rec=$(make_spawn_home spawn)
  IFS='|' read -r home proj fakebin <<<"$rec"
  write_spawn_brief "$home" complete-ship \
    "Fix the pager off-by-one on line 40." \
    "Change only pager.sh. Do not refactor the caller."
  out=$(run_spawn "$home" "$fakebin" complete-ship "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" 'warning: brief preflight' "complete spawn is silent"
  assert_not_contains "$out" 'still contains {TASK}' "complete spawn is not a structural refusal"
  jq -e '.verdict == "need_human" and .block == false' \
    "$home/state/complete-ship.jev-brief-preflight.jsonl" >/dev/null \
    || fail "spawn must write a need_human record: $out"

  write_spawn_brief "$home" no-dod-ship "Fix the pager." "Change only pager.sh." no
  out=$(run_spawn "$home" "$fakebin" no-dod-ship "$proj" claude --mode direct-PR --yolo off)
  assert_contains "$out" 'is missing acceptance criteria or definition of done' "missing DoD spawn warns"
  assert_contains "$out" 'spawn continues' "missing DoD spawn does not refuse"
  jq -e '.verdict == "missing_acceptance" and .block == false' \
    "$home/state/no-dod-ship.jev-brief-preflight.jsonl" >/dev/null \
    || fail "spawn must write a missing_acceptance record: $out"
  assert_absent "$LOG/argv" "spawn preflight makes no network call"
  pass "spawn records the deterministic verdict and still proceeds"
}

test_spawn_structural_refusals_still_fire() {
  local rec home proj fakebin out status content
  rec=$(make_spawn_home structural)
  IFS='|' read -r home proj fakebin <<<"$rec"
  FM_HOME="$home" "$BRIEF_TOOL" unfilled-ship proj --mode direct-PR >/dev/null 2>&1 \
    || fail "unfilled ship brief should still scaffold"
  out=$(run_spawn "$home" "$fakebin" unfilled-ship "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "unfilled ship spawn should exit non-zero"
  assert_contains "$out" "still contains {TASK} or {FIRSTMATE_SPEC}" \
    "unfilled ship spawn still names leftover placeholders"
  assert_absent "$home/state/unfilled-ship.jev-brief-preflight.jsonl" \
    "structural placeholder refusal writes no preflight record"
  assert_absent "$home/state/unfilled-ship.meta" "unfilled ship spawn wrote task metadata"

  FM_HOME="$home" "$BRIEF_TOOL" empty-ship proj --mode direct-PR >/dev/null 2>&1 \
    || fail "empty-ship brief should scaffold"
  content=$(cat "$home/data/empty-ship/brief.md")
  content=${content//'{TASK}'/}
  content=${content//'{FIRSTMATE_SPEC}'/}
  printf '%s\n' "$content" > "$home/data/empty-ship/brief.md"
  out=$(run_spawn "$home" "$fakebin" empty-ship "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "empty Task subsections should exit non-zero"
  assert_contains "$out" "must contain nonempty ## Captain's intent and ## Firstmate spec" \
    "empty Task subsections are still rejected"
  assert_absent "$home/state/empty-ship.jev-brief-preflight.jsonl" \
    "empty-subsection refusal writes no preflight record"

  mkdir -p "$home/data/address-ship"
  printf "# Task\n## Captain's intent\nCaptain, fix the pager.\n\n## Firstmate spec\nChange only pager.sh.\n\n# Definition of done\nDelivery contract: mode=direct-PR\n" \
    > "$home/data/address-ship/brief.md"
  out=$(run_spawn "$home" "$fakebin" address-ship "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "Captain-addressed intent should exit non-zero"
  assert_contains "$out" "has an operator-address line" \
    "Captain-addressed intent is still refused"
  assert_absent "$home/state/address-ship.jev-brief-preflight.jsonl" \
    "address-line refusal writes no preflight record"
  pass "existing structural brief refusals still fire before the preflight"
}

test_spawn_generated_briefs_record_need_human() {
  local rec home proj fakebin out content kind id mode
  local -a args
  rec=$(make_spawn_home generated)
  IFS='|' read -r home proj fakebin <<<"$rec"
  for mode in direct-PR local-only no-mistakes scout; do
    id="generated-$mode"
    kind=ship
    args=(--mode "$mode")
    if [ "$mode" = scout ]; then
      kind=scout
      args=(--scout)
    fi
    FM_HOME="$home" "$BRIEF_TOOL" "$id" proj "${args[@]}" >/dev/null \
      || fail "could not scaffold $id"
    content=$(cat "$home/data/$id/brief.md")
    content=${content//'{TASK}'/Fix the pager off-by-one.}
    content=${content//'{FIRSTMATE_SPEC}'/Change only pager.sh and add a regression test.}
    printf '%s\n' "$content" > "$home/data/$id/brief.md"
    if [ "$kind" = ship ]; then args+=(--yolo off); fi
    out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude "${args[@]}")
    jq -e --arg kind "$kind" '.verdict == "need_human" and .kind == $kind and .block == false' \
      "$home/state/$id.jev-brief-preflight.jsonl" >/dev/null \
      || fail "$id must record need_human: $out"
    assert_not_contains "$out" 'warning: brief preflight' "$id stays silent"
    assert_absent "$LOG/argv" "$id makes no network call"
  done
  pass "populated generated ship and scout briefs record need_human through spawn"
}

test_usage_requires_brief_and_task
test_rule_matches_recorded_jev_grid
test_reachable_grid_through_the_script
test_complete_brief_is_silent_and_records_need_human
test_missing_dod_warns_and_records
test_off_and_unrecognized_metadata_write_nothing
test_record_keeps_brief_content_local
test_spawn_records_and_proceeds
test_spawn_structural_refusals_still_fire
test_spawn_generated_briefs_record_need_human
