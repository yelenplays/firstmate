#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/Users/yelen/.no-mistakes/evidence/01M5FSAP09E7P0EN195XAT673W
LAB=$(mktemp -d "$ROOT/.test-runtime/fm-lab.registration.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bash bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/os-home"
# Use real OS tools only. No gh is exposed, deliberately exercising the public
# no-forge-head fallback. Nothing is published to a remote hosting service.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$LAB/os-home" FM_HOME="$LAB" NM_HOME="$LAB/nm"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM TMUX
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
URL=https://github.com/example/isolated-registration/pull/1
printf 'Surface: real fm-pr-check.sh, real Git and filesystem; no fake executable or forge.\n'
printf 'The URL is an inert registration input, not evidence of a remotely opened PR.\n'
printf 'gh availability: '; command -v gh || true
git init -q --bare "$LAB/origin.git"
git init -q -b main "$LAB/project"
printf 'base\n' > "$LAB/project/README.md"
git -C "$LAB/project" add README.md
git -C "$LAB/project" commit -qm base
git -C "$LAB/project" remote add origin "$LAB/origin.git"
git -C "$LAB/project" push -q origin main
git --git-dir="$LAB/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$LAB/origin.git" "$LAB/worker"
git -C "$LAB/worker" checkout -qb fm/test-phase
mkdir "$LAB/worker/tests"
printf '#!/bin/sh\ntest "$(sh "$(dirname "$0")/../answer.sh")" = 42\n' > "$LAB/worker/tests/answer.test.sh"
printf '#!/bin/sh\necho 0\n' > "$LAB/worker/answer.sh"
git -C "$LAB/worker" add .
git -C "$LAB/worker" commit -qm 'tests-first author supplies a failing acceptance test'
SINCE=$(git -C "$LAB/worker" rev-parse HEAD)
set +e
sh "$LAB/worker/tests/answer.test.sh"; RED=$?
set -e
[ "$RED" = 1 ]
printf 'Tests-first acceptance before implementation: exit=%s\n' "$RED"
printf '#!/bin/sh\necho 42\n' > "$LAB/worker/answer.sh"
git -C "$LAB/worker" add answer.sh
git -C "$LAB/worker" commit -qm 'implement answer without editing acceptance test'
sh "$LAB/worker/tests/answer.test.sh"
printf 'Tests-first acceptance after implementation: exit=0\n'
git -C "$LAB/worker" push -q origin fm/test-phase
BASELINE=$(git -C "$LAB/worker" rev-parse HEAD)
meta() {
  local id=$1 model=$2 since=${3:-} allowed=${4:-}
  printf 'kind=ship\nmode=no-mistakes\nworktree=%s\nproject=%s\nbranch=fm/test-phase\nbase_branch=main\nmodel=%s\n' "$LAB/worker" "$LAB/project" "$model" > "$LAB/state/$id.meta"
  case "$model" in opus) ;; *) printf 'test_ban_model=%s\n' "$model" >> "$LAB/state/$id.meta" ;; esac
  [ -z "$since" ] || printf 'test_ban_since=%s\n' "$since" >> "$LAB/state/$id.meta"
  [ -z "$allowed" ] || printf 'test_ban_allowed=%s\n' "$allowed" >> "$LAB/state/$id.meta"
  return 0
}
check() {
  local id=$1 want=$2 rc=0
  printf '\n=== %s ===\n' "$id"
  bash "$ROOT/bin/fm-pr-check.sh" "$id" "$URL" > "$LAB/$id.out" 2> "$LAB/$id.err" || rc=$?
  printf 'CLI exit=%s expected=%s\n' "$rc" "$want"
  # Only show the actual interface result, not unrelated supervision advisories.
  grep -E '^(error:|armed:)' "$LAB/$id.out" "$LAB/$id.err" || true
  [ "$rc" = "$want" ]
  if [ "$want" = 0 ]; then
    grep '^pr=' "$LAB/state/$id.meta"
    test -f "$LAB/state/$id.check.sh"
    printf 'Persisted merge-monitor registration exists.\n'
  else
    ! grep -q '^pr=' "$LAB/state/$id.meta"
    test ! -e "$LAB/state/$id.check.sh"
    printf 'No PR registration or merge monitor was persisted.\n'
  fi
}
for model in sonnet haiku opencode-go/deepseek-v4.1-flash zai/glm-5.3-flash; do
  id=$(printf '%s' "$model" | tr '/.' '--')
  meta "$id" "$model"
  check "$id" 1
done
meta opus-author opus
check opus-author 0
meta sonnet-handoff sonnet "$SINCE"
check sonnet-handoff 0
for attack in edit delete rename; do
  git -C "$LAB/worker" reset -q --hard "$BASELINE"
  case "$attack" in
    edit) printf '#!/bin/sh\nexit 0\n' > "$LAB/worker/tests/answer.test.sh" ;;
    delete) git -C "$LAB/worker" rm -q tests/answer.test.sh ;;
    rename) git -C "$LAB/worker" mv tests/answer.test.sh notes.txt ;;
  esac
  git -C "$LAB/worker" add -A
  git -C "$LAB/worker" commit -qm "attempt to $attack locked test"
  meta "sonnet-$attack" sonnet "$SINCE"
  check "sonnet-$attack" 1
done
git -C "$LAB/worker" reset -q --hard "$BASELINE"
meta explicit-exception opencode-go/deepseek-v4.1-flash '' tests/answer.test.sh
check explicit-exception 0
meta wrong-exception opencode-go/deepseek-v4.1-flash '' tests/other.test.sh
check wrong-exception 1
# Unreadable origin: Opus may register via a locally published named head;
# the banned-worker half still refuses before registration.
git -C "$LAB/worker" update-ref -d refs/remotes/origin/main
meta opus-no-base opus
check opus-no-base 0
meta sonnet-no-base sonnet "$SINCE"
check sonnet-no-base 1
git -C "$LAB/worker" fetch -q origin main:refs/remotes/origin/main
# A commit claiming pipeline authorship with no invocation ledger cannot gain
# permission merely by naming an allowlisted worker in task metadata.
printf '#!/bin/sh\nexit 0\n' > "$LAB/worker/tests/fixer.test.sh"
git -C "$LAB/worker" add tests/fixer.test.sh
git -C "$LAB/worker" commit -qm 'no-mistakes(review): claimed fixer adds a test'
git -C "$LAB/worker" push -q origin fm/test-phase
meta unrecorded-fixer opus
check unrecorded-fixer 1
git -C "$LAB/worker" revert --no-edit HEAD >/dev/null
git -C "$LAB/worker" push -q origin fm/test-phase
meta reverted-fixer opus
check reverted-fixer 0
printf '\nAll local CLI scenarios completed. Lab cleanup follows automatically.\n'
