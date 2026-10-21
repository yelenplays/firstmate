#!/usr/bin/env bash
# fm-tdd-split.sh - move a tdd-split ship between its test seat and its
# implementer. bin/fm-tdd-split-lib.sh owns the profile; this script is its
# steps 3 and 5.
#
# Usage: fm-tdd-split.sh handoff <task-id> [--timeout <seconds>]
#        fm-tdd-split.sh dispute <task-id>
#        fm-tdd-split.sh mutation <task-id> [--timeout <seconds>]
#
# Before handoff or mutation runs its command, it must resolve the base and
# merge-base and find at least one changed test still present at HEAD. Either
# an unreadable base or an empty test list refuses without running the command.
#
# handoff
#   Run by firstmate when a ship whose state/<id>.meta records tdd_split=tests
#   reports `done: tests-ready <sha>`. In order, it refuses (exit 1, naming why)
#   unless:
#     - the task's current status line is that report and passes the seat's
#       done gate (clean worker copy; its commits since the base change only
#       tests, at least one; or, back on the seat after a dispute or the
#       mutation gate, only tests since tdd_split_dispute_head=);
#     - the task's brief, data/<id>/brief.md, declares one fail-to-pass command;
#     - that command, run with `bash -c` from the root of a private clone of the
#       base with the test files the branch changes checked out from the seat's
#       HEAD, and those files as "$@", exits red: non-zero, and neither 124 (the
#       --timeout bound, default 900 seconds), 126 or 127 (the command could not
#       run), nor a signal death above 128.
#   Exit status alone cannot distinguish an assertion failure from every
#   setup or syntax failure. Firstmate must inspect the log for a meaningful
#   missing-behavior failure; the command does not verify each test separately.
#   The run's output and exit status go to data/<id>/tdd-split-red.log. It then
#   records test_ban_since=<seat HEAD>, relaunches the task onto the recorded
#   implementer (bin/fm-control.sh relaunch with tdd_split_impl_harness=,
#   tdd_split_impl_model=, and tdd_split_impl_effort=), and records
#   tdd_split=implement and tdd_split_tests=<seat HEAD>. A failed relaunch
#   leaves tdd_split=tests, so the handoff can simply be run again. A first
#   handoff is refused once the record names a PR; a later one is not.
#
# dispute
#   Accepts the implementer's `blocked [key=test-dispute]: <test>: <reason>`
#   and sends the task back to the test seat. Refused unless the record shows
#   tdd_split=implement, that key is open as blocked, the worker copy is clean,
#   and fm-dod-lib.sh's test-authoring gate accepts the implementer. It relaunches the seat
#   (FM_TDD_SPLIT_SEAT_*) with the dispute in its note, records tdd_split=tests
#   and tdd_split_dispute_head=<implementer HEAD>, and closes the key with a
#   `resolved [key=test-dispute]` line. Firstmate answers a dispute it rejects
#   with bin/fm-send.sh --resolve-key test-dispute instead.
#
# mutation
#   The optional mutation gate, run on the implementer's done: when the brief
#   declares `Mutation command: `<command>``. Refused unless the record shows
#   tdd_split=implement, the current status line is a done:, and
#   fm-dod-lib.sh's test-authoring gate accepts the implementer.
#   It runs the command bounded like
#   the red run, in a private clone of the worker copy's HEAD with the test
#   files the branch changes as "$@", logging to
#   data/<id>/tdd-split-mutation.log. Exit 0 when it passes; exit 1 when it
#   cannot run, times out, or is refused; exit 3 when it fails, after sending
#   the task back to the test seat the same way a dispute does.
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
usage() {
  echo "usage: fm-tdd-split.sh handoff|mutation <task-id> [--timeout <seconds>]" >&2
  echo "       fm-tdd-split.sh dispute <task-id>" >&2
  exit 2
}

case "${1:-}" in handoff|dispute|mutation) CMD=$1 ;; *) usage ;; esac
[ "$#" -ge 2 ] || usage
ID=$2
shift 2
TIMEOUT=900
while [ "$#" -gt 0 ]; do
  [ "$CMD" != dispute ] || usage
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
STATUS="$STATE/$ID.status"
[ -f "$META" ] && [ ! -L "$META" ] || die "task $ID has no task record"
[ "$(fm_dod_meta_value "$META" kind)" = ship ] || die "task $ID is not a ship"
PHASE=$(fm_dod_meta_value "$META" tdd_split)
WT=$(fm_dod_meta_value "$META" worktree)
BASE_BRANCH=$(fm_dod_meta_value "$META" base_branch)
DISPUTE_HEAD=$(fm_dod_meta_value "$META" tdd_split_dispute_head)
COMMAND=$(fm_tdd_split_check_command "$DATA/$ID/brief.md") || COMMAND=

# Rewrites the task record under its lock: drops every <key>= line given before
# `--`, then appends the key=value lines after it.
meta_rewrite() {  # <key>... -- <line>...
  local drop=() lock tmp
  while [ "$1" != -- ]; do drop+=(-e "^$1="); shift; done
  shift
  lock=$(fm_meta_lock_path "$META") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  tmp=$(mktemp "$STATE/.fm-tdd-split-meta.XXXXXX") || { fm_lock_release "$lock" || true; return 1; }
  if ! { grep -v "${drop[@]}" "$META"; printf '%s\n' "$@"; } >"$tmp" || ! mv -f -- "$tmp" "$META"; then
    rm -f -- "$tmp"
    fm_lock_release "$lock" || true
    return 1
  fi
  fm_lock_release "$lock" || true
}

# Fills TESTS with the test files the branch changes since its merge-base with
# the base that still exist at the worker copy's HEAD. Runs in the main shell
# so a failed diff dies the command instead of yielding an empty list.
branch_tests() {
  local files path
  TESTS=()
  files=$(fm_tdd_split_changed_files "$WT" "$BASE_BRANCH") || die "$files"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    fm_tdd_split_seat_path_ok "$path" || continue
    [ -e "$WT/$path" ] || continue
    TESTS+=("$path")
  done <<<"$files"
}

# Runs <command> with `bash -c` from <dir>, bounded by --timeout, with <tests>
# as "$@", logging to <log>. Sets RC; dies when the run proves nothing: a
# timeout, a command that could not run, or a signal death.
run_bounded() {  # <dir> <log> <head> <what> <command> <tests>...
  local dir=$1 log=$2 head=$3 what=$4 command=$5
  shift 5
  set +e
  (cd "$dir" && fm_run_timed "$TIMEOUT" bash -c "$command" fm-tdd-split "$@") >"$log" 2>&1 </dev/null
  RC=$?
  set -e
  printf '\nfm-tdd-split: head=%s exit=%s command=%s\n' "$head" "$RC" "$command" >>"$log"
  if fm_timed_out "$RC"; then
    die "the $what hit its ${TIMEOUT}s bound; see $log"
  elif [ "$RC" -eq 126 ] || [ "$RC" -eq 127 ] || [ "$RC" -gt 128 ]; then
    die "the $what could not run (exit $RC), which proves nothing about the tests; see $log"
  fi
}

# Applies fm-dod-lib.sh's test-authoring contract, including its model scope.
implementer_tests_untouched() {
  local reason
  reason=$(fm_test_ban_accept_done ship "$(fm_dod_meta_value "$META" mode)" "$WT" "done: $CMD" "$META" 1) \
    || die "$reason"
}

# Sends the implementer's task back to the test seat at <head> because of
# <reason>, recording tdd_split=tests and tdd_split_dispute_head=<head>.
route_to_seat() {  # <head> <reason>
  local head=$1 note
  note="tdd-split: this task is back on its test seat because $2. From $head change test files only: fix or strengthen the tests so they pin the brief's required behavior, and leave every other file as it is. Firstmate reruns \`$COMMAND\` from a clean clone of the base with the test files the branch changes, checked out from your HEAD, as its arguments, and hands over only when that run fails. Commit, report \`done: $FM_TDD_SPLIT_READY_VERB <sha>\` naming your HEAD, and stop; do not run no-mistakes, push, or open a PR. If the tests are right as they are, report \`done: $FM_TDD_SPLIT_READY_VERB <sha>\` without changing them."
  "$FM_CONTROL_BIN" "$ID" relaunch --harness "$FM_TDD_SPLIT_SEAT_HARNESS" --model "$FM_TDD_SPLIT_SEAT_MODEL" \
    --effort "$FM_TDD_SPLIT_SEAT_EFFORT" --note "$note" \
    || die "relaunch onto the test seat failed; the task stays on its implementer and the $CMD can be run again"
  meta_rewrite tdd_split tdd_split_dispute_head -- tdd_split=tests "tdd_split_dispute_head=$head" \
    || die "relaunched onto the test seat but could not record tdd_split=tests in $META"
}

require_implementer() {
  [ "$PHASE" = implement ] || die "task $ID is not a tdd-split ship on its implementer (tdd_split=$PHASE)"
  [ -n "$COMMAND" ] || die "$DATA/$ID/brief.md declares no single $FM_TDD_SPLIT_CHECK_LABEL \`<command>\` line"
  git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 || die "cannot read the worker copy of $ID"
}

RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-tdd-split.XXXXXX") || die "cannot create a scratch directory"
trap 'rm -rf -- "$RUN_DIR"' EXIT
mkdir -p "$DATA/$ID"

case "$CMD" in
  handoff)
    [ "$PHASE" = tests ] || die "task $ID is not a tdd-split ship on its test seat (tdd_split=$PHASE)"
    IMPL_HARNESS=$(fm_dod_meta_value "$META" tdd_split_impl_harness)
    IMPL_MODEL=$(fm_dod_meta_value "$META" tdd_split_impl_model)
    IMPL_EFFORT=$(fm_dod_meta_value "$META" tdd_split_impl_effort)
    [ -n "$IMPL_HARNESS" ] && [ -n "$IMPL_MODEL" ] || die "task $ID records no tdd-split implementer"
    [ -n "$DISPUTE_HEAD" ] || ! grep -q '^pr=' "$META" \
      || die "task $ID already records a PR, so its test seat cannot hand over"
    LINE=$(status_current_line "$STATUS" ship)
    case "$(status_line_note "$LINE")" in
      "$FM_TDD_SPLIT_READY_VERB"|"$FM_TDD_SPLIT_READY_VERB "*) ;;
      *) die "task $ID has not reported done: $FM_TDD_SPLIT_READY_VERB" ;;
    esac
    [ "$(status_line_verb "$LINE")" = "done" ] || die "task $ID has not reported done: $FM_TDD_SPLIT_READY_VERB"
    REASON=$(fm_tdd_split_accept_done ship "$WT" "$LINE" "$META") || die "$REASON"
    [ -n "$COMMAND" ] || die "$DATA/$ID/brief.md declares no single $FM_TDD_SPLIT_CHECK_LABEL \`<command>\` line"
    SEAT_HEAD=$(git -C "$WT" rev-parse --verify 'HEAD^{commit}') || die "cannot read the worker copy's HEAD"
    BASE_REF=$(fm_test_ban_base_ref "$WT" "$BASE_BRANCH") || die "cannot resolve the base branch in the worker copy"
    MB=$(git -C "$WT" merge-base "$BASE_REF" HEAD) || die "no merge-base between HEAD and $BASE_REF"
    branch_tests
    [ "${#TESTS[@]}" -gt 0 ] || die "the branch's commits delete tests but add or change none"

    # The red run happens in a private clone of the base plus the branch's
    # tests, so a red run is the tests failing without the change, even after
    # an implementer's commits, and whatever the tests write never reaches the
    # worker copy the implementer inherits.
    git clone -q --shared --no-checkout -- "$WT" "$RUN_DIR/clone" 2>/dev/null || die "cannot clone the worker copy"
    git -C "$RUN_DIR/clone" checkout -q --detach "$MB" 2>/dev/null || die "cannot check out the base $MB in the clone"
    git -C "$RUN_DIR/clone" checkout -q "$SEAT_HEAD" -- "${TESTS[@]}" 2>/dev/null \
      || die "cannot check out the tests at $SEAT_HEAD in the clone"
    LOG="$DATA/$ID/tdd-split-red.log"
    run_bounded "$RUN_DIR/clone" "$LOG" "$SEAT_HEAD" "fail-to-pass command" "$COMMAND" "${TESTS[@]}"
    [ "$RC" -ne 0 ] || die "the handed-over tests pass on the base, so they pin nothing the change adds; see $LOG"

    # The implementer's test ban starts at this head, so tests the seat changed
    # in an earlier round or after a dispute are the seat's, not the implementer's.
    meta_rewrite test_ban_since -- "test_ban_since=$SEAT_HEAD" || die "cannot record test_ban_since in $META"
    NOTE="tdd-split handoff: the test seat committed failing tests up to $SEAT_HEAD (red on the base, exit $RC; $LOG). Implement the change in the brief until those tests pass, without changing them, then continue with the brief's Definition of done. If a handed-over test is wrong, do not change it: commit your work in progress and report \`blocked [key=$FM_TDD_SPLIT_DISPUTE_KEY]: <test>: <reason>\`."
    RELAUNCH=("$FM_CONTROL_BIN" "$ID" relaunch --harness "$IMPL_HARNESS" --model "$IMPL_MODEL")
    [ -z "$IMPL_EFFORT" ] || RELAUNCH+=(--effort "$IMPL_EFFORT")
    "${RELAUNCH[@]}" --note "$NOTE" || die "relaunch onto $IMPL_MODEL failed; the task stays on its test seat and the handoff can be run again"
    meta_rewrite tdd_split tdd_split_tests tdd_split_dispute_head -- tdd_split=implement "tdd_split_tests=$SEAT_HEAD" \
      || die "relaunched onto $IMPL_MODEL but could not record tdd_split=implement in $META"
    echo "tdd-split: $ID handed over at $SEAT_HEAD to $IMPL_HARNESS/$IMPL_MODEL${IMPL_EFFORT:+ ($IMPL_EFFORT)}"
    ;;

  dispute)
    require_implementer
    DISPUTE=$(status_open_decisions "$STATUS" ship | awk -F'\t' -v key="$FM_TDD_SPLIT_DISPUTE_KEY" \
      '$1 == key && $2 == "blocked" { print $3 }' | tail -1)
    [ -n "$DISPUTE" ] || die "task $ID has no open blocked [key=$FM_TDD_SPLIT_DISPUTE_KEY] report"
    [ -z "$(git -C "$WT" status --porcelain 2>/dev/null)" ] \
      || die "the implementer's worker copy has uncommitted changes; it must commit or discard them before the dispute moves the task"
    implementer_tests_untouched
    HEAD_SHA=$(git -C "$WT" rev-parse --verify 'HEAD^{commit}') || die "cannot read the worker copy's HEAD"
    route_to_seat "$HEAD_SHA" "the implementer disputes a handed-over test: $DISPUTE"
    rc=0
    fm_wake_status_append_self_announced "$STATE" "$STATUS" \
      "resolved [key=$FM_TDD_SPLIT_DISPUTE_KEY]: accepted: back on the test seat at $HEAD_SHA" || rc=$?
    [ "$rc" -ne 2 ] || echo "fm-tdd-split: warning: could not close [key=$FM_TDD_SPLIT_DISPUTE_KEY] in $STATUS" >&2
    echo "tdd-split: $ID dispute accepted at $HEAD_SHA; back on the test seat $FM_TDD_SPLIT_SEAT_HARNESS/$FM_TDD_SPLIT_SEAT_MODEL ($FM_TDD_SPLIT_SEAT_EFFORT)"
    ;;

  mutation)
    require_implementer
    MUTATION=$(fm_tdd_split_mutation_command "$DATA/$ID/brief.md") \
      || die "$DATA/$ID/brief.md declares no single $FM_TDD_SPLIT_MUTATION_LABEL \`<command>\` line"
    [ "$(status_line_verb "$(status_current_line "$STATUS" ship)")" = "done" ] \
      || die "task $ID's implementer has not reported done:"
    implementer_tests_untouched
    HEAD_SHA=$(git -C "$WT" rev-parse --verify 'HEAD^{commit}') || die "cannot read the worker copy's HEAD"
    branch_tests
    [ "${#TESTS[@]}" -gt 0 ] || die "the branch's commits leave no test file to run the mutation command against"
    git clone -q --shared --no-checkout -- "$WT" "$RUN_DIR/clone" 2>/dev/null || die "cannot clone the worker copy"
    git -C "$RUN_DIR/clone" checkout -q --detach "$HEAD_SHA" 2>/dev/null || die "cannot check out $HEAD_SHA in the clone"
    LOG="$DATA/$ID/tdd-split-mutation.log"
    run_bounded "$RUN_DIR/clone" "$LOG" "$HEAD_SHA" "mutation command" "$MUTATION" "${TESTS[@]}"
    if [ "$RC" -eq 0 ]; then
      echo "tdd-split: $ID mutation gate passed at $HEAD_SHA"
      exit 0
    fi
    route_to_seat "$HEAD_SHA" "the mutation command \`$MUTATION\` failed at $HEAD_SHA (exit $RC; $LOG), so the tests let mutants of the implementation survive"
    echo "tdd-split: $ID mutation gate failed at $HEAD_SHA (exit $RC); back on the test seat $FM_TDD_SPLIT_SEAT_HARNESS/$FM_TDD_SPLIT_SEAT_MODEL ($FM_TDD_SPLIT_SEAT_EFFORT)"
    exit 3
    ;;
esac
