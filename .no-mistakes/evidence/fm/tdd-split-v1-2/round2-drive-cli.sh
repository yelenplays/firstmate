#!/usr/bin/env bash
# Drive public product CLIs over disposable real Git histories; no tool doubles.
set -eu
ROOT=$PWD
E=/Users/yelen/.no-mistakes/evidence/01M5DR0CF1E1R45T9NEBBZT18D
LAB=$(mktemp -d "$ROOT/.test-tdd-cli-round2.XXXXXX")
trap 'chmod -R u+w "$LAB"; rm -rf "$LAB"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONTROL_BIN FM_GATE_REFUSE_BYPASS GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
export FM_HOME="$LAB/home" NM_HOME="$LAB/nm" TMPDIR="$LAB/tmp"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
mkdir -p "$TMPDIR" "$NM_HOME"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
git init -q --bare "$LAB/origin.git"
git init -q -b main "$LAB/project"
printf 'base\n' > "$LAB/project/README"
git -C "$LAB/project" add README; git -C "$LAB/project" commit -q -m base
git -C "$LAB/project" remote add origin "$LAB/origin.git"
git -C "$LAB/project" push -q -u origin main
URL=https://github.com/firstmate-validation-lab/nonexistent-tdd-task/pull/1
setup() {
  ID=$1; WT="$LAB/$ID"; META="$FM_HOME/state/$ID.meta"
  git -C "$LAB/project" worktree add -q -b "fm/$ID" "$WT" main
  git -C "$WT" fetch -q origin
  mkdir -p "$WT/tests" "$WT/e2e" "$FM_HOME/data/$ID"
  printf '[ -f feature.sh ]\n' > "$WT/tests/feature.test.sh"
  printf '[ -f feature.sh ]\n' > "$WT/e2e/feature.test.sh"
  git -C "$WT" add tests e2e; git -C "$WT" commit -q -m 'tests first'
  SEAT=$(git -C "$WT" rev-parse HEAD)
  printf '%s\n' kind=ship mode=direct-PR yolo=off "worktree=$WT" "project=$LAB/project" base_branch=main "branch=fm/$ID" harness=claude model=claude-opus-5-5 tdd_split=tests tdd_split_impl_harness=claude tdd_split_impl_model=claude-sonnet-5-5 tdd_split_impl_effort=medium > "$META"
  printf 'done: tests-ready %s\n' "$SEAT" > "$FM_HOME/state/$ID.status"
  printf 'Fail-to-pass command: `for t; do bash "$t" || exit 1; done`\n' > "$FM_HOME/data/$ID/brief.md"
}
commit() { git -C "$WT" add -A; git -C "$WT" commit -q -m "$1"; }
refuse_handoff() {
  local expected=$1 out rc
  set +e; out=$("$ROOT/bin/fm-tdd-split.sh" handoff "$ID" --timeout 1 2>&1); rc=$?; set -e
  printf '\n$ bin/fm-tdd-split.sh handoff %s --timeout 1\n%s\nexit=%s\n' "$ID" "$out" "$rc"
  [ "$rc" -ne 0 ] && [[ "$out" == *"$expected"* ]]
  grep '^tdd_split=tests$' "$META"
  if [ -f "$FM_HOME/data/$ID/tdd-split-red.log" ]; then cp "$FM_HOME/data/$ID/tdd-split-red.log" "$E/round2-$ID-red.log"; fi
}
setup premature
printf 'working: writing tests\n' > "$FM_HOME/state/$ID.status"
refuse_handoff 'has not reported done: tests-ready'
setup dirty
printf 'draft\n' > "$WT/tests/draft.test.sh"
refuse_handoff 'uncommitted changes'
setup mixed
printf 'feature\n' > "$WT/feature.sh"; commit 'production on test seat'
refuse_handoff 'not tests: feature.sh'
setup green
printf 'true\n' > "$WT/tests/feature.test.sh"; printf 'true\n' > "$WT/e2e/feature.test.sh"; commit 'green tests'
refuse_handoff 'pass on the base'
setup missing
printf 'Fail-to-pass command: `no-such-fm-validation-command`\n' > "$FM_HOME/data/$ID/brief.md"
refuse_handoff 'could not run (exit 127)'
setup timeout
printf 'Fail-to-pass command: `sleep 3`\n' > "$FM_HOME/data/$ID/brief.md"
refuse_handoff 'hit its 1s bound'
for model in opencode-go/deepseek-v4.1-flash opencode-go/glm-5; do
  case "$model" in *deepseek*) id=deepseek ;; *) id=glm ;; esac
  setup "$id"
  printf '%s\n' kind=ship mode=direct-PR "worktree=$WT" "project=$LAB/project" base_branch=main "model=$model" "test_ban_model=$model" > "$META"
  set +e; out=$("$ROOT/bin/fm-pr-check.sh" "$ID" "$URL" 2>&1); rc=$?; set -e
  printf '\n$ bin/fm-pr-check.sh %s <nonexistent-lab-URL> (tests authored by %s)\n%s\nexit=%s\n' "$ID" "$model" "$out" "$rc"
  [ "$rc" -ne 0 ] && [[ "$out" == *"no test authoring on $model"* ]]
  ! grep -q '^pr=' "$META"; [ ! -e "$FM_HOME/state/$ID.check.sh" ]
done
for attack in unit-weaken e2e-weaken e2e-delete e2e-rename; do
  setup "$attack"
  printf '%s\n' kind=ship mode=direct-PR yolo=off "worktree=$WT" "project=$LAB/project" base_branch=main "branch=fm/$ID" harness=claude model=claude-sonnet-5-5 test_ban_model=claude-sonnet-5-5 "test_ban_since=$SEAT" tdd_split=implement "tdd_split_tests=$SEAT" > "$META"
  set +e; (cd "$WT" && bash e2e/feature.test.sh); red_rc=$?; set -e
  [ "$red_rc" -eq 1 ]
  printf '\nCheckpoint %s: feature absent, handed tests fail (exit=%s).\n' "$SEAT" "$red_rc"
  case "$attack" in
    unit-weaken) path=tests/feature.test.sh; printf 'true\n' > "$WT/$path" ;;
    e2e-weaken) path=e2e/feature.test.sh; printf 'true\n' > "$WT/$path" ;;
    e2e-delete) path=e2e/feature.test.sh; rm "$WT/$path" ;;
    e2e-rename) path=e2e/feature.test.sh; mv "$WT/$path" "$WT/disabled.sh" ;;
  esac
  commit "$attack checkpoint test"; git -C "$WT" push -q origin HEAD
  git -C "$WT" diff "$SEAT" HEAD -- tests e2e disabled.sh
  set +e; out=$("$ROOT/bin/fm-pr-check.sh" "$ID" "$URL" 2>&1); rc=$?; set -e
  printf '\n$ bin/fm-pr-check.sh %s <nonexistent-lab-URL>\n%s\nexit=%s\n' "$ID" "$out" "$rc"
  [ "$rc" -ne 0 ] && [[ "$out" == *"$path"* ]]
  ! grep -q '^pr=' "$META"; [ ! -e "$FM_HOME/state/$ID.check.sh" ]
  printf 'Refusal preserved metadata and left PR monitoring unarmed.\n'
  git -C "$WT" revert --no-edit HEAD >/dev/null
  printf 'implemented\n' > "$WT/feature.sh"
  printf '[ -f feature.sh ]\n' > "$WT/e2e/new.test.sh"
  commit 'implement feature without changing checkpoint tests'; git -C "$WT" push -q origin HEAD
  (cd "$WT" && bash tests/feature.test.sh && bash e2e/feature.test.sh && bash e2e/new.test.sh)
  printf '\nFeature implemented: unit, checkpoint e2e, and new e2e tests pass.\n'
  set +e; out=$("$ROOT/bin/fm-pr-check.sh" "$ID" "$URL" 2>&1); rc=$?; set -e
  printf '$ bin/fm-pr-check.sh %s <nonexistent-lab-URL> (checkpoint restored; implementation complete)\n%s\nexit=%s\n' "$ID" "$out" "$rc"
  [ "$rc" -eq 0 ]; grep '^pr=' "$META"; [ -f "$FM_HOME/state/$ID.check.sh" ]
  printf 'PR monitoring armed; checkpoint test bytes unchanged: '
  git -C "$WT" diff --exit-code "$SEAT" HEAD -- tests/feature.test.sh e2e/feature.test.sh
  printf 'yes\n'
done
# A banned review fixer cannot add tests even when the worker itself is Opus.
setup fixer-on-opus
printf '%s\n' kind=ship mode=no-mistakes "worktree=$WT" "project=$LAB/project" base_branch=main model=claude-opus-5-5 > "$META"
printf '%s\n' 'review_agents:' '  fixer:' '    agent: claude' '    model: claude-sonnet-5-5' > "$NM_HOME/config.yaml"
printf 'true\n' > "$WT/tests/fixer.test.sh"
commit 'no-mistakes(review): add unauthorized fixer test'
git -C "$WT" push -q origin HEAD
set +e; out=$("$ROOT/bin/fm-pr-check.sh" "$ID" "$URL" 2>&1); rc=$?; set -e
printf '\n$ bin/fm-pr-check.sh fixer-on-opus <nonexistent-lab-URL> (Sonnet review fixer adds test on Opus task)\n%s\nexit=%s\n' "$out" "$rc"
[ "$rc" -ne 0 ] && [[ "$out" == *'pipeline fixer commits'* ]] && [[ "$out" == *'tests/fixer.test.sh'* ]]
! grep -q '^pr=' "$META"; [ ! -e "$FM_HOME/state/$ID.check.sh" ]
printf '\nAll manual CLI scenarios passed; disposable lab removed on exit. No published PR or live harness is claimed.\n'
