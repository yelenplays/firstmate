'use strict';
// Reproduce chrome-devtools-axi's MCP hop: a guarded Node parent starts a
// Node server with an allowlisted env; that server launches a known browser.
// The browser is a recording executable, so even a regression opens no window.
const assert = require('node:assert/strict');
const cp = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { promisify } = require('node:util');

async function main() {
  const dir = process.argv[2];
  fs.mkdirSync(dir, { recursive: true });
  const browser = path.join(dir, 'Google Chrome');
  fs.writeFileSync(browser, '#!/bin/sh\nprintf "%s\\n" "$@"\n', { mode: 0o755 });
  const worker = path.join(dir, 'mcp-server.cjs');
  fs.writeFileSync(worker, `#!${process.execPath}
const cp = require('node:child_process');
const args = ['--remote-debugging-port=0'];
if (process.env.CHROME_DEVTOOLS_AXI_HEADED !== '1') args.push('--headless');
const launched = cp.execFileSync(${JSON.stringify(browser)}, args, {encoding:'utf8'});
process.stdout.write(JSON.stringify({
  args: launched.trim().split('\\n'),
  nodeOptions: process.env.NODE_OPTIONS,
  explicit: process.env.EXPLICIT,
  privateValue: process.env.FM_TEST_PRIVATE_VALUE,
  browserHook: process.env.BROWSER,
  path: process.env.PATH,
  noOpen: process.env.LAVISH_AXI_NO_OPEN
}));
`, { mode: 0o755 });

  // Deliberately omit NODE_OPTIONS's preload and all guard exports, like the
  // MCP SDK's environment builder. Keep a caller-owned Node option intact.
  const env = Object.freeze({
    HOME: dir,
    PATH: '/usr/bin:/bin',
    NODE_OPTIONS: '--max-old-space-size=128',
    CHROME_DEVTOOLS_AXI_HEADED: '1',
    EXPLICIT: 'kept',
  });
  const before = JSON.stringify(env);
  const options = Object.freeze({ env, encoding: 'utf8' });
  process.env.FM_TEST_PRIVATE_VALUE = 'must-not-leak';
  function check(output, label, allowed = false) {
    const result = JSON.parse(output);
    assert.deepEqual(result.args, allowed ? ['--remote-debugging-port=0'] : ['--remote-debugging-port=0', '--headless'], label);
    assert.equal(result.explicit, 'kept', label + ': explicit environment retained');
    assert.equal(result.privateValue, undefined, label + ': parent secrets not copied');
    assert(result.nodeOptions.includes('--max-old-space-size=128'), label + ': caller Node options retained');
    if (!allowed) {
      assert.equal(result.browserHook, path.resolve(__dirname, '../../../bin/fm-browser-guard-browser.sh'));
      assert.equal(result.path.split(path.delimiter)[0], path.resolve(__dirname, '../../../bin/fm-browser-guard-bin'));
      assert.equal(result.noOpen, '1');
    }
    assert.equal(JSON.stringify(env), before, label + ': caller environment not mutated');
  }

  const args = [worker];
  const sync = cp.spawnSync(process.execPath, args, options);
  assert.equal(sync.status, 0, sync.stderr);
  check(sync.stdout, 'spawnSync filtered MCP child');
  check(cp.execFileSync(process.execPath, args, options), 'execFileSync filtered MCP child');
  const execResult = await promisify(cp.execFile)(process.execPath, args, options);
  check(execResult.stdout, 'promisified execFile filtered MCP child');
  check(await new Promise((resolve, reject) => {
    cp.execFile(worker, options, (err, stdout) => err ? reject(err) : resolve(stdout));
  }), 'execFile options-only overload');
  for (const [command, callArgs] of [[process.execPath, [args, options]], [worker, [options]]]) {
    const output = await new Promise((resolve, reject) => {
      const child = cp.spawn(command, ...callArgs);
      let stdout = '', stderr = '';
      child.stdout.on('data', (chunk) => { stdout += chunk; });
      child.stderr.on('data', (chunk) => { stderr += chunk; });
      child.on('error', reject);
      child.on('close', (code) => code === 0 ? resolve(stdout) : reject(new Error(stderr)));
    });
    check(output, 'spawn filtered MCP child');
  }
  // Every hop can rebuild an allowlist, not just the immediate worker child.
  const relay = `process.stdout.write(require('node:child_process').execFileSync(process.execPath, ${JSON.stringify(args)}, ${JSON.stringify(options)}));`;
  check(cp.execFileSync(process.execPath, ['-e', relay], options), 'two filtered MCP hops');
  check(cp.execFileSync('/bin/sh', ['-c', 'exec "$1" "$2"', 'relay', process.execPath, worker], options), 'shell intermediary');
  check(cp.execFileSync(process.execPath, args, { ...options, env: { ...env, FM_ALLOW_HEADED_BROWSER: '1' } }), 'explicit child opt-out', true);
  console.log('filtered subprocess browser guard passed');
}
main().catch((err) => { console.error(err); process.exitCode = 1; });
