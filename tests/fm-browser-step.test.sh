#!/usr/bin/env bash
# Offline behavior tests for the public browser-step command and its parser.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-browser.sh"
pass() { printf 'ok - %s\n' "$1"; }

help=$("$SCRIPT" --help) || fail 'fm-browser --help failed'
assert_contains "$help" '--within <target>' 'help must document target scoping'
assert_contains "$help" 'Output is one compact JSON object' 'help must document the output privacy boundary'
pass 'help documents the step contract'

set +e
out=$(CHROME_DEVTOOLS_AXI_SESSION=default "$SCRIPT" step --press Enter 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail 'the default browser session must be refused before launch'
assert_contains "$out" 'default browser session is not allowed' 'session refusal must name the safe requirement'
pass 'default session is refused'

FM_BROWSER_ENGINE="$ROOT/bin/fm-browser-engine.mjs" node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const engine = await import(pathToFileURL(process.env.FM_BROWSER_ENGINE));

const secret = 'cfut_Zx9Kq2Lm8Rt4Vw6Yb1Nc3Hd5Jf7Gs0PaQe8Ui2Ok4';
const account = '0123456789abcdef0123456789abcdef';
const redacted = engine.redact(`Copy ${secret}; account ${account}; ghp_abcdefghijklmnopqrstuvwxyz0123456789; github_pat_abcdefghijklmnopqrstuvwxyz0123456789; sk-abcdefghijklmnopqrstuvwxyz0123456789; Bearer abcdefghijklmnopqrstuvwxyz0123456789; mail jane@example.test; https://example.test/callback?code=123456; OTP 123456`);
for (const needle of [secret, account, 'ghp_abcdefghijklmnopqrstuvwxyz', 'github_pat_abcdefghijklmnopqrstuvwxyz', 'sk-abcdefghijklmnopqrstuvwxyz', 'Bearer abcdef', 'jane@example.test', 'example.test/callback', '123456']) {
  assert.equal(redacted.includes(needle), false, `redactor leaked ${needle}`);
}
for (const expected of ['[redacted]', '[opaque]', '[email]', '[url]', '[number]']) {
  assert.ok(redacted.includes(expected), `redactor omitted ${expected}`);
}
assert.ok(engine.redact('Workers Scripts Edit').includes('Workers Scripts Edit'));
assert.ok(engine.redact('internationalization-settings-panel').includes('internationalization-settings-panel'));

const snapshot = [
  'uid=g1:0 rootwebarea "Step fixture"',
  '  uid=g1:1 main',
  '    uid=g1:2 row "Token 7"',
  '      uid=g1:3 button "Use"',
  '    uid=g1:4 row "Token 8"',
  '      uid=g1:5 button "Use"',
  '    uid=g1:6 textbox "Token name" value="scout-fixture"',
].join('\n');
const nodes = engine.parseSnapshot(snapshot);
assert.equal(nodes.length, 7);
assert.equal(nodes[2].indent, 4);
const useTarget = engine.resolveSelector(nodes, engine.parseSelector('button= use #2 '));
assert.equal(useTarget.target.uid, 'g1:5');
const scoped = engine.resolveSelector(
  nodes,
  engine.parseSelector('button~us'),
  engine.parseSelector('row=Token 7'),
);
assert.equal(scoped.target.uid, 'g1:3');
assert.equal(engine.resolveSelector(nodes, engine.parseSelector('button=Use'), engine.parseSelector('row=Missing')).error, 'WITHIN_NOT_FOUND');
assert.throws(() => engine.parseSelector('button=Use#0'));
assert.throws(() => engine.validateParams({ action: 'select', target: 'button=Use', option: 'DNS Edit' }));

let index = 0;
const afterSnapshot = `${snapshot}\n    uid=g2:7 button "Copy"\n    uid=g2:8 generic "${secret}"`;
const clickCalls = [];
const fakePage = {
  async snapshot() { return index++ === 0 ? snapshot : afterSnapshot; },
  async click(uid) { clickCalls.push(uid); },
  async fill() { throw new Error('not expected'); },
  async press() { throw new Error('not expected'); },
  async wait() {},
  async eval() { return '/safe-path'; },
};
const result = await engine.executeStep({
  action: 'click',
  target: 'button=Use#2',
  expectation: { kind: 'appears', selector: 'button=Copy' },
}, fakePage);
assert.equal(result.ok, true);
assert.deepEqual(clickCalls, ['@g1:5']);
assert.deepEqual(result.appeared, ['button|Copy']);
assert.equal(JSON.stringify(result).includes(secret), false);
assert.equal(JSON.stringify(result).includes('scout-fixture'), false);

let fillValue = '';
index = 0;
const fillResult = await engine.executeStep({
  action: 'fill',
  target: 'textbox=Token name',
  value: 'scout-fixture',
}, {
  ...fakePage,
  async snapshot() { return snapshot; },
  async fill(uid, value) { fillValue = `${uid}:${value}`; },
});
assert.equal(fillValue, '@g1:6:scout-fixture');
assert.equal(fillResult.ok, true);
assert.equal(JSON.stringify(fillResult).includes('scout-fixture'), false);

let pressed = '';
const urlResult = await engine.executeStep({
  action: 'press', key: 'Enter', expectation: { kind: 'url-path', path: '/safe-path' },
}, {
  ...fakePage,
  async snapshot() { return snapshot; },
  async press(key) { pressed = key; },
  async eval() { return '/safe-path'; },
});
assert.equal(pressed, 'Enter');
assert.equal(urlResult.ok, true);
const titleResult = await engine.executeStep({
  action: 'press', key: 'Enter', expectation: { kind: 'title', selector: 'title~step fixture' },
}, {
  ...fakePage,
  async snapshot() { return snapshot; },
  async press() {},
});
assert.equal(titleResult.ok, true);

const filtered = engine.sanitizeResult({
  step: 'step', ok: true, appeared: [`button|${secret}`], gone: [], ms: 4,
  value: secret, pageText: secret,
});
assert.equal(JSON.stringify(filtered).includes(secret), false);
assert.equal(Object.hasOwn(filtered, 'value'), false);
console.log('offline parser, selector, execution, and redaction checks passed');
JS
pass 'selectors, within scoping, action execution, and redaction are covered'

printf 'all tests passed\n'
