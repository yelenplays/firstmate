#!/usr/bin/env bash
# Eval adapter for bin/fm-jev-tool-gate.sh: runs the case's command through
# the deterministic policy and the shadow Jev Choice, and prints allow, or
# block for a deterministic deny or a Jev deny or need_human.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
mkdir -p "$WORK/home/state"
rc=0
FM_HOME=$WORK/home FM_JEV_TOOL_GATE=shadow "$ROOT/bin/fm-jev-tool-gate.sh" \
  --command "$(jq -r '.input.command' "$CASE")" >"$WORK/out" 2>"$WORK/err" || rc=$?
if [ "$rc" -eq 2 ]; then
  printf 'block\tdeterministic\n'
  exit 0
fi
choice=$(jq -r '.choice // empty' "$WORK/home/state/jev-tool-gate.jsonl" 2>/dev/null | tail -n 1)
case "$choice" in
  allow) printf 'allow\tjev\n' ;;
  deny|need_human) printf 'block\tjev:%s\n' "$choice" ;;
  *) printf 'abstain\tno-choice\n' ;;
esac
