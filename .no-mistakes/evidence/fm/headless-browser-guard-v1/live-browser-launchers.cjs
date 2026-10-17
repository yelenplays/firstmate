const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const assert = require('node:assert/strict');
const root = process.cwd();
const evidence = '/Users/yelen/.no-mistakes/evidence/01M55STZBF17XWCASAY5ZRABQW';
const deps = path.join(root, '.guard-validation/deps/node_modules');
// This is the executable path reported by the real chrome://version proof,
// not a filesystem search or a replacement browser.
const executablePath = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
(async () => {
  const library = process.argv[2];
  const runtime = process.versions.bun ? 'bun' : 'node';
  const filtered = process.argv.includes('--filtered-child');
  const tag = `${runtime}-${library}${filtered ? '-filtered' : ''}`;
  const launcher = library === 'playwright' ? require(path.join(deps, 'playwright-core')).chromium : require(path.join(deps, 'puppeteer-core'));
  const options = { executablePath, headless: false, timeout: 30000 };
  if (filtered) options.env = { PATH: process.env.PATH, HOME: process.env.HOME };
  const browser = await launcher.launch(options);
  try {
    const page = await browser.newPage();
    if (library === 'playwright') await page.setViewportSize({ width: 1440, height: 900 });
    else await page.setViewport({ width: 1440, height: 900 });
    await page.goto('chrome://version');
    const report = await page.evaluate(() => ({ userAgent: navigator.userAgent, commandLine: document.querySelector('#command_line').textContent }));
    assert.match(report.userAgent, /HeadlessChrome/);
    assert.match(report.commandLine, /--headless(?:\s|=|$)/);
    fs.writeFileSync(path.join(evidence, `real-${tag}.png`), await page.screenshot());
    console.log(JSON.stringify({ runtime, library, filteredChildEnvironment: filtered, requestedHeadless: false, ...report, screenshot: `real-${tag}.png` }));
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
