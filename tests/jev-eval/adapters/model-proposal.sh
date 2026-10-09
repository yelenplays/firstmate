#!/usr/bin/env bash
# Eval adapter for bin/fm-jev-model-proposal.sh: offers one role (the case's
# job) against a public candidate pool from fixtures/model-proposal-candidates.json
# and prints the candidate Jev proposes in its act band, none_fit when Jev
# finds no candidate fits, or no-proposal for a pick below the act band, with
# band and probability as detail.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
POOLS=$(cd "$(dirname "$0")/../fixtures" && pwd)/model-proposal-candidates.json
H=$WORK/home
mkdir -p "$H/state"
jq --slurpfile c "$CASE" '{as_of, candidates: .pools[$c[0].input.pool],
  roles: [{id: "eval-role", job: $c[0].input.job, current: []}]}' "$POOLS" >"$WORK/evidence.json"
FM_HOME=$H "$ROOT/bin/fm-jev-model-proposal.sh" --evidence "$WORK/evidence.json" \
  --dispatch "$WORK/no-dispatch.json" --out "$WORK/proposal.md" >"$WORK/out" 2>"$WORK/err" || true
rec=$H/state/jev-model-proposal.jsonl
[ -s "$rec" ] || { printf 'error\tno-record\n'; exit 0; }
tail -n 1 "$rec" | jq -r '
  if .error then "error\t\(.error)"
  elif .band == "act" then "\(.choice)\tband=act p=\(.probabilities[.choice])"
  elif .choice == "none_fit" then "none_fit\tband=\(.band) p=\(.probabilities.none_fit)"
  else "no-proposal\tband=\(.band) lean=\(.choice) p=\(.probabilities[.choice])" end'
