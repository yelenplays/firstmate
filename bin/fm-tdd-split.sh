#!/usr/bin/env bash
# fm-tdd-split.sh - hand a tdd-split ship from its test seat to its implementer.
# bin/fm-tdd-split-lib.sh owns the profile; this script is its step 3.
#
# Usage: fm-tdd-split.sh handoff <task-id> [--timeout <seconds>]
#   Run by firstmate when a ship whose state/<id>.meta records tdd_split=tests
#   reports `done: tests-ready <sha>`. In order, it refuses (exit 1, naming why)
#   unless:
#     - the task's current status line is that report and passes the seat's
#       done gate (clean worker copy; its commits since the base change only
#       tests, at least one);
#     - the task's brief, data/<id>/brief.md, declares one fail-to-pass command;
#     - that command, run with `bash -c` from the root of a private clone of the
#       seat's HEAD with the changed test files as "$@", exits red: non-zero,
#       and neither 124 (the --timeout bound, default 900 seconds), 126 or 127
#       (the command could not run), nor a signal death above 128.
#   The run's output and exit status go to data/<id>/tdd-split-red.log. It then
#   relaunches the task onto the recorded implementer (bin/fm-control.sh
#   relaunch with tdd_split_impl_harness=, tdd_split_impl_model=, and
#   tdd_split_impl_effort=) and records tdd_split=implement and
#   tdd_split_tests=<seat HEAD> in the task record. A failed relaunch leaves
#   tdd_split=tests, so the handoff can simply be run again.
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
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

die() { echo "error: $*" >&2; exit 1; }
usage() { echo "usage: fm-tdd-split.sh handoff <task-id> [--timeout <seconds>]" >&2; exit 2; }

[ "${1:-}" = handoff ] || usage
[ "$#" -ge 2 ] || usage
ID=$2
shift 2
TIMEOUT=900
while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout)
      [ "$#" -ge 2 ] || usage
      TIMEOUT=$2
      shift 2 ;;
    --timeout=*) TIMEOUT=${1#--timeout=}; shift ;;
    *) usage ;;
  esac
done
case "$TIMEOUT" in ''|*[!0-9]*|0) die "--timeout needs a positive number of seconds" ;; esac
case "$ID" in ''|*[!A-Za-z0-9._-]*|.*) die "invalid task id" ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "task $ID has no task record"
[ "$(fm_dod_meta_value "$META" kind)" = ship ] || die "task $ID is not a ship"
[ "$(fm_dod_meta_value "$META" tdd_split)" = tests ] \
  || die "task $ID is not a tdd-split ship on its test seat (tdd_split=$(fm_dod_meta_value "$META" tdd_split))"
WT=$(fm_dod_meta_value "$META" worktree)
IMPL_HARNESS=$(fm_dod_meta_value "$META" tdd_split_impl_harness)
IMPL_MODEL=$(fm_dod_meta_value "$META" tdd_split_impl_model)
IMPL_EFFORT=$(fm_dod_meta_value "$META" tdd_split_impl_effort)
[ -n "$IMPL_HARNESS" ] && [ -n "$IMPL_MODEL" ] || die "task $ID records no tdd-split implementer"
! grep -q '^pr=' "$META" || die "task $ID already records a PR, so its test seat cannot hand over"

LINE=$(status_current_line "$STATE/$ID.status" ship)
case "$(status_line_note "$LINE")" in
  "$FM_TDD_SPLIT_READY_VERB"|"$FM_TDD_SPLIT_READY_VERB "*) ;;
  *) die "task $ID has not reported done: $FM_TDD_SPLIT_READY_VERB" ;;
esac
[ "$(status_line_verb "$LINE")" = "done" ] || die "task $ID has not reported done: $FM_TDD_SPLIT_READY_VERB"
REASON=$(fm_tdd_split_accept_done ship "$WT" "$LINE" "$META") || die "$REASON"
COMMAND=$(fm_tdd_split_check_command "$DATA/$ID/brief.md") \
  || die "$DATA/$ID/brief.md declares no single $FM_TDD_SPLIT_CHECK_LABEL \`<command>\` line"
SEAT_HEAD=$(git -C "$WT" rev-parse --verify 'HEAD^{commit}') || die "cannot read the worker copy's HEAD"
TESTS=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ -e "$WT/$path" ] || continue
  TESTS+=("$path")
done < <(fm_tdd_split_changed_files "$WT" "$(fm_dod_meta_value "$META" base_branch)")
[ "${#TESTS[@]}" -gt 0 ] || die "the test seat's commits delete tests but add or change none"

# The red run happens in a private clone, so whatever the tests write never
# reaches the worker copy the implementer inherits.
RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-tdd-split.XXXXXX") || die "cannot create a scratch directory"
trap 'rm -rf -- "$RUN_DIR"' EXIT
git clone -q --shared --no-checkout -- "$WT" "$RUN_DIR/clone" 2>/dev/null || die "cannot clone the worker copy"
git -C "$RUN_DIR/clone" checkout -q --detach "$SEAT_HEAD" 2>/dev/null || die "cannot check out $SEAT_HEAD in the clone"
mkdir -p "$DATA/$ID"
LOG="$DATA/$ID/tdd-split-red.log"
set +e
(cd "$RUN_DIR/clone" && fm_run_timed "$TIMEOUT" bash -c "$COMMAND" fm-tdd-split "${TESTS[@]}") >"$LOG" 2>&1 </dev/null
RC=$?
set -e
printf '\nfm-tdd-split: head=%s exit=%s command=%s\n' "$SEAT_HEAD" "$RC" "$COMMAND" >>"$LOG"
if [ "$RC" -eq 0 ]; then
  die "the handed-over tests pass on the base, so they pin nothing the change adds; see $LOG"
elif fm_timed_out "$RC"; then
  die "the fail-to-pass command hit its ${TIMEOUT}s bound; see $LOG"
elif [ "$RC" -eq 126 ] || [ "$RC" -eq 127 ] || [ "$RC" -gt 128 ]; then
  die "the fail-to-pass command could not run (exit $RC), which proves nothing about the tests; see $LOG"
fi

NOTE="tdd-split handoff: the test seat committed failing tests up to $SEAT_HEAD (red on the base, exit $RC; $LOG). Implement the change in the brief until those tests pass, without changing them, then continue with the brief's Definition of done."
RELAUNCH=("$FM_CONTROL_BIN" "$ID" relaunch --harness "$IMPL_HARNESS" --model "$IMPL_MODEL")
[ -z "$IMPL_EFFORT" ] || RELAUNCH+=(--effort "$IMPL_EFFORT")
"${RELAUNCH[@]}" --note "$NOTE" || die "relaunch onto $IMPL_MODEL failed; the task stays on its test seat and the handoff can be run again"

LOCK=$(fm_meta_lock_path "$META") || die "invalid task record lock path"
fm_lock_acquire_wait "$LOCK" || die "cannot lock the task record"
TMP=$(mktemp "$STATE/.fm-tdd-split-meta.XXXXXX") || { fm_lock_release "$LOCK" || true; die "cannot write the task record"; }
if ! { grep -v -e '^tdd_split=' -e '^tdd_split_tests=' "$META"; printf 'tdd_split=implement\ntdd_split_tests=%s\n' "$SEAT_HEAD"; } >"$TMP" \
  || ! mv -f -- "$TMP" "$META"; then
  rm -f -- "$TMP"
  fm_lock_release "$LOCK" || true
  die "relaunched onto $IMPL_MODEL but could not record tdd_split=implement in $META"
fi
fm_lock_release "$LOCK" || true
echo "tdd-split: $ID handed over at $SEAT_HEAD to $IMPL_HARNESS/$IMPL_MODEL${IMPL_EFFORT:+ ($IMPL_EFFORT)}"
