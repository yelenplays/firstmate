#!/usr/bin/env bash
# fm-remote-readiness-lib.sh - the remote second-mate readiness gate sequence.
#
# Source this file and call:
#   fm_remote_readiness_ensure <bin-dir> <secondmate-id>
#
# It runs bin/fm-remote-doctor.sh on that route's configured host, and when the
# read-only run reports any gap it runs the doctor again with --fix and then a
# third read-only time. That last read-only run is the verdict, so a repair is
# never trusted on its own word. bin/fm-remote-doctor.sh remains the single
# owner of every check, every repair, and every message; nothing here restates
# them.
#
# Returns 0 when the host is ready, 1 when a gap remains, and 255 when SSH could
# not complete. 255 means unknown remote completion, so a caller preserves its
# route and reconciles on the same host instead of treating it as a refusal.
# FM_REMOTE_READINESS_OUT always holds the output of the last run, which carries
# the check lines, the remaining human: gaps, and their exact operator actions.
# An optional third argument bounds each remote doctor invocation individually;
# callers without it retain the existing unbounded interactive behavior.

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
FM_REMOTE_READINESS_OUT=

fm_remote_readiness_call() { # <bin-dir> <id> <timeout> <step> <detail> [args...]
  local bin_dir=$1 id=$2 timeout=$3 step=$4 detail=$5 out rc started
  shift 5
  if [ -n "$timeout" ]; then
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$bin_dir/fm-timeout-lib.sh"
    # shellcheck source=bin/fm-timing-lib.sh
    . "$bin_dir/fm-timing-lib.sh"
    started=$(fm_timing_now_ms)
    out=$(fm_run_timed "$timeout" "$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh "$@" < /dev/null 2>&1)
    rc=$?
    fm_timing_record remote-operation "readiness-$step" "$started" "$detail"
  else
    out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh "$@" < /dev/null 2>&1)
    rc=$?
  fi
  FM_REMOTE_READINESS_OUT=$out
  return "$rc"
}

fm_remote_readiness_ensure() { # <bin-dir> <secondmate-id> [per-operation-timeout] [timing-detail]
  local bin_dir=$1 id=$2 timeout=${3:-} detail=${4:-$2} rc

  fm_remote_readiness_call "$bin_dir" "$id" "$timeout" probe "$detail" || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -ne 124 ] || return 124

  rc=0
  fm_remote_readiness_call "$bin_dir" "$id" "$timeout" repair "$detail" --fix || rc=$?
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -ne 124 ] || return 124

  rc=0
  fm_remote_readiness_call "$bin_dir" "$id" "$timeout" verify "$detail" || rc=$?
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -ne 124 ] || return 124
  [ "$rc" -eq 0 ] || return 1
  return 0
}
