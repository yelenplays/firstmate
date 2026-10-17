import assert from 'node:assert/strict';
import {chromium} from 'playwright-core';
import puppeteer from 'puppeteer-core';
const executablePath='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
for (const [name,launcher] of [['ESM Playwright',chromium],['ESM Puppeteer',puppeteer]]) {
 let browser;
 const options={headless:false,executablePath,args:['--use-mock-keychain','--password-store=basic'],timeout:30000};
 try {
  browser=await launcher.launch(options);
  const page=await browser.newPage();
  await page.setContent('<h1>Real ESM launcher proof</h1>');
  const ua=await page.evaluate(()=>navigator.userAgent);
  assert.match(ua,/HeadlessChrome\//);
  assert.equal(await page.evaluate(()=>document.querySelector('h1').textContent),'Real ESM launcher proof');
  assert.equal(options.headless,false);
  console.log(JSON.stringify({scenario:name,requestedHeadless:false,userAgent:ua,heading:'Real ESM launcher proof',callerOptionsUnchanged:true}));
 } finally {if(browser)await browser.close();}
}
