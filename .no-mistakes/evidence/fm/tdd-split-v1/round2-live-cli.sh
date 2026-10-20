#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB=$(mktemp -d "$PWD/.fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/nm" "$LAB/project/tests"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Validation GIT_AUTHOR_EMAIL=validation@example.invalid
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
printf 'candidate=%s\n' "$(git rev-parse HEAD)"
git -C "$LAB/project" init -q -b main
printf 'baseline\n' > "$LAB/project/implementation.sh"
git -C "$LAB/project" add . && git -C "$LAB/project" commit -qm baseline
git clone -q --bare "$LAB/project" "$LAB/origin.git"
git -C "$LAB/project" remote add origin "$LAB/origin.git"
git -C "$LAB/project" fetch -q origin
git -C "$LAB/project" switch -qc fm/lab
printf '%s\n' 'agent: [claude]' 'agent_config:' '  claude:' '    model: claude-opus-5-5' 'review_agents:' '  fixer:' '    agent: claude' '    model: claude-sonnet-5-5' > "$LAB/nm/config.yaml"
write_meta() {
  printf 'kind=ship\nmode=no-mistakes\nworktree=%s\nproject=%s\nbranch=fm/lab\nbase_branch=main\nmodel=claude-opus-5-5\n' "$LAB/project" "$LAB/project" > "$LAB/state/lab.meta"
}
commit() { git -C "$LAB/project" add -A; git -C "$LAB/project" commit -qm "$1"; }
check() {
  local label=$1 expected=$2 out rc=0
  printf '\n=== %s ===\n' "$label"
  # Real local remote: prove named-head reachability without publishing anything.
  git -C "$LAB/project" push -q origin HEAD:refs/heads/fm/lab
  out=$(env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE PATH=/usr/bin:/bin FM_HOME="$LAB" NM_HOME="$LAB/nm" "$ROOT/bin/fm-pr-check.sh" lab https://github.com/firstmate-validation/nonexistent/pull/1 2>&1) || rc=$?
  printf '%s\nexit=%s\n' "$out" "$rc"
  if [ "$expected" = accept ]; then
    [ "$rc" = 0 ]
    grep '^pr=' "$LAB/state/lab.meta"
    test -s "$LAB/state/lab.pr-poll-registration"
    printf 'PR metadata and poll registration persisted in isolated home\n'
  else
    [ "$rc" = 1 ]
    printf '%s\n' "$out" | grep -F "$expected" >/dev/null
    ! grep -q '^pr=' "$LAB/state/lab.meta"
    printf 'PR record absent\n'
  fi
}
write_meta
printf 'assert contract\n' > "$LAB/project/tests/locked.test.sh"
commit 'Opus authors contract'
HANDOFF=$(git -C "$LAB/project" rev-parse HEAD)
printf 'implementation\n' > "$LAB/project/implementation.sh"
commit 'Sonnet implements'
printf 'test_ban_model=claude-sonnet-5-5\ntest_ban_since=%s\n' "$HANDOFF" >> "$LAB/state/lab.meta"
check 'Locked tests survive implementation and permit local registration' accept
for change in edit delete rename; do
  write_meta
  printf 'test_ban_model=claude-sonnet-5-5\ntest_ban_since=%s\n' "$HANDOFF" >> "$LAB/state/lab.meta"
  case "$change" in
    edit) printf 'weakened\n' > "$LAB/project/tests/locked.test.sh" ;;
    delete) rm "$LAB/project/tests/locked.test.sh" ;;
    rename) mv "$LAB/project/tests/locked.test.sh" "$LAB/project/notes.txt" ;;
  esac
  commit "Sonnet $change locked tests"
  check "A locked-test $change refuses registration" 'no test authoring on claude-sonnet-5-5'
  git -C "$LAB/project" revert --no-edit HEAD >/dev/null
 done
for model in opencode-go/deepseek-v4.1-flash zai/glm-5.3-flash; do
  write_meta
  printf 'test_ban_model=%s\n' "$model" >> "$LAB/state/lab.meta"
  check "A $model task may not author tests" "no test authoring on $model"
done
write_meta
printf 'unauthorized test\n' > "$LAB/project/tests/fixer.test.sh"
printf 'unauthorized edit\n' > "$LAB/project/tests/locked.test.sh"
commit 'no-mistakes(review): introduce and change tests'
FIXER=$(git -C "$LAB/project" rev-parse HEAD)
check 'A Sonnet fixer on an Opus task cannot add or modify tests' 'pipeline fixer commits add or modify unauthorized test files'
write_meta
printf 'test_ban_allowed=tests/fixer.test.sh\n' >> "$LAB/state/lab.meta"
check 'A single authorized path does not permit its unauthorized sibling' 'tests/locked.test.sh'
printf 'test_ban_allowed=tests/locked.test.sh\n' >> "$LAB/state/lab.meta"
check 'Explicit path exceptions permit exactly the two named tests' accept
write_meta
# Restore only one changed file: the remaining unauthorized test must refuse.
git -C "$LAB/project" checkout "$FIXER^" -- tests/locked.test.sh
commit 'Restore only the modified test'
check 'A partial revert must not clear remaining unauthorized tests' 'tests/fixer.test.sh'
# Restore the remaining introduced path using an ordinary follow-up commit.
git -C "$LAB/project" rm -q tests/fixer.test.sh
commit 'Finish restoring pre-fixer tests'
printf '\nRestored paths relative to pre-fixer tree (must be empty):\n'
git -C "$LAB/project" diff --exit-code "$FIXER^" HEAD -- tests
check 'Restoring every unauthorized test clears the registration refusal' accept
write_meta
printf 'test step coverage\n' > "$LAB/project/tests/opus-step.test.sh"
commit 'no-mistakes(test): Opus adds coverage'
check 'An allowlisted pipeline step can author tests' accept
# Reproduce the exact previous-round remedy with git revert on another commit.
write_meta
printf 'bad test\n' > "$LAB/project/tests/revert.test.sh"
commit 'no-mistakes(review): unauthorized regression'
check 'A second unauthorized fixer test is refused before reverting' 'tests/revert.test.sh'
git -C "$LAB/project" revert --no-edit HEAD >/dev/null
printf '\nAfter git revert: test exists=%s\n' "$([ -e "$LAB/project/tests/revert.test.sh" ] && printf yes || printf no)"
check 'git revert of unauthorized fixer tests clears refusal' accept
write_meta
printf 'model policy check\n' > "$LAB/project/tests/model.test.sh"
commit 'no-mistakes(review): model policy coverage'
for model in opencode-go/deepseek-v4.1-flash zai/glm-5.3-flash claude-opus-5-5 claude-fable-5-1 openai-codex/gpt-6.1-sol; do
  write_meta
  printf 'review_agents:\n  fixer:\n    agent: claude\n    model: %s\n' "$model" > "$LAB/nm/config.yaml"
  case "$model" in
    *deepseek*|*glm*) check "The pipeline fixer model $model refuses test authorship" "no test authoring on $model" ;;
    *) check "The pipeline fixer model $model permits test authorship" accept ;;
  esac
done
printf '\nAll isolated CLI scenarios completed; no forge was contacted and no agent model was invoked.\n'
