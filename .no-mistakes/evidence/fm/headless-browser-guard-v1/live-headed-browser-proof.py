import json, os, pathlib, subprocess, urllib.request, base64
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M55STZBF17XWCASAY5ZRABQW')
env=os.environ.copy()
for k in ['FM_ALLOW_HEADED_BROWSER','CHROME_DEVTOOLS_AXI_BROWSER_URL','CHROME_DEVTOOLS_AXI_AUTO_CONNECT']:
    env.pop(k,None)
env.update(HOME=str(ROOT/'.guard-validation/browser-home'), XDG_CACHE_HOME=str(ROOT/'.guard-validation/browser-cache'), CHROME_DEVTOOLS_AXI_SESSION='fm-guard-live-01M55',CHROME_DEVTOOLS_AXI_HEADED='1', CHROME_DEVTOOLS_AXI_BRIDGE_TIMEOUT_MS='90000')
snippet=subprocess.check_output(['bin/fm-browser-guard-env.sh','--command'],text=True)
records=[]
def run(args):
    p=subprocess.run(['/bin/sh','-c',snippet+' exec "$@"','guard-proof','chrome-devtools-axi',*args],env=env,text=True,capture_output=True,timeout=110)
    r=dict(command=['chrome-devtools-axi',*args],exit=p.returncode,stdout=p.stdout,stderr=p.stderr)
    records.append(r)
    print(json.dumps(r),flush=True)
    if p.returncode: raise RuntimeError('browser tool failed')
    return p.stdout
try:
    run(['newpage','chrome://version'])
    result=run(['eval','JSON.stringify({userAgent:navigator.userAgent,versionPage:document.body.innerText})'])
    assert 'HeadlessChrome' in result, 'headed request was not forced headless'
    assert '--headless' in result, 'actual browser process command line has no headless flag'
    run(['resize','1440','1000'])
    run(['screenshot',str(E/'forced-headless-chrome-version.png')])
    if not (E/'forced-headless-chrome-version.png').exists():
        request=urllib.request.Request('http://127.0.0.1:10097/call',data=json.dumps({'name':'take_screenshot','args':{}}).encode(),headers={'Content-Type':'application/json'})
        raw=json.load(urllib.request.urlopen(request))
        (E/'screenshot-tool-response.json').write_text(json.dumps(raw,indent=2)+'\n')
        print('Raw screenshot response: '+json.dumps(raw)[:2000],flush=True)
        payload=raw.get('result',{})
        if isinstance(payload,str):
            try: payload=json.loads(payload)
            except json.JSONDecodeError: payload={}
        for block in payload.get('content',[]):
            if block.get('type')=='image':
                (E/'forced-headless-chrome-version.png').write_bytes(base64.b64decode(block['data']))
    print('Screenshot exists: '+str((E/'forced-headless-chrome-version.png').exists()),flush=True)
    print('Verified real browser reports HeadlessChrome and chrome://version reports --headless despite CHROME_DEVTOOLS_AXI_HEADED=1.',flush=True)
finally:
    try: run(['stop'])
    finally: (E/'live-headed-browser-proof.json').write_text(json.dumps(records,indent=2)+'\n')
