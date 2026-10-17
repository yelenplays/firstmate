import json, os, pathlib, subprocess
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M55STZBF17XWCASAY5ZRABQW')
prior=root/'.guard-validation/prior-preload.cjs'
prior.write_bytes(subprocess.check_output(['git','show','0ff9cebf4549ba70a4e64c50078c8f91f6533479^:bin/fm-browser-guard-preload.cjs']))
env=os.environ.copy()
for key in ['NODE_OPTIONS','BUN_OPTIONS','FM_ALLOW_HEADED_BROWSER']: env.pop(key,None)
env['HOME']=str(root/'.guard-validation/browser-home')
script='const cp=require("node:child_process");const r=cp.spawnSync(process.argv[1],["test","--list","--pass-with-no-tests","--config="+process.argv[2]],{encoding:"utf8"});console.log(JSON.stringify({exit:r.status,stdout:r.stdout,stderr:r.stderr}));'
records=[]
for label,preload in [('before-fix',prior),('current',root/'bin/fm-browser-guard-preload.cjs')]:
    p=subprocess.run(['node','--require',str(preload),'-e',script,str(root/'.guard-validation/deps/node_modules/.bin/playwright'),str(root/'.guard-validation/empty-tests')],env=env,text=True,capture_output=True,timeout=30)
    result=json.loads(p.stdout)
    records.append(dict(version=label,parentExit=p.returncode,parentStderr=p.stderr,cli=result))
assert records[0]['cli']['exit'] != 0 and '--headless' in records[0]['cli']['stderr'],records
assert records[1]['cli']['exit'] == 0 and records[1]['parentStderr'] == '' and records[1]['cli']['stderr'] == '',records
(evidence/'cli-regression-proof.json').write_text(json.dumps(records,indent=2)+'\n')
print(json.dumps(records,indent=2))
prior.unlink()
