#!/usr/bin/env bash
# Eval adapter for bin/fm-jev-brief-preflight.sh (deterministic, no model
# call): renders the case's brief headings and prints the logged verdict.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
mkdir -p "$WORK/home/state"
BRIEF=$WORK/brief.md
{
  printf '# Task\n\n%s\n\n' "$(jq -r '.input.task' "$CASE")"
  if [ "$(jq -r '.input.has_dod' "$CASE")" = true ]; then
    printf '# Definition of done\nDelivery contract: mode=%s\n\nCommit on the branch.\n\n' "$(jq -r '.input.mode' "$CASE")"
  fi
  if [ "$(jq -r '.input.has_intent' "$CASE")" = true ]; then
    printf "## Captain's intent\n\n%s\n\n" "$(jq -r '.input.intent' "$CASE")"
  fi
  if [ "$(jq -r '.input.has_spec' "$CASE")" = true ]; then
    printf '## Firstmate spec\n\n%s\n\n' "$(jq -r '.input.spec' "$CASE")"
  fi
} >"$BRIEF"
FM_HOME=$WORK/home "$ROOT/bin/fm-jev-brief-preflight.sh" --brief "$BRIEF" --task eval-case \
  --kind "$(jq -r '.input.kind' "$CASE")" --mode "$(jq -r '.input.mode' "$CASE")" >"$WORK/out" 2>"$WORK/err"
log=$WORK/home/state/eval-case.jev-brief-preflight.jsonl
[ -s "$log" ] || { printf 'skipped\tno-log\n'; exit 0; }
jq -r '"\(.verdict)\t\(.missing // "" | tostring)"' "$log" | tail -n 1
