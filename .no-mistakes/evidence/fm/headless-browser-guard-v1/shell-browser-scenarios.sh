#!/usr/bin/env bash
set -eu
unset FM_ALLOW_HEADED_BROWSER
eval "$(bin/fm-browser-guard-env.sh --command)"
refused() {
 local label=$1 out code
 shift
 set +e
 out=$("$@" 2>&1)
 code=$?
 set -e
 printf '%s: exit=%s\n%s\n' "$label" "$code" "$out"
 [ "$code" -ne 0 ]
 [[ "$out" == fm-browser-guard:* ]]
}
printf 'open=%s\nosascript=%s\n' "$(command -v open)" "$(command -v osascript)"
refused 'URL through open' open https://example.invalid/fm-guard-live
refused 'Browser application through clustered open flags' open -na 'Google Chrome'
refused 'Browser bundle through open' open -b com.apple.Safari
refused 'Local HTML document' open "$PWD/.test-runtime/browser-proof.html"
refused 'Browser AppleScript' osascript -e 'tell application "Safari" to activate'
refused 'Browser AppleScript on stdin' bash -c 'printf '\''tell application "Safari" to activate'\'' | osascript'
refused 'JXA browser request' osascript -l JavaScript -e 'Application("Google Chrome").activate()'
python3 -I -c 'import webbrowser; print("Python webbrowser handled request:",webbrowser.open("https://example.invalid/fm-guard-live"))'
result=$(osascript -e 'return 6 * 7')
printf 'Harmless AppleScript result=%s\n' "$result"
[ "$result" = 42 ]
result=$(node -e 'const cp=require("node:child_process"); process.stdout.write(cp.execFileSync("/bin/echo",["ordinary subprocess unaffected"],{encoding:"utf8"}))')
printf '%s\n' "$result"
[ "$result" = 'ordinary subprocess unaffected' ]
printf 'SHELL_BROWSER_SCENARIOS_PASSED\n'
