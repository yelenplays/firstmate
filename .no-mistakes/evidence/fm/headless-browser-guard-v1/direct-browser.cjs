const assert = require('node:assert/strict');
const cp = require('node:child_process');
const {promisify} = require('node:util');
const fs = require('node:fs');
const path = require('node:path');
const root = process.cwd();
const browser = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const base = path.join(root, '.guard-validation');
const url = 'data:text/html,<title>Direct guard proof</title><script>document.write(navigator.userAgent)</script>';
(async () => {
 for (const method of ['spawn', 'spawnSync', 'execFile', 'promisifiedExecFile', 'execFileSync']) {
  const profile = path.join(base, 'direct-'+method);
  const args = ['--headless=false','--user-data-dir='+profile,'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--use-mock-keychain','--password-store=basic','--dump-dom',url];
  const options = {encoding:'utf8', timeout:30000, maxBuffer:4*1024*1024};
  let stdout;
  if (method === 'spawn') {
   stdout = await new Promise((resolve,reject)=>{
    const child=cp.spawn(browser,args,options); let output=''; let error='';
    child.stdout.on('data',b=>output+=b); child.stderr.on('data',b=>error+=b);
    child.on('error',reject); child.on('close',code=>code===0?resolve(output):reject(new Error('exit='+code+' '+error)));
   });
  } else if (method === 'spawnSync') {
   const result=cp.spawnSync(browser,args,options); assert.equal(result.status,0,String(result.stderr)); stdout=result.stdout;
  } else if (method === 'execFile') {
   stdout=await new Promise((resolve,reject)=>cp.execFile(browser,args,options,(err,out)=>err?reject(err):resolve(out)));
  } else if (method === 'promisifiedExecFile') {
   stdout=(await promisify(cp.execFile)(browser,args,options)).stdout;
  } else { stdout=cp.execFileSync(browser,args,{...options,stdio:['ignore','pipe','ignore']}); }
  assert.match(stdout,/HeadlessChrome\//);
  console.log(JSON.stringify({scenario:method,requested:'--headless=false',renderedDOM:stdout.trim(),result:'headless'}));
 }
 const childProfile=path.join(base,'filtered-live');
 const env={HOME:path.join(base,'home'),PATH:process.env.PATH,TMPDIR:path.join(base,'tmp')};
 const script=`const cp=require('node:child_process'); const out=cp.execFileSync(${JSON.stringify(browser)},${JSON.stringify(['--user-data-dir='+childProfile,'--no-first-run','--disable-background-networking','--disable-component-update','--use-mock-keychain','--password-store=basic','--dump-dom',url])},{encoding:'utf8',stdio:['ignore','pipe','ignore']}); console.log(JSON.stringify({guard:process.env.FM_BROWSER_GUARD,parentSecret:process.env.GUARD_PROOF_SECRET||null,renderedDOM:out.trim()}));`;
 process.env.GUARD_PROOF_SECRET='do-not-copy';
 const out=cp.execFileSync(process.execPath,['-e',script],{env,encoding:'utf8',timeout:30000});
 const result=JSON.parse(out); assert.equal(result.guard,'1'); assert.equal(result.parentSecret,null); assert.match(result.renderedDOM,/HeadlessChrome\//); assert.equal(env.NODE_OPTIONS,undefined);
 console.log(JSON.stringify({scenario:'filtered-subprocess',...result,callerEnvUnmodified:true}));
})().catch(err=>{console.error(err);process.exitCode=1});
