#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/Users/yelen/.no-mistakes/evidence/01M5FEG8P20S1TF90YMEC8GAVC
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_PR_CHECK_MERGE
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
LAB=$(mktemp -d "$ROOT/.test-phase-tmp/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB"
export FM_HOME=$LAB NM_HOME=$LAB/nm
mkdir -p "$NM_HOME"
WT=$LAB/projects/probe
mkdir -p "$WT"
git -C "$WT" init -q
git -C "$WT" remote add origin https://github.com/yelenplays/firstmate.git
git -C "$WT" fetch -q origin main fm/tdd-split-v1
git -C "$WT" checkout -q -b probe origin/fm/tdd-split-v1
PR_HEAD=$(git -C "$WT" rev-parse HEAD)
BASE=$(git -C "$WT" merge-base origin/main HEAD)
printf 'Product code: %s\nExisting remote PR: https://github.com/yelenplays/firstmate/pull/187\nPublished input head: %s\nMerge base: %s\nNo upstream writes or pipeline commands performed.\n' "$(git -C "$ROOT" rev-parse HEAD)" "$PR_HEAD" "$BASE"
# Keep the worker HEAD behind the real published head; fm-pr-check must inspect
# the forge result rather than this clean local HEAD.
git -C "$WT" checkout -q --detach "$BASE"
write_meta() {
  local id=$1 model=$2
  printf 'kind=ship\nmode=no-mistakes\nyolo=off\nworktree=%s\nproject=%s\nbranch=fm/tdd-split-v1\nbase_branch=main\nmodel=%s\n' "$WT" "$WT" "$model" > "$LAB/state/$id.meta"
  case "$model" in *deepseek*|*glm*) printf 'test_ban_model=%s\n' "$model" >> "$LAB/state/$id.meta" ;; esac
}
check() {
  local id=$1 expected=$2 rc=0
  printf '\n=== %s: expected %s ===\n' "$id" "$expected"
  "$ROOT/bin/fm-pr-check.sh" "$id" https://github.com/yelenplays/firstmate/pull/187 > "$EVIDENCE/$id.stdout.log" 2> "$EVIDENCE/$id.stderr.log" || rc=$?
  printf 'exit=%s\n' "$rc"
  python3 - "$EVIDENCE/$id.stdout.log" "$EVIDENCE/$id.stderr.log" <<'PY'
from pathlib import Path
import sys
for p in sys.argv[1:]:
    for line in Path(p).read_text().splitlines():
        if line.startswith(('error:', 'armed:')):
            print(line)
PY
  if [ "$expected" = refuse ]; then
    [ "$rc" != 0 ] && [ ! -f "$LAB/state/$id.check.sh" ] && ! grep -q '^pr=' "$LAB/state/$id.meta"
    grep -q 'no test authoring on' "$EVIDENCE/$id.stderr.log"
    printf 'Persisted result: no PR record and no merge poll.\n'
  else
    [ "$rc" = 0 ] && [ -f "$LAB/state/$id.check.sh" ]
    grep '^pr=' "$LAB/state/$id.meta"
    grep "^pr_head=$PR_HEAD$" "$LAB/state/$id.meta"
    printf 'Persisted result: exact published PR head and merge poll recorded.\n'
  fi
}
write_meta deepseek-forbidden opencode-go/deepseek-v4.1-flash
check deepseek-forbidden refuse
write_meta glm-forbidden zai/glm-5
check glm-forbidden refuse
printf '%s\n' 'agent: [opencode]' 'agent_config:' '  opencode:' '    model: anthropic/claude-opus-5-5' 'agent_args_override:' '  opencode:' '    - -m' '    - opencode-go/deepseek-v4.1-flash' > "$NM_HOME/config.yaml"
write_meta native-deepseek-fixer claude-opus-5-5
check native-deepseek-fixer refuse
printf '%s\n' 'agent: [opencode]' 'agent_config:' '  opencode:' '    model: anthropic/claude-opus-5-5' 'agent_args_override:' '  opencode:' '    - -mopencode-go/deepseek-v4.1-flash' > "$NM_HOME/config.yaml"
write_meta unparsed-native-fixer claude-opus-5-5
check unparsed-native-fixer refuse
printf '%s\n' 'agent: [claude]' 'agent_config:' '  claude:' '    model: claude-opus-5-5' > "$NM_HOME/config.yaml"
write_meta opus-authorized claude-opus-5-5
check opus-authorized accept
# A banned implementer may carry the test author's unchanged handoff tests.
write_meta inherited-handoff opencode-go/deepseek-v4.1-flash
printf 'test_ban_since=%s\n' "$PR_HEAD" >> "$LAB/state/inherited-handoff.meta"
check inherited-handoff accept
write_meta changed-handoff opencode-go/deepseek-v4.1-flash
printf 'test_ban_since=3905158c\n' >> "$LAB/state/changed-handoff.meta"
check changed-handoff refuse
# Explicit path exceptions must permit only the captain-named files.
write_meta captain-path-exception zai/glm-5
git -C "$WT" diff --name-only "$BASE" "$PR_HEAD" -- tests | while IFS= read -r path; do
  printf 'test_ban_allowed=%s\n' "$path"
done >> "$LAB/state/captain-path-exception.meta"
check captain-path-exception accept
# Missing base only disables pipeline attribution; it must not weaken workers.
git -C "$WT" update-ref -d refs/remotes/origin/main
write_meta opus-unreadable-base claude-opus-5-5
check opus-unreadable-base accept
write_meta deepseek-unreadable-base opencode-go/deepseek-v4.1-flash
printf '\n=== deepseek-unreadable-base: expected strict refusal ===\n'
rc=0
"$ROOT/bin/fm-pr-check.sh" deepseek-unreadable-base https://github.com/yelenplays/firstmate/pull/187 > "$EVIDENCE/deepseek-unreadable-base.stdout.log" 2> "$EVIDENCE/deepseek-unreadable-base.stderr.log" || rc=$?
printf 'exit=%s\n' "$rc"
[ "$rc" != 0 ] && [ ! -f "$LAB/state/deepseek-unreadable-base.check.sh" ]
grep 'error: test-file check cannot resolve the base branch' "$EVIDENCE/deepseek-unreadable-base.stderr.log"
! grep -q '^pr=' "$LAB/state/deepseek-unreadable-base.meta"
printf 'Persisted result: no PR record and no merge poll.\n'
