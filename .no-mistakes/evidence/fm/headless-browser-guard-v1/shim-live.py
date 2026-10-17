import subprocess, json, sys
checks = [
 ('open-url', ['open','https://example.invalid/fm-browser-guard-proof'], 1),
 ('open-browser-app', ['open','-na','Google Chrome','--args','--remote-debugging-port=0'], 1),
 ('open-browser-bundle', ['open','-b','com.google.Chrome'], 1),
 ('open-html', ['open','.guard-validation/proof.html'], 1),
 ('applescript-browser', ['osascript','-e','tell application "Safari" to activate'], 1),
 ('jxa-stdin', ['osascript','-l','JavaScript'], 1),
 ('python-webbrowser', ['python3','-I','-c','import webbrowser; print("returned="+str(webbrowser.open("https://example.invalid/fm-browser-guard-proof")))'], 0),
 ('ordinary-applescript', ['osascript','-e','return 6 * 7'], 0),
 ('ordinary-node', ['node','-e','const {execFile}=require("child_process");require("util").promisify(execFile)("/bin/echo",["ordinary-node-ok"]).then(({stdout})=>process.stdout.write(stdout))'], 0),
]
for name,argv,code in checks:
 p = subprocess.run(argv,input="Application('Google Chrome').activate()" if name=='jxa-stdin' else '',capture_output=True,text=True,timeout=20)
 print(json.dumps(dict(scenario=name,command=argv,exit=p.returncode,stdout=p.stdout,stderr=p.stderr)),flush=True)
 assert p.returncode == code, name
 if code==1 or name=='python-webbrowser': assert 'fm-browser-guard: refused' in p.stderr, name
 if name=='ordinary-applescript': assert p.stdout.strip()=='42',name
 if name=='ordinary-node': assert p.stdout.strip()=='ordinary-node-ok' and p.stderr=='',name
