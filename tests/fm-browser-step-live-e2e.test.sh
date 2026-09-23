#!/usr/bin/env bash
# Live browser guard for compact, isolated, redacted browser steps.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_BROWSER_STEPS_LIVE chrome-devtools-axi node

SESSION="fm-browser-steps-$$-${RANDOM}"
FIXTURE="$ROOT/tests/fixtures/browser-steps/index.html"
STARTED=0

cleanup() {
  if [ "$STARTED" -eq 1 ]; then
    CHROME_DEVTOOLS_AXI_SESSION="$SESSION" chrome-devtools-axi stop >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }
trap cleanup EXIT

unset CHROME_DEVTOOLS_AXI_AUTO_CONNECT CHROME_DEVTOOLS_AXI_BROWSER_URL \
  CHROME_DEVTOOLS_AXI_WS_HEADERS CHROME_DEVTOOLS_AXI_USER_DATA_DIR \
  CHROME_DEVTOOLS_AXI_PORT
export CHROME_DEVTOOLS_AXI_SESSION="$SESSION"

chrome-devtools-axi start >/dev/null 2>&1 || fail 'could not start the named isolated browser session'
STARTED=1
FIXTURE_URL=$(node -e 'process.stdout.write(JSON.stringify(require("node:url").pathToFileURL(process.argv[1]).href))' "$FIXTURE") \
  || fail 'could not encode fixture URL'
printf 'await page.open(%s);\nconsole.log("fixture-opened");\n' "$FIXTURE_URL" |
  chrome-devtools-axi run >/dev/null 2>&1 || fail 'could not open the local fixture'

OUT=$("$ROOT/bin/fm-browser.sh" step \
  --click 'button=Reveal token' \
  --expect 'heading~API token created' \
  --timeout 5000) || fail 'the reveal-token step failed'
node -e '
  const result = JSON.parse(process.argv[1]);
  if (!result.ok || result.step !== "click") process.exit(1);
  const text = JSON.stringify(result);
  if (text.includes("cfut_Zx9Kq2Lm8Rt4Vw6Yb1Nc3Hd5Jf7Gs0PaQe8Ui2Ok4") || text.includes("StaticText")) process.exit(1);
' "$OUT" || fail 'the result was not compact, successful, and free of the revealed token'
pass 'a one-call click verifies the revealed heading without exposing page text'

OUT=$("$ROOT/bin/fm-browser.sh" step \
  --fill 'textbox=Token name' \
  --value 'scout-fixture') || fail 'the fill step failed'
node -e '
  const result = JSON.parse(process.argv[1]);
  if (!result.ok || JSON.stringify(result).includes("scout-fixture")) process.exit(1);
' "$OUT" || fail 'a typed form value escaped into the result'
pass 'typed values are not returned'

OUT=$("$ROOT/bin/fm-browser.sh" step \
  --select 'combobox=Permission' \
  --option 'DNS Edit') || fail 'the select step failed'
node -e 'if (!JSON.parse(process.argv[1]).ok) process.exit(1)' "$OUT" \
  || fail "the combobox option was not selected: $OUT"
pass 'a combobox option can be selected in one step'

OUT=$("$ROOT/bin/fm-browser.sh" step \
  --click 'button=Use#2' \
  --expect-gone 'statictext=Token 8') || fail 'the ordinal-scoped control step failed'
node -e 'if (!JSON.parse(process.argv[1]).ok) process.exit(1)' "$OUT" \
  || fail "the ordinal control did not remove its matching item: $OUT"
pass 'an ordinal targets one of two duplicate controls and verifies removal'

printf 'live browser-step checks passed\n'
