import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
import path from 'node:path';
import {execFile, spawn} from 'node:child_process';
import {promisify} from 'node:util';
const require = createRequire(path.join(process.cwd(), '.live-browser/package.json'));
const {chromium} = require('playwright-core');
const evidence = process.env.EVIDENCE;
const executablePath = chromium.executablePath();
console.log(JSON.stringify({node:process.version, playwright:require('playwright-core/package.json').version, puppeteer:require('puppeteer-core/package.json').version, executablePath,guard:process.env.FM_BROWSER_GUARD}));
assert.equal(process.env.FM_BROWSER_GUARD,'1');
const profile = name => path.join(process.cwd(),'.live-browser',name);
async function prove(page, label, screenshot) {
  await page.setContent(`<html><head><title>Browser guard live proof</title></head><body style="font:24px system-ui;padding:60px;background:#f3f5f4;color:#182920"><p>Firstmate · live browser proof</p><h1>${label}</h1><p>Requested: headless: false</p><p id="ua"></p><p>Actual: headless enforced</p></body></html>`);
  const ua=await page.evaluate(()=>{document.querySelector('#ua').textContent=navigator.userAgent; return navigator.userAgent;});
  const cdp = page.context ? await page.context().newCDPSession(page) : await page.createCDPSession();
  const {arguments:argv}=await cdp.send('Browser.getBrowserCommandLine');
  assert.match(ua,/HeadlessChrome/);
  assert(argv.some(arg=>/^--headless(?:=|$)/.test(arg)));
  console.log(JSON.stringify({scenario:label,userAgent:ua,headlessArguments:argv.filter(arg=>arg.startsWith('--headless')),passed:true}));
  if(screenshot) await page.screenshot({path:path.join(evidence,screenshot)});
  await cdp.detach();
}
for (const method of ['launch','launchPersistentContext','launchServer']) {
  let owner;
  try {
    if(method==='launchPersistentContext') {
      owner=await chromium.launchPersistentContext(profile(method),{headless:false,executablePath,args:['--enable-automation'],viewport:{width:1100,height:620}});
      await prove(await owner.newPage(),`Playwright ${method}`);
    } else if(method==='launchServer') {
      owner=await chromium.launchServer({headless:false,executablePath,args:['--enable-automation']});
      const browser=await chromium.connect(owner.wsEndpoint());
      await prove(await browser.newPage(),`Playwright ${method}`);
      await browser.close();
    } else {
      owner=await chromium.launch({headless:false,executablePath,args:['--enable-automation']});
      const page=await owner.newPage({viewport:{width:1100,height:620}});
      await prove(page,`Playwright ${method}`,'playwright-headless.png');
    }
  } finally {await owner?.close();}
}
for(const mode of ['esm','commonjs']) {
  const puppeteer=mode==='esm' ? (await import(pathToFileURL(require.resolve('puppeteer-core').replace('/lib/cjs/puppeteer/puppeteer-core.js','/lib/esm/puppeteer/puppeteer-core.js')))).default : require('puppeteer-core');
  const browser=await puppeteer.launch({headless:false,executablePath,args:['--enable-automation'],userDataDir:profile(`puppeteer-${mode}`)});
  try {const page=await browser.newPage(); await page.setViewport({width:1100,height:620}); await prove(page,`Puppeteer ${mode}`,mode==='esm'?'puppeteer-headless.png':undefined);} finally {await browser.close();}
}
for(const mode of ['promisified','spawn-false']) {
  const chromeArgs=['--no-first-run','--no-default-browser-check','--enable-automation','--disable-background-networking','--remote-debugging-port=0',`--user-data-dir=${profile(mode+'-cdp')}`];
  if(mode==='spawn-false') chromeArgs.unshift('--headless=false');
  const promise=mode==='promisified'?promisify(execFile)(executablePath,chromeArgs,{timeout:30000,maxBuffer:5e6}):null;
  const child=promise?.child ?? spawn(executablePath,chromeArgs);
  assert(child.pid);
  const settled=promise ? promise.then(()=>({code:0}),err=>({code:err.code,signal:err.signal})) : new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',(code,signal)=>resolve({code,signal}));});
  // Attach immediately so a launch error cannot become an unhandled rejection.
  settled.catch(()=>{});
  try {
    const endpoint=await new Promise((resolve,reject)=>{
      let stderr='';
      const timer=setTimeout(()=>reject(new Error('CDP endpoint unavailable')),15000);
      child.stderr.on('data',chunk=>{stderr+=chunk;const match=stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/); if(match){clearTimeout(timer);resolve(match[1]);}});
      child.once('error',err=>{clearTimeout(timer);reject(err);});
    });
    const browser=await chromium.connectOverCDP(endpoint);
    await prove(await browser.contexts()[0].newPage(),mode==='promisified'?'promisified execFile Chrome launch':'raw Chrome spawn overrides --headless=false');
    // The local Chrome build's raw-process shutdown hits its teardown watchdog.
    // Stop only this owned disposable PID after collecting live CDP proof.
    child.kill('SIGKILL');
    console.log(JSON.stringify({scenario:mode,cleanup:await settled}));
  } finally { if(child.exitCode===null && child.signalCode===null) child.kill('SIGTERM'); }
}
const ordinary=await promisify(execFile)('/bin/echo',['unrelated-process-unchanged']);
assert.equal(ordinary.stdout,'unrelated-process-unchanged\n');
console.log(JSON.stringify({scenario:'ordinary promisified execFile',stdout:ordinary.stdout.trim(),passed:true}));
