#!/usr/bin/env bash
# Eval adapter for bin/fm-home-route.sh decide: registers the public
# pseudonymized secondmate scopes in a scratch home, approves them, and prints
# the routed lead (main or a mate id) or judgment-needed with its reason.
# The backup judge is switched off so only Jev is scored: a route Jev did not
# decide prints as judgment-needed with the typed reason.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
SCOPES=$(dirname "$0")/../fixtures/home-scopes.json
H=$WORK/home
mkdir -p "$H/data" "$H/config" "$H/state"
cp "$SCOPES" "$H/config/jev-mate-public-scopes.json"
jq -r --arg h "$H" 'to_entries[] | "- \(.key) - Persistent second mate (home: \($h)/mates/\(.key); scope: \(.value); projects: none; added 2026-01-01)"' "$SCOPES" >"$H/data/secondmates.md"
FM_HOME=$H FM_BACKUP_JUDGE_CMD=false "$ROOT/bin/fm-home-route.sh" decide eval-case --project "$(jq -r '.input.project' "$CASE")" \
  --public-summary "$(jq -r '.input.summary' "$CASE")" >"$WORK/out" 2>"$WORK/err" || true
rec=$H/state/home-route/eval-case.json
[ -s "$rec" ] || { printf 'judgment-needed\tno-record\n'; exit 0; }
jq -r 'if .source != "jev" and .source != "local_only" then "judgment-needed\t\(.reason) p=\(.probability)" else "\(.lead)\tp=\(.probability) consult=\(.consult | join(","))" end' "$rec"
