import os, subprocess, json
from pathlib import Path
root=Path.cwd()
evidence=Path('/Users/yelen/.no-mistakes/evidence/01M55Y2Q30TR9XSAETE04MHGAM')
snippet=subprocess.check_output(['bin/fm-browser-guard-env.sh','--command'],text=True)
results=[]
def run(name,cmd,stdin=None,refuse=True):
    p=subprocess.run(['/bin/sh','-c',snippet+' exec "$@"','validation',*cmd],input=stdin,text=True,capture_output=True,timeout=15)
    if refuse:
        assert p.returncode==1,(name,p.returncode,p.stderr)
        assert p.stdout=='',(name,p.stdout)
        assert len(p.stderr.splitlines())==1 and 'fm-browser-guard: refused' in p.stderr,(name,p.stderr)
    results.append(dict(name=name,command=cmd,exit=p.returncode,stdout=p.stdout,stderr=p.stderr))
run('open HTTPS URL refuses',['open','https://example.invalid/browser-guard'])
run('clustered app launch refuses',['open','-gna','Google Chrome','--args','--remote-debugging-port=0'])
run('browser bundle launch refuses',['open','-b','org.mozilla.firefox'])
run('HTML default handler refuses',['open','browser-guard-report.html'])
run('non-browser app cannot bypass URL refusal',['open','-a','TextEdit','https://example.invalid/browser-guard'])
run('AppleScript explicit browser refuses',['osascript','-e','tell application "Google Chrome" to activate'])
run('AppleScript bundle id refuses',['osascript','-e','tell application id "com.google.Chrome" to activate'])
run('JXA browser refuses',['osascript','-l','JavaScript','-e',"Application('Google Chrome').activate()"])
run('AppleScript stdin with language option refuses',['osascript','-l','AppleScript'],stdin='tell application "Safari" to activate\n')
run('safe AppleScript still executes',['osascript','-e','return 6 * 7'],refuse=False)
assert results[-1]['exit']==0 and results[-1]['stdout'].strip()=='42' and not results[-1]['stderr'],results[-1]
run('Python webbrowser refuses without fallback',['python3','-c','import webbrowser; print("open_return=" + str(webbrowser.open("https://example.invalid/browser-guard")))'],refuse=False)
assert results[-1]['exit']==0 and 'open_return=True' in results[-1]['stdout'] and 'fm-browser-guard: refused' in results[-1]['stderr'],results[-1]
# Help has no GUI side effects and compares the actual macOS binary's passthrough contract.
run('ordinary open flags still reach system consumer',['open','-h'],refuse=False)
control=subprocess.run(['/usr/bin/open','-h'],text=True,capture_output=True)
assert (results[-1]['exit'],results[-1]['stdout'],results[-1]['stderr'])==(control.returncode,control.stdout,control.stderr)
evidence.joinpath('shell-results.json').write_text(json.dumps(results,indent=2))
for r in results: print(json.dumps(r))
