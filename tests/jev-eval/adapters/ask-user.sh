#!/usr/bin/env bash
# Eval adapter for bin/fm-jev-ask-user.sh: builds one task with an open
# ask-user gate from the case, runs the real script, and prints act or
# escalate (with its code). The send seam is a no-op, so nothing reaches a worker.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
HOME_DIR=$WORK/home TASK=eval-task
mkdir -p "$HOME_DIR/state/$TASK.inbox/handled" "$HOME_DIR/data/$TASK" "$WORK/project" "$WORK/no-wikis"
KEY=nm-01EVALCASE00000000000000-$(jq -r '.input.step' "$CASE")
ROUND=$(jq -r '.input.round' "$CASE")
[ "$ROUND" -le 1 ] || KEY=$KEY-r$ROUND
FINDINGS=$HOME_DIR/data/$TASK/$KEY-findings.txt
jq -r '.input.findings | map("id: \(.id)\nseverity: \(.severity // "")\nfile: \(.file // "")\nline: \(.line // "")\ndescription: \(.description // "")\nauthority: ask-user") | join("\n---\n")' "$CASE" >"$FINDINGS"
IDS=$(jq -r '.input.findings | map(.id) | join(",")' "$CASE")
{
  printf '# Task\n## Captain'"'"'s intent\n%s\n\n' "$(jq -r '.input.intent' "$CASE")"
  printf '## Firstmate spec\n%s\n\n# Rules\n' "$(jq -r '.input.spec' "$CASE")"
} >"$HOME_DIR/data/$TASK/brief.md"
n=0
while IFS= read -r steer; do
  n=$((n + 1))
  printf 'schema=fm-task-inbox.v1\nat=2026-01-01T00:00:00Z\n--\n%s\n' "$steer" >"$HOME_DIR/state/$TASK.inbox/handled/$(printf '%03d' "$n").msg"
done < <(jq -c '.input.steers[]' "$CASE" | jq -r '.')
printf 'kind=ship\nproject=%s\n' "$WORK/project" >"$HOME_DIR/state/$TASK.meta"
printf 'needs-decision [at=1700000000] [key=%s]: ask-user findings=%s file=%s\n' "$KEY" "$IDS" "$FINDINGS" >"$HOME_DIR/state/$TASK.status"
rc=0
FM_HOME=$HOME_DIR FM_WIKIS_ROOT=$WORK/no-wikis FM_JEV_ASK_USER_SEND=true \
  "$ROOT/bin/fm-jev-ask-user.sh" "$TASK" "$KEY" --round "$ROUND" >"$WORK/out" 2>"$WORK/err" || rc=$?
case $rc in
  0) echo act ;;
  2) printf 'escalate\t%s\n' "$(awk 'NR == 1 { sub(/:.*/, ""); print $3 }' "$WORK/out")" ;;
  *) cat "$WORK/err" >&2; exit 1 ;;
esac
