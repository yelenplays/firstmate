#!/bin/sh
# fm-browser-guard-browser.sh - the agent browser guard's `BROWSER` command.
#
# bin/fm-browser-guard-env.sh exports BROWSER=<this script> for every launched
# worker. BROWSER is the conventional "open this URL" hook that Python's
# webbrowser module, gh, git web--browse, and similar tools call with the URL as
# the argument. It matters most for Python: since 3.13 webbrowser pipes its
# AppleScript to /usr/bin/osascript by full path, so the osascript shim on PATH
# never sees it, and BROWSER is the one switch webbrowser reads before that.
#
# It refuses the URL in one line on stderr and exits 0. The zero is deliberate:
# webbrowser.open walks its browser list until one succeeds, so a non-zero exit
# would hand the URL straight to the next entry - the direct osascript pipe -
# and open the window anyway. FM_ALLOW_HEADED_BROWSER=1 (captain only) hands
# the URL to the real `open` with one notice line.
#
# POSIX sh. docs/browser-guard.md owns the contract.

fm_bg_lib="$(dirname "$0")/fm-browser-guard-shim-lib.sh"
if [ ! -r "$fm_bg_lib" ]; then
  printf '%s\n' 'fm-browser-guard: warning: bin/fm-browser-guard-shim-lib.sh is missing; this browser launch is not guarded' >&2
  exec /usr/bin/open "$@"
fi
# shellcheck source=bin/fm-browser-guard-shim-lib.sh disable=SC1091
. "$fm_bg_lib"

if fm_bg_opt_out; then
  fm_bg_note_allowed "BROWSER $*"
  exec "$(fm_bg_real_binary open)" "$@"
fi

# fm_bg_refuse prints the one refusal line and exits 1; the subshell keeps the
# line and drops the status, for the reason above.
(fm_bg_refuse "BROWSER $*")
exit 0
