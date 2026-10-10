#!/usr/bin/env bash
# Eval adapter for bin/fm-jev-done-verify.sh: scores the case's done line
# against its acceptance text as a firstmate-repository task and prints
# evidenced, flag (not_evidenced or need_human), or skipped.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
mkdir -p "$WORK/home/state"
printf 'kind=ship\nproject=%s\n' "$ROOT" >"$WORK/home/state/eval-case.meta"
FM_HOME=$WORK/home "$ROOT/bin/fm-jev-done-verify.sh" eval-case \
  --done-line "$(jq -r '.input.done_line' "$CASE")" \
  --acceptance "$(jq -r '.input.acceptance' "$CASE")" >"$WORK/out" 2>"$WORK/err"
verdict=$(awk '$1 == "verdict:" { print $2; exit }' "$WORK/out")
conf=$(awk '$1 == "confidence:" { print $2; exit }' "$WORK/out")
case "$verdict" in
  evidenced) printf 'evidenced\tconf=%s\n' "$conf" ;;
  not_evidenced|need_human) printf 'flag\t%s conf=%s\n' "$verdict" "$conf" ;;
  *) printf 'skipped\t%s\n' "${verdict:-none}" ;;
esac
