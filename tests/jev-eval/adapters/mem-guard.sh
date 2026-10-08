#!/usr/bin/env bash
# Eval adapter for bin/fm-jev-mem-guard.sh (deterministic, no model call):
# feeds the case's meminfo fixture and prints the guard's status.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
mkdir -p "$WORK"
jq -j '.input.meminfo' "$CASE" >"$WORK/meminfo"
FM_JEV_MEM_GUARD_MEMINFO=$WORK/meminfo "$ROOT/bin/fm-jev-mem-guard.sh" --json >"$WORK/out"
jq -r '"\(.status)\t\(.reason // "")"' "$WORK/out"
