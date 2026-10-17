const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const {promisify} = require('node:util');
const ROOT = process.cwd();
const runtime = process.versions.bun ? 'bun' : 'node';
const E = '/Users/yelen/.no-mistakes/evidence/01M55Y2Q30TR9XSAETE04MHGAM';
const pw = require(path.join(ROOT, '.browser-guard-validation/node_modules/playwright-core'));
const pp = require(path.join(ROOT, '.browser-guard-validation/node_modules/puppeteer-core'));
const chrome = pw.chromium.executablePath();
const results = [];
const html = '<!doctype html><html><style>body{font:24px system-ui;background:#eef4ef;color:#143522;padding:64px}h1{font-size:48px}p{max-width:750px;line-height:1.6}</style><h1>Browser guard: live render</h1><p>A request for a visible browser rendered this page in an isolated headless browser instead.</p></html>';
function record(name, detail) { console.log(JSON.stringify({name,result:'pass',detail})); results.push({name,result:'pass',detail}); }
function commands(executable) { return cp.execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'}).split('\n').filter(x=>x.includes(executable) && !x.includes(' -axo ')); }
async function playwright(family, method) {
  let browser, context;
  const options = {headless:process.env.VALIDATION_CONTROL==='1',timeout:30000};
  try {
    if (method==='persistent') { context=await pw[family].launchPersistentContext(path.join(ROOT,'.browser-guard-validation',family+'-profile'),options); browser=context.browser(); }
    else if(method==='server') { const server=await pw[family].launchServer(options); browser=await pw[family].connect(server.wsEndpoint()); browser._serverToClose=server; }
    else browser=await pw[family].launch(options);
    context ||= await browser.newContext({viewport:{width:1200,height:700}});
    const page=await context.newPage(); await page.setContent(html);
    assert.equal(await page.locator('h1').textContent(),'Browser guard: live render');
    const processes=commands(process.env.PLAYWRIGHT_BROWSERS_PATH);
    assert(processes.some(x=> /(?:--headless|-headless)(?:[ =]|$)/.test(x)),JSON.stringify(processes));
    const ua=await page.evaluate(()=>navigator.userAgent);
    if(family==='chromium') assert(ua.includes('HeadlessChrome'),ua);
    await page.screenshot({path:path.join(E,`${runtime}-${family}-${method}.png`)});
    record(`${runtime} Playwright ${family} ${method} headless:false`,{ua,processes});
  } finally { console.log(`CLOSING ${runtime} ${family} ${method}`); if(context) await context.close(); if(browser) {await browser.close(); if(browser._serverToClose) await browser._serverToClose.close();} console.log(`CLOSED ${runtime} ${family} ${method}`); }
}
async function puppeteer() {
  const browser=await pp.launch({headless:false,executablePath:chrome,timeout:30000});
  try {const page=await browser.newPage(); await page.setContent(html); const ua=await page.evaluate(()=>navigator.userAgent); assert(ua.includes('HeadlessChrome'),ua); const argv=browser.process().spawnargs; assert(argv.includes('--headless')); await page.screenshot({path:path.join(E,`${runtime}-puppeteer.png`)}); record(`${runtime} Puppeteer headless:false`,{ua,argv});} finally {await browser.close();}
}
async function direct() {
  // Browser --dump-dom exits by itself, allowing sync, callback and promise routes to use the real executable.
  const args=['--dump-dom','--no-first-run','--no-default-browser-check','--user-data-dir='+path.join(ROOT,'.browser-guard-validation/direct-profile'),'data:text/html,<h1>direct-real-browser</h1>'];
  for(const method of ['spawnSync','execFileSync','execFile','promisified-execFile','bun-spawnSync']) {
    if(method==='bun-spawnSync' && !globalThis.Bun) continue;
    let out;
    if(method==='spawnSync') {const p=cp.spawnSync(chrome,args,{encoding:'utf8',timeout:30000}); assert.equal(p.status,0,p.stderr); out=p.stdout;}
    if(method==='execFileSync') out=cp.execFileSync(chrome,args,{encoding:'utf8',timeout:30000});
    if(method==='execFile') out=await new Promise((resolve,reject)=>cp.execFile(chrome,args,{timeout:30000},(e,stdout)=>e?reject(e):resolve(stdout)));
    if(method==='promisified-execFile') {const promise=promisify(cp.execFile)(chrome,args,{timeout:30000}); assert(promise.child); out=(await promise).stdout;}
    if(method==='bun-spawnSync') {const p=Bun.spawnSync([chrome,...args]); assert.equal(p.exitCode,0); out=p.stdout.toString();}
    assert(out.includes('<h1>direct-real-browser</h1>')); record(`${runtime} direct ${method} real Chrome without headless argument`,{dom:out.trim()});
  }
}
async function filtered() {
  const env={PATH:process.env.PATH,PLAYWRIGHT_BROWSERS_PATH:process.env.PLAYWRIGHT_BROWSERS_PATH,VALIDATION_FILTERED_CHILD:'1'};
  const snapshot=JSON.stringify(env);
  const child=cp.spawnSync(process.execPath,[__filename,'filtered-child'],{env,encoding:'utf8',timeout:90000});
  assert.equal(child.status,0,child.stderr+child.stdout); assert.equal(JSON.stringify(env),snapshot);
  record(`${runtime} filtered environment child remains guarded`,{stdout:child.stdout,stderr:child.stderr,callerEnvUnchanged:true});
}
(async()=>{
  console.log(JSON.stringify({runtime,version:process.version,bunVersion:process.versions.bun,playwright:require(path.join(ROOT,'.browser-guard-validation/node_modules/playwright-core/package.json')).version,puppeteer:require(path.join(ROOT,'.browser-guard-validation/node_modules/puppeteer-core/package.json')).version}));
  if(process.argv[2]==='filtered-child') { assert.equal(process.env.FM_BROWSER_GUARD,'1'); await playwright('chromium','launch'); return; }
  if(process.env.VALIDATION_CASE==='persistent') await playwright('chromium','persistent');
  else if(process.env.VALIDATION_CASE==='server') await playwright('chromium','server');
  else if(process.env.VALIDATION_CASE==='remaining') { await puppeteer(); await direct(); await filtered(); }
  else {for(const family of ['chromium','firefox','webkit']) await playwright(family,'launch');
  await playwright('chromium','persistent'); await playwright('chromium','server'); await puppeteer(); await direct(); await filtered();}
  fs.writeFileSync(path.join(E,`${runtime}-live-results.json`),JSON.stringify(results,null,2));
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
