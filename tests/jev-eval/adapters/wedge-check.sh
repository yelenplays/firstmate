#!/usr/bin/env bash
# Eval adapter for bin/fm-jev-wedge-check.sh --class: sends the case's pane
# tail as a firstmate-repository task with its idle age and prints escalate or
# suppress with the stuck class; no verdict prints abstain.
set -eu
CASE=$1 WORK=$2
ROOT=$FM_JEV_EVAL_CODE_ROOT
mkdir -p "$WORK/home/state"
printf 'kind=ship\nproject=%s\n' "$ROOT" >"$WORK/home/state/eval-case.meta"
args=(--class --task eval-case --state-dir "$WORK/home/state")
idle=$(jq -r '.input.idle_secs // empty' "$CASE")
[ -z "$idle" ] || args+=(--idle-secs "$idle")
out=$(jq -r '.input.tail' "$CASE" | FM_HOME=$WORK/home FM_JEV_WEDGE_WARN_EVERY_SECS=0 \
  "$ROOT/bin/fm-jev-wedge-check.sh" "${args[@]}" 2>"$WORK/err") || out=
verdict=${out%% *}
class=${out#* }
[ "$class" != "$out" ] || class=none
printf '%s\tclass=%s\n' "${verdict:-abstain}" "$class"
