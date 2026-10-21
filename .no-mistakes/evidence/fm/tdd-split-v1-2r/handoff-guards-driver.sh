#!/usr/bin/env bash
set -eu
ROOT=$PWD
export TMPDIR="$ROOT/.test-tmp"
LAB=$(mktemp -d "$TMPDIR/fm-lab-guards.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_CONTROL_BIN
mkdir -p "$LAB/projects/base"
git -C "$LAB/projects/base" init -q -b main
printf 'printf "0\\n"\n' > "$LAB/projects/base/counter.sh"
git -C "$LAB/projects/base" add counter.sh
git -C "$LAB/projects/base" -c user.name=Lab -c user.email=lab@example.invalid commit -qm base
case_setup() {
  id=$1
  git clone -q "$LAB/projects/base" "$LAB/projects/$id"
  wt="$LAB/projects/$id"
  git -C "$wt" checkout -qb "fm/$id"
  mkdir -p "$wt/tests" "$LAB/data/$id"
  printf '[ "$(bash counter.sh)" = 1 ]\n' > "$wt/tests/counter.test.sh"
  git -C "$wt" add tests
  git -C "$wt" -c user.name=Lab -c user.email=lab@example.invalid commit -qm 'failing behavioral test'
  printf '%s\n' kind=ship mode=local-only "worktree=$wt" base_branch=main harness=claude model=claude-opus-5-5 tdd_split=tests tdd_split_impl_harness=claude tdd_split_impl_model=sonnet tdd_split_impl_effort=medium > "$LAB/state/$id.meta"
  printf 'done: tests-ready %s\n' "$(git -C "$wt" rev-parse HEAD)" > "$LAB/state/$id.status"
  printf 'Fail-to-pass command: `%s`\n' "$2" > "$LAB/data/$id/brief.md"
}
reject() {
  printf '\nSCENARIO: %s\nCOMMAND: fm-tdd-split.sh handoff %s --timeout 1\n' "$1" "$id"
  set +e
  out=$("$ROOT/bin/fm-tdd-split.sh" handoff "$id" --timeout 1 2>&1)
  rc=$?
  set -e
  printf '%s\nexit=%s\n' "$out" "$rc"
  [ "$rc" -eq 1 ]
  [[ "$out" == *"$2"* ]]
  grep -qx tdd_split=tests "$LAB/state/$id.meta"
  printf 'Persisted phase: tests (no handoff)\n'
  if [ -f "$LAB/data/$id/tdd-split-red.log" ]; then python3 - "$LAB/data/$id/tdd-split-red.log" <<'PY'
import pathlib,sys
print(pathlib.Path(sys.argv[1]).read_text())
PY
  fi
}
case_setup dirty 'for t; do bash "$t" || exit 1; done'
printf '# draft\n' >> "$wt/tests/counter.test.sh"
reject 'Uncommitted test cannot transfer' 'uncommitted changes'
case_setup production 'for t; do bash "$t" || exit 1; done'
printf 'printf "1\\n"\n' > "$wt/counter.sh"
git -C "$wt" add counter.sh
git -C "$wt" -c user.name=Lab -c user.email=lab@example.invalid commit -qm 'unauthorized implementation'
reject 'Test seat cannot implement production code' 'not tests: counter.sh'
case_setup green 'for t; do bash "$t" || exit 1; done'
printf '[ "$(bash counter.sh)" = 0 ]\n' > "$wt/tests/counter.test.sh"
git -C "$wt" add tests
git -C "$wt" -c user.name=Lab -c user.email=lab@example.invalid commit -qm 'test existing output'
reject 'Already-passing test cannot transfer' 'pass on the base'
case_setup missing 'fm-intentionally-missing-tdd-command "$@"'
reject 'Unavailable test command cannot count as red' 'could not run (exit 127)'
case_setup timed 'sleep 5'
reject 'Timed-out command cannot count as red' 'hit its 1s bound'
printf '\nAll real CLI refusals preserved the test-seat phase. No harness, transport, or control stub was used.\n'
