#!/usr/bin/env bash
set -euo pipefail
ROOT="$PWD"
EVIDENCE=/Users/yelen/.no-mistakes/evidence/01M5DJP1TKSR5VAZWYB5FJ334P
export TMPDIR="$ROOT/.phase-test-tmp"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TASK_ID FM_SUPERVISION_ACTOR FM_MEMORY_CAPTURE_CHILD
LAB=$(mktemp -d "$TMPDIR/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME="$LAB"
run() {
  printf '\n$'; printf ' %q' "$@"; printf '\n'
  "$@"
}
expect() {
  local want=$1 rc=0; shift
  run "$@" || rc=$?
  printf '[exit %s; expected %s]\n' "$rc" "$want"
  [ "$rc" -eq "$want" ]
}
{
  run bin/fm-rules.sh add --check bang-interactive terminal-only 'Never hand over ! sudo commands; copy the command with pbcopy and ask for a real Terminal window.'
  run bin/fm-rules.sh add short-replies 'Keep routine replies short.'
  run bin/fm-rules.sh add short-replies 'Keep routine replies short.'
  run bin/fm-rules.sh list
  run bin/fm-rules.sh unchecked
  bin/fm-rules.sh unchecked | grep -q short-replies
  run bin/fm-rules.sh render
  run bin/fm-rules.sh nocheck short-replies 'Reply length needs judgment about the task.'
  [ -z "$(bin/fm-rules.sh unchecked)" ]
  run bin/fm-rules.sh revoke short-replies
  expect 1 bin/fm-rules.sh revoke short-replies
  run bin/fm-rules.sh list
  printf '\nPersisted operator rule-store contract:\n'
  readfile="$LAB/config/captain-rules.md" python3 -c 'import os; print(open(os.environ["readfile"]).read())'
} > "$EVIDENCE/rules-store.txt" 2>&1
{
  before=$(shasum -a 256 "$LAB/config/captain-rules.md")
  expect 3 bin/fm-rules.sh add 'Bad Id' 'Do not save invalid identifiers.'
  expect 3 bin/fm-rules.sh add invalid-comment 'Injected <!-- seen=99 --> comment'
  expect 3 bin/fm-rules.sh check terminal-only not-a-check
  expect 4 env FM_RULES_MAX_CHARS=200 bin/fm-rules.sh add overflow 'This new rule must not fit the intentionally tiny block budget.'
  [ "$before" = "$(shasum -a 256 "$LAB/config/captain-rules.md")" ]
  printf '\nAll refused operations left the persisted store unchanged.\n'
  printf 'mate-test\n' > "$LAB/.fm-secondmate-home"
  expect 2 bin/fm-rules.sh add unauthorized 'Do not save divergent secondmate rules.'
  [ "$before" = "$(shasum -a 256 "$LAB/config/captain-rules.md")" ]
  rm "$LAB/.fm-secondmate-home"
  run bin/fm-rules.sh list
} > "$EVIDENCE/rules-refusals.txt" 2>&1
{
  run bin/fm-rule-guard.sh list
  for text in '! sudo darwin-rebuild switch' 'no worries, run ! sudo darwin-rebuild switch' 'No worries now run ! sudo -v' 'Kein Problem: `! gh auth login`' 'Never use the old command; run ! sudo -v instead.' '! security add-generic-password -s example'; do
    printf '\n$ printf %%s\\n %q | bin/fm-rule-guard.sh scan\n' "$text"
    rc=0; printf '%s\n' "$text" | bin/fm-rule-guard.sh scan || rc=$?
    printf '[exit %s; expected 1]\n' "$rc"
    [ "$rc" -eq 1 ]
  done
  for text in 'Never hand the captain a `! sudo` line.' 'Use pbcopy, not ! sudo.' 'Never run ! sudo -v' 'Use pbcopy instead of ! gh auth login.' '! git status' 'sudo darwin-rebuild switch (paste into Terminal)'; do
    printf '\n$ printf %%s\\n %q | bin/fm-rule-guard.sh scan\n' "$text"
    printf '%s\n' "$text" | bin/fm-rule-guard.sh scan
    printf '[exit 0: safe instruction accepted]\n'
  done
} > "$EVIDENCE/rules-scan.txt" 2>&1
{
  run bin/fm-brief.sh memory-ship example-project --mode local-only
  run bin/fm-brief.sh memory-scout example-project --scout
  cp "$LAB/data/memory-ship/brief.md" "$EVIDENCE/ship-brief.md"
  cp "$LAB/data/memory-scout/brief.md" "$EVIDENCE/scout-brief.md"
  for kind in ship scout; do
    testfile="$LAB/data/memory-$kind/brief.md" python3 - <<'PY'
import os
text = open(os.environ['testfile']).read()
section = text.split('# Captain rules\n', 1)[1].split('\n# ', 1)[0]
assert 'Never hand over ! sudo commands; copy the command with pbcopy and ask for a real Terminal window.' in section
assert 'task scope and safety rules still win' in section
print('Generated brief captain-rules section:\n' + section)
PY
  done
} > "$EVIDENCE/rules-briefs.txt" 2>&1
{
  run bin/fm-rules.sh add terminal-only 'Never hand over ! sudo commands; copy the command with pbcopy and ask for a real Terminal window.'
  run bin/fm-rules.sh weekly-arm
  run "$LAB/state/captain-rules-weekly.check.sh"
  first=$(bin/fm-rules.sh weekly-check)
  [ -z "$first" ]
  printf 'Second weekly check: silent, as required.\n'
  bin/fm-rules.sh report --transcripts "$LAB/transcripts" > "$EVIDENCE/weekly-report.md"
  printf '\n$ bin/fm-rules.sh report --transcripts <isolated-home>/transcripts\n'
  reportfile="$EVIDENCE/weekly-report.md" python3 -c 'import os; print(open(os.environ["reportfile"]).read())'
  [ -z "$("$LAB/state/captain-rules-weekly.check.sh")" ]
  printf 'Armed check after report: silent, as required.\n'
  run bin/fm-rules.sh weekly-disarm
  [ ! -e "$LAB/state/captain-rules-weekly.check.sh" ]
  [ ! -e "$LAB/state/captain-rules-weekly.check-trust" ]
} > "$EVIDENCE/rules-weekly.txt" 2>&1
{
  printf 'Live-primary prerequisite check from run worktree:\n'
  if command -v tmux; then :; else printf 'tmux is not on PATH; the required private fm-lab tmux socket cannot be started. No host search, installation, alternate checkout, or default session was used.\n'; fi
  command -v claude
  claude --version
  printf '\nMarked lab session projection in this gate (no bypass):\n'
  out=$(bin/fm-rules.sh session </dev/null)
  [ -z "$out" ]
  printf 'No block emitted: gate stand-down remains active even with a marked lab home.\n'
  printf '\nA real primary must be driven through the authorized private socket from this worktree. Missing tmux and the existing primary-scope gate stand-down leave model-level delivery, correction/retraction, and Stop interception untested.\n'
} > "$EVIDENCE/live-primary-prerequisites.txt" 2>&1
printf 'Manual CLI scenarios completed; evidence saved to %s\n' "$EVIDENCE"
