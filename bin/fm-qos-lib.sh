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
# The scheduling policy is always utility on macOS.
# docs/configuration.md "Worker CPU priority" owns the operator contract.
#
# Callers:
#   bin/fm-spawn.sh prefixes every worker launch with fm_qos_command_prefix and
#   marks the clamp as applied in the launch environment.
#   bin/fm-test-run.sh re-execs itself once through fm_qos_reexec, which covers
#   suites a pipeline daemon or any other non-worker parent starts.

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
# it at utility QoS. Empty when unsupported here.
fm_qos_command_prefix() {
  local tp
  tp=$(fm_qos_taskpolicy)
  [ -n "$tp" ] || return 0
  printf '%q -c utility' "$tp"
}

# fm_qos_reexec <script> [args...]: re-exec the calling bash script once under
# utility class. FM_QOS_APPLIED marks the clamped generation so the
# re-exec never loops. Returns normally when unsupported or already applied.
fm_qos_reexec() {
  local tp
  [ "${FM_QOS_APPLIED:-}" != utility ] || return 0
  tp=$(fm_qos_taskpolicy)
  [ -n "$tp" ] || return 0
  export FM_QOS_APPLIED=utility
  exec "$tp" -c utility "${BASH:-bash}" "$@"
}
