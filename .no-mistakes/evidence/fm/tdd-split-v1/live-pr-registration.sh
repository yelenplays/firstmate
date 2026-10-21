#!/usr/bin/env bash
# Drive the real registration CLI against an existing GitHub PR; no forge writes,
# fake CLIs, model invocation records, pipeline controls, or terminal sessions.
set -euo pipefail
ROOT=/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5F2YD3Y9VR56Y7KB4XVCWM0
EVIDENCE=/Users/yelen/.no-mistakes/evidence/01M5F2YD3Y9VR56Y7KB4XVCWM0
cd "$ROOT"
WT="$ROOT/.test-runtime/live-pr"
LAB=$(mktemp -d "$ROOT/.test-runtime/registration-home.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" FM_DATA_OVERRIDE="$LAB/data" FM_PROJECTS_OVERRIDE="$LAB/projects" NM_HOME="$LAB/nm"
export TMPDIR="$ROOT/.test-runtime/phase-tmp"
unset FM_ROOT_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM
mkdir -p "$NM_HOME"
URL=https://github.com/yelenplays/firstmate/pull/187
HEAD_PR=$(git -C "$WT" rev-parse origin/validation-pr)
HEAD_LOCAL=$(git -C "$WT" rev-parse HEAD)
BASE=$(git -C "$WT" rev-parse origin/main)
printf 'Product code: %s\nInput PR: %s\nFetched PR head: %s\nOlder local HEAD: %s\n' "$(git rev-parse HEAD)" "$URL" "$HEAD_PR" "$HEAD_LOCAL"
[ "$HEAD_PR" != "$HEAD_LOCAL" ]

task() {
  local id=$1 model=$2 ban=${3:-}
  printf 'kind=ship\nmode=no-mistakes\nmodel=%s\nbranch=fm/tdd-split-v1\nworktree=%s\nproject=%s\nbase_branch=main\n' "$model" "$WT" "$WT" > "$LAB/state/$id.meta"
  [ -z "$ban" ] || printf 'test_ban_model=%s\n' "$ban" >> "$LAB/state/$id.meta"
}
check() {
  local id=$1 expected=$2 fragment=${3:-} rc=0
  "$ROOT/bin/fm-pr-check.sh" "$id" "$URL" > "$LAB/$id.out" 2> "$LAB/$id.err" || rc=$?
  printf '\n=== %s (expected %s): exit %s ===\n' "$id" "$expected" "$rc"
  # These are the real public CLI's outputs and generated registration contract.
  tail -8 "$LAB/$id.err"
  while IFS= read -r line; do printf '%s\n' "$line"; done < "$LAB/$id.out"
  if [ "$expected" = refuse ]; then
    [ "$rc" -ne 0 ]
    grep -Fq "$fragment" "$LAB/$id.err"
    ! grep -q '^pr=' "$LAB/state/$id.meta"
    [ ! -e "$LAB/state/$id.check.sh" ]
    printf 'Observed: no PR registration or merge poll created.\n'
  else
    [ "$rc" -eq 0 ]
    grep -Fxq "pr=$URL" "$LAB/state/$id.meta"
    grep -Fxq "pr_head=$HEAD_PR" "$LAB/state/$id.meta"
    [ -f "$LAB/state/$id.check.sh" ]
    grep '^pr' "$LAB/state/$id.meta"
    printf 'Observed: canonical PR and exact forge head recorded; merge poll armed, not executed.\n'
  fi
  cp "$LAB/state/$id.meta" "$EVIDENCE/$id.meta.txt"
}

# Genuine published test changes must be checked even with an older local HEAD.
for model in opencode-go/deepseek-v4.1-flash zai/glm-5.3-flash claude-sonnet-5-5; do
  case "$model" in *deepseek*) id=live-deepseek ;; *glm*) id=live-glm ;; *) id=live-sonnet ;; esac
  task "$id" "$model" "$model"
  check "$id" refuse "no test authoring on $model"
done

# Optional attribution accepts when history is unavailable; the worker check
# remains strict in exactly the same situation. Do not alter the forge.
git -C "$WT" update-ref -d refs/remotes/origin/main
task live-opus-no-base claude-opus-5-5
check live-opus-no-base accept
task live-sonnet-no-base claude-sonnet-5-5 claude-sonnet-5-5
check live-sonnet-no-base refuse 'test-file check cannot resolve the base branch origin/main'
git -C "$WT" update-ref refs/remotes/origin/main "$BASE"

# Exercise actual pipeline commits already published on the PR. Config-only
# attribution is a supported product path; no invocation database is fabricated.
printf '%s\n' 'agent: [claude]' 'agent_config:' '  claude:' '    model: claude-opus-5-5' 'agent_args_override:' '  claude:' '    - --model' '    - claude-sonnet-5-5' 'review_agents:' '  fixer:' '    agent: claude' '    model: claude-opus-5-5' > "$NM_HOME/config.yaml"
task live-native-sonnet claude-opus-5-5
check live-native-sonnet refuse 'pipeline fixer commits add or modify unauthorized test files'

printf '%s\n' 'agent: [claude]' 'agent_config:' '  claude:' '    model: claude-haiku-5-5' 'agent_args_override:' '  claude: ["--model=claude-opus-5-5"]' 'review_agents:' '  fixer:' '    agent: claude' '    model: claude-sonnet-5-5' > "$NM_HOME/config.yaml"
task live-native-opus claude-opus-5-5
check live-native-opus accept

rm "$NM_HOME/config.yaml"
task live-unknown-fixer claude-opus-5-5
check live-unknown-fixer accept
printf '\nCompleted; disposable home removed by EXIT trap. No forge writes or pipeline commands were executed.\n'
