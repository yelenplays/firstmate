#!/usr/bin/env bash
# Eval adapter for bin/fm-jev-skill-select.sh in live selection mode (no
# overlay, so nothing is loaded): offers the public skill roster snapshot with
# every description approved and prints the primary skill, none for a none or
# search_external answer, or the status when no primary cleared the floor.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
SKILLS=$(cd "$(dirname "$0")/../fixtures/skills" && pwd)
H=$WORK/home
mkdir -p "$H/config" "$H/state"
: >"$H/config/jev-skill-select-live"
find "$SKILLS" -name SKILL.md -print0 | sort -z | xargs -0 shasum -a 256 | awk '{ print $1 }' | jq -R . | jq -s . >"$H/config/jev-skill-public.json"
FM_HOME=$H FM_JEV_SKILL_SELECT=live "$ROOT/bin/fm-jev-skill-select.sh" --harness "$(jq -r '.input.harness' "$CASE")" \
  --task-id eval-case --summary "$(jq -r '.input.summary' "$CASE")" --skills-dir "$SKILLS" >"$WORK/out" 2>"$WORK/err" || true
rec=$H/state/eval-case.jev-skills.json
[ -s "$rec" ] || { printf 'error\tno-record\n'; exit 0; }
jq -r 'if .status == "clear" and (.primary // "") != "" and .primary != "none" and .primary != "search_external" then "\(.primary)\tconf=\(.confidence)"
  elif (.primary // "none") == "none" or .primary == "search_external" then "none\t\(.status):\(.primary // "none")"
  else "none\t\(.status):\(.primary)" end' "$rec"
