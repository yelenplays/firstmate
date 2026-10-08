# shellcheck shell=bash
# Background CPU scheduling for Firstmate's own heavy work.
# Usage: . bin/fm-qos-lib.sh
#
# This file is the single owner of the scheduling class that worker process
# trees and local test suites run at, so a fleet of workers and their suites
# yields the CPU to the person using the machine instead of competing with them.
# On macOS it applies a QoS clamp through taskpolicy(8) `-c <class>`; the clamp
# is inherited by every descendant, and taskpolicy execs the program in place,
# so the clamped process keeps its pid, parent, and process group. Everywhere
# else it is a no-op that runs the command unchanged.
#
# FM_WORKER_QOS selects the class: utility (the default), background,
# maintenance, or off. Any other value is refused rather than guessed, because
# the caller is about to launch work and a typo should not silently change how
# hard that work competes. docs/configuration.md "Worker CPU priority" owns the
# operator contract.
#
# Callers:
#   bin/fm-spawn.sh prefixes every worker launch with fm_qos_command_prefix and
#   exports the resolved class into it, because a nested clamp replaces the
#   outer one rather than stacking.
#   bin/fm-test-run.sh re-execs itself once through fm_qos_reexec, which covers
#   suites a pipeline daemon or any other non-worker parent starts.

# fm_qos_class: print the configured class, empty when disabled. Exit 2 with a
# diagnostic on stderr for an unknown value.
fm_qos_class() {
  local class=${FM_WORKER_QOS-utility}
  case "$class" in
    utility|background|maintenance) printf '%s' "$class" ;;
    off|none|'') ;;
    *)
      printf 'error: FM_WORKER_QOS must be utility, background, maintenance, or off (got %s)\n' "$class" >&2
      return 2
      ;;
  esac
}

# fm_qos_taskpolicy: print the taskpolicy path when this host can clamp, empty
# otherwise. FM_QOS_TASKPOLICY overrides the path; FM_QOS_UNAME overrides the
# kernel name. Both exist so the behavior is testable on any host.
fm_qos_taskpolicy() {
  local kernel tp
  kernel=${FM_QOS_UNAME:-$(uname -s 2>/dev/null || true)}
  [ "$kernel" = Darwin ] || return 0
  tp=${FM_QOS_TASKPOLICY:-/usr/sbin/taskpolicy}
  [ -x "$tp" ] || return 0
  printf '%s' "$tp"
}

# fm_qos_command_prefix: print shell words that, placed before a command, run
# it at the configured class. Empty when disabled or unsupported here. Exit 2
# for an unknown class.
fm_qos_command_prefix() {
  local class tp
  class=$(fm_qos_class) || return 2
  [ -n "$class" ] || return 0
  tp=$(fm_qos_taskpolicy)
  [ -n "$tp" ] || return 0
  printf '%q -c %s' "$tp" "$class"
}

# fm_qos_reexec <script> [args...]: re-exec the calling bash script once under
# the configured class. FM_QOS_APPLIED marks the clamped generation so the
# re-exec never loops. Returns normally (without exec) when disabled,
# unsupported, or already applied; exits 2 for an unknown class.
fm_qos_reexec() {
  local class tp
  class=$(fm_qos_class) || exit 2
  [ -n "$class" ] || return 0
  [ "${FM_QOS_APPLIED:-}" != "$class" ] || return 0
  tp=$(fm_qos_taskpolicy)
  [ -n "$tp" ] || return 0
  export FM_QOS_APPLIED="$class"
  exec "$tp" -c "$class" "${BASH:-bash}" "$@"
}
