#!/usr/bin/env bash
# Eval adapter for bin/fm-jev-compaction.sh: places the case's segment after a
# fixed anchor segment in a cache-busted trace and prints park when the helper
# parked it, keep otherwise.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
mkdir -p "$WORK/home/state"
{
  jq -nc '{id: "anchor", role: "user", content: "Task: fix one flaky test."}'
  jq -c '{id: "seg", role: .input.role, content: .input.content}' "$CASE"
} >"$WORK/trace.jsonl"
FM_HOME=$WORK/home FM_JEV_COMPACTION=on "$ROOT/bin/fm-jev-compaction.sh" --task eval-case \
  --trace "$WORK/trace.jsonl" --out "$WORK/out.jsonl" --park-dir "$WORK/park" --cache-busted >"$WORK/out" 2>"$WORK/err"
if [ -s "$WORK/park/index.jsonl" ] && jq -e 'select(.id == "seg")' "$WORK/park/index.jsonl" >/dev/null 2>&1; then
  printf 'park\n'
elif jq -e 'select(.id == "seg")' "$WORK/out.jsonl" >/dev/null 2>&1; then
  printf 'keep\n'
else
  printf 'error\tsegment-lost\n'
fi
