#!/usr/bin/env bash
# Eval adapter for bin/fm-jev-retrieval-miss.sh: classifies the case's query
# and metadata-only retrieval envelope and prints the verdict.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
mkdir -p "$WORK/home/state"
jq -c '.input.envelope' "$CASE" >"$WORK/envelope.json"
FM_HOME=$WORK/home "$ROOT/bin/fm-jev-retrieval-miss.sh" --query "$(jq -r '.input.query' "$CASE")" \
  --envelope-file "$WORK/envelope.json" --embeddings-enabled "$(jq -r '.input.embeddings' "$CASE")" \
  --openviking-enabled "$(jq -r '.input.openviking' "$CASE")" >"$WORK/out" 2>"$WORK/err"
printf '%s\tconf=%s\n' "$(awk '$1 == "verdict:" { print $2; exit }' "$WORK/out")" "$(awk '$1 == "confidence:" { print $2; exit }' "$WORK/out")"
