const assert=require('node:assert/strict');
const path=require('node:path');
const {execFileSync}=require('node:child_process');
const {createRequire}=require('node:module');
const req=createRequire(path.join(process.cwd(),'.live-browser/package.json'));
const pw=req('playwright-core');
(async()=>{
 for(const family of ['firefox','webkit']) {
  let server,browser;
  try {
   server=await pw[family].launchServer({headless:false});
   const pid=server.process().pid;
   const command=execFileSync('/bin/ps',['-p',String(pid),'-o','command='],{encoding:'utf8'}).trim();
   assert.match(command,/(?:^|\s)--?headless(?:\s|$)/);
   browser=await pw[family].connect(server.wsEndpoint());
   const page=await browser.newPage();
   await page.setContent('<h1>Real '+family+' headless guard proof</h1>');
   const heading=await page.locator('h1').innerText();
   assert.equal(heading,'Real '+family+' headless guard proof');
   console.log(JSON.stringify({family,version:browser.version(),pid,command,heading,passed:true}));
  } finally {await browser?.close();await server?.close();}
 }
})().catch(err=>{console.error(err);process.exitCode=1;});
