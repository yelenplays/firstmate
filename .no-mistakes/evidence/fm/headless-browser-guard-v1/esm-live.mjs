import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const root=process.cwd();
const {chromium}=await import(pathToFileURL(root+'/.browser-guard-validation/node_modules/playwright-core/index.mjs'));
const browser=await chromium.launch({headless:false,args:['--enable-automation'],timeout:30000});
try {
  const page=await browser.newPage(); await page.setContent('<h1>ESM and repeated activation stayed headless</h1>');
  const ua=await page.evaluate(()=>navigator.userAgent);
  assert(ua.includes('HeadlessChrome'));
  const cdp=await browser.newBrowserCDPSession();const {arguments:argv}=await cdp.send('Browser.getBrowserCommandLine');
  assert.equal(argv.filter(x=>x==='--headless').length,1);
  assert(process.env.NODE_OPTIONS.includes('--trace-warnings'));
  await page.screenshot({path:'/Users/yelen/.no-mistakes/evidence/01M55Y2Q30TR9XSAETE04MHGAM/esm-live.png'});
  console.log(JSON.stringify({esmImport:true,doubleSnippet:true,preservedNodeOption:true,ua,argv},null,2));
} finally {await browser.close();}
