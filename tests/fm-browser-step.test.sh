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
const redacted = engine.redact(`Copy ${secret}; account ${account}; ghp_abcdefghijklmnopqrstuvwxyz0123456789; github_pat_abcdefghijklmnopqrstuvwxyz0123456789; sk-abcdefghijklmnopqrstuvwxyz0123456789; Bearer abcdefghijklmnopqrstuvwxyz0123456789; mail jane@example.test; https://example.test/callback?code=123456; OTP 123456; Copy token=ab12cd34; Copy token abcdef; API key: Qx6; password hunter2; code 123; reference 987654`);
for (const needle of [secret, account, 'ghp_abcdefghijklmnopqrstuvwxyz', 'github_pat_abcdefghijklmnopqrstuvwxyz', 'sk-abcdefghijklmnopqrstuvwxyz', 'Bearer abcdef', 'jane@example.test', 'example.test/callback', '123456', '987654', 'ab12cd34', 'abcdef', 'Qx6', 'hunter2']) {
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
const afterSnapshot = `${snapshot}\n    uid=g2:7 button "Copy token=ab12cd34"\n    uid=g2:8 button "Copy token abcdef"\n    uid=g2:9 generic "${secret}"`;
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
  expectation: { kind: 'appears', selector: 'button~Copy' },
}, fakePage);
assert.equal(result.ok, true);
assert.equal(result.verified, true);
assert.deepEqual(clickCalls, ['@g1:5']);
assert.deepEqual(result.appeared, ['button|Copy token=[redacted]', 'button|Copy token [redacted]']);
assert.equal(JSON.stringify(result).includes(secret), false);
assert.equal(JSON.stringify(result).includes('scout-fixture'), false);

const missingTarget = await engine.executeStep({ action: 'click', target: 'button=Settings' }, {
  ...fakePage,
  async snapshot() { return snapshot; },
});
assert.equal(missingTarget.error, 'TARGET_NOT_FOUND');
assert.equal(Object.hasOwn(missingTarget, 'candidates'), false);
assert.deepEqual(missingTarget.gone, []);

const actionFailure = await engine.executeStep({ action: 'click', target: 'button=Use' }, {
  ...fakePage,
  async snapshot() { return snapshot; },
  async click() { throw new Error('rejected click'); },
});
assert.equal(actionFailure.ok, false);
assert.equal(actionFailure.verified, false);
assert.deepEqual(actionFailure.gone, []);
assert.deepEqual(actionFailure.appeared, []);

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
assert.equal(fillResult.verified, false);
assert.equal(JSON.stringify(fillResult).includes('scout-fixture'), false);

const alreadySatisfiedSnapshot = [
  'uid=s:0 rootwebarea "Save fixture"',
  '  uid=s:1 status "Saved"',
  '  uid=s:2 button "Save"',
].join('\n');
const alreadyAppears = await engine.executeStep({
  action: 'click', target: 'button=Save',
  expectation: { kind: 'appears', selector: 'status=Saved' },
}, {
  async snapshot() { return alreadySatisfiedSnapshot; },
  async click() {},
});
assert.equal(alreadyAppears.ok, true);
assert.equal(alreadyAppears.verified, false);
assert.equal(alreadyAppears.reason, 'already true before action');
const alreadyGone = await engine.executeStep({
  action: 'click', target: 'button=Save',
  expectation: { kind: 'gone', selector: 'status=Pending' },
}, {
  async snapshot() { return alreadySatisfiedSnapshot; },
  async click() {},
});
assert.equal(alreadyGone.ok, true);
assert.equal(alreadyGone.verified, false);
assert.equal(alreadyGone.reason, 'already true before action');
const alreadyTitle = await engine.executeStep({
  action: 'press', key: 'Enter',
  expectation: { kind: 'title', selector: 'title~Save fixture' },
}, {
  async snapshot() { return alreadySatisfiedSnapshot; },
  async press() {},
});
assert.equal(alreadyTitle.ok, true);
assert.equal(alreadyTitle.verified, false);
assert.equal(alreadyTitle.reason, 'already true before action');
let stablePathReadCount = 0;
const alreadyPath = await engine.executeStep({
  action: 'press', key: 'Enter',
  expectation: { kind: 'url-path', path: '/same-path' },
}, {
  async snapshot() { return alreadySatisfiedSnapshot; },
  async press() {},
  async eval() { stablePathReadCount += 1; return '/same-path'; },
});
assert.equal(alreadyPath.ok, true);
assert.equal(alreadyPath.verified, false);
assert.equal(alreadyPath.reason, 'already true before action');
assert.equal(stablePathReadCount, 2);

const pendingSnapshot = 'uid=p:0 rootwebarea "Save fixture"\n  uid=p:1 status "Saving"\n  uid=p:2 button "Save"';
let saveSnapshotIndex = 0;
const goneTransition = await engine.executeStep({
  action: 'click', target: 'button=Save',
  expectation: { kind: 'gone', selector: 'status=Saving' },
}, {
  async snapshot() { return saveSnapshotIndex++ === 0 ? pendingSnapshot : alreadySatisfiedSnapshot; },
  async click() {},
});
assert.equal(goneTransition.ok, true);
assert.equal(goneTransition.verified, true);

let pressed = '';
let urlReadCount = 0;
const urlResult = await engine.executeStep({
  action: 'press', key: 'Enter', expectation: { kind: 'url-path', path: '/safe-path' },
}, {
  ...fakePage,
  async snapshot() { return snapshot; },
  async press(key) { pressed = key; },
  async eval() { return urlReadCount++ === 0 ? '/before' : '/safe-path'; },
});
assert.equal(pressed, 'Enter');
assert.equal(urlResult.ok, true);
assert.equal(urlResult.verified, true);
let titleSnapshotIndex = 0;
const titleResult = await engine.executeStep({
  action: 'press', key: 'Enter', expectation: { kind: 'title', selector: 'title~Build #2' },
}, {
  ...fakePage,
  async snapshot() { return titleSnapshotIndex++ === 0 ? 'uid=t:0 rootwebarea "Build"' : 'uid=t:0 rootwebarea "Build #2"'; },
  async press() {},
});
assert.equal(titleResult.ok, true);
assert.equal(titleResult.verified, true);

const filtered = engine.sanitizeResult({
  step: 'step', ok: true, verified: true, appeared: [`button|${secret}`, 'button|Copy token=ab12cd34'], gone: ['button|Copy token abcdef'], ms: 4,
  value: secret, pageText: secret,
});
assert.equal(JSON.stringify(filtered).includes(secret), false);
assert.equal(JSON.stringify(filtered).includes('ab12cd34'), false);
assert.equal(JSON.stringify(filtered).includes('abcdef'), false);
assert.equal(Object.hasOwn(filtered, 'value'), false);
console.log('offline parser, selector, execution, and redaction checks passed');
JS
pass 'selectors, within scoping, action execution, and redaction are covered'

printf 'all tests passed\n'
