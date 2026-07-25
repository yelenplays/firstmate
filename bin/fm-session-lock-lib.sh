#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process belong to that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake;
# bin/fm-sessionstart-nudge.sh uses it to stay silent once session start has
# already run in this session.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$'

# Ancestry hop budget. A harness may interpose several of its own processes
# between a hook or tool call and the session: Claude Code 2.1.220 adds a
# daemon, a pty host, and a bg-spare helper, so the session sits six or more
# parents above the process asking the question.
FM_ANCESTRY_HOPS=12

# True when pid $1 names a verified harness process. Liveness is not checked:
# every pid reached through a ppid chain is live by construction, and callers
# that need liveness for an unrelated pid use fm_harness_pid_alive instead.
fm_pid_looks_like_harness() {
  local pid=$1 comm args
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  [ -n "$comm" ] || return 1
  printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE" && return 0
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      printf '%s' "$args" | grep -qE "$FM_HARNESS_RE" && return 0
      ;;
  esac
  return 1
}

# Walk the current process ancestry and print the OUTERMOST pid of the
# uninterrupted harness-named run that begins at the nearest harness ancestor.
#
# The nearest harness ancestor is not the session. A harness interposes its own
# helper processes - Claude Code 2.1.220 puts a daemon, a pty host, and a
# bg-spare helper between every hook and the session - and those helpers carry
# the harness command name and rotate independently of the session. Minting the
# nearest one records a pid that dies with the next helper generation while the
# session lives on, so the recorded owner drifts away from the session that
# actually holds the home.
#
# The run deliberately stops at the first NON-harness parent. A genuinely
# separate parent session is reachable only across a multiplexer server or a
# plain shell, so that boundary keeps another session's identity out of this
# one even when the two process trees are related.
fm_harness_ancestry_pid() {
  local pid=$$ hops=0 found=
  while [ "$hops" -lt "$FM_ANCESTRY_HOPS" ]; do
    hops=$((hops + 1))
    if fm_pid_looks_like_harness "$pid"; then
      found=$pid
    elif [ -n "$found" ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# True if $1 is a live process that looks like a verified harness. This stays
# deliberately broader than the ancestry walk's fm_pid_looks_like_harness: it
# judges an unrelated recorded pid rather than a parent, so it also accepts a
# harness name anywhere in the command line, and refusing to evict a possible
# live owner is the safe direction.
fm_harness_pid_alive() {
  local pid=$1 comm
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$FM_HARNESS_RE"
}

# True when state dir $1 holds a session lock recorded by THIS session: the
# recorded pid appears anywhere in the current process ancestry.
#
# Ownership is an identity question - "does this session own this home?" - not a
# category question - "is my nearest harness ancestor the recorded pid?".
# Asking the category question silently drops ownership as soon as the harness
# interposes a helper, because the recorded session pid is then an ancestor of
# that helper rather than the helper itself. Chain membership answers the
# question the lock actually asks, and stays true no matter how many helper
# generations the harness inserts or rotates.
#
# A missing lock, a malformed lock, a lock recorded by a session outside this
# ancestry, and an ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pid=$$ hops=0
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  while [ "$hops" -lt "$FM_ANCESTRY_HOPS" ]; do
    hops=$((hops + 1))
    [ "$pid" = "$lock_pid" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}
