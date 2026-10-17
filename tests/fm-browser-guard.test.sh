#!/usr/bin/env bash
# tests/fm-browser-guard.test.sh - no browser a launched agent starts may open a
# visible window on the captain's Mac.
#
# The assertions never read bin/fm-spawn.sh's source. The launch-layer case
# drives the real spawn against a fake pane and a real isolated git worktree,
# then EXECUTES the launch command the pane actually received, with the harness
# binary replaced by a probe that reports the guard environment it started with
# and runs a real headed browser launch through it. The remaining cases exercise
# the shipped preload and PATH shims the way a worker's own tooling reaches them:
# real Node processes, argv recorded from the real launchers, and stand-ins for
# the system `open` and `osascript` tools.
#
# Every fixture under tests/fixtures/browser-guard/ is one launcher's real
# argument list, captured on 2026-10-15 with playwright-core 1.64.1 and
# puppeteer-core 25.14.0 against a recording stub in place of the browser
# binary; docs/verification/browser-guard.md owns that provenance.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

GUARD_ENV="$ROOT/bin/fm-browser-guard-env.sh"
LOADER="$ROOT/bin/fm-browser-guard-load.cjs"
SHIM_DIR="$ROOT/bin/fm-browser-guard-bin"
FIXTURES="$ROOT/tests/fixtures/browser-guard"
TMP_ROOT=$(fm_test_tmproot fm-browser-guard)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
command -v node >/dev/null 2>&1 || fail "the browser guard tests need node"

# --- shared helpers ---------------------------------------------------------

# guard_snippet prints the launch environment the spawn layer embeds.
guard_snippet() {
  "$GUARD_ENV" --command
}

# guarded <cmd...>: run a command in a fresh shell carrying the guard
# environment a launched worker starts with, and nothing else of the caller's.
guarded() {
  local snippet
  snippet=$(guard_snippet) || fail "the guard environment snippet could not be built"
  /bin/sh -c "$snippet exec \"\$@\"" fm-browser-guard-test "$@"
}

# make_browser_stub <dir> <name>: a browser-binary stand-in that records its own
# argv and exits, so a launcher's spawn is observable without a browser.
make_browser_stub() {
  local dir=$1 name=$2
  mkdir -p "$dir"
  cat > "$dir/$name" <<'SH'
#!/bin/sh
{
  printf 'EXEC %s\n' "$0"
  printf 'ARG %s\n' "$@"
  printf 'END\n'
} >> "${FM_STUB_LOG:?}"
exit 1
SH
  chmod +x "$dir/$name"
  printf '%s\n' "$dir/$name"
}

# stub_launches <log>: how many browser processes were started.
stub_launches() {
  grep -c '^EXEC ' "$1" || true
}

# stub_args <log> <n>: the argument list of the n-th recorded launch.
stub_args() {
  awk -v want="$2" '/^EXEC / { n++ } n == want && /^ARG / { sub(/^ARG /, ""); print }' "$1"
}

# The replay driver is a real ESM Node program: it proves the guard reaches a
# launcher through an ESM entry point, which is the shape a worker's scratchpad
# script usually has.
REPLAY="$TMP_ROOT/replay.mjs"
cat > "$REPLAY" <<'JS'
import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
const args = readFileSync(process.argv[2], 'utf8').split('\n').filter((line) => line !== '');
const child = spawn(process.argv[3], args, { stdio: 'ignore' });
child.on('error', (err) => {
  console.error('spawn failed: ' + err.message);
  process.exit(3);
});
child.on('exit', () => process.exit(0));
JS

REPLAY_LOG="$TMP_ROOT/replay.log"
REPLAY_ERR="$TMP_ROOT/replay.err"

# run_replay <fixture-args-file> <stub> [opt-out]: run one recorded launcher
# argument list through the guard, leaving the stub's record in $REPLAY_LOG and
# the guard's own output in $REPLAY_ERR.
run_replay() {
  local fixture=$1 stub=$2 opt_out=${3:-} snippet
  snippet=$(guard_snippet) || fail "the guard environment snippet could not be built"
  rm -f "$REPLAY_LOG" "$REPLAY_ERR"
  if [ -n "$opt_out" ]; then
    FM_ALLOW_HEADED_BROWSER=1 FM_STUB_LOG="$REPLAY_LOG" \
      /bin/sh -c "$snippet exec \"\$@\"" fm-browser-guard-test node "$REPLAY" "$fixture" "$stub" 2>"$REPLAY_ERR" || true
  else
    FM_STUB_LOG="$REPLAY_LOG" \
      /bin/sh -c "$snippet exec \"\$@\"" fm-browser-guard-test node "$REPLAY" "$fixture" "$stub" 2>"$REPLAY_ERR" || true
  fi
}

guard_lines() {
  grep -c '^fm-browser-guard:' "$1" || true
}

# --- the launch layer -------------------------------------------------------

# make_case <name> <harness> <id>: the spawn world the launch-layer case needs.
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog panelog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$panelog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# install_browser_probe <fakebin> <harness> <fixture> <stub> <replay> <log>
# Replaces the harness binary with a probe that reports the environment the
# launch gave it and then runs one recorded headed launcher argv through the
# guard from inside that environment. What the probe records is what a real
# agent's browser launch would have done.
install_browser_probe() {
  local fakebin=$1 harness=$2 fixture=$3 stub=$4 replay=$5 log=$6
  cat > "$fakebin/$harness" <<SH
#!/bin/sh
printf 'PATH_HEAD=%s\n' "\${PATH%%:*}"
printf 'NODE_OPTIONS=%s\n' "\${NODE_OPTIONS:-}"
printf 'FM_BROWSER_GUARD=%s\n' "\${FM_BROWSER_GUARD:-}"
printf 'LAVISH_AXI_NO_OPEN=%s\n' "\${LAVISH_AXI_NO_OPEN:-}"
FM_STUB_LOG="$log" node "$replay" "$fixture" "$stub" >/dev/null 2>"$log.err"
printf 'PROBE_DONE=1\n'
SH
  chmod +x "$fakebin/$harness"
}

# emitted_launch <fakebin> <launch-log> <pane-log>: execute the launch command
# the pane received, with the pane's own pre-launch exports replayed first, and
# return its combined output.
emitted_launch() {
  local fakebin=$1 launchlog=$2 panelog=$3 errlog=$4 launch preamble
  launch=$(cat "$launchlog")
  preamble=$(grep '^export ' "$panelog")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane \
    /bin/sh -c "$preamble
$launch" >"$TMP_ROOT/launch.out" 2>"$errlog"
  cat "$TMP_ROOT/launch.out"
}

# assert_launch_guards <label> <output> <stub-log>
assert_launch_guards() {
  local label=$1 out=$2 log=$3
  assert_contains "$out" "PATH_HEAD=$SHIM_DIR" \
    "$label: the launch must put the guard's shim directory first on PATH"
  assert_contains "$out" "NODE_OPTIONS=--require \"$LOADER\"" \
    "$label: the launch must load the guard's stable loader into every Node process"
  assert_contains "$out" "FM_BROWSER_GUARD=1" \
    "$label: the launch must mark the pane as guarded"
  assert_contains "$out" "LAVISH_AXI_NO_OPEN=1" \
    "$label: the launch must suppress lavish-axi's own local window launch"
  assert_contains "$out" 'PROBE_DONE=1' \
    "$label: the probe harness must have run the browser launch"
  assert_equals 1 "$(stub_launches "$log")" \
    "$label: the probe should record exactly one browser process"
  assert_contains "$(stub_args "$log" 1)" '--headless' \
    "$label: a browser the launched agent asked to see must start headless"
  assert_contains "$(cat "$CASE_DIR/probe.log.err")" 'fm-browser-guard: forced headless:' \
    "$label: the guard must say in one line that it forced the launch"
}

test_launch_layer_carries_the_guard() {
  local harness setting rec out status log
  for harness in claude codex; do
    for setting in absent enabled; do
      rec=$(make_case "launch-$harness-$setting" "$harness" "launch-$harness-$setting-a1")
      read_case "$rec"
      [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      out=$(run_case_spawn "launch-$harness-$setting-a1" "$PROJ_DIR" --mode no-mistakes --yolo off)
      status=$?
      expect_code 0 "$status" "a $harness ship spawn with allowlist=$setting should succeed: $out"
      log="$CASE_DIR/probe.log"
      install_browser_probe "$FAKEBIN_DIR" "$harness" "$FIXTURES/playwright-chromium-headed.args" \
        "$(make_browser_stub "$CASE_DIR/stub" chromium)" "$REPLAY" "$log"
      assert_launch_guards "$harness allowlist=$setting" \
        "$(emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "$CASE_DIR/probe.err")" "$log"
    done
  done
  pass "every launch carries the guard environment, through the cleared allowlist environment too"
}

# --- the Node layer ---------------------------------------------------------

test_recorded_launcher_argvs_are_forced_headless() {
  local stub stub_dir fixture expect recorded expected actual
  stub_dir="$TMP_ROOT/stub"
  while read -r fixture expect; do
    [ -n "$fixture" ] || continue
    case $fixture in
    *firefox*) stub=$(make_browser_stub "$stub_dir" firefox) ;;
    *webkit*) stub=$(make_browser_stub "$stub_dir" pw_run.sh) ;;
    *) stub=$(make_browser_stub "$stub_dir" chromium) ;;
    esac
    run_replay "$FIXTURES/$fixture.args" "$stub"
    recorded=$(stub_launches "$REPLAY_LOG")
    assert_equals 1 "$recorded" "$fixture: exactly one browser process should be started"
    if [ "$expect" = forced ]; then
      expected=$(cat "$FIXTURES/$fixture.args")
      case $fixture in
      *firefox*) expected="$expected
-headless" ;;
      *) expected="$expected
--headless" ;;
      esac
      actual=$(stub_args "$REPLAY_LOG" 1)
      assert_equals "$expected" "$actual" \
        "$fixture: the forced launch must be the launcher's own argv plus one headless flag"
      assert_equals 1 "$(guard_lines "$REPLAY_ERR")" \
        "$fixture: the guard must report the forced launch in exactly one line"
    else
      actual=$(stub_args "$REPLAY_LOG" 1)
      assert_equals "$(cat "$FIXTURES/$fixture.args")" "$actual" \
        "$fixture: an already-headless launch must reach the browser unchanged"
      assert_equals 0 "$(guard_lines "$REPLAY_ERR")" \
        "$fixture: an already-headless launch must not print a guard line"
    fi
  done <<'EOF'
playwright-chromium-headed forced
playwright-chromium-headless unchanged
playwright-firefox-headed forced
playwright-webkit-headed forced
puppeteer-headed forced
puppeteer-headless unchanged
EOF
  pass "every recorded headed launcher argv ends headless and every headless one is untouched"
}

# make_fake_launcher_packages <dir>: playwright-shaped and puppeteer-shaped
# modules whose launch methods report the options they received.
make_fake_launcher_packages() {
  local dir=$1
  mkdir -p "$dir/node_modules/playwright-core/lib" "$dir/node_modules/puppeteer-core/lib"
  cat > "$dir/node_modules/playwright-core/package.json" <<'JSON'
{"name": "playwright-core", "version": "0.0.0", "main": "index.js"}
JSON
  cat > "$dir/node_modules/playwright-core/lib/browserType.js" <<'JS'
class BrowserType {
  constructor(name) {
    this.name = name;
  }
  launch(options) {
    return Promise.resolve(this.name + ' launch headless=' + String(options && options.headless));
  }
  launchPersistentContext(dir, options) {
    return Promise.resolve(this.name + ' persistent headless=' + String(options && options.headless));
  }
}
module.exports = { BrowserType };
JS
  cat > "$dir/node_modules/playwright-core/index.js" <<'JS'
const { BrowserType } = require('./lib/browserType');
module.exports = { chromium: new BrowserType('chromium'), firefox: new BrowserType('firefox') };
JS
  cat > "$dir/node_modules/puppeteer-core/package.json" <<'JSON'
{"name": "puppeteer-core", "version": "0.0.0", "main": "index.js"}
JSON
  cat > "$dir/node_modules/puppeteer-core/index.js" <<'JS'
const instance = {
  launch: (options) => Promise.resolve('puppeteer launch headless=' + String(options && options.headless)),
  executablePath: () => '/nonexistent/browser',
};
const namespace = {
  launch: instance.launch,
  executablePath: instance.executablePath,
  default: instance,
};
module.exports = namespace;
JS
  cat > "$dir/esm-driver.mjs" <<'JS'
import { chromium } from 'playwright-core';
import puppeteer from 'puppeteer-core';
console.log(await chromium.launch({ headless: false }));
console.log(await chromium.launchPersistentContext('/tmp/profile', { headless: false }));
console.log(await puppeteer.launch({ headless: false }));
console.log(await puppeteer.default.launch({ headless: false }));
JS
  cat > "$dir/cjs-driver.cjs" <<'JS'
const { chromium } = require('playwright-core');
const puppeteer = require('puppeteer-core');
chromium.launch({ headless: false }).then((line) => console.log(line));
puppeteer.launch({ headless: false }).then((line) => console.log(line));
JS
}

test_launcher_api_is_forced_headless() {
  local dir out control
  dir="$TMP_ROOT/launcher-api"
  make_fake_launcher_packages "$dir"
  # Control first: without the guard the same drivers really do ask for a
  # window, so a passing assertion below cannot be vacuous.
  control=$(cd "$dir" && node ./esm-driver.mjs 2>&1)
  assert_contains "$control" 'chromium launch headless=false' \
    "the control run without the guard must show the launcher asking for a visible window"
  for driver in esm-driver.mjs cjs-driver.cjs; do
    out=$(cd "$dir" && guarded node "./$driver" 2>&1)
    assert_contains "$out" 'headless=true' \
      "$driver: a launcher API that asked for a visible window must be forced headless"
    assert_not_contains "$out" 'headless=false' \
      "$driver: no launch may reach the launcher still asking for a visible window"
    assert_contains "$out" 'fm-browser-guard: forced headless:' \
      "$driver: the guard must report the forced launch"
  done
  pass "the launcher API is forced headless through an ESM and a CommonJS entry point"
}

test_opt_out_allows_a_visible_launch() {
  local stub dir out
  stub=$(make_browser_stub "$TMP_ROOT/stub" chromium)
  run_replay "$FIXTURES/playwright-chromium-headed.args" "$stub" opt-out
  assert_equals "$(cat "$FIXTURES/playwright-chromium-headed.args")" "$(stub_args "$REPLAY_LOG" 1)" \
    "the captain's opt-out must leave the launcher's argv exactly as it was"
  assert_equals 1 "$(guard_lines "$REPLAY_ERR")" \
    "the opt-out must print exactly one line saying the window was allowed"
  assert_contains "$(cat "$REPLAY_ERR")" 'FM_ALLOW_HEADED_BROWSER=1' \
    "the opt-out line must name the variable that allowed the window"
  dir="$TMP_ROOT/opt-out-api"
  make_fake_launcher_packages "$dir"
  out=$(cd "$dir" && FM_ALLOW_HEADED_BROWSER=1 guarded node ./cjs-driver.cjs 2>&1)
  assert_contains "$out" 'headless=false' \
    "the captain's opt-out must reach the launcher API as well"
  pass "FM_ALLOW_HEADED_BROWSER=1 allows a visible window in every layer, with one notice line"
}

# --- the PATH shims ---------------------------------------------------------

make_fake_system_tools() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/open" <<'SH'
#!/bin/sh
{
  printf 'CALL open'
  for arg in "$@"; do printf ' [%s]' "$arg"; done
  printf '\n'
} >> "${FM_SHIM_LOG:?}"
exit 0
SH
  cat > "$dir/osascript" <<'SH'
#!/bin/sh
{
  printf 'CALL osascript'
  for arg in "$@"; do printf ' [%s]' "$arg"; done
  printf '\n'
  printf 'STDIN '
  cat
  printf '\n'
} >> "${FM_SHIM_LOG:?}"
exit 0
SH
  chmod +x "$dir/open" "$dir/osascript"
  printf '%s\n' "$dir"
}

# run_shim <path-prefix> <tool> [args...]: run the shim a PATH lookup reaches
# first. Sets SHIM_STATUS and leaves the shim's stderr in $SHIM_ERR and the
# stand-in tool's record in $FM_SHIM_LOG.
run_shim() {
  local prefix=$1 tool=$2
  shift 2
  FM_SHIM_LOG="$TMP_ROOT/shim.log"
  export FM_SHIM_LOG
  SHIM_ERR="$TMP_ROOT/shim.err"
  : > "$FM_SHIM_LOG"
  PATH="$prefix:$PATH" "$tool" "$@" >/dev/null 2>"$SHIM_ERR"
  SHIM_STATUS=$?
}

# run_shim_stdin <path-prefix> <tool> <script>: the stdin form, which is how
# Python's webbrowser drives Safari and Chrome.
run_shim_stdin() {
  local prefix=$1 tool=$2 script=$3
  FM_SHIM_LOG="$TMP_ROOT/shim.log"
  export FM_SHIM_LOG
  SHIM_ERR="$TMP_ROOT/shim.err"
  : > "$FM_SHIM_LOG"
  printf '%s\n' "$script" | PATH="$prefix:$PATH" "$tool" >/dev/null 2>"$SHIM_ERR"
  SHIM_STATUS=$?
}

# run_shim_stdin_args <path-prefix> <tool> <script> <arg...>: the stdin form with
# the caller's own tool arguments, which is how `osascript -` and
# `osascript -l JavaScript` name a script that still arrives on stdin.
run_shim_stdin_args() {
  local prefix=$1 tool=$2 script=$3
  shift 3
  FM_SHIM_LOG="$TMP_ROOT/shim.log"
  export FM_SHIM_LOG
  SHIM_ERR="$TMP_ROOT/shim.err"
  : > "$FM_SHIM_LOG"
  printf '%s\n' "$script" | PATH="$prefix:$PATH" "$tool" "$@" >/dev/null 2>"$SHIM_ERR"
  SHIM_STATUS=$?
}

assert_refused() {
  local label=$1
  assert_not_equals 0 "$SHIM_STATUS" "$label: the shim must refuse the launch"
  assert_equals 1 "$(guard_lines "$SHIM_ERR")" "$label: the refusal must be exactly one line"
  assert_equals '' "$(cat "$FM_SHIM_LOG")" "$label: the real tool must not be reached"
}

assert_passed_through() {
  local label=$1 want=$2
  assert_equals 0 "$SHIM_STATUS" "$label: the shim must pass the call through"
  assert_equals "" "$(cat "$SHIM_ERR")" "$label: a pass-through must be silent"
  assert_equals "$want" "$(cat "$FM_SHIM_LOG")" "$label: the real tool must receive the original arguments"
}

# assert_passed_through_allowed is the opt-out's shape: the same pass-through,
# with exactly one line naming the variable that allowed it.
assert_passed_through_allowed() {
  local label=$1 want=$2
  assert_equals 0 "$SHIM_STATUS" "$label: the shim must pass the call through"
  assert_equals "$want" "$(cat "$FM_SHIM_LOG")" "$label: the real tool must receive the original arguments"
  assert_equals 1 "$(guard_lines "$SHIM_ERR")" "$label: the opt-out must be reported in exactly one line"
  assert_contains "$(cat "$SHIM_ERR")" 'FM_ALLOW_HEADED_BROWSER=1' \
    "$label: the opt-out line must name the variable that allowed the window"
}

test_open_shim_refuses_visible_windows() {
  local prefix fake
  fake=$(make_fake_system_tools "$TMP_ROOT/system-tools")
  prefix="$SHIM_DIR:$fake"
  run_shim "$prefix" open 'https://example.com'
  assert_refused 'open <url>'
  run_shim "$prefix" open -a 'Google Chrome' 'https://example.com'
  assert_refused 'open -a "Google Chrome"'
  run_shim "$prefix" open -b com.google.Chrome
  assert_refused 'open -b com.google.Chrome'
  # getopt-style clusters: `-na` is `-n -a`, and the debuggable Chrome recipe
  # is `open -na "Google Chrome" --args ...`.
  run_shim "$prefix" open -na 'Google Chrome'
  assert_refused 'open -na "Google Chrome"'
  run_shim "$prefix" open -gna 'Brave Browser' 'https://example.com'
  assert_refused 'open -gna "Brave Browser"'
  run_shim "$prefix" open -nb com.google.Chrome
  assert_refused 'open -nb com.google.Chrome'
  run_shim "$prefix" open -na 'Google Chrome' --args --remote-debugging-port=9222 'https://example.com'
  assert_refused 'open -na "Google Chrome" --args <url>'
  # A bare `--` ends option parsing but not target checking: macOS `open` still
  # opens every later argument, so each one is still judged.
  run_shim "$prefix" open -- ./report.html
  assert_refused 'open -- report.html'
  run_shim "$prefix" open -- 'https://example.com'
  assert_refused 'open -- <url>'
  run_shim "$prefix" open ./report.html
  assert_refused 'open report.html'
  run_shim "$prefix" open 'file:///tmp/report.html'
  assert_refused 'open file://'
  pass "the open shim refuses every launch that could only end in a browser window"
}

test_open_shim_passes_ordinary_opens() {
  local prefix fake
  fake=$(make_fake_system_tools "$TMP_ROOT/system-tools")
  prefix="$SHIM_DIR:$fake"
  run_shim "$prefix" open ./report.md
  assert_passed_through 'open report.md' 'CALL open [./report.md]'
  run_shim "$prefix" open -R ./report.html
  assert_passed_through 'open -R report.html' 'CALL open [-R] [./report.html]'
  run_shim "$prefix" open -a TextEdit ./notes.txt
  assert_passed_through 'open -a TextEdit' 'CALL open [-a] [TextEdit] [./notes.txt]'
  run_shim "$prefix" open -a 'Archive Utility' ./bundle.zip
  assert_passed_through 'open -a "Archive Utility"' 'CALL open [-a] [Archive Utility] [./bundle.zip]'
  run_shim "$prefix" open -na TextEdit ./notes.txt
  assert_passed_through 'open -na TextEdit' 'CALL open [-na] [TextEdit] [./notes.txt]'
  run_shim "$prefix" open -ga 'Archive Utility' ./bundle.zip
  assert_passed_through 'open -ga "Archive Utility"' 'CALL open [-ga] [Archive Utility] [./bundle.zip]'
  run_shim "$prefix" open -- ./report.md
  assert_passed_through 'open -- report.md' 'CALL open [--] [./report.md]'
  run_shim "$prefix" open .
  assert_passed_through 'open .' 'CALL open [.]'
  run_shim "$prefix" open ./invoice.pdf
  assert_passed_through 'open invoice.pdf' 'CALL open [./invoice.pdf]'
  pass "ordinary file opening still reaches the real open with its arguments intact"
}

test_shims_step_over_nested_guard_directories() {
  local fake nested prefix
  fake=$(make_fake_system_tools "$TMP_ROOT/system-tools")
  # A secondmate runs its own guarded pane inside a guarded firstmate, so two
  # guard directories can sit on one PATH; the shims must step over both.
  nested="$TMP_ROOT/nested-guard"
  mkdir -p "$nested"
  cp "$SHIM_DIR/.fm-browser-guard" "$nested/.fm-browser-guard"
  ln -s "$ROOT/bin/fm-browser-guard-open.sh" "$nested/open"
  ln -s "$ROOT/bin/fm-browser-guard-osascript.sh" "$nested/osascript"
  prefix="$nested:$SHIM_DIR:$fake"
  run_shim "$prefix" open ./report.md
  assert_passed_through 'nested guards: open report.md' 'CALL open [./report.md]'
  run_shim "$prefix" open 'https://example.com'
  assert_refused 'nested guards: open <url>'
  pass "the shims step over a nested guard directory instead of recursing into it"
}

test_osascript_shim_refuses_browser_scripts() {
  local prefix fake
  fake=$(make_fake_system_tools "$TMP_ROOT/system-tools")
  prefix="$SHIM_DIR:$fake"
  run_shim "$prefix" osascript -e 'tell application "Google Chrome" to open location "https://example.com"'
  assert_refused 'osascript naming Chrome'
  run_shim "$prefix" osascript -e 'tell application "Safari" to activate'
  assert_refused 'osascript naming Safari'
  run_shim "$prefix" osascript -e 'tell app "Google Chrome" to activate'
  assert_refused 'osascript app abbreviation naming Chrome'
  run_shim "$prefix" osascript -e 'tell application id "com.google.Chrome" to activate'
  assert_refused 'osascript bundle id naming Chrome'
  run_shim "$prefix" osascript -l JavaScript -e 'Application("Google Chrome").activate()'
  assert_refused 'osascript JXA double-quoted browser name'
  run_shim "$prefix" osascript -l JavaScript -e "Application('Brave Browser').activate()"
  assert_refused 'osascript JXA single-quoted browser name'
  run_shim "$prefix" osascript -e 'open location "https://example.com"'
  assert_refused 'osascript open location'
  run_shim_stdin "$prefix" osascript 'open location "https://example.com"'
  assert_refused 'osascript script on stdin (Python webbrowser)'
  run_shim_stdin_args "$prefix" osascript 'open location "https://example.com"' -
  assert_refused 'osascript - (script on stdin)'
  run_shim_stdin_args "$prefix" osascript 'Application("Safari").activate()' -l JavaScript
  assert_refused 'osascript -l JavaScript (script on stdin)'
  pass "the osascript shim refuses the AppleScript routes to a browser window"
}

test_osascript_shim_passes_other_scripts() {
  local prefix fake
  fake=$(make_fake_system_tools "$TMP_ROOT/system-tools")
  prefix="$SHIM_DIR:$fake"
  run_shim "$prefix" osascript -e 'display notification "done"'
  assert_passed_through 'osascript notification' 'CALL osascript [-e] [display notification "done"]
STDIN '
  run_shim "$prefix" osascript -e 'tell application "TextEdit" to activate'
  assert_passed_through 'osascript TextEdit' 'CALL osascript [-e] [tell application "TextEdit" to activate]
STDIN '
  run_shim "$prefix" osascript -e 'tell app "TextEdit" to activate'
  assert_passed_through 'osascript app abbreviation TextEdit' 'CALL osascript [-e] [tell app "TextEdit" to activate]
STDIN '
  run_shim "$prefix" osascript -e 'tell application id "com.apple.finder" to activate'
  assert_passed_through 'osascript bundle id Finder' 'CALL osascript [-e] [tell application id "com.apple.finder" to activate]
STDIN '
  run_shim "$prefix" osascript -l JavaScript -e 'Application("Finder").activate()'
  assert_passed_through 'osascript JXA Application("Finder")' 'CALL osascript [-l] [JavaScript] [-e] [Application("Finder").activate()]
STDIN '
  run_shim "$prefix" osascript -e 'tell application "Finder" to open location "file:///tmp"'
  assert_passed_through 'osascript Finder reveal' 'CALL osascript [-e] [tell application "Finder" to open location "file:///tmp"]
STDIN '
  run_shim_stdin "$prefix" osascript 'tell application "System Events" to keystroke "a"'
  assert_passed_through 'osascript stdin pass-through' 'CALL osascript
STDIN tell application "System Events" to keystroke "a"'
  run_shim_stdin_args "$prefix" osascript 'display notification "done"' -
  assert_passed_through 'osascript - pass-through' 'CALL osascript [-]
STDIN display notification "done"'
  run_shim_stdin_args "$prefix" osascript 'display notification "done"' -l JavaScript
  assert_passed_through 'osascript -l JavaScript pass-through' 'CALL osascript [-l] [JavaScript]
STDIN display notification "done"'
  pass "scripts that are not browser launches reach the real osascript, stdin included"
}

test_shims_honor_the_opt_out() {
  local prefix fake
  fake=$(make_fake_system_tools "$TMP_ROOT/system-tools")
  prefix="$SHIM_DIR:$fake"
  run_shim "$prefix" env FM_ALLOW_HEADED_BROWSER=1 open 'https://example.com'
  assert_passed_through_allowed 'opt-out open <url>' 'CALL open [https://example.com]'
  run_shim "$prefix" env FM_ALLOW_HEADED_BROWSER=1 osascript -e 'tell application "Safari" to activate'
  assert_passed_through_allowed 'opt-out osascript' 'CALL osascript [-e] [tell application "Safari" to activate]
STDIN '
  pass "the captain's opt-out passes the PATH shims through with one notice line"
}

# Python's webbrowser reaches a browser without the PATH shims: since Python 3.13
# it pipes its AppleScript to /usr/bin/osascript by full path. The driver lets
# webbrowser run for real but records that final os.popen instead of executing
# it, so a route that would have opened a window is observable without one.
PY_WEBBROWSER_DRIVER='
import os, webbrowser
calls = []
class Pipe:
    def write(self, text): pass
    def close(self): return None
def popen(cmd, mode="r", buffering=-1):
    calls.append(cmd)
    return Pipe()
os.popen = popen
opened = webbrowser.open("https://example.com")
print("POPEN=%s" % ",".join(calls))
'

test_python_webbrowser_is_refused() {
  local fake out
  command -v python3 >/dev/null 2>&1 || fail "the browser guard tests need python3"
  fake=$(make_fake_system_tools "$TMP_ROOT/system-tools")
  FM_SHIM_LOG="$TMP_ROOT/shim.log"
  export FM_SHIM_LOG
  : > "$FM_SHIM_LOG"
  out=$(PATH="$fake:$PATH" guarded python3 -I -c "$PY_WEBBROWSER_DRIVER" 2>"$TMP_ROOT/py.err")
  assert_equals 'POPEN=' "$out" "webbrowser.open must not fall through to a direct osascript pipe"
  assert_equals 1 "$(guard_lines "$TMP_ROOT/py.err")" "the refusal must be exactly one line"
  assert_equals '' "$(cat "$FM_SHIM_LOG")" "the real open and osascript must not be reached"

  : > "$FM_SHIM_LOG"
  out=$(PATH="$fake:$PATH" FM_ALLOW_HEADED_BROWSER=1 guarded python3 -I -c "$PY_WEBBROWSER_DRIVER" 2>"$TMP_ROOT/py.err")
  assert_equals 'POPEN=' "$out" "the opt-out must open through the real open, not a direct osascript pipe"
  assert_equals 'CALL open [https://example.com]' "$(cat "$FM_SHIM_LOG")" \
    "the opt-out must hand the URL to the real open"
  assert_contains "$(cat "$TMP_ROOT/py.err")" 'FM_ALLOW_HEADED_BROWSER=1' \
    "the opt-out must be reported in one line"
  pass "Python's webbrowser is refused in a guarded pane and allowed through the opt-out"
}

# --- the guard must not break a worker --------------------------------------

test_filtered_subprocess_environment_keeps_the_guard() {
  guarded node "$FIXTURES/filtered-subprocess.cjs" "$TMP_ROOT/filtered-subprocess" \
    || fail "a filtered MCP subprocess must not escape the browser guard"
  pass "filtered subprocess environments retain browser enforcement without copying secrets"
}

test_guard_leaves_ordinary_node_work_alone() {
  local out status
  out=$(guarded node -e 'process.stdout.write("stdout-clean")' 2>"$TMP_ROOT/node.err")
  status=$?
  assert_equals 0 "$status" "a Node process under the guard must still exit 0"
  assert_equals 'stdout-clean' "$out" "the preload must never write to stdout"
  assert_equals '' "$(cat "$TMP_ROOT/node.err")" "a Node process that launches nothing must stay silent"

  out=$(guarded node -e 'const { execFile } = require("child_process"); const { promisify } = require("util"); promisify(execFile)("/bin/echo", ["promisified"]).then((r) => process.stdout.write(String(r.stdout)))' 2>&1)
  assert_equals 'promisified' "$out" "promisified execFile must keep working under the guard"

  out=$(guarded node -e 'const { spawnSync } = require("child_process"); process.stdout.write(String(spawnSync("/bin/echo", ["plain"]).stdout))' 2>&1)
  assert_equals 'plain' "$out" "a non-browser spawn must be untouched"

  out=$(guarded node -e 'const { execSync } = require("child_process"); process.stdout.write(execSync("echo shell-form").toString())' 2>&1)
  assert_equals 'shell-form' "$out" "a shell-form spawn must be untouched"

  out=$(guarded node -e 'const { spawnSync } = require("child_process"); process.stdout.write(String(spawnSync("/bin/sh", ["-c", "printf indirect"]).stdout))' 2>&1)
  assert_equals 'indirect' "$out" "a browser-shaped shell command must not be rewritten as an argv"
  pass "the guard leaves ordinary Node work, promisified execFile, and shell spawns untouched"
}

test_electron_launch_is_left_alone_and_bare_browser_spawn_is_forced() {
  local stub log out
  stub=$(make_browser_stub "$TMP_ROOT/electron-stub" electron)
  log="$TMP_ROOT/electron.log"
  rm -f "$log"
  FM_STUB_LOG="$log" guarded node -e 'require("child_process").spawnSync(process.argv[1], ["app.js", "--remote-debugging-port=9222", "--enable-automation"])' "$stub" >/dev/null 2>"$log.err" || true
  assert_equals 1 "$(stub_launches "$log")" "the electron app must be launched once"
  assert_equals "$(printf 'app.js\n--remote-debugging-port=9222\n--enable-automation')" "$(stub_args "$log" 1)" \
    "an Electron launch must reach the app without an injected headless flag"
  assert_equals 0 "$(guard_lines "$log.err")" "an Electron launch must not be reported as a forced browser"

  stub=$(make_browser_stub "$TMP_ROOT/bare-stub" chrome)
  for form in 'spawnSync(b)' 'spawnSync(b, {stdio: "ignore"})' 'execFileSync(b, {stdio: "ignore"})' 'spawnSync(b, [])'; do
    log="$TMP_ROOT/bare.log"
    rm -f "$log"
    FM_STUB_LOG="$log" guarded node -e "const b = process.argv[1]; try { require('child_process').$form } catch (e) {}" "$stub" >/dev/null 2>"$log.err" || true
    assert_equals 1 "$(stub_launches "$log")" "$form: a bare browser spawn must start once"
    assert_equals '--headless' "$(stub_args "$log" 1)" "$form: a bare browser spawn must be forced headless"
    assert_equals 1 "$(guard_lines "$log.err")" "$form: the forced launch must be reported once"
  done
  stub=$(make_browser_stub "$TMP_ROOT/promisified-stub" chrome)
  log="$TMP_ROOT/promisified.log"
  rm -f "$log"
  FM_STUB_LOG="$log" guarded node -e 'const { execFile } = require("child_process"); require("util").promisify(execFile)(process.argv[1], ["--remote-debugging-port=0", "https://example.com"]).catch(() => {})' "$stub" >/dev/null 2>"$log.err" || true
  assert_equals 1 "$(stub_launches "$log")" "a promisified browser execFile must start once"
  assert_equals "$(printf '%s\n' --remote-debugging-port=0 https://example.com --headless)" "$(stub_args "$log" 1)" \
    "a promisified browser execFile must be forced headless"
  pass "Electron launches are untouched and argument-less browser spawns are forced headless"
}

# A macOS Brave install's browser binary basename is `Brave Browser` (with a
# space), so the spawn layer must classify it as Chromium instead of skipping it
# because of the gap between the words.
test_macos_brave_binary_is_forced_headless() {
  local stub log
  stub=$(make_browser_stub "$TMP_ROOT/brave-stub" 'Brave Browser')
  log="$TMP_ROOT/brave.log"
  rm -f "$log"
  FM_STUB_LOG="$log" guarded node -e 'require("child_process").spawnSync(process.argv[1], ["--remote-debugging-port=9222"])' "$stub" >/dev/null 2>"$log.err" || true
  assert_equals 1 "$(stub_launches "$log")" "a macOS Brave Browser spawn must start once"
  assert_equals "$(printf '%s\n' --remote-debugging-port=9222 --headless)" "$(stub_args "$log" 1)" \
    "a macOS Brave Browser spawn must be forced headless"
  assert_equals 1 "$(guard_lines "$log.err")" "the forced Brave launch must be reported once"
  pass "the macOS Brave Browser binary is classified and forced headless"
}

test_guard_environment_is_safe_to_apply_twice() {
  local snippet out stub
  snippet=$(guard_snippet) || fail "the guard environment snippet could not be built"
  out=$(PATH=/usr/bin:/bin NODE_OPTIONS=--max-old-space-size=4096 /bin/sh -c \
    "$snippet$snippet printf '%s\n' \"\$NODE_OPTIONS\"; printf '%s\n' \"\${PATH%%:*}\"")
  assert_equals "$SHIM_DIR" "$(printf '%s\n' "$out" | sed -n '2p')" \
    "the shim directory must lead PATH after two applications"
  assert_contains "$out" '--max-old-space-size=4096' \
    "an existing NODE_OPTIONS must survive the guard"
  assert_contains "$out" 'fm-browser-guard-load.cjs' \
    "the guard loader must still be named after two applications"

  # A secondmate's own worker inherits the guard and its spawn adds it again, so
  # the twice-applied environment still has to force a headed launch headless.
  stub=$(make_browser_stub "$TMP_ROOT/stub" chromium)
  rm -f "$REPLAY_LOG" "$REPLAY_ERR"
  FM_STUB_LOG="$REPLAY_LOG" /bin/sh -c "$snippet$snippet exec \"\$@\"" fm-browser-guard-test \
    node "$REPLAY" "$FIXTURES/playwright-chromium-headed.args" "$stub" 2>"$REPLAY_ERR" || true
  assert_equals 1 "$(stub_launches "$REPLAY_LOG")" \
    "a twice-guarded launch must still start exactly one browser process"
  assert_contains "$(stub_args "$REPLAY_LOG" 1)" '--headless' \
    "a twice-guarded launch must still end headless"
  pass "the guard environment keeps an existing NODE_OPTIONS and is safe to apply twice"
}

test_guard_warns_instead_of_failing_when_the_install_is_missing() {
  local install out status
  # A host that never received the guard files must still launch its worker: the
  # snippet names the missing install in one line instead of refusing to run.
  # The install under test is a copy of the real script whose own root has no
  # guard files beside it, which is exactly the state a stale host is in.
  install="$TMP_ROOT/missing-install"
  mkdir -p "$install/bin"
  cp "$GUARD_ENV" "$install/bin/"
  out=$(PATH=/usr/bin:/bin /bin/sh -c "$("$install/bin/fm-browser-guard-env.sh" --command) printf 'STATUS=%s\n' \"\$?\"" 2>&1)
  status=$?
  assert_equals 0 "$status" "the wrapper shell must not fail"
  assert_contains "$out" 'fm-browser-guard: warning: the browser guard is not installed' \
    "a missing install must be named in one line"
  assert_contains "$out" 'STATUS=0' "a missing install must not fail the launch"
  pass "a host without the guard files warns once and still launches"
}

test_guard_survives_a_hostile_checkout_path() {
  local install snippet out
  # A checkout whose directory name carries shell syntax must not break the
  # snippet, must not make it execute what the name embeds, and must still guard
  # the PATH shims even though NODE_OPTIONS cannot name that path.
  install="$TMP_ROOT/hostile's \$(touch SHOULD_NOT_EXIST) \`false\` root"
  mkdir -p "$install"
  cp -R "$ROOT/bin" "$install/bin"
  snippet=$("$install/bin/fm-browser-guard-env.sh" --command) \
    || fail "the guard environment snippet could not be built from a hostile path"
  rm -f "$TMP_ROOT/SHOULD_NOT_EXIST"
  out=$(PATH=/usr/bin:/bin /bin/sh -c "$snippet printf 'PATH_HEAD=%s\\n' \"\${PATH%%:*}\"; printf 'NODE_OPTIONS=%s\\n' \"\${NODE_OPTIONS:-unset}\"" 2>&1)
  assert_contains "$out" "PATH_HEAD=$install/bin/fm-browser-guard-bin" \
    "a hostile path must still put the shim directory on PATH"
  assert_contains "$out" 'cannot be named in NODE_OPTIONS' \
    "a path NODE_OPTIONS cannot represent must be named in one warning line"
  assert_equals 'unset' "$(printf '%s\n' "$out" | sed -n 's/^NODE_OPTIONS=//p')" \
    "a path NODE_OPTIONS cannot represent must not produce a broken assignment"
  assert_absent "$TMP_ROOT/SHOULD_NOT_EXIST" \
    "shell syntax inside a path must never be executed by the snippet"
  pass "a hostile checkout path is quoted inertly and only the Node layer is skipped"
}

# A pane's launch snippet names an absolute loader path. If the preload that
# loader requires disappears from the checkout afterwards (a branch switch or
# revert in the home), every `node` in that pane must keep working unguarded
# instead of aborting with MODULE_NOT_FOUND.
test_vanished_preload_does_not_break_node() {
  local install snippet out status node_dir
  install="$TMP_ROOT/vanished-preload"
  mkdir -p "$install"
  cp -R "$ROOT/bin" "$install/bin"
  snippet=$("$install/bin/fm-browser-guard-env.sh" --command) \
    || fail "the guard environment snippet could not be built from the install copy"
  rm "$install/bin/fm-browser-guard-preload.cjs"
  node_dir=$(dirname "$(command -v node)")
  out=$(PATH="$node_dir:/usr/bin:/bin" /bin/sh -c "$snippet node -e 'process.stdout.write(\"survived\")'" 2>"$TMP_ROOT/vanished.err")
  status=$?
  assert_equals 0 "$status" "node must start when the preload vanished after the launch snippet was built"
  assert_equals 'survived' "$out" "the unguarded node must still run its program"
  pass "a vanished preload degrades to an unguarded Node process instead of MODULE_NOT_FOUND"
}

test_guard_snippet_shape() {
  local out status
  out=$("$GUARD_ENV" --command)
  status=$?
  assert_equals 0 "$status" "--command must succeed"
  assert_contains "$out" 'export FM_BROWSER_GUARD=1' "the snippet must set the guard marker"
  lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  assert_equals 1 "$lines" "the snippet must be a single line"
  "$GUARD_ENV" --help >/dev/null 2>&1 || fail "--help must succeed"
  out=$("$GUARD_ENV" --bogus 2>&1)
  status=$?
  assert_equals 2 "$status" "an unknown argument must be refused"
  assert_contains "$out" 'Usage:' "an unknown argument must print the usage"
  pass "the guard environment script has one documented command and refuses anything else"
}

# --- runner -----------------------------------------------------------------

for t in \
  test_launch_layer_carries_the_guard \
  test_recorded_launcher_argvs_are_forced_headless \
  test_launcher_api_is_forced_headless \
  test_opt_out_allows_a_visible_launch \
  test_open_shim_refuses_visible_windows \
  test_open_shim_passes_ordinary_opens \
  test_shims_step_over_nested_guard_directories \
  test_osascript_shim_refuses_browser_scripts \
  test_osascript_shim_passes_other_scripts \
  test_shims_honor_the_opt_out \
  test_python_webbrowser_is_refused \
  test_filtered_subprocess_environment_keeps_the_guard \
  test_guard_leaves_ordinary_node_work_alone \
  test_electron_launch_is_left_alone_and_bare_browser_spawn_is_forced \
  test_macos_brave_binary_is_forced_headless \
  test_guard_environment_is_safe_to_apply_twice \
  test_guard_warns_instead_of_failing_when_the_install_is_missing \
  test_guard_survives_a_hostile_checkout_path \
  test_vanished_preload_does_not_break_node \
  test_guard_snippet_shape; do
  "$t"
done

echo "all fm-browser-guard tests passed"
