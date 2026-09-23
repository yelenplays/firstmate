#!/usr/bin/env bash
# Offline route-contract checks plus an opt-in live fixture replay.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENGINE="$ROOT/bin/fm-browser-engine.mjs"
SCRIPT="$ROOT/bin/fm-browser.sh"
FM_BROWSER_ENGINE="$ENGINE" node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
const engine = await import(pathToFileURL(process.env.FM_BROWSER_ENGINE));
const route = {
  version: 1,
  host: '127.0.0.1',
  route: 'fixture',
  start: { url_path: '/routes.html' },
  vars: { name: { required: true } },
  steps: [
    { id: 'name', do: 'fill', target: { role: 'textbox', label: 'Route name' }, value: '${name}', expect: { appears: { role: 'heading', label: 'Name recorded' } } },
    { id: 'reveal', do: 'click', target: { role: 'button', label: 'Reveal fixture' }, expect: { appears: { role: 'heading', label: 'Route finished' } } },
    { id: 'handback', do: 'handoff', say: 'Continue in the browser', expect: { appears: { role: 'heading', label: 'Route finished' } } },
  ],
  heal_log: [],
};
assert.equal(engine.validateRoute(route), route);
assert.equal(engine.selectorFromRoute({ role: 'button', operator: '~', label: 'Save' }), 'button~Save');
assert.equal(engine.selectorFromRoute({ role: 'main', operator: '~', label: 'Workspace' }), 'main~Workspace');
assert.equal(engine.selectorFromRoute({ role: 'title', operator: '~', label: 'Dashboard' }, true), 'title~Dashboard');
assert.throws(() => engine.validateRoute({ ...route, version: 2 }));
assert.throws(() => engine.validateRoute({ ...route, steps: [...route.steps, route.steps[0]] }));
const snapshot = 'uid=x:0 rootwebarea "fixture"\n  uid=x:1 textbox "Route name"\n  uid=x:2 button "Reveal fixture"\n  uid=x:3 heading "Name recorded"\n  uid=x:4 heading "Route finished"';
let actionLog = [];
const page = {
  async eval() { return { host: '127.0.0.1', path: '/routes.html' }; },
  async snapshot() { return snapshot; },
  async fill(target, value) { actionLog.push(['fill', target, value]); },
  async click(target) { actionLog.push(['click', target]); },
  async press(key) { actionLog.push(['press', key]); },
  async wait() {},
};
let result = await engine.executeRoute(route, { name: 'deployment' }, null, page);
assert.equal(result.ok, true);
assert.deepEqual(result.completed, ['name', 'reveal', 'handback']);
assert.deepEqual(result.handoff, { step: 'handback', say: 'Continue in the browser' });
assert.deepEqual(actionLog[0], ['fill', '@x:1', 'deployment']);
assert.deepEqual(actionLog[1], ['click', '@x:2']);
assert.equal(JSON.stringify(result).includes('deployment'), false);
result = await engine.executeRoute(route, { name: 'deployment' }, 'reveal', page);
assert.equal(result.ok, true);
assert.deepEqual(result.completed, ['reveal', 'handback']);
for (const [vars, error] of [
  [{}, 'MISSING_VARIABLE'],
  [{ name: 'deployment', extra: 'x' }, 'UNKNOWN_VARIABLE'],
  [{ name: 'ghp_abcdefghijklmnopqrstuvwxyz123456' }, 'UNSAFE_VARIABLE'],
  [{ name: 'ABCDEFGHIJKLMNOPQRSTUVWX1234' }, 'UNSAFE_VARIABLE'],
]) {
  const response = await engine.executeRoute(route, vars, null, page);
  assert.equal(response.error, error);
}
const confirmed = { ...route, steps: [{ id: 'danger', do: 'click', confirm: true, target: { role: 'button', label: 'Reveal fixture' } }] };
actionLog = [];
result = await engine.executeRoute(confirmed, { name: 'safe' }, null, page);
assert.equal(result.error, 'CONFIRM_REQUIRED');
assert.deepEqual(actionLog, []);
const mismatchPage = { ...page, async eval() { return { host: 'elsewhere.test', path: '/routes.html' }; } };
assert.equal((await engine.executeRoute(route, { name: 'safe' }, null, mismatchPage)).error, 'START_MISMATCH');
let hostChecks = 0;
actionLog = [];
const changingHostPage = { ...page, async eval() {
  hostChecks += 1;
  return { host: hostChecks >= 3 ? 'elsewhere.test' : '127.0.0.1', path: '/routes.html' };
} };
result = await engine.executeRoute(route, { name: 'safe' }, null, changingHostPage);
assert.equal(result.error, 'START_MISMATCH');
assert.deepEqual(result.completed, ['name']);
assert.deepEqual(actionLog, [['fill', '@x:1', 'safe']]);
const timeoutRoute = {
  version: 1, host: '127.0.0.1', route: 'timeout', start: { url_path: '/routes.html' }, vars: {},
  steps: [{ id: 'wait', do: 'press', key: 'Tab', timeoutMs: 25, expect: { appears: { role: 'heading', label: 'Never appears' } } }],
  heal_log: [],
};
let timeoutWaits = 0;
const timeoutPage = {
  ...page,
  async snapshot() { return 'uid=x:0 rootwebarea "fixture"'; },
  async wait() {
    timeoutWaits += 1;
    if (timeoutWaits > 10) throw new Error('route timeout was not forwarded');
    await new Promise((resolve) => setTimeout(resolve, 5));
  },
};
result = await engine.executeRoute(timeoutRoute, {}, null, timeoutPage);
assert.equal(result.error, 'EXPECT_TIMEOUT');
assert.ok(timeoutWaits <= 10);
const healingRoute = {
  version: 1, host: '127.0.0.1', route: 'healing', start: { url_path: '/routes.html' }, vars: {},
  steps: [{ id: 'deploy', do: 'click', target: { role: 'button', label: 'Deploy production' }, expect: { appears: { role: 'heading', label: 'Done' } } }],
  heal_log: [],
};
const healingPage = {
  ...page,
  async snapshot() { return 'uid=x:0 rootwebarea "fixture"\n  uid=x:1 button "Deploy production 123456"\n  uid=x:2 heading "Done"'; },
  async click(target) { actionLog.push(['click', target]); },
};
result = await engine.executeRoute(healingRoute, {}, null, healingPage);
assert.equal(result.ok, true);
assert.equal(result.routeUpdates[0].target, 'Deploy production 123456');
assert.equal(result.heals[0].to, 'Deploy production [number]');
const runner = String.raw`
import { pathToFileURL } from 'node:url';
let evalCount = 0;
globalThis.PARAMS = {
  action: 'click', target: 'button=Go', expectation: { kind: 'url-path', path: '/done' },
  record: { host: 'target.example', route: 'mismatch', step: { id: 'click', do: 'click' } },
};
globalThis.page = {
  async eval() {
    evalCount += 1;
    if (evalCount === 1) return { host: 'start.example', path: '/form' };
    if (evalCount === 2) return '/done';
    return { host: 'target.example' };
  },
  async snapshot() { return 'uid=x:0 rootwebarea "fixture"\n  uid=x:1 button "Go"'; },
  async click() {}, async wait() {},
};
await import(pathToFileURL(process.env.FM_BROWSER_ENGINE));
`;
const invocation = spawnSync(process.execPath, ['--input-type=module', '-e', runner], {
  encoding: 'utf8', env: { ...process.env, FM_BROWSER_ENGINE: process.env.FM_BROWSER_ENGINE },
});
assert.equal(invocation.status, 0, invocation.stderr);
assert.equal(JSON.parse(invocation.stdout).record, undefined);
console.log('offline route format, variables, resume, confirmation, selector semantics, healing, and recording host checks passed');
JS
pass 'route format, interpolation, resume, confirmation, and one-run sequencing are covered'

TMP_HOME=$(fm_test_tmproot fm-browser-routes)
if FM_HOME="$TMP_HOME" "$SCRIPT" step --fill 'textbox=Route name' --value ignored --expect 'heading=Name recorded' --record 127.0.0.1/ignored --record-var toKEN --session browser-routes-test >/dev/null 2>&1; then
  fail 'mixed-case secret-like record variable was accepted'
fi
fm_live_gate default-on FM_BROWSER_ROUTES_LIVE chrome-devtools-axi node python3
mkdir -p "$TMP_HOME/data/browser-routes/127.0.0.1"
PORT=$((40000 + $$ % 20000))
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT/tests/fixtures/browser-steps" >/dev/null 2>&1 &
SERVER_PID=$!
SESSION="fm-browser-routes-$$-${RANDOM}"
STARTED=0
cleanup_routes() {
  if [ "$STARTED" -eq 1 ]; then
    CHROME_DEVTOOLS_AXI_SESSION="$SESSION" chrome-devtools-axi stop >/dev/null 2>&1 || true
  fi
  kill "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_routes EXIT INT TERM
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/routes.html" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
curl -fsS "http://127.0.0.1:$PORT/routes.html" >/dev/null || fail 'fixture server did not become ready'
cat >"$TMP_HOME/data/browser-routes/127.0.0.1/fixture.json" <<'JSON'
{
  "version": 1,
  "host": "127.0.0.1",
  "route": "fixture",
  "start": { "url_path": "/routes.html" },
  "vars": { "name": { "required": true } },
  "steps": [
    { "id": "name", "do": "fill", "target": { "role": "textbox", "label": "Route name" }, "value": "${name}", "expect": { "appears": { "role": "heading", "label": "Name recorded" } } },
    { "id": "reveal", "do": "click", "target": { "role": "button", "label": "Reveal fixture" }, "expect": { "appears": { "role": "heading", "label": "Route finished" } } },
    { "id": "handoff", "do": "handoff", "say": "Continue in the browser", "expect": { "appears": { "role": "heading", "label": "Route finished" } } }
  ],
  "heal_log": []
}
JSON
chmod 600 "$TMP_HOME/data/browser-routes/127.0.0.1/fixture.json"
unset CHROME_DEVTOOLS_AXI_AUTO_CONNECT CHROME_DEVTOOLS_AXI_BROWSER_URL \
  CHROME_DEVTOOLS_AXI_WS_HEADERS CHROME_DEVTOOLS_AXI_USER_DATA_DIR \
  CHROME_DEVTOOLS_AXI_PORT CHROME_DEVTOOLS_AXI_CHROME_ARGS
export CHROME_DEVTOOLS_AXI_SESSION="$SESSION"
chrome-devtools-axi start >/dev/null 2>&1 || fail 'could not start the named isolated browser session'
STARTED=1
printf 'await page.open("http://127.0.0.1:%s/routes.html");\nconsole.log("ready");\n' "$PORT" | chrome-devtools-axi run >/dev/null 2>&1 || fail 'could not open the route fixture'
OUT=$(env -u FM_HOME FM_ROOT_OVERRIDE="$TMP_HOME" "$SCRIPT" route run 127.0.0.1/fixture --var name=route-fixture --session "$SESSION") || fail "route did not replay from FM_ROOT_OVERRIDE: $OUT"
node -e 'const r=JSON.parse(process.argv[1]); if (!r.ok || r.completed.join(",") !== "name,reveal,handoff") process.exit(1)' "$OUT" || fail "route output did not confirm the full sequence: $OUT"
ROUTE=$(cat "$TMP_HOME/data/browser-routes/127.0.0.1/fixture.json")
case "$ROUTE" in *'route-fixture'*) fail 'a route variable value was written to disk' ;; esac
pass 'one named-session browser run replays, verifies, and keeps variable values out of route storage'
OUT=$(FM_HOME="$TMP_HOME" "$SCRIPT" step --fill 'textbox=Route name' --value recorded-literal --expect 'heading=Name recorded' --record 127.0.0.1/recorded --record-var name --session "$SESSION") || fail "verified step was not recorded: $OUT"
RECORDED=$(cat "$TMP_HOME/data/browser-routes/127.0.0.1/recorded.json")
case "$RECORDED" in *'${name}'*) ;; *) fail 'recorded fill did not use its named variable placeholder' ;; esac
case "$RECORDED" in *recorded-literal*) fail 'recorded input value was persisted' ;; esac
pass 'verified steps append safely and replace fill text with a named variable'
env -u FM_HOME FM_ROOT_OVERRIDE="$TMP_HOME" "$SCRIPT" step --press Tab --expect-title 'Firstmate ~ browser-route fixture' --record 127.0.0.1/root-override --session "$SESSION" >/dev/null || fail 'recording did not use FM_ROOT_OVERRIDE'
[ -f "$TMP_HOME/data/browser-routes/127.0.0.1/root-override.json" ] || fail 'recording was not written beneath FM_ROOT_OVERRIDE'
OUT=$(FM_HOME="$TMP_HOME" "$SCRIPT" step --press Tab --expect-title 'Firstmate ~ browser-route fixture' --record 127.0.0.1/titled --session "$SESSION") || fail "tilde-containing title expectation was not recorded: $OUT"
node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const t=r.steps[0].expect.title; if (t.role !== "title" || t.operator !== "~" || t.label !== "Firstmate ~ browser-route fixture") process.exit(1)' "$TMP_HOME/data/browser-routes/127.0.0.1/titled.json" || fail 'recorded title expectation changed its substring semantics'
pass 'title expectations preserve embedded tildes when recorded'
OUT=$(FM_HOME="$TMP_HOME" "$SCRIPT" step --click 'button=Navigate fixture' --expect-url-path /done --record 127.0.0.1/navigated --session "$SESSION") || fail "navigating step was not recorded: $OUT"
START_PATH=$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(r.start.url_path)' "$TMP_HOME/data/browser-routes/127.0.0.1/navigated.json")
[ "$START_PATH" = '/routes.html' ] || fail "recording used the post-action path: $START_PATH"
pass 'recording preserves the pre-action route start path'
cat >"$TMP_HOME/data/browser-routes/127.0.0.1/heal.json" <<'JSON'
{
  "version": 1,
  "host": "127.0.0.1",
  "route": "heal",
  "start": { "url_path": "/routes.html" },
  "vars": {},
  "steps": [
    { "id": "renamed", "do": "click", "target": { "role": "button", "label": "Reveal fixture now" }, "expect": { "appears": { "role": "heading", "label": "Route finished" } } },
    { "id": "approval", "do": "click", "confirm": true, "target": { "role": "button", "label": "Reveal fixture" } }
  ],
  "heal_log": []
}
JSON
chmod 600 "$TMP_HOME/data/browser-routes/127.0.0.1/heal.json"
printf 'await page.open("http://127.0.0.1:%s/routes.html");\nconsole.log("ready");\n' "$PORT" | chrome-devtools-axi run >/dev/null 2>&1 || fail 'could not reset the route fixture'
OUT=$(FM_HOME="$TMP_HOME" "$SCRIPT" route run 127.0.0.1/heal --session "$SESSION") || fail "route did not stop at confirmation: $OUT"
node -e 'const r=JSON.parse(process.argv[1]); if (r.ok || r.error !== "CONFIRM_REQUIRED" || r.completed.join(",") !== "renamed") process.exit(1)' "$OUT" || fail "route did not report the confirmation stop: $OUT"
node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); if (r.steps[0].target.label !== "Reveal fixture" || r.heal_log.length !== 1 || r.heal_log[0].by !== "local") process.exit(1)' "$TMP_HOME/data/browser-routes/127.0.0.1/heal.json" || fail 'verified healing was not persisted before the later confirmation stop'
pass 'verified healing persists even when a later step stops for confirmation'
printf 'browser route tests passed\n'
