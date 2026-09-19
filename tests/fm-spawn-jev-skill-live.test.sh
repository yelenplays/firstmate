#!/usr/bin/env bash
# Behavior tests for the live Jev skill hop into fm-spawn.sh.
#
# Fake Jev through the existing curl seam. No case touches the network.
# Assertions pin the published launch-brief overlay and live_loaded, not
# implementation source.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-jev-skill-live)
RESPONSE="$TMP_ROOT/response.json"
TS_KEY='ts-test-key-not-for-argv'

write_pager_response() {
  cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "skill": { "type": "choice", "choice": "pager", "confidence": 0.82,
    "probabilities": { "pager": 0.8, "review": 0.1, "none": 0.05, "search_external": 0.05 } } },
  "usage": { "input_tokens": 40, "output_tokens": 12 } }
JSON
}

write_none_response() {
  cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "skill": { "type": "choice", "choice": "none", "confidence": 0.91,
    "probabilities": { "pager": 0.05, "none": 0.9, "search_external": 0.05 } } },
  "usage": { "input_tokens": 8, "output_tokens": 4 } }
JSON
}

install_fake_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
cat /dev/fd/3 >/dev/null 2>/dev/null || true
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
  chmod +x "$fakebin/curl"
}

seed_project_skills() {
  local proj=$1
  mkdir -p "$proj/.agents/skills/pager" "$proj/.agents/skills/review"
  printf '# pager\n' > "$proj/.agents/skills/pager/SKILL.md"
  printf '# review\n' > "$proj/.agents/skills/review/SKILL.md"
}

make_case() {
  local name=$1 id=$2
  local case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  install_fake_curl "$fakebin"
  fm_test_spawn_home "$home" grok
  fm_git_worktree "$proj" "$wt" "wt-$name"
  seed_project_skills "$proj"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$id"
}

run_ship() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FAKE_CURL_RESPONSE="$RESPONSE" FAKE_CURL_HTTP="${FAKE_CURL_HTTP:-200}" \
    FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" \
    CLAUDE_CONFIG_DIR='' \
    FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off --harness grok
}

read_case() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG ID <<EOF
$1
EOF
}

test_live_selection_reaches_overlay() {
  local rec out status overlay record
  write_pager_response
  rec=$(make_case live-load t-live-load)
  read_case "$rec"
  : > "$HOME_DIR/config/jev-skill-select-live"
  out=$(FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY \
    run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "live spawn should succeed: $out"
  overlay="$HOME_DIR/data/$ID/launch-brief.md"
  record="$HOME_DIR/state/$ID.jev-skills.json"
  assert_present "$overlay" "live spawn did not publish launch-brief.md"
  assert_present "$record" "live spawn did not write the skill record"
  jq -e '.live_loaded == true and .primary == "pager" and (.skills | index("pager") != null)' \
    "$record" >/dev/null \
    || fail "live spawn must set live_loaded true for pager"
  assert_grep '# Jev-selected skills' "$overlay" "launch-brief missing selected skills"
  assert_grep '/pager' "$overlay" "launch-brief did not carry pager in grok form"
  assert_grep '# Current worker role contract' "$overlay" "launch-brief lost the worker role"
  pass "live selection reaches the launch overlay and live_loaded is true"
}

test_disabled_and_none_match_today() {
  local rec out status overlay_disabled overlay_none record
  write_pager_response
  rec=$(make_case disabled t-disabled)
  read_case "$rec"
  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "disabled spawn should succeed: $out"
  overlay_disabled="$HOME_DIR/data/$ID/launch-brief.md"
  assert_present "$overlay_disabled" "disabled spawn did not publish launch-brief.md"
  assert_no_grep 'Jev-selected skills' "$overlay_disabled" \
    "disabled spawn must not inject a skills section"
  assert_absent "$HOME_DIR/state/$ID.jev-skills.json" \
    "disabled spawn must not write a skill record"

  write_none_response
  rec=$(make_case none t-none)
  read_case "$rec"
  : > "$HOME_DIR/config/jev-skill-select-live"
  out=$(FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY \
    run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "none spawn should succeed: $out"
  overlay_none="$HOME_DIR/data/$ID/launch-brief.md"
  record="$HOME_DIR/state/$ID.jev-skills.json"
  assert_present "$record" "none spawn should still record the suggestion"
  jq -e '.primary == "none" and .live_loaded == false and .skills == []' "$record" >/dev/null \
    || fail "none spawn must record empty skills and live_loaded false"
  assert_no_grep 'Jev-selected skills' "$overlay_none" \
    "none spawn must not inject a skills section"
  pass "disabled and none launches match today's overlay shape"
}

test_jev_failure_does_not_block_spawn() {
  local rec out status overlay record
  write_pager_response
  rec=$(make_case jev-fail t-jev-fail)
  read_case "$rec"
  : > "$HOME_DIR/config/jev-skill-select-live"
  out=$(FM_JEV_SKILL_SELECT=live TYPESAFE_API_KEY=$TS_KEY FAKE_CURL_FAIL=1 \
    run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Jev failure must not refuse spawn: $out"
  overlay="$HOME_DIR/data/$ID/launch-brief.md"
  record="$HOME_DIR/state/$ID.jev-skills.json"
  assert_present "$overlay" "failed Jev still publishes launch-brief.md"
  assert_contains "$out" "spawned $ID harness=grok" "failed Jev lost the spawn report"
  assert_no_grep 'Jev-selected skills' "$overlay" \
    "failed Jev must not inject a skills section"
  if [ -f "$record" ]; then
    jq -e '.live_loaded == false' "$record" >/dev/null \
      || fail "failed Jev must not claim live_loaded true"
  fi
  pass "Jev failure does not block spawn and does not load skills"
}

test_live_selection_reaches_overlay
test_disabled_and_none_match_today
test_jev_failure_does_not_block_spawn
