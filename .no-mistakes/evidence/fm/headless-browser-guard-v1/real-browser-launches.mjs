import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
import {execFileSync, execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {resolve} from 'node:path';
import assert from 'node:assert/strict';
const root=process.cwd();
const require=createRequire(resolve(root,'.test-runtime/automation/package.json'));
const evidence=process.env.EVIDENCE;
const chrome='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const pw=await import(pathToFileURL(require.resolve('playwright-core').replace(/index\.js$/, 'index.mjs')));
const pupp=(await import(pathToFileURL(require.resolve('puppeteer-core')))).default;
for (const [label, launcher, isPW] of [['Playwright ESM',pw.chromium,true],['Playwright CommonJS',require('playwright-core').chromium,true],['Puppeteer ESM',pupp,false]]) {
 let browser;
 try {
  browser=await launcher.launch({headless:false,executablePath:chrome,args:['--enable-automation','--no-first-run','--use-mock-keychain','--password-store=basic']});
  const page=await browser.newPage();
  await page.setContent('<title>Guard live verification</title><h1>'+label+' requested headed; guard enforced headless</h1>');
  const session=isPW?await browser.newBrowserCDPSession():await browser.target().createCDPSession();
  const argv=(await session.send('Browser.getBrowserCommandLine')).arguments;
  const version=await session.send('Browser.getVersion');
  const procs=await session.send('SystemInfo.getProcessInfo');
  const pid=procs.processInfo.find(p=>p.type==='browser').id;
  const windows=JSON.parse(execFileSync(resolve(root,'.test-runtime/window-probe'),[String(pid)],{encoding:'utf8'}));
  const result={label,requestedHeadless:false,product:version.product,ua:version.userAgent,pid,headlessFlags:argv.filter(a=>/^--?headless/.test(a)),onscreenWindows:windows.onscreenWindows};
  console.log(JSON.stringify(result));
  await page.screenshot({path:resolve(evidence,label.replaceAll(' ','-')+'.png')});
  assert(result.headlessFlags.length>0,label+' must have a real headless flag');
  assert.match(version.userAgent,/HeadlessChrome/);
  assert.equal(windows.onscreenWindows.length,0,label+' must not own a visible Mac window');
 } finally { if(browser) await browser.close(); }
}
const args=['--user-data-dir='+resolve(root,'.test-runtime/promisify-profile'),'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-extensions','--use-mock-keychain','--password-store=basic','--dump-dom','data:text/html,<title>Raw Chrome headless proof</title><h1 id="ua"></h1><script>document.getElementById("ua").textContent=navigator.userAgent</script>'];
const task=promisify(execFile)(chrome,args,{timeout:45000,maxBuffer:1024*1024});
console.log(JSON.stringify({label:'promisified execFile',pid:task.child.pid,spawnargs:task.child.spawnargs}));
const {stdout}=await task;
console.log('promisified DOM: '+stdout.trim());
assert.match(stdout,/HeadlessChrome/);
assert(task.child.spawnargs.includes('--headless'));
process.env.FM_ALLOW_HEADED_BROWSER='1';
const versionTask=promisify(execFile)(chrome,['--version']);
const version=await versionTask;
console.log(JSON.stringify({label:'captain opt-out with non-window --version',spawnargs:versionTask.child.spawnargs,stdout:version.stdout.trim()}));
assert(!versionTask.child.spawnargs.includes('--headless'));
console.log('REAL_BROWSER_SCENARIOS_PASSED');
