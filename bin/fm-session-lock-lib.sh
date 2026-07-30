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
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# Ancestry hop budget. A harness may interpose several of its own processes
# between a hook or tool call and the session, and Claude Code 2.1.220 grew that
# tree, so the walk carries headroom rather than truncating before it reaches
# the session that owns the home.
# 16 is the depth measured against Claude Code's deepest observed bg-spare hook
# chain (upstream #1206), which is the deepest ancestry either side has seen.
# This budget covers the bash implementations only. The Pi extensions and the
# OpenCode plugin ask the same membership question against the same state/.lock
# inside their own runtimes and keep their own budgets, so changing this value
# does not reach them.
FM_ANCESTRY_HOPS=16

# True when pid $1 names a verified harness process. Liveness is not checked:
# every pid reached through a ppid chain is live by construction, and callers
# that need liveness for an unrelated pid use fm_harness_pid_alive instead.
fm_pid_looks_like_harness() {
  local pid=$1 comm args
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  [ -n "$comm" ] || return 1
  # Strip any directory with parameter expansion, not basename: a login shell's
  # comm begins with a dash, which basename parses as an option and rejects.
  printf '%s' "${comm##*/}" | grep -qE "$FM_HARNESS_RE" && return 0
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      printf '%s' "$args" | grep -qE "$FM_HARNESS_RE" && return 0
      ;;
  esac
  return 1
}

# Walk the current process ancestry and print the NEAREST harness-named
# ancestor. That pid is the session, and it is the only identity this home may
# record as its owner.
#
# The nearest match must not be widened to an outer harness-named ancestor.
# Claude Code 2.1.220 runs a session as a `claude bg-spare` whose ancestors are
# a `claude bg-pty-host` and a `claude daemon run` at ppid 1; the session is the
# bg-spare, and the two above it carry the harness command name while being
# SHARED by every Claude session on the machine. A walk that continued past the
# nearest match would therefore never stop at a non-harness parent - it would
# run to the pid > 1 guard on the shared daemon and mint one pid for every
# session at once, letting two unrelated sessions each satisfy
# fm_session_lock_owned_by_self for the other's home.
#
# The opposite shape - a hook firing several claude-named processes BELOW the
# pid that actually holds the lock (upstream #1206's bg-spare hook chain) - is
# not a reason to widen this walk. That shape is already answered by
# fm_session_lock_owned_by_self, which asks whether the recorded pid appears
# anywhere in the ancestry rather than whether it equals the nearest match, so
# ownership survives any number of interposed helpers without minting a pid the
# session does not exclusively own.
#
# Nearest-match is also the correct rule for every non-Claude harness: Pi's
# signed wrapper can be the direct PARENT of the inner `pi` engine pid that
# holds the lock, so the outer wrapper pid is not the owner there either.
fm_harness_ancestry_pid() {
  local pid=$$ hops=0
  while [ "$hops" -lt "$FM_ANCESTRY_HOPS" ]; do
    hops=$((hops + 1))
    if fm_pid_looks_like_harness "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# True if $1 is a live process that looks like a verified harness. This stays
# deliberately broader than the ancestry walk's fm_pid_looks_like_harness: it
# judges an unrelated recorded pid rather than a parent, so it also accepts a
# harness name anywhere in the command line, and refusing to evict a possible
# live owner is the safe direction.
#
# The command name is tested on its own rather than concatenated with the
# arguments, because FM_HARNESS_RE anchors `^pi$` and `^pi-signed$`: neither can
# ever match a line that also carries the argument string, so folding the two
# together silently makes every Pi session look dead.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  # Strip any directory with parameter expansion, not basename: a login shell's
  # comm begins with a dash, which basename parses as an option and rejects.
  printf '%s' "${comm##*/}" | grep -qE "$FM_HARNESS_RE" && return 0
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"
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
