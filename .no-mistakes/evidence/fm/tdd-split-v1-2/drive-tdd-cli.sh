#!/usr/bin/env bash
# Manual product CLI checks; no fake harnesses, backends, or forge executables.
set -eu
ROOT=$PWD
EVIDENCE=/Users/yelen/.no-mistakes/evidence/01M5DR0CF1E1R45T9NEBBZT18D
LAB=$(mktemp -d "$ROOT/.test-tdd-cli.XXXXXX")
trap 'chmod -R u+w "$LAB"; rm -rf "$LAB"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONTROL_BIN FM_GATE_REFUSE_BYPASS GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
export FM_HOME="$LAB/home" NM_HOME="$LAB/nm" TMPDIR="$LAB/tmp"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
mkdir -p "$TMPDIR" "$NM_HOME"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
# All refs, objects, worktrees, and remote pushes stay inside this disposable lab.
git init -q --bare "$LAB/origin.git"
git init -q -b main "$LAB/project"
printf 'base\n' > "$LAB/project/README"
git -C "$LAB/project" add README
git -C "$LAB/project" commit -q -m base
git -C "$LAB/project" remote add origin "$LAB/origin.git"
git -C "$LAB/project" push -q -u origin main
case_setup() {
  ID=$1
  WT="$LAB/$ID"
  git -C "$LAB/project" worktree add -q -b "fm/$ID" "$WT" main
  git -C "$WT" fetch -q origin
  mkdir -p "$WT/tests" "$FM_HOME/data/$ID"
  printf '[ -f feature.sh ]\n' > "$WT/tests/feature.test.sh"
  git -C "$WT" add tests
  git -C "$WT" commit -q -m 'tests first'
  SEAT=$(git -C "$WT" rev-parse HEAD)
  META="$FM_HOME/state/$ID.meta"
  printf '%s\n' kind=ship mode=direct-PR yolo=off "worktree=$WT" "project=$LAB/project" base_branch=main "branch=fm/$ID" harness=claude model=claude-opus-5-5 tdd_split=tests tdd_split_impl_harness=claude tdd_split_impl_model=claude-sonnet-5-5 tdd_split_impl_effort=medium > "$META"
  printf 'done: tests-ready %s\n' "$SEAT" > "$FM_HOME/state/$ID.status"
  printf '# Brief\n\nFail-to-pass command: `for t; do bash "$t" || exit 1; done`\n' > "$FM_HOME/data/$ID/brief.md"
}
refuse_handoff() {
  local expected=$1 output rc
  set +e
  output=$("$ROOT/bin/fm-tdd-split.sh" handoff "$ID" --timeout 1 2>&1)
  rc=$?
  set -e
  printf '\n$ bin/fm-tdd-split.sh handoff %s --timeout 1\n%s\nexit=%s\n' "$ID" "$output" "$rc"
  [ "$rc" -ne 0 ] && [[ "$output" == *"$expected"* ]]
  grep '^tdd_split=' "$META"
  ! grep -q '^tdd_split=implement$' "$META"
  if [ -f "$FM_HOME/data/$ID/tdd-split-red.log" ]; then
    cp "$FM_HOME/data/$ID/tdd-split-red.log" "$EVIDENCE/$ID-red.log"
  fi
}
case_setup premature
printf 'working: writing tests\n' > "$FM_HOME/state/$ID.status"
refuse_handoff 'has not reported done: tests-ready'
case_setup dirty
printf 'draft\n' > "$WT/tests/draft.test.sh"
refuse_handoff 'uncommitted changes'
case_setup production
printf 'echo feature\n' > "$WT/feature.sh"
git -C "$WT" add feature.sh
git -C "$WT" commit -q -m 'production code on seat'
refuse_handoff 'not tests: feature.sh'
case_setup green
printf 'true\n' > "$WT/tests/feature.test.sh"
git -C "$WT" add tests; git -C "$WT" commit -q -m 'green test'
refuse_handoff 'pass on the base'
case_setup missing-command
printf 'Fail-to-pass command: `no-such-fm-validation-command`\n' > "$FM_HOME/data/$ID/brief.md"
refuse_handoff 'could not run (exit 127)'
case_setup timeout
printf 'Fail-to-pass command: `sleep 3`\n' > "$FM_HOME/data/$ID/brief.md"
refuse_handoff 'hit its 1s bound'

# Both newly banned model families must be refused by the real pre-PR gate.
for model in opencode-go/deepseek-v4.1-flash opencode-go/glm-5; do
  case "$model" in *deepseek*) id=deepseek ;; *) id=glm ;; esac
  case_setup "$id"
  printf '%s\n' kind=ship mode=direct-PR yolo=off "worktree=$WT" "project=$LAB/project" base_branch=main "branch=fm/$ID" "model=$model" "test_ban_model=$model" > "$META"
  set +e
  OUTPUT=$("$ROOT/bin/fm-pr-check.sh" "$ID" https://github.com/firstmate-validation-lab/nonexistent-tdd-task/pull/1 2>&1); RC=$?
  set -e
  printf '\n$ bin/fm-pr-check.sh %s <nonexistent-lab-URL> (unauthorized tests on %s)\n%s\nexit=%s\n' "$ID" "$model" "$OUTPUT" "$RC"
  [ "$RC" -ne 0 ] && [[ "$OUTPUT" == *"no test authoring on $model"* ]]
  ! grep -q '^pr=' "$META"
done

# Public PR-registration CLI: exercise the ban against real git commits.
# URL is a deliberately nonexistent lab URL, NOT a claimed published PR.
# Actual gh, if installed, may read it; no forge executable is replaced.
case_setup locked
mkdir -p "$WT/e2e"
printf '[ -f feature.sh ]\n' > "$WT/e2e/feature.test.sh"
git -C "$WT" add e2e; git -C "$WT" commit -q -m 'end-to-end tests first'
SEAT=$(git -C "$WT" rev-parse HEAD)
set +e
(cd "$WT" && bash e2e/feature.test.sh); RED_RC=$?
set -e
printf '\nCheckpoint-owned e2e test on missing feature: exit=%s\n' "$RED_RC"
[ "$RED_RC" -eq 1 ]
printf '%s\n' kind=ship mode=direct-PR yolo=off "worktree=$WT" "project=$LAB/project" base_branch=main "branch=fm/$ID" harness=claude model=claude-sonnet-5-5 test_ban_model=claude-sonnet-5-5 "test_ban_since=$SEAT" tdd_split=implement "tdd_split_tests=$SEAT" > "$META"
printf 'true\n' > "$WT/tests/feature.test.sh"
git -C "$WT" add tests; git -C "$WT" commit -q -m 'weaken unit test'
git -C "$WT" push -q origin HEAD
URL=https://github.com/firstmate-validation-lab/nonexistent-tdd-task/pull/1
set +e
OUTPUT=$("$ROOT/bin/fm-pr-check.sh" "$ID" "$URL" 2>&1); RC=$?
set -e
printf '\n$ bin/fm-pr-check.sh locked <nonexistent-lab-URL> (unit test changed)\n%s\nexit=%s\n' "$OUTPUT" "$RC"
[ "$RC" -ne 0 ] && [[ "$OUTPUT" == *'no test authoring'* ]]
! grep -q '^pr=' "$META"
git -C "$WT" restore --source="$SEAT" -- tests/feature.test.sh
git -C "$WT" add tests; git -C "$WT" commit -q -m 'restore handed unit test'
printf 'true\n' > "$WT/e2e/feature.test.sh"
git -C "$WT" add e2e; git -C "$WT" commit -q -m 'weaken handed end-to-end test'
git -C "$WT" push -q origin HEAD
printf '\nHanded-over test diff (unit test restored; only end-to-end test weakened):\n'
git -C "$WT" diff "$SEAT" HEAD -- tests e2e
(cd "$WT" && bash e2e/feature.test.sh)
printf 'Weakened e2e test: exit=0; feature.sh still absent=%s\n' "$([ ! -e "$WT/feature.sh" ] && printf yes || printf no)"
set +e
OUTPUT=$("$ROOT/bin/fm-pr-check.sh" "$ID" "$URL" 2>&1); RC=$?
set -e
printf '\n$ bin/fm-pr-check.sh locked <nonexistent-lab-URL> (handed e2e test changed)\n%s\nexit=%s\n' "$OUTPUT" "$RC"
cp "$META" "$EVIDENCE/locked-after-e2e-change.meta"
if [ "$RC" -eq 0 ] && grep -q '^pr=' "$META"; then
  printf 'BUG REPRODUCED: handed-over e2e test was changed to true, yet PR registration succeeded.\n'
  exit 3
fi
[ "$RC" -ne 0 ] && [[ "$OUTPUT" == *'no test authoring'* ]]
