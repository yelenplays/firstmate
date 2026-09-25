#!/usr/bin/env bash
# fm-queue-ready.sh - advisory next-work line from this home's backlog fields.
#
# Usage:
#   fm-queue-ready.sh
#
# bin/fm-wake-drain.sh runs this when it presents a heartbeat row. It reads the
# queued items of this home's backlog once through bin/fm-tasks-axi.sh and
# prints one line naming the items that are ready to dispatch, or nothing when
# none are. The check is structured and local: no model or network call.
#
# An item is ready only when all of these backlog fields agree:
#   blocked=no       every blocker is cleared
#   held=no          no active hold; tasks-axi already treats a hold whose
#                    --until date has arrived as inactive, so this is also the
#                    time gate
#   hold_kind is not captain, and kind is not captain
#                    a captain call is never work to dispatch, even after its
#                    deferral date has passed
#
# Output (stdout, only when at least one item is ready):
#   QUEUE READY (advisory, never dispatch): <n> ready: <id>, <id>, ...
# At most 5 ids are named, in backlog order, followed by "(+<k> more)".
# The line is advisory only: this script never dispatches a task, never clears
# a hold, and never changes backlog state.
#
# Exit 0 in every case except usage (exit 2). A missing or failing backlog
# listing prints nothing, so a drain is never blocked.
#
# Environment: FM_HOME and FM_DATA_OVERRIDE select the backlog exactly as
# bin/fm-tasks-axi.sh documents.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SHOW_MAX=5

case "${1:-}" in
  '') ;;
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  *)
    printf 'queue-ready: unexpected argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

listing=$("$SCRIPT_DIR/fm-tasks-axi.sh" list --state queued \
  --fields blocked,held,hold_kind --limit 1000000 2>/dev/null) || exit 0

# Rows sit under the "tasks[<n>]{...}" header, indented. The id, state, and
# kind lead each row and never contain commas; the three requested fields are
# the last three, after the free-text title.
printf '%s\n' "$listing" | awk -F ',' -v show_max="$SHOW_MAX" '
  function unquote(s) {
    gsub(/^"|"$/, "", s)
    return s
  }
  /^tasks\[/ { rows = 1; next }
  rows && /^[[:space:]]/ {
    line = $0
    sub(/^[[:space:]]+/, "", line)
    n = split(line, f, ",")
    if (n < 8) next
    id = f[1]
    kind = unquote(f[3])
    blocked = unquote(f[n - 2])
    held = unquote(f[n - 1])
    hold_kind = unquote(f[n])
    if (id == "" || blocked != "no" || held != "no") next
    if (hold_kind == "captain" || kind == "captain") next
    ready++
    if (ready <= show_max) ids = (ids == "" ? id : ids ", " id)
    next
  }
  rows { rows = 0 }
  END {
    if (!ready) exit
    more = (ready > show_max ? " (+" (ready - show_max) " more)" : "")
    printf "QUEUE READY (advisory, never dispatch): %d ready: %s%s\n", ready, ids, more
  }
'
exit 0
