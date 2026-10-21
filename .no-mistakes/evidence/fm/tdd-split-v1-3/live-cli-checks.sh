#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/Users/yelen/.no-mistakes/evidence/01M5G1PSQAN8YZS9NJ9PNZGMTB
LAB=$(mktemp -d "$ROOT/.test-phase-tmp/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmp"
export FM_HOME="$LAB" TMPDIR="$LAB/tmp"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONTROL_BIN FM_GATE_REFUSE_BYPASS FM_TEST_SEAM
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_COUNT=0 GIT_AUTHOR_NAME=Validation GIT_AUTHOR_EMAIL=validation@example.invalid GIT_COMMITTER_NAME=Validation GIT_COMMITTER_EMAIL=validation@example.invalid
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
WT="$LAB/projects/demo"
mkdir -p "$WT"
git -C "$WT" init -q -b main
printf '#!/usr/bin/env bash\nprintf "old\\n"\n' > "$WT/greet.sh"
git -C "$WT" add greet.sh
git -C "$WT" -c commit.gpgsign=false commit -qm base
git -C "$WT" update-ref refs/remotes/origin/main HEAD
git -C "$WT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$WT" checkout -qb fm/demo
mkdir -p "$WT/tests" "$LAB/data/demo"
printf '#!/usr/bin/env bash\nactual=$(bash greet.sh)\nprintf "expected=new actual=%%s\\n" "$actual"\n[ "$actual" = new ]\n' > "$WT/tests/greet.test.sh"
git -C "$WT" add tests/greet.test.sh
git -C "$WT" -c commit.gpgsign=false commit -qm 'test desired greeting'
SEAT=$(git -C "$WT" rev-parse HEAD)
meta() {
  printf '%s\n' kind=ship mode=local-only "worktree=$WT" base_branch=main harness=claude model=claude-opus-5-5 effort=medium tdd_split=tests tdd_split_impl_harness=claude tdd_split_impl_model=claude-sonnet-5-5 tdd_split_impl_effort=medium "spawn_gen=s$(date +%s).1.live" > "$LAB/state/demo.meta"
}
brief() { printf '# Manual acceptance scenario\nFail-to-pass command: `%s`\nMutation command: `bash tests/greet.test.sh`\n' "$1" > "$LAB/data/demo/brief.md"; }
run_expect() {
  local expected=$1; shift
  printf '\n$ %s\n' "$*"
  set +e
  "$@" > "$LAB/last-output" 2>&1
  rc=$?
  set -e
  while IFS= read -r line; do printf '%s\n' "$line"; done < "$LAB/last-output"
  printf 'exit=%s (expected %s)\n' "$rc" "$expected"
  [ "$rc" -eq "$expected" ]
}
meta
printf 'done: tests-ready %s\n' "$SEAT" > "$LAB/state/demo.status"
printf 'SCENARIO: already-green tests cannot trigger a handoff\n'
brief 'bash greet.sh'
run_expect 1 "$ROOT/bin/fm-tdd-split.sh" handoff demo
[ "$(awk -F= '$1 == "tdd_split" {print $2}' "$LAB/state/demo.meta")" = tests ]
printf 'Persisted phase remains tests\n'
printf '\nSCENARIO: missing executable and timeout cannot count as red\n'
brief 'fm-validation-no-such-tool'
run_expect 1 "$ROOT/bin/fm-tdd-split.sh" handoff demo
brief 'sleep 5'
run_expect 1 "$ROOT/bin/fm-tdd-split.sh" handoff demo --timeout 1
printf '\nSCENARIO: test seat cannot add production code\n'
printf '# accidental production edit\n' >> "$WT/greet.sh"
git -C "$WT" add greet.sh
git -C "$WT" -c commit.gpgsign=false commit -qm 'accidental implementation'
brief 'bash tests/greet.test.sh'
run_expect 1 "$ROOT/bin/fm-tdd-split.sh" handoff demo
git -C "$WT" reset -q --hard "$SEAT"
printf '\nSCENARIO: meaningful failing assertion runs without implementation\n'
run_expect 1 "$ROOT/bin/fm-tdd-split.sh" handoff demo
cp "$LAB/data/demo/tdd-split-red.log" "$EVIDENCE/live-red-assertion.log"
printf 'Red assertion log:\n'
while IFS= read -r line; do printf '%s\n' "$line"; done < "$LAB/data/demo/tdd-split-red.log"
printf '\nSCENARIO: DeepSeek and GLM cannot weaken handed-over tests\n'
printf 'true\n' > "$WT/tests/greet.test.sh"
git -C "$WT" add tests/greet.test.sh
git -C "$WT" -c commit.gpgsign=false commit -qm 'weaken handed-over test'
for model in deepseek/deepseek-v4.1 zhipu/glm-5.2; do
  meta
  printf '%s\n' tdd_split=implement "test_ban_model=$model" "test_ban_since=$SEAT" >> "$LAB/state/demo.meta"
  # Rewrite the intentional serialized task record to one current phase.
  awk '!/^tdd_split=tests$/' "$LAB/state/demo.meta" > "$LAB/meta.new"
  mv "$LAB/meta.new" "$LAB/state/demo.meta"
  printf 'blocked [key=test-dispute]: tests/greet.test.sh: try a weakened test\n' > "$LAB/state/demo.status"
  printf 'Implementer: %s\n' "$model"
  run_expect 1 "$ROOT/bin/fm-tdd-split.sh" dispute demo
done
git -C "$WT" reset -q --hard "$SEAT"
printf '\nSCENARIO: optional mutation command passes on a working implementation\n'
printf '#!/usr/bin/env bash\nprintf "new\\n"\n' > "$WT/greet.sh"
git -C "$WT" add greet.sh
git -C "$WT" -c commit.gpgsign=false commit -qm 'implement greeting'
printf 'done: ready in branch\n' > "$LAB/state/demo.status"
run_expect 0 "$ROOT/bin/fm-tdd-split.sh" mutation demo
cp "$LAB/data/demo/tdd-split-mutation.log" "$EVIDENCE/live-mutation-pass.log"
printf '\nSCENARIO: two distinct Sonnet failures recommend Opus; repeated head counts once\n'
printf '%s\n' kind=ship mode=local-only "worktree=$WT" base_branch=main harness=claude model=claude-sonnet-5-5 effort=medium tdd_split=implement "spawn_gen=s$(date +%s).1.live" > "$LAB/state/demo.meta"
run_expect 0 "$ROOT/bin/fm-escalate.sh" record-failure demo --reason 'first review refusal'
run_expect 0 "$ROOT/bin/fm-escalate.sh" record-failure demo --reason 'same head must not count twice'
printf '# next attempt\n' >> "$WT/greet.sh"
git -C "$WT" add greet.sh
git -C "$WT" -c commit.gpgsign=false commit -qm 'second implementation attempt'
run_expect 0 "$ROOT/bin/fm-escalate.sh" record-failure demo --reason 'second review refusal'
run_expect 0 "$ROOT/bin/fm-escalate.sh" check demo
cp "$LAB/data/demo/rounds.jsonl" "$EVIDENCE/live-rounds.jsonl"
printf '\nDisposable lab removed on exit. No model, PR, pipeline, or fleet process was launched.\n'
