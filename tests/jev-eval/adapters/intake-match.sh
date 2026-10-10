#!/usr/bin/env bash
# Eval adapter for bin/fm-jev-intake-match.sh: lays the public record fixture
# out as data/<id>/report.md with fixed modification times in an empty-backlog
# scratch home, then prints the top Jev-ranked id, or none when Jev ranked
# nothing (keyword fallback or the none? pick).
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
H=$WORK/home
mkdir -p "$H/data" "$H/state"
printf '# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n' >"$H/data/backlog.md"
i=0
while IFS=$'\t' read -r id title; do
  mkdir -p "$H/data/$id"
  printf '# %s\n' "$title" >"$H/data/$id/report.md"
  i=$((i + 1))
  touch -t "$(printf '20260101%02d%02d' $((i / 60)) $((i % 60)))" "$H/data/$id/report.md"
done < <(jq -r '.[] | [.id, .title] | @tsv' "$(dirname "$0")/../fixtures/intake-records.json")
FM_HOME=$H "$ROOT/bin/fm-jev-intake-match.sh" "$(jq -r '.input.reference' "$CASE")" >"$WORK/out" 2>"$WORK/err"
ranking=$(awk '$1 == "ranking:" { print $2; exit }' "$WORK/out")
fallback=$(awk '$1 == "fallback:" { print $2; exit }' "$WORK/out")
top=$(awk '$1 == "1." { print $2; exit }' "$WORK/out")
if [ "$ranking" = jev ] && [ -n "$top" ]; then
  printf '%s\tjev\n' "$top"
else
  printf 'none\t%s:%s\n' "${ranking:-none}" "${fallback:-none}"
fi
