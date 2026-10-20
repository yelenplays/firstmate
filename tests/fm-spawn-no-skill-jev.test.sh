#!/usr/bin/env bash
# Behavior tests: spawn makes no skill-selection Jev call, whatever the old knobs say.
#
# Fake Jev through the existing curl seam. No case touches the network.
# Assertions pin the published launch-brief overlay and live_loaded, not
# implementation source.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_git_identity

TMP_ROOT=$(fm_test_tmproot fm-spawn-no-skill-jev)
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
cat > "${FAKE_CURL_BODY:?}"
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
  mkdir -p "$home/.agents/skills/pager"
  cat > "$home/.agents/skills/pager/SKILL.md" <<'EOF'
---
name: pager
description: Find and explain pager workflows.
---
Use pager workflows.
EOF
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
  git -C "$proj" add .agents
  git -C "$proj" commit --quiet -m 'Add worker skills'
  git -C "$proj" push --quiet origin HEAD
  git -C "$proj" rm -r --quiet .agents
  git -C "$proj" commit --quiet -m 'Remove skills only in launching checkout'
  mkdir -p "$proj/.agents/skills/launcher-only"
  printf '# launcher only\n' > "$proj/.agents/skills/launcher-only/SKILL.md"
  fm_test_spawn_brief "$home" "$id" 'PRIVATE_EXCERPT <<<<<<< conflict lines'
  printf 'Find pager skills\n' > "$home/data/$id/jev-skill-query.txt"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$id"
}

run_ship() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  local -a delivery=(--mode "${TEST_SHIP_MODE:-no-mistakes}" --yolo off)
  if [ "${TEST_RELAUNCH:-0}" = 1 ]; then
    delivery=(--relaunch)
  elif [ "${TEST_SCOUT:-0}" = 1 ]; then
    delivery=(--scout)
  fi
  : > "$launchlog"
  # The shared curl recorder belongs to skill selection, not brief preflight.
  # Keep that independent spawn-time Jev consumer out of this fixture.
  FM_JEV_BRIEF_PREFLIGHT=off \
  FAKE_CURL_BODY="$home/request.json" FAKE_CURL_RESPONSE="$RESPONSE" FAKE_CURL_HTTP="${FAKE_CURL_HTTP:-200}" \
    FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" \
    CLAUDE_CONFIG_DIR='' \
    FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" "${delivery[@]}" --harness "${TEST_HARNESS:-grok}"
}

read_case() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG ID <<EOF
$1
EOF
}

test_spawn_makes_no_skill_jev_call() {
  local mode rec out status overlay
  write_pager_response
  for mode in shadow live; do
    rec=$(make_case "no-call-$mode" "t-no-call-$mode")
    read_case "$rec"
    : > "$HOME_DIR/config/jev-skill-select-live"
    mkdir -p "$HOME_DIR/state"
    out=$(FM_JEV_SKILL_SELECT=$mode TYPESAFE_API_KEY=$TS_KEY \
      run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ID" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$mode spawn should succeed: $out"
    overlay="$HOME_DIR/data/$ID/launch-brief.md"
    assert_present "$overlay" "$mode spawn did not publish launch-brief.md"
    assert_present "$HOME_DIR/data/$ID/jev-skill-query.txt" "fixture query must exist"
    [ ! -e "$HOME_DIR/request.json" ] || fail "$mode spawn must make no Jev HTTP call"
    [ ! -s "$HOME_DIR/state/jev-calls.jsonl" ] || fail "$mode spawn must append nothing to jev-calls.jsonl"
    [ ! -e "$HOME_DIR/state/jev-skill-shadow" ] || fail "$mode spawn must write no shadow case"
    [ ! -e "$HOME_DIR/state/$ID.jev-skills.json" ] || fail "$mode spawn must write no skill record"
    if grep -q '# Jev-selected skills' "$overlay"; then fail "$mode overlay must carry no selected skills"; fi
    assert_grep '# Current worker role contract' "$overlay" "launch-brief lost the worker role"
  done
  pass "spawn launches with an unchanged overlay and no skill-selection Jev traffic"
}

test_spawn_makes_no_skill_jev_call
