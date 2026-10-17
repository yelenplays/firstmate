# shellcheck shell=sh
# fm-browser-guard-shim-lib.sh - the shared decision logic for the agent
# browser guard's PATH shims.
#
# Sourced by bin/fm-browser-guard-bin/open and bin/fm-browser-guard-bin/osascript
# (which find it through their own guard directory). POSIX sh only: the shims
# are exec'd by arbitrary tools through /bin/sh, which is dash on Linux.
#
# It owns three things in one place: which applications and bundle identifiers
# are browsers, which command targets can only be rendered by a browser, and how
# a shim finds the real binary it is standing in front of. docs/browser-guard.md
# owns the contract; bin/fm-browser-guard-preload.cjs owns the Node half.

# The captain's opt-out is read from this shim process's inherited environment.
# Anything other than exactly 1 leaves the guard on.
fm_bg_opt_out() {
  [ "${FM_ALLOW_HEADED_BROWSER:-}" = 1 ]
}

fm_bg_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# fm_bg_note_allowed <what>
fm_bg_note_allowed() {
  printf '%s\n' "fm-browser-guard: FM_ALLOW_HEADED_BROWSER=1 - allowing a visible browser window for $1" >&2
}

# fm_bg_refuse <what>: one clear line, then a non-zero exit, so the caller sees
# a refusal rather than a silent success.
fm_bg_refuse() {
  printf '%s\n' "fm-browser-guard: refused a visible browser window for $1; use a headless browser and relay the URL instead, or set FM_ALLOW_HEADED_BROWSER=1 to allow one (captain only)" >&2
  exit 1
}

# fm_bg_real_binary <name>: print the first <name> on PATH that is not the
# guard's own directory, falling back to /usr/bin/<name>. A guard directory is
# recognized by its .fm-browser-guard marker, so nested guards (a secondmate's
# pane inside a firstmate's) all step over each other instead of recursing.
fm_bg_real_binary() {
  fm_bg_name=$1
  fm_bg_found=
  fm_bg_ifs=$IFS
  IFS=:
  for fm_bg_dir in ${PATH:-}; do
    [ -n "$fm_bg_dir" ] || continue
    [ -e "$fm_bg_dir/.fm-browser-guard" ] && continue
    if [ -x "$fm_bg_dir/$fm_bg_name" ]; then
      fm_bg_found="$fm_bg_dir/$fm_bg_name"
      break
    fi
  done
  IFS=$fm_bg_ifs
  if [ -n "$fm_bg_found" ]; then
    printf '%s' "$fm_bg_found"
  else
    printf '%s' "/usr/bin/$fm_bg_name"
  fi
}

# fm_bg_browser_application <lowercased app name or .app basename>: true when the
# name is a browser. Long names match as a prefix so "Google Chrome for Testing"
# and "Firefox Developer Edition" are covered; short names that another
# application could begin with ("Arc", "Zen") match exactly, so Archive Utility
# stays openable.
fm_bg_browser_application() {
  case $1 in
    'google chrome'* | 'chromium'* | 'chrome'* | 'safari'* | 'firefox'* | 'mozilla firefox'* | 'brave'* | 'microsoft edge'* | 'msedge'* | 'opera'* | 'vivaldi'* | 'duckduckgo'* | 'waterfox'* | 'librewolf'* | 'tor browser'*) return 0 ;;
  esac
  case $1 in
    arc | dia | orion | zen | comet | sidekick | 'the browser' | 'chrome canary' | 'zen browser') return 0 ;;
  esac
  return 1
}

# fm_bg_browser_bundle <lowercased bundle identifier>
fm_bg_browser_bundle() {
  case $1 in
    com.google.chrome* | org.chromium.chromium* | com.apple.safari* | org.mozilla.firefox* | com.brave.browser* | com.microsoft.edgemac* | com.operasoftware.opera* | com.vivaldi.vivaldi* | com.duckduckgo.macos.browser* | company.thebrowser.browser* | ai.perplexity.comet* | org.mozilla.nightly* | io.github.zen_browser.zen*) return 0 ;;
  esac
  return 1
}

# fm_bg_browser_target <lowercased target>: true when the target can only be
# rendered by a browser. A path to an ordinary document stays false, which is
# what keeps `open report.md` and `open invoice.pdf` working.
fm_bg_browser_target() {
  case $1 in
    http://* | https://* | file://* | ftp://* | data:* | view-source:*) return 0 ;;
    *.html | *.htm | *.xhtml | *.shtml | *.svg | *.webarchive | *.webloc | *.url | *.mhtml) return 0 ;;
  esac
  return 1
}

# fm_bg_browser_script <lowercased AppleScript source>: true when running it
# would put a browser on screen, either by asking for a web URL ("open
# location", which is how Python's webbrowser drives Safari and Chrome) or by
# addressing a browser application directly. `open location` on a non-web URL is
# left alone because it is how Finder reveals a path, and a URL held in a
# variable cannot be judged at all - docs/browser-guard.md records that boundary.
fm_bg_browser_script() {
  case $1 in
    *'open location "http'* | *'open location http'* | *'open "http'* | *'open http'*) return 0 ;;
  esac
  case $1 in
    *'application "google chrome'* | *'application "chromium'* | *'application "chrome'* | *'application "safari'* | *'application "firefox'* | *'application "mozilla firefox'* | *'application "brave'* | *'application "microsoft edge'* | *'application "msedge'* | *'application "opera'* | *'application "vivaldi'* | *'application "duckduckgo'* | *'application "waterfox'* | *'application "librewolf'* | *'application "tor browser'*) return 0 ;;
  esac
  case $1 in
    *'application "arc"'* | *'application "dia"'* | *'application "orion"'* | *'application "zen"'* | *'application "zen browser"'* | *'application "comet"'* | *'application "sidekick"'* | *'application "the browser"'*) return 0 ;;
  esac
  return 1
}
