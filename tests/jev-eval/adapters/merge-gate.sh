#!/usr/bin/env bash
# Eval adapter for bin/fm-jev-merge-gate.sh: runs the case's redacted merge
# evidence through the gate's own eval question and prints merge (Jev chose
# merge in its act band) or hold (anything else), with the band as detail.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
mkdir -p "$WORK/home/state"
jq -c '{id, expect: (if .gold == "merge" then "merge" else "hold" end), input}' "$CASE" >"$WORK/case.jsonl"
FM_HOME=$WORK/home "$ROOT/bin/fm-jev-merge-gate.sh" eval --cases "$WORK/case.jsonl" >"$WORK/report.json" 2>"$WORK/err"
jq -r '.rows[0] | if .choice == "merge" and .band == "act" then "merge\t\(.band)" else "hold\t\(.choice // "none")/\(.band // "none")" end' "$WORK/report.json"
