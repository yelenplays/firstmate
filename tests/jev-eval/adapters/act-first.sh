#!/usr/bin/env bash
# Eval adapter for bin/fm-jev-act-first.sh: writes the case's items into a
# drain file in the session-start section shape and prints the task id of the
# item Jev ranks first, or none when it printed no ranking.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
mkdir -p "$WORK/home/state"
DRAIN=$WORK/drain
{
  if jq -e '.input.items | any(.section == "d")' "$CASE" >/dev/null; then
    printf 'OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):\n'
    jq -r '.input.items[] | select(.section == "d") | .line' "$CASE"
    printf "OPEN DECISIONS: close one by answering it: bin/fm-send.sh <task> --resolve-key <key> '<answer>'\n"
  fi
  if jq -e '.input.items | any(.section == "e")' "$CASE" >/dev/null; then
    printf 'UNFINISHED EXECUTION (task, accountable owner, next action; acknowledgement is not handling):\n'
    jq -r '.input.items[] | select(.section == "e") | .line' "$CASE"
  fi
  if jq -e '.input.items | any(.section == "u")' "$CASE" >/dev/null; then
    printf 'UNREAD STATUS (newly surfaced; read these now):\n'
    jq -r '.input.items[] | select(.section == "u") | .line' "$CASE"
  fi
} >"$DRAIN"
FM_HOME=$WORK/home "$ROOT/bin/fm-jev-act-first.sh" --drain-file "$DRAIN" >"$WORK/out" 2>"$WORK/err"
first=$(awk 'NR == 1' "$WORK/out")
[ -n "$first" ] || { printf 'none\tno-ranking\n'; exit 0; }
jq -r --arg line "$first" '[.input.items[].line | split("\t")[0] | split(" ")[0] | rtrimstr(".status:")] | map(select(. as $t | $line | test("(^|[^a-z0-9-])" + $t + "([^a-z0-9-]|$)"))) | first // "unknown"' "$CASE" | tr -d '\n'
printf '\t%s\n' "$(printf '%s' "$first" | awk '{ print $NF }')"
