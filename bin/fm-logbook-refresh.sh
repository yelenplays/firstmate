#!/usr/bin/env bash
# fm-logbook-refresh.sh - best-effort daily Logbook generation and Deck refresh.
#
# Called after a task lands or a captain decision is recorded. Both operations
# have hard time bounds and never affect the caller's success. The optional
# $FM_HOME/config/deck-path contains one absolute path to a Deck checkout.
# When the optional one-line $FM_HOME/config/deck-launchd-label names the Deck's
# launchd job, a successful `launchctl kickstart gui/<uid>/<label>` is the
# refresh, so it runs with the job's own environment and publish settings.
# Otherwise, or when the kickstart fails, the checkout's deploy/refresh.sh runs
# directly with FM_DECK_ROOT and FM_DECK_FIRSTMATE_ROOT (this home) set.
#
# Environment: FM_HOME, FM_DATA_OVERRIDE, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE,
# FM_ROOT_OVERRIDE, FM_LOGBOOK_TIMEOUT, FM_DECK_REFRESH_TIMEOUT.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
LOGBOOK_TIMEOUT=${FM_LOGBOOK_TIMEOUT:-20}
DECK_REFRESH_TIMEOUT=${FM_DECK_REFRESH_TIMEOUT:-20}

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

valid_timeout() {
  case "$1" in
    ''|*[!0-9]*|0|??????????*) return 1 ;;
  esac
  [ "$1" -le 60 ]
}
valid_timeout "$LOGBOOK_TIMEOUT" || LOGBOOK_TIMEOUT=20
valid_timeout "$DECK_REFRESH_TIMEOUT" || DECK_REFRESH_TIMEOUT=20

FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_ROOT_OVERRIDE="$FM_ROOT" \
  fm_run_timed "$LOGBOOK_TIMEOUT" "$SCRIPT_DIR/fm-history.sh" logbook \
  >/dev/null 2>&1 || exit 0

config_file="$CONFIG_DIR/deck-path"
[ -f "$config_file" ] && [ ! -L "$config_file" ] || exit 0
IFS= read -r deck_path < "$config_file" || [ -n "${deck_path:-}" ] || exit 0
[ -n "${deck_path:-}" ] || exit 0
case "$deck_path" in /*) ;; *) exit 0 ;; esac
# Reject multi-line config rather than silently selecting one of several paths.
IFS= read -r extra_line < <(tail -n +2 "$config_file") || true
[ -z "${extra_line:-}" ] || exit 0
[ -d "$deck_path" ] && [ ! -L "$deck_path" ] || exit 0

# Prefer the Deck's own scheduled job: it carries the environment and publish
# settings a real refresh needs, and launchd runs only one copy at a time.
label_file="$CONFIG_DIR/deck-launchd-label"
if [ -f "$label_file" ] && [ ! -L "$label_file" ] && command -v launchctl >/dev/null 2>&1; then
  IFS= read -r label < "$label_file" || [ -n "${label:-}" ] || label=
  case "${label:-}" in
    ''|*[!A-Za-z0-9._-]*) ;;
    *)
      fm_run_timed "$DECK_REFRESH_TIMEOUT" launchctl kickstart "gui/$(id -u)/$label" \
        >/dev/null 2>&1 && exit 0
      ;;
  esac
fi

refresh="$deck_path/deploy/refresh.sh"
[ -f "$refresh" ] && [ -x "$refresh" ] && [ ! -L "$refresh" ] || exit 0
FM_DECK_ROOT="$deck_path" FM_DECK_FIRSTMATE_ROOT="$FM_HOME" \
  fm_run_timed "$DECK_REFRESH_TIMEOUT" "$refresh" work-landed >/dev/null 2>&1 || true
exit 0
