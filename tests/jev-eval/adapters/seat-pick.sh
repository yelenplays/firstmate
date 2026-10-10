#!/usr/bin/env bash
# Eval adapter for bin/fm-seat-pick.sh pick: offers the case's seats and work
# summary and prints the dispatched seat, or lead-decides with Jev's suggestion.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
mkdir -p "$WORK/home/state"
jq -c '.input.seats' "$CASE" | FM_HOME=$WORK/home FM_SEAT_PICK=1 "$ROOT/bin/fm-seat-pick.sh" pick \
  --role "$(jq -r '.input.role' "$CASE")" --task "$(jq -r '.input.task' "$CASE")" >"$WORK/out" 2>"$WORK/err" || true
jq -r 'if .action == "dispatch" then "\(.seat)\tband=\(.band) conf=\(.confidence)" else "lead-decides\tseat=\(.seat // "none") band=\(.band // "none") \(.reason // "")" end' "$WORK/out"
