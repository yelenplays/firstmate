#!/usr/bin/env bash
# fm-memory-capture.sh - automatic durable-memory capture for a primary home.
#
# Usage:
#   fm-memory-capture.sh hook <precompact|sessionend>
#   fm-memory-capture.sh run [--trigger <name>] [--dry-run] [--after <day>/<captain-id>]
#                            [--until-day <YYYY-MM-DD>] [--no-watermark]
#   fm-memory-capture.sh status
#
# `hook` is what the Claude PreCompact and SessionEnd hooks in
# .claude/settings.json call right after bin/fm-history.sh has journaled the
# transcript. It returns at once and starts `run` detached in its own process
# group, so neither the compaction nor the session exit waits on a model.
# It stands down silently unless this is the primary (non-secondmate) home's
# own main session: never in a crew, scout, or ship worktree (FM_TASK_ID), a
# no-mistakes gate, the supervision branch (FM_SUPERVISION_ACTOR), the
# capture's own model child (FM_MEMORY_CAPTURE_CHILD), or a home whose
# config/memory-capture says off. FM_MEMORY_CAPTURE=off disables it too.
#
# `run` explicitly processes the journal selected by FM_HOME; unlike `hook`,
# it does not enforce primary-session scope or capture-disable settings.
# Use it only for an intentional operator replay with the correct home selected.
# docs/memory.md "Automatic capture" owns filtering, privacy, verified writes,
# watermark advancement, and failure/recovery behavior.
# --after overrides the saved watermark; --until-day limits the last day read.
# --dry-run filters and plans model calls, but does not call Claude, write
# memories, update the watermark, take the run lock, or append run/failure
# records. --no-watermark only preserves the saved watermark; memory writes
# and run/failure records still occur.
#
# A boundary that arrives while another run holds the lock leaves a pending
# marker and returns; the run holding the lock drains every pending boundary
# with a fresh watermark run before it lets go, and re-checks after releasing
# so a boundary landing in that gap is never stranded. --after, --until-day,
# and --no-watermark runs are replays, not boundaries: they set no marker, but
# still drain any marker they find when they finish.
#
# `status` prints the watermark, the failure streak, and the last runs.
# docs/configuration.md "Automatic capture" owns disable and model settings.
#
# State: state/memory-capture/ holds watermark.json (fm-memory-capture-mark.v1),
# runs.jsonl (one fm-memory-capture-run.v1 record per run, with token usage,
# cost), failures, log, pending, and the run lock.
# model_calls is a planned call count in dry-run output; model_cost_usd counts
# Claude extraction only, not the primary session's total usage.
# Failure/recovery events append to state/memory-capture.status.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE,
# FM_ROOT_OVERRIDE, FM_MEMORY_DIR, FM_MEMORY_CAPTURE, FM_MEMORY_CAPTURE_MODEL,
# FM_CLAUDE_BIN.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CAPTURE_DIR="$STATE/memory-capture"
export FM_HOME

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  fm-memory-capture.sh hook <precompact|sessionend>
  fm-memory-capture.sh run [--trigger <name>] [--dry-run] [--after <day>/<captain-id>]
                           [--until-day <YYYY-MM-DD>] [--no-watermark]
  fm-memory-capture.sh status
EOF
}

die() {
  printf 'fm-memory-capture: %s\n' "$1" >&2
  exit "${2:-2}"
}

capture_disabled() {
  local line
  case "${FM_MEMORY_CAPTURE:-}" in off|0|false) return 0 ;; esac
  if [ -f "$CONFIG/memory-capture" ] && [ ! -L "$CONFIG/memory-capture" ]; then
    line=$(grep -v -E '^[[:space:]]*(#|$)' "$CONFIG/memory-capture" | head -n 1)
    case "$line" in off|0|false) return 0 ;; esac
  fi
  return 1
}

# Succeeds only for the primary home's own main session.
in_scope() {
  [ -z "${FM_MEMORY_CAPTURE_CHILD:-}" ] || return 1
  [ -z "${FM_TASK_ID:-}" ] || return 1
  [ -z "${FM_SUPERVISION_ACTOR:-}" ] || return 1
  fm_is_gate_agent "$FM_ROOT" && return 1
  fm_root_is_secondmate_home "$FM_HOME" && return 1
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 1
  capture_disabled && return 1
  return 0
}

cmd_hook() {
  local trigger=${1:-}
  case "$trigger" in
    precompact|sessionend) ;;
    *) die "hook needs precompact or sessionend" ;;
  esac
  [ -t 0 ] || cat >/dev/null 2>&1 || true
  in_scope || exit 0
  mkdir -p "$CAPTURE_DIR" 2>/dev/null || exit 0
  # shellcheck disable=SC2016 # Perl owns every $ expression in this literal program.
  perl -e 'defined(my $pid = fork) or exit 125;
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV; exit 125; }
    exit 0;' "$0" run --trigger "$trigger" >>"$CAPTURE_DIR/log" 2>&1 </dev/null &
  exit 0
}

acquire_lock() {
  local lock="$CAPTURE_DIR/lock" owner
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock/pid"
    return 0
  fi
  owner=$(cat "$lock/pid" 2>/dev/null || true)
  case "$owner" in
    ''|*[!0-9]*) ;;
    *) kill -0 "$owner" 2>/dev/null && return 1 ;;
  esac
  rm -rf "$lock"
  mkdir "$lock" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$lock/pid"
}

release_lock() {
  rm -rf "$CAPTURE_DIR/lock"
}

record_outcome() {
  local rc=$1 why=$2 streak=0 now
  now=$(date +%s)
  streak=$(cat "$CAPTURE_DIR/failures" 2>/dev/null || printf 0)
  case "$streak" in ''|*[!0-9]*) streak=0 ;; esac
  if [ "$rc" -eq 0 ]; then
    if [ "$streak" -ge 2 ]; then
      printf 'resolved [at=%s]: memory capture recovered; queued captain turns are captured\n' "$now" \
        >> "$STATE/memory-capture.status"
    fi
    printf '0\n' > "$CAPTURE_DIR/failures"
    return 0
  fi
  streak=$((streak + 1))
  printf '%s\n' "$streak" > "$CAPTURE_DIR/failures"
  if [ "$streak" -eq 2 ]; then
    printf 'failed [at=%s]: memory capture failed twice in a row (%s); captain turns stay queued for the next boundary, see %s/log\n' \
      "$now" "${why:-unknown reason}" "$CAPTURE_DIR" >> "$STATE/memory-capture.status"
  fi
}

# One extraction pass; prints its record and returns the extractor's exit.
extract_once() {
  local out rc why dry=$1
  shift
  out=$(node "$SCRIPT_DIR/fm-memory-capture.mjs" run --bin "$SCRIPT_DIR" --state "$CAPTURE_DIR" "$@")
  rc=$?
  printf '%s\n' "$out"
  [ "$dry" = 1 ] && return "$rc"
  why=$(printf '%s' "$out" | tail -n 1 | jq -r '.why // empty' 2>/dev/null || true)
  [ "$rc" -eq 0 ] || [ -n "$why" ] || why="extractor exit $rc"
  record_outcome "$rc" "$why"
  return "$rc"
}

cmd_run() {
  local -a args=()
  local trigger=manual boundary=1 dry=0 rc=0 first=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --trigger)
        [ $# -ge 2 ] || die "$1 needs a value"
        trigger=$2
        args+=("$1" "$2")
        shift 2
        ;;
      --after|--until-day)
        [ $# -ge 2 ] || die "$1 needs a value"
        boundary=0
        args+=("$1" "$2")
        shift 2
        ;;
      --dry-run) boundary=0; dry=1; args+=("$1"); shift ;;
      --no-watermark) boundary=0; args+=("$1"); shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  command -v node >/dev/null 2>&1 || die 'node is required'
  mkdir -p "$CAPTURE_DIR" || die "cannot create $CAPTURE_DIR"
  chmod 700 "$CAPTURE_DIR" 2>/dev/null || true
  if [ "$dry" = 1 ]; then
    extract_once 1 "${args[@]}"
    exit
  fi
  [ "$boundary" = 1 ] && printf '%s\n' "$trigger" > "$CAPTURE_DIR/pending"
  while acquire_lock; do
    trap release_lock EXIT
    if [ "$first" = 1 ]; then
      first=0
      [ "$boundary" = 1 ] && rm -f "$CAPTURE_DIR/pending"
      extract_once 0 ${args[@]+"${args[@]}"} || rc=$?
    fi
    while [ "$rc" -eq 0 ] && [ -e "$CAPTURE_DIR/pending" ]; do
      trigger=$(cat "$CAPTURE_DIR/pending" 2>/dev/null || true)
      rm -f "$CAPTURE_DIR/pending"
      extract_once 0 --trigger "${trigger:-pending}" || rc=$?
    done
    release_lock
    trap - EXIT
    # A failed run leaves later boundaries pending for the next one; otherwise
    # take the lock again only for a marker that landed after the last check.
    [ "$rc" -eq 0 ] && [ -e "$CAPTURE_DIR/pending" ] || exit "$rc"
  done
  if [ "$first" = 1 ] && [ "$boundary" = 1 ]; then
    printf 'fm-memory-capture: another capture run is active; it will drain this boundary before it exits\n'
  elif [ "$first" = 1 ]; then
    die 'another capture run is active; retry the replay when it finishes' 1
  fi
  exit "$rc"
}

cmd_status() {
  [ $# -eq 0 ] || die "status takes no arguments"
  printf 'dir: %s\n' "$CAPTURE_DIR"
  if capture_disabled; then printf 'capture: off\n'; else printf 'capture: on\n'; fi
  printf 'watermark: %s\n' "$(cat "$CAPTURE_DIR/watermark.json" 2>/dev/null || printf 'none')"
  printf 'failure streak: %s\n' "$(cat "$CAPTURE_DIR/failures" 2>/dev/null || printf 0)"
  if [ -f "$CAPTURE_DIR/runs.jsonl" ]; then
    printf 'last runs:\n'
    tail -n 5 "$CAPTURE_DIR/runs.jsonl" | jq -rc '"  \(.at) \(.trigger) ok=\(.ok) turns=\(.turns) units=\(.units) model_calls=\(.model_calls) memories=\(.memories) now=\(.now_entries) cost_usd=\(.model_cost_usd) \(.why)"' 2>/dev/null || true
  fi
}

cmd=${1:-}
case "$cmd" in
  ''|-h|--help) usage; [ -n "$cmd" ] || exit 2; exit 0 ;;
esac
shift
case "$cmd" in
  hook) cmd_hook "$@" ;;
  run) cmd_run "$@" ;;
  status) cmd_status "$@" ;;
  *) usage; die "unknown command: $cmd" ;;
esac
