#!/bin/sh
# fm-browser-guard-open.sh - the agent browser guard's `open` shim.
#
# It is reached as `open` through bin/fm-browser-guard-bin/open, the symlink
# that puts this script on a launched worker's PATH under the name the real tool
# has, and it is tracked here so the repository's own ShellCheck set covers it.
#
# Firstmate puts this directory first on PATH for every crewmate, scout, and
# secondmate it launches (bin/fm-browser-guard-env.sh owns that environment
# text), so a worker's `open <url>`, `open -a "Google Chrome"`, and the `open`
# call inside a browser tool all reach this shim first.
#
# It refuses the launches that can only end in a visible browser window: an
# http/https/file URL, a browser-renderable document (.html and friends) with no
# application named, a browser named with -a or -b. Everything else - `open .`,
# `open report.md`, `open -a TextEdit index.html`, `open -R` - is handed to the
# real `open` unchanged, which
# is what keeps ordinary file opening working inside a guarded pane.
#
# It refuses rather than forcing, because `open` has no headless form: the caller
# must use a headless browser and relay the URL instead. The refusal is one line
# on stderr plus a non-zero exit, and FM_ALLOW_HEADED_BROWSER=1 (captain only)
# passes the launch through with one notice line.
#
# POSIX sh: this is exec'd by arbitrary tools through /bin/sh.
# docs/browser-guard.md owns the contract; bin/fm-browser-guard-shim-lib.sh owns
# the browser-name and target rules.

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
  # A missing library means a broken install, not a policy decision, so the
  # launch is not blocked on it - but it is never silent either.
  printf '%s\n' 'fm-browser-guard: warning: bin/fm-browser-guard-shim-lib.sh is missing; this browser launch is not guarded' >&2
  exec /usr/bin/open "$@"
fi
# shellcheck source=bin/fm-browser-guard-shim-lib.sh disable=SC1091
. "$fm_bg_lib"

if fm_bg_opt_out; then
  fm_bg_note_allowed "open $*"
  exec "$(fm_bg_real_binary open)" "$@"
fi

fm_bg_app=
fm_bg_bundle=
fm_bg_reveal=0

# First pass: the flags that name an application. The argument list itself is
# never consumed here, because the real `open` still needs it verbatim.
#
# `open` takes getopt-style clusters, so `-na "Google Chrome"` means
# `-n -a "Google Chrome"` and `-gna` means `-g -n -a`; the standard debuggable
# Chrome recipe `open -na "Google Chrome" --args ...` is exactly that shape.
# Each single-dash cluster is split, and the first `a`, `b`, or `s` in it takes
# its value from the rest of the cluster when there is one, otherwise from the
# next argument - the rule getopt itself applies.
fm_bg_expect=
for fm_bg_arg in "$@"; do
  case $fm_bg_expect in
  app)
    fm_bg_app=$fm_bg_arg
    fm_bg_expect=
    continue
    ;;
  bundle)
    fm_bg_bundle=$fm_bg_arg
    fm_bg_expect=
    continue
    ;;
  sdk)
    fm_bg_expect=
    continue
    ;;
  esac
  case $fm_bg_arg in
  --args | --) break ;;
  - | --*) ;;
  -?*)
    fm_bg_cluster=${fm_bg_arg#-}
    while [ -n "$fm_bg_cluster" ]; do
      fm_bg_flag=${fm_bg_cluster%"${fm_bg_cluster#?}"}
      fm_bg_cluster=${fm_bg_cluster#?}
      case $fm_bg_flag in
      R)
        # -R reveals the target in Finder instead of opening it, so a .html
        # path is a Finder selection, not a browser window.
        fm_bg_reveal=1
        ;;
      a | b | s)
        if [ -n "$fm_bg_cluster" ]; then
          fm_bg_value=$fm_bg_cluster
          fm_bg_cluster=
        else
          fm_bg_value=
          case $fm_bg_flag in
          a) fm_bg_expect=app ;;
          b) fm_bg_expect=bundle ;;
          s) fm_bg_expect=sdk ;;
          esac
        fi
        case $fm_bg_flag in
        a) [ -z "$fm_bg_value" ] || fm_bg_app=$fm_bg_value ;;
        b) [ -z "$fm_bg_value" ] || fm_bg_bundle=$fm_bg_value ;;
        esac
        ;;
      esac
    done
    ;;
  esac
done

if [ -n "$fm_bg_app" ]; then
  fm_bg_name=${fm_bg_app##*/}
  fm_bg_name=${fm_bg_name%.app}
  if fm_bg_browser_application "$(fm_bg_lower "$fm_bg_name")"; then
    fm_bg_refuse "open -a \"$fm_bg_app\""
  fi
fi
if [ -n "$fm_bg_bundle" ]; then
  if fm_bg_browser_bundle "$(fm_bg_lower "$fm_bg_bundle")"; then
    fm_bg_refuse "open -b \"$fm_bg_bundle\""
  fi
fi

# Second pass: the targets. A bare `--` only ends option parsing - macOS `open`
# still treats everything after it as a target - so only `--args` stops the
# target checks, because those arguments belong to the application being
# launched rather than to `open`.
fm_bg_past_args=0
for fm_bg_arg in "$@"; do
  [ "$fm_bg_past_args" -eq 0 ] || break
  case $fm_bg_arg in
  --args)
    fm_bg_past_args=1
    continue
    ;;
  -*) continue ;;
  esac
  [ "$fm_bg_reveal" -eq 0 ] || continue
  fm_bg_target=$(fm_bg_lower "$fm_bg_arg")
  if fm_bg_browser_url "$fm_bg_target"; then
    if [ -n "$fm_bg_app" ]; then
      fm_bg_refuse "open -a \"$fm_bg_app\" $fm_bg_arg"
    fi
    fm_bg_refuse "open $fm_bg_arg"
  fi
  # A browser document opened by a named application reaches that application,
  # and the first pass already refused a named browser.
  if [ -z "$fm_bg_app" ] && [ -z "$fm_bg_bundle" ] && fm_bg_browser_document "$fm_bg_target"; then
    fm_bg_refuse "open $fm_bg_arg"
  fi
done

exec "$(fm_bg_real_binary open)" "$@"
