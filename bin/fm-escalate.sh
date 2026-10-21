#!/usr/bin/env bash
# fm-escalate.sh - the model escalation ladder: a task whose current incarnation
# failed two rounds is relaunched one step stronger, and a task already on the
# strongest step goes to the captain.
#
# Usage: fm-escalate.sh record-failure <task-id> --reason <text> [--head <sha>]
#        fm-escalate.sh check <task-id>
#        fm-escalate.sh run <task-id>
#
# A failed round is a distinct head the current incarnation produced that
# failed review: an accepted `failure` verdict for it in
# data/<id>/cross-review.jsonl (bin/fm-cross-review.sh collect) recorded at or
# after the incarnation's start, or a failure firstmate recorded for it with
# `record-failure` - a refused done:, a pipeline that gave up, a review that
# sent the work back. The incarnation is the task record's spawn_gen=
# (s<epoch>.<pid>.<rand>, bin/fm-spawn.sh), so every relaunch, including the
# escalation itself, starts counting again from zero.
#
# The ladder, by the task record's model=:
#   - Claude Opus, Claude Fable, GPT Sol, and an unset or `default` model: top
#     of the ladder; two failed rounds go to the captain.
#   - a known cheap model (Haiku, DeepSeek, GLM, Kimi, Qwen, MiniMax): next
#     step FM_ESCALATE_SONNET_* (Sonnet at medium effort).
#   - Claude Sonnet and every other model: next step FM_ESCALATE_OPUS_* (Opus
#     at medium effort), so a model the ladder does not know, which may be
#     stronger than Sonnet, is never escalated down.
#
# record-failure
#   Appends {at, head, reason, spawn_gen} to data/<id>/rounds.jsonl; <head>
#   defaults to the worker copy's HEAD. Prints the round count `check` would.
# check
#   Prints key=value lines: current=<harness>/<model>/<effort>,
#   failed_rounds=<n>, heads=<sha,...>, and action=none, action=relaunch with
#   next_harness=, next_model=, next_effort=, or action=captain with reason=.
#   Exit 0.
# run
#   Acts on check: for action=relaunch it relaunches the task onto the next
#   step with bin/fm-control.sh, and for a tdd-split ship on its implementer
#   (tdd_split=implement) records that step as tdd_split_impl_harness=,
#   tdd_split_impl_model=, and tdd_split_impl_effort=, so a later handoff
#   returns to it. Exit 0 for action=none and a relaunch, 3 for action=captain,
#   which firstmate raises with the captain, and 1 when it cannot act.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
FM_CONTROL_BIN="${FM_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

FM_ESCALATE_ROUNDS=2
FM_ESCALATE_SONNET_HARNESS=claude
FM_ESCALATE_SONNET_MODEL=claude-sonnet-5-5
FM_ESCALATE_SONNET_EFFORT=medium
FM_ESCALATE_OPUS_HARNESS=claude
FM_ESCALATE_OPUS_MODEL=claude-opus-5-5
FM_ESCALATE_OPUS_EFFORT=medium

die() { echo "error: $*" >&2; exit 1; }
usage() {
  echo "usage: fm-escalate.sh record-failure <task-id> --reason <text> [--head <sha>]" >&2
  echo "       fm-escalate.sh check|run <task-id>" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || die "fm-escalate.sh needs jq"
case "${1:-}" in record-failure|check|run) CMD=$1 ;; *) usage ;; esac
[ "$#" -ge 2 ] || usage
ID=$2
shift 2
REASON=
HEAD_ARG=
while [ "$#" -gt 0 ]; do
  [ "$CMD" = record-failure ] && [ "$#" -ge 2 ] || usage
  case "$1" in
    --reason) REASON=$2 ;;
    --head) HEAD_ARG=$2 ;;
    *) usage ;;
  esac
  shift 2
done
case "$ID" in ''|*[!A-Za-z0-9._-]*|.*) die "invalid task id" ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "task $ID has no task record"
WT=$(fm_dod_meta_value "$META" worktree)
HARNESS=$(fm_dod_meta_value "$META" harness)
MODEL=$(fm_dod_meta_value "$META" model)
EFFORT=$(fm_dod_meta_value "$META" effort)
GEN=$(fm_dod_meta_value "$META" spawn_gen)
ROUNDS="$DATA/$ID/rounds.jsonl"
REVIEWS="$DATA/$ID/cross-review.jsonl"

# The incarnation's start in epoch seconds, read from spawn_gen=s<epoch>.*;
# 0 when the record predates spawn_gen=, so every record counts.
gen_start() {
  local epoch=${GEN#s}
  epoch=${epoch%%.*}
  case "$epoch" in ''|*[!0-9]*) echo 0 ;; *) echo "$epoch" ;; esac
}

# Prints the distinct heads of the current incarnation's failed rounds, one per line.
failed_heads() {
  local start
  start=$(gen_start)
  {
    if [ -f "$REVIEWS" ]; then
      jq -r --argjson start "$start" '
        select(.accepted == true and .verdict == "failure" and (.head // "") != ""
          and ((.at // "") | (try fromdateiso8601 catch 0)) >= $start) | .head
      ' "$REVIEWS" 2>/dev/null || die "cannot read $REVIEWS"
    fi
    if [ -f "$ROUNDS" ]; then
      jq -r --arg gen "$GEN" 'select(.spawn_gen == $gen and (.head // "") != "") | .head' "$ROUNDS" 2>/dev/null \
        || die "cannot read $ROUNDS"
    fi
  } | awk '!seen[$0]++'
}

# Sets NEXT_HARNESS, NEXT_MODEL, and NEXT_EFFORT to the step above <model>;
# 1 when <model> is the top of the ladder.
next_step() {  # <model>
  local lower
  fm_test_ban_model_applies "$1" || return 1
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *haiku*|*deepseek*|*glm*|*kimi*|*qwen*|*minimax*)
      NEXT_HARNESS=$FM_ESCALATE_SONNET_HARNESS NEXT_MODEL=$FM_ESCALATE_SONNET_MODEL NEXT_EFFORT=$FM_ESCALATE_SONNET_EFFORT ;;
    *)
      NEXT_HARNESS=$FM_ESCALATE_OPUS_HARNESS NEXT_MODEL=$FM_ESCALATE_OPUS_MODEL NEXT_EFFORT=$FM_ESCALATE_OPUS_EFFORT ;;
  esac
}

# Sets HEADS, COUNT, and ACTION, plus NEXT_* or CAPTAIN_REASON, and prints the
# check's key=value lines.
check() {
  HEADS=$(set -o pipefail; failed_heads) || die "cannot read the round records of $ID"
  COUNT=$(printf '%s' "$HEADS" | grep -c . || true)
  printf 'task=%s\ncurrent=%s/%s/%s\nfailed_rounds=%s\nheads=%s\n' \
    "$ID" "$HARNESS" "${MODEL:-default}" "${EFFORT:-default}" "$COUNT" "$(printf '%s' "$HEADS" | paste -sd, -)"
  if [ "$COUNT" -lt "$FM_ESCALATE_ROUNDS" ]; then
    ACTION=none
    echo "action=none"
  elif next_step "${MODEL:-default}"; then
    ACTION=relaunch
    printf 'action=relaunch\nnext_harness=%s\nnext_model=%s\nnext_effort=%s\n' "$NEXT_HARNESS" "$NEXT_MODEL" "$NEXT_EFFORT"
  else
    ACTION=captain
    CAPTAIN_REASON="$COUNT failed rounds on ${MODEL:-default}, the top of the escalation ladder"
    printf 'action=captain\nreason=%s\n' "$CAPTAIN_REASON"
  fi
}

case "$CMD" in
  record-failure)
    [ -n "$REASON" ] || usage
    if [ -z "$HEAD_ARG" ]; then
      HEAD_ARG=$(git -C "$WT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || die "cannot read the worker copy's HEAD; pass --head"
    fi
    mkdir -p "$DATA/$ID" || die "cannot create $DATA/$ID"
    jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg head "$HEAD_ARG" --arg reason "$REASON" --arg gen "$GEN" \
      '{at: $at, head: $head, reason: $reason, spawn_gen: $gen}' >>"$ROUNDS" || die "cannot append to $ROUNDS"
    check
    ;;
  check)
    check
    ;;
  run)
    check
    case "$ACTION" in
      none) exit 0 ;;
      captain) exit 3 ;;
    esac
    NOTE="escalation: $COUNT rounds on $HARNESS/${MODEL:-default} failed (heads $(printf '%s' "$HEADS" | paste -sd' ' -)), so this task moves one step up the ladder to $NEXT_MODEL. Continue the brief from the current worker copy, starting with what those rounds got wrong."
    "$FM_CONTROL_BIN" "$ID" relaunch --harness "$NEXT_HARNESS" --model "$NEXT_MODEL" --effort "$NEXT_EFFORT" --note "$NOTE" \
      || die "relaunch onto $NEXT_MODEL failed; the task stays on ${MODEL:-default}"
    if [ "$(fm_dod_meta_value "$META" tdd_split)" = implement ]; then
      LOCK=$(fm_meta_lock_path "$META") || die "invalid task record lock path"
      fm_lock_acquire_wait "$LOCK" || die "cannot lock the task record"
      TMP=$(mktemp "$STATE/.fm-escalate-meta.XXXXXX") || { fm_lock_release "$LOCK" || true; die "cannot write the task record"; }
      if ! { grep -v -e '^tdd_split_impl_harness=' -e '^tdd_split_impl_model=' -e '^tdd_split_impl_effort=' "$META"
             printf 'tdd_split_impl_harness=%s\ntdd_split_impl_model=%s\ntdd_split_impl_effort=%s\n' "$NEXT_HARNESS" "$NEXT_MODEL" "$NEXT_EFFORT"
           } >"$TMP" || ! mv -f -- "$TMP" "$META"; then
        rm -f -- "$TMP"
        fm_lock_release "$LOCK" || true
        die "relaunched onto $NEXT_MODEL but could not record it as the tdd-split implementer in $META"
      fi
      fm_lock_release "$LOCK" || true
    fi
    echo "escalated: $ID relaunched onto $NEXT_HARNESS/$NEXT_MODEL ($NEXT_EFFORT)"
    ;;
esac
