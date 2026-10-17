const cp=require('node:child_process');
const fs=require('node:fs');
const path=require('node:path');
const assert=require('node:assert/strict');
const root=process.cwd();
(async()=>{
 const cli=path.join(root,'.guard-validation/deps/node_modules/.bin/playwright');
 const cliArgs=['test','--list','--pass-with-no-tests','--config='+path.join(root,'.guard-validation/empty-tests')];
 fs.mkdirSync(path.join(root,'.guard-validation/empty-tests'),{recursive:true});
 const r=cp.spawnSync(cli,cliArgs,{encoding:'utf8'});
 assert.equal(r.status,0,r.stderr);
 assert.match(r.stdout,/Total: 0 tests/);
 assert.equal(r.stderr,'');
 console.log(JSON.stringify({scenario:'real Playwright CLI subprocess is not misclassified',command:[cli,...cliArgs],exit:r.status,stdout:r.stdout,stderr:r.stderr}));
 const profile=fs.mkdtempSync(path.join(root,'.guard-validation/tmp/promisify-profile-'));
 try {
   const args=['--dump-dom','--no-first-run','--password-store=basic','--use-mock-keychain','--user-data-dir='+profile,'data:text/html,<h1>promisified-browser-headless-ok</h1>'];
   const result=await require('node:util').promisify(cp.execFile)('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',args,{timeout:30000,maxBuffer:1024*1024});
   assert.match(result.stdout,/<h1>promisified-browser-headless-ok<\/h1>/);
   console.log(JSON.stringify({scenario:'promisified execFile runs real Chrome headlessly',requestedArgs:args,stdout:result.stdout,stderr:result.stderr}));
 } finally { fs.rmSync(profile,{recursive:true,force:true}); }
})().catch(e=>{console.error(e);process.exitCode=1;});
