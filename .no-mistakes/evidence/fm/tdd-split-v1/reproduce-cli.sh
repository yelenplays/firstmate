#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/Users/yelen/.no-mistakes/evidence/01M5DAWCT0WRXAZY0TJ3N80XYQ
LAB=$(mktemp -d "$PWD/.fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/nm" "$LAB/project/tests"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME='Validation' GIT_AUTHOR_EMAIL='validation@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
git -C "$LAB/project" init -q -b main
printf 'baseline\n' > "$LAB/project/implementation.sh"
git -C "$LAB/project" add .
git -C "$LAB/project" commit -qm baseline
BASE=$(git -C "$LAB/project" rev-parse HEAD)
git clone -q --bare "$LAB/project" "$LAB/origin.git"
git -C "$LAB/project" remote add origin "$LAB/origin.git"
git -C "$LAB/project" fetch -q origin
git -C "$LAB/project" switch -qc fm/lab
cat > "$LAB/nm/config.yaml" <<'YAML'
agent: [claude]
agent_config:
  claude:
    model: claude-opus-5-5
review_agents:
  fixer:
    agent: claude
    model: claude-sonnet-5-5
YAML
write_meta() {
  printf 'kind=ship\nmode=no-mistakes\nworktree=%s\nproject=%s\nbranch=fm/lab\nbase_branch=main\nmodel=claude-opus-5-5\n' "$LAB/project" "$LAB/project" > "$LAB/state/lab.meta"
}
check() {
  local label=$1 expected=$2 out rc=0
  printf '\n=== %s ===\n' "$label"
  # Exercise the installed public command. The intentionally minimal PATH has
  # no forge CLI: this checks local enforcement without contacting a forge.
  out=$(env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH=/usr/bin:/bin FM_HOME="$LAB" NM_HOME="$LAB/nm" \
    "$ROOT/bin/fm-pr-check.sh" lab https://github.com/firstmate-validation/nonexistent/pull/1 2>&1) || rc=$?
  printf '%s\nexit=%s\n' "$out" "$rc"
  printf '%s\n' "$out" | grep -F "$expected" >/dev/null || { printf 'UNEXPECTED RESULT\n'; return 1; }
  if grep -q '^pr=' "$LAB/state/lab.meta"; then printf 'PR record exists\n'; return 1; else printf 'PR record absent\n'; fi
}
write_meta
printf 'assert implementation\n' > "$LAB/project/tests/locked.test.sh"
git -C "$LAB/project" add . && git -C "$LAB/project" commit -qm 'Opus writes failing contract'
HANDOFF=$(git -C "$LAB/project" rev-parse HEAD)
printf 'implementation\n' > "$LAB/project/implementation.sh"
git -C "$LAB/project" add . && git -C "$LAB/project" commit -qm 'Sonnet implements'
printf 'test_ban_model=claude-sonnet-5-5\ntest_ban_since=%s\n' "$HANDOFF" >> "$LAB/state/lab.meta"
check 'Committed tests remain usable after the implementation handoff' 'unreachable outside the worker copy'
printf 'weakened assertion\n' > "$LAB/project/tests/locked.test.sh"
git -C "$LAB/project" add . && git -C "$LAB/project" commit -qm 'Sonnet changes locked tests'
check 'Changing a locked test blocks PR registration' 'no test authoring on claude-sonnet-5-5'
# New tasks with disallowed lanes may not introduce test files.
for model in opencode-go/deepseek-v4.1-flash zai/glm-5.3-flash; do
  write_meta
  printf 'test_ban_model=%s\n' "$model" >> "$LAB/state/lab.meta"
  check "A $model task introduces a test" "no test authoring on $model"
done
# Isolate a pipeline review-fixer test from the implementation task's own tests.
write_meta
printf 'pipeline test\n' > "$LAB/project/tests/fixer.test.sh"
git -C "$LAB/project" add . && git -C "$LAB/project" commit -qm 'no-mistakes(review): add regression coverage'
FIXER=$(git -C "$LAB/project" rev-parse HEAD)
check 'Sonnet review-fixer tests are refused even on an Opus task' 'pipeline fixer commits add or modify unauthorized test files'
printf 'test_ban_allowed=tests/fixer.test.sh\n' >> "$LAB/state/lab.meta"
check 'An explicit test-path exception permits the pipeline test' 'unreachable outside the worker copy'
write_meta
git -C "$LAB/project" revert --no-edit "$FIXER" >/dev/null
printf '\nAfter follow-up revert: test exists=%s; net test diff: ' "$([ -f "$LAB/project/tests/fixer.test.sh" ] && printf yes || printf no)"
git -C "$LAB/project" diff --name-only "$BASE" HEAD -- tests/fixer.test.sh
check 'Follow the refusal advice: revert the unauthorized pipeline test and retry' 'pipeline fixer commits add or modify unauthorized test files'
printf '\nRecovery still refused despite the unauthorized test being absent.\n'
