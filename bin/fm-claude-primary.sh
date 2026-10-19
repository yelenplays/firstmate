#!/usr/bin/env bash
# Launch (or relaunch) the Claude Code PRIMARY firstmate session for this home,
# adding Claude Code's native Remote Control when the home opts in.
#
# Usage: fm-claude-primary.sh [<claude arg>...]
#   <claude arg>  passed through to claude unchanged, after the Remote Control
#                 flag, so a relaunch is the same command plus e.g. --continue
#                 or --resume <id>.
#
# The opt-in is the local, gitignored config/claude-remote-control under the
# effective home (FM_HOME, else this checkout). docs/configuration.md "Claude
# primary Remote Control" owns the file format, the phone-side setup, and what
# the flag does and does not change. In short:
#   absent or "off"   launch plain `claude`, exactly as `claude` typed by hand.
#   "on"              launch `claude --remote-control firstmate`.
# Anything else, or an unreadable file, refuses to launch and names the accepted
# values: the captain chose a posture, so the launcher never guesses another one.
#
# The launch always runs from this checkout's root so Claude loads the tracked
# .claude/settings.json hooks for this home. Remote Control only adds a
# claude.ai bridge to the same local interactive process;
# tests/fm-claude-remote-control-live-e2e.test.sh checks the bridge and the
# Stop-hook auto-arm with it on.
#
# FM_CLAUDE_BIN overrides the claude executable (tests use it).
# Exit codes: exec's own on launch; 2 for a refused config.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RC_FILE="$CONFIG/claude-remote-control"
DEFAULT_NAME=firstmate

refuse() {
  printf 'error: %s; accepted values are: off (the default when the file is absent) or on\n' "$1" >&2
  exit 2
}

RC_ARGS=()
if [ -e "$RC_FILE" ] || [ -L "$RC_FILE" ]; then
  [ -f "$RC_FILE" ] && [ -r "$RC_FILE" ] || refuse "$RC_FILE is not a readable regular file"
  # Only the first non-empty, non-comment line counts.
  LINE=$(grep -v -E '^[[:space:]]*(#|$)' "$RC_FILE" | head -n 1)
  read -r MODE NAME EXTRA <<<"$LINE"
  [ -z "${EXTRA:-}" ] || refuse "$RC_FILE holds more than a mode and a name: '$LINE'"
  case "${MODE:-off}" in
    off)
      [ -z "${NAME:-}" ] || refuse "$RC_FILE gives a name with off: '$LINE'"
      ;;
    on)
      [ -z "${NAME:-}" ] || refuse "$RC_FILE gives an unsupported value: '$LINE'"
      RC_ARGS=(--remote-control "$DEFAULT_NAME")
      ;;
    *) refuse "$RC_FILE holds '$LINE'" ;;
  esac
fi

CLAUDE_BIN="${FM_CLAUDE_BIN:-claude}"
ARGV=("$CLAUDE_BIN" ${RC_ARGS[@]+"${RC_ARGS[@]}"} "$@")

cd "$FM_ROOT" || exit 1
exec "${ARGV[@]}"
