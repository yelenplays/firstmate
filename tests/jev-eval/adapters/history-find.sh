#!/usr/bin/env bash
# Eval adapter for bin/fm-history.sh find: lays the public record fixture out
# as history task pages, runs the local search plus the Jev rerank, and prints
# the top page's task id with the ranking that produced it.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
H=$WORK/home
mkdir -p "$H/data/history/tasks" "$H/state"
while IFS=$'\t' read -r id title; do
  printf -- '# %s\n\n%s\n' "$title" "$title" >"$H/data/history/tasks/$id.md"
done < <(jq -r '.[] | [.id, .title] | @tsv' "$(dirname "$0")/../fixtures/intake-records.json")
FM_HOME=$H "$ROOT/bin/fm-history.sh" find "$(jq -r '.input.reference' "$CASE")" >"$WORK/out" 2>"$WORK/err"
ranking=$(awk '$1 == "ranking:" { print $2; exit }' "$WORK/out")
fallback=$(awk '$1 == "fallback:" { print $2; exit }' "$WORK/out")
top=$(awk '$1 == "1." { sub(/^data\/history\/tasks\//, "", $2); sub(/\.md$/, "", $2); print $2; exit }' "$WORK/out")
printf '%s\t%s:%s\n' "${top:-none}" "${ranking:-none}" "${fallback:-none}"
