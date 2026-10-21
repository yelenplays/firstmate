#!/usr/bin/env bash
set -euo pipefail
ROOT=/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5F2YD3Y9VR56Y7KB4XVCWM0
EVIDENCE=/Users/yelen/.no-mistakes/evidence/01M5F2YD3Y9VR56Y7KB4XVCWM0
cd "$ROOT"
LAB=$(mktemp -d "$ROOT/.test-runtime/handoff-home.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" FM_DATA_OVERRIDE="$LAB/data" FM_PROJECTS_OVERRIDE="$LAB/projects" NM_HOME="$LAB/nm" TMPDIR="$ROOT/.test-runtime/phase-tmp"
unset FM_ROOT_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM
WT="$LAB/projects/policy-check"
URL=https://github.com/yelenplays/firstmate/pull/187
PR_HEAD=$(git -C .test-runtime/live-pr rev-parse origin/validation-pr)
BASE=$(git -C .test-runtime/live-pr rev-parse origin/main)
git init -q "$WT"
git -C "$WT" remote add origin https://github.com/yelenplays/firstmate.git
git -C "$WT" fetch -q origin "$BASE"
git -C "$WT" update-ref refs/remotes/origin/main "$BASE"
git -C "$WT" checkout -q --detach "$BASE"
if git -C "$WT" cat-file -e "$PR_HEAD^{commit}" 2>/dev/null; then
  echo 'Precondition failed: PR head is already present'; exit 1
fi
printf 'Product code: %s\nReal PR: %s\nInitial local HEAD: %s\nPR head initially absent: %s\n' "$(git rev-parse HEAD)" "$URL" "$BASE" "$PR_HEAD"

# A recorded tests-first handoff at the published tree leaves its tests intact.
# Registration must fetch the real forge head before evaluating that boundary.
printf 'kind=ship\nmode=no-mistakes\nmodel=claude-sonnet-5-5\ntest_ban_model=claude-sonnet-5-5\ntest_ban_since=%s\nbase_branch=main\nworktree=%s\nproject=%s\n' "$PR_HEAD" "$WT" "$WT" > "$LAB/state/live-handed-tests.meta"
rc=0
bin/fm-pr-check.sh live-handed-tests "$URL" > "$LAB/accepted.out" 2> "$LAB/accepted.err" || rc=$?
printf '\n=== unchanged handed-over tests: exit %s ===\n' "$rc"
tail -8 "$LAB/accepted.err"
while IFS= read -r line; do printf '%s\n' "$line"; done < "$LAB/accepted.out"
[ "$rc" -eq 0 ]
grep -Fxq "pr_head=$PR_HEAD" "$LAB/state/live-handed-tests.meta"
[ -f "$LAB/state/live-handed-tests.check.sh" ]
git -C "$WT" cat-file -e "$PR_HEAD^{commit}"
[ "$(git -C "$WT" rev-parse HEAD)" = "$BASE" ]
printf 'Observed: missing published object fetched from real origin; local HEAD unchanged; exact PR head registered.\n'
cp "$LAB/state/live-handed-tests.meta" "$EVIDENCE/live-handed-tests.meta.txt"

# An earlier, genuine published commit handed off test files that later genuine
# commits changed. The same registration request must refuse those changes.
SINCE=$(git -C "$WT" log --format='%H' --grep='^feat: ban test authoring on every lane' "$PR_HEAD" -1)
[ -n "$SINCE" ]
printf 'kind=ship\nmode=no-mistakes\nmodel=claude-sonnet-5-5\ntest_ban_model=claude-sonnet-5-5\ntest_ban_since=%s\nbase_branch=main\nworktree=%s\nproject=%s\n' "$SINCE" "$WT" "$WT" > "$LAB/state/live-changed-handed-tests.meta"
rc=0
bin/fm-pr-check.sh live-changed-handed-tests "$URL" > "$LAB/refused.out" 2> "$LAB/refused.err" || rc=$?
printf '\n=== handed-over tests changed after %s: exit %s ===\n' "$SINCE" "$rc"
tail -3 "$LAB/refused.err"
[ "$rc" -ne 0 ]
grep -Fq 'unauthorized test files' "$LAB/refused.err"
! grep -q '^pr=' "$LAB/state/live-changed-handed-tests.meta"
[ ! -e "$LAB/state/live-changed-handed-tests.check.sh" ]
printf 'Observed: modified handed-over tests prevent PR registration and poll creation.\n'
cp "$LAB/state/live-changed-handed-tests.meta" "$EVIDENCE/live-changed-handed-tests.meta.txt"
printf '\nDisposable home and fetched repository removed by EXIT trap; no forge writes or model calls.\n'
