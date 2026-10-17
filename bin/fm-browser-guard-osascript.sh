#!/bin/sh
# fm-browser-guard-osascript.sh - the agent browser guard's `osascript` shim.
#
# It is reached as `osascript` through bin/fm-browser-guard-bin/osascript, the
# symlink that puts this script on a launched worker's PATH under the name the
# real tool has, and it is tracked here so the repository's own ShellCheck set
# covers it.
#
# It closes the AppleScript route to a visible browser window, which is the one
# a non-Node worker takes most often: Python's webbrowser module writes
# `open location "<url>"` to `osascript` on stdin, and an agent can address a
# browser application directly.
#
# Only scripts that would put a browser on screen are refused: a script naming a
# browser application, or one that asks for a URL with `open location`. A script
# that does anything else - a notification, System Events, Finder, a dialog -
# is handed to the real `osascript` unchanged, with stdin preserved.
#
# A script file argument (`osascript script.scpt`) is not inspected, because its
# contents are not part of the command line; docs/browser-guard.md records that
# boundary.
#
# POSIX sh: this is exec'd by arbitrary tools through /bin/sh.

fm_bg_locate_lib() {
  fm_bg_ifs=$IFS
  IFS=:
  for fm_bg_dir in ${PATH:-}; do
    if [ -e "$fm_bg_dir/.fm-browser-guard" ] && [ -r "$fm_bg_dir/../fm-browser-guard-shim-lib.sh" ]; then
      IFS=$fm_bg_ifs
      printf '%s' "$fm_bg_dir/../fm-browser-guard-shim-lib.sh"
      return 0
    fi
  done
  IFS=$fm_bg_ifs
  return 1
}

fm_bg_lib=$(fm_bg_locate_lib) || fm_bg_lib=
if [ -z "$fm_bg_lib" ]; then
  printf '%s\n' 'fm-browser-guard: warning: bin/fm-browser-guard-shim-lib.sh is missing; this browser launch is not guarded' >&2
  exec /usr/bin/osascript "$@"
fi
# shellcheck source=bin/fm-browser-guard-shim-lib.sh disable=SC1091
. "$fm_bg_lib"

if fm_bg_opt_out; then
  fm_bg_note_allowed "osascript $*"
  exec "$(fm_bg_real_binary osascript)" "$@"
fi

# Decide where the script comes from before judging anything. `osascript` reads
# stdin when no `-e` statement and no program-file operand is given: no
# arguments at all, an explicit `-` operand, or only options such as
# `-l JavaScript`. A named script file is still not read, because its contents
# are not on the command line; docs/browser-guard.md records that boundary.
fm_bg_stdin=0
fm_bg_inline=0
fm_bg_operand=
fm_bg_expect=
for fm_bg_arg in "$@"; do
  case $fm_bg_expect in
  stmt)
    fm_bg_inline=1
    fm_bg_expect=
    continue
    ;;
  value)
    fm_bg_expect=
    continue
    ;;
  esac
  case $fm_bg_arg in
  -e) fm_bg_expect=stmt ;;
  -e?*) fm_bg_inline=1 ;;
  -l | -s) fm_bg_expect=value ;;
  -l?* | -s?*) ;;
  -) fm_bg_operand=- ;;
  -*) ;;
  *) [ -n "$fm_bg_operand" ] || fm_bg_operand=$fm_bg_arg ;;
  esac
done
if [ "$fm_bg_inline" -eq 0 ] && { [ -z "$fm_bg_operand" ] || [ "$fm_bg_operand" = - ]; }; then
  fm_bg_stdin=1
fi

if [ "$fm_bg_stdin" -eq 0 ]; then
  if [ $# -gt 0 ] && fm_bg_browser_script "$(fm_bg_lower "$*")"; then
    fm_bg_refuse "osascript $*"
  fi
  exec "$(fm_bg_real_binary osascript)" "$@"
fi

# The script arrives on stdin: read it, judge it, and feed it back to the real
# osascript with the caller's own arguments when it passes. This covers no
# arguments, `-` as the script, and option-only forms such as `-l JavaScript`.
fm_bg_script=$(cat)
if fm_bg_browser_script "$(fm_bg_lower "$fm_bg_script")"; then
  fm_bg_refuse 'osascript (script on stdin)'
fi
printf '%s' "$fm_bg_script" | "$(fm_bg_real_binary osascript)" "$@"
exit $?
