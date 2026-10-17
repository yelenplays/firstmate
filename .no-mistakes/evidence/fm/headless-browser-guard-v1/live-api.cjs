const assert = require('node:assert/strict');
const {chromium} = require('playwright-core');
const {execFileSync} = require('node:child_process');
const path = require('node:path');
const base=path.join(process.cwd(),'.guard-validation');
const executablePath='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
(async()=>{
 console.log(JSON.stringify({node:process.version,playwright:require('playwright-core/package.json').version,puppeteer:require('puppeteer-core/package.json').version}));
 for (const method of ['launch','launchPersistentContext','launchServer']) {
  const profile=path.join(base,'pw-'+method);
  const opts={headless:false,executablePath,args:['--use-mock-keychain','--password-store=basic'],timeout:30000};
  let browser,context,server;
  try {
   if (method==='launchPersistentContext') context=await chromium.launchPersistentContext(profile,opts);
   else if (method==='launchServer') {server=await chromium.launchServer(opts);browser=await chromium.connect(server.wsEndpoint());context=await browser.newContext();}
   else {browser=await chromium.launch(opts);context=await browser.newContext();}
   const page=await context.newPage();
   await page.setContent('<h1>Real launcher headless proof</h1>');
   const ua=await page.evaluate(()=>navigator.userAgent);
   assert.match(ua,/HeadlessChrome\//);assert.equal(await page.locator('h1').textContent(),'Real launcher headless proof');
   if(method==='launch') {
    await page.evaluate(ua=>{const pre=document.createElement('pre');pre.style.whiteSpace='pre-wrap';pre.textContent='Requested: chromium.launch({ headless: false })\nObserved: '+ua;document.body.append(pre)},ua);
    await page.screenshot({path:'/Users/yelen/.no-mistakes/evidence/01M55C8XTJG96SJKKMS60QGCG5/guarded-browser.png'});
   }
   assert.equal(opts.headless,false);
   console.log(JSON.stringify({scenario:'CommonJS Playwright '+method,requestedHeadless:false,userAgent:ua,heading:await page.locator('h1').textContent(),callerOptionsUnchanged:opts.headless===false}));
  } finally {if(context)await context.close();if(browser)await browser.close();if(server)await server.close();}
 }
})().catch(e=>{console.error(e);process.exitCode=1});
