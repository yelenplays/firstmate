#!/usr/bin/env bash
# Eval adapter for bin/fm-jev.sh: asks the case's pick, yes, or score
# question and prints the answer, or escalate when the command escalated.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
mkdir -p "$WORK/home"
type=$(jq -r '.input.type' "$CASE")
mapfile -t opts < <(jq -r '.input.options[]' "$CASE")
rc=0
FM_HOME=$WORK/home "$ROOT/bin/fm-jev.sh" "$type" "$(jq -r '.input.state' "$CASE")" \
  "$(jq -r '.input.question' "$CASE")" ${opts[@]+"${opts[@]}"} >"$WORK/out" 2>"$WORK/err" || rc=$?
line=$(awk 'NF { print; exit }' "$WORK/out")
case "$rc:$line" in
  0:*) set -- $line; ans=$2; [ "$type" != yes ] || { p=${3#p=}; ans=$(awk -v p="$p" 'BEGIN { print (p >= 0.5 ? "yes" : "no") }'); }; printf '%s\t%s\n' "$ans" "$line" ;;
  2:*) printf 'escalate\t%s\n' "$line" ;;
  *) printf 'error\t%s\n' "$(head -n 1 "$WORK/err")" ;;
esac
