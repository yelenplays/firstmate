const cp=require('node:child_process');
const fs=require('node:fs');
const path=require('node:path');
const assert=require('node:assert/strict');
const ROOT=process.cwd();
const E='/Users/yelen/.no-mistakes/evidence/01M55Y2Q30TR9XSAETE04MHGAM';
const pw=require(path.join(ROOT,'.browser-guard-validation/node_modules/playwright-core'));
const dir=path.join(ROOT,'.browser-guard-validation/argumentless');fs.mkdirSync(dir,{recursive:true});
const profile=path.join(dir,'profile');fs.mkdirSync(profile,{recursive:true});
const launcher=path.join(dir,'chrome');
const quote=s=>"'"+s.replaceAll("'","'\\''")+"'";
fs.writeFileSync(launcher,'#!/bin/sh\nexec '+quote(pw.chromium.executablePath())+' --no-first-run --no-default-browser-check --remote-debugging-port=0 --user-data-dir='+quote(profile)+' "$@" about:blank\n',{mode:0o755});
(async()=>{
 const child=cp.spawn(launcher); // Deliberately no args or options.
 let stderr='';child.stderr.on('data',x=>stderr+=x);
 let browser;
 try {
   const active=path.join(profile,'DevToolsActivePort');
   for(let i=0;i<100&&!fs.existsSync(active);i++)await new Promise(r=>setTimeout(r,100));
   assert(fs.existsSync(active),stderr);
   const port=fs.readFileSync(active,'utf8').split('\n')[0];
   const version=await(await fetch('http://127.0.0.1:'+port+'/json/version')).json();
   assert(version['User-Agent'].includes('HeadlessChrome'),JSON.stringify(version));
   const command=cp.execFileSync('/bin/ps',['-p',String(child.pid),'-o','command='],{encoding:'utf8'}).trim();
   assert(command.includes('--headless'),command);
   browser=await pw.chromium.connectOverCDP('http://127.0.0.1:'+port);
   const page=await browser.contexts()[0].newPage();await page.setContent('<h1>Argument-less launch stayed headless</h1>');
   await page.screenshot({path:path.join(E,'argumentless-live.png')});
   console.log(JSON.stringify({call:'child_process.spawn(knownChromeLauncher) with no argument list',command,version,dom:await page.locator('h1').textContent()},null,2));
 }finally{if(browser)await browser.close();child.kill('SIGTERM');}
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
