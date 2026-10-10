#!/usr/bin/env bash
# Eval adapter for bin/fm-jev-status-triage.sh: sends the case's status line
# as a firstmate-repository task (the free-text path) and prints escalate or
# suppress; no verdict prints abstain.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
mkdir -p "$WORK/home/state"
printf 'kind=ship\nproject=%s\n' "$ROOT" >"$WORK/home/state/eval-case.meta"
verdict=$(jq -r '.input.line' "$CASE" | FM_HOME=$WORK/home "$ROOT/bin/fm-jev-status-triage.sh" \
  --task eval-case --state-dir "$WORK/home/state" 2>"$WORK/err") || verdict=
noul=$(jq -r '.noul // empty' "$WORK/home/state/jev-status-triage.jsonl" 2>/dev/null | tail -n 1)
printf '%s\tnoul=%s\n' "${verdict:-abstain}" "${noul:-none}"
