#!/usr/bin/env python3
import os,pathlib,subprocess,tempfile,shutil,json
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M52YWSZ3NT93VE6AGZ7RJJBZ')
w=pathlib.Path(tempfile.mkdtemp(prefix='digest-',dir=R/'.validation-tmp')); home=w/'home'
e=os.environ.copy()
for k in list(e):
    if k.startswith('FM_'): del e[k]
e.update(FM_HOME=str(home),TMPDIR=str(R/'.validation-tmp'),FM_SESSION_START_TIMEOUT='60')
try:
    subprocess.run([str(R/'bin/fm-lab-home.sh'),'create',str(home)],check=True,capture_output=True)
    for title,level,body in [('Public shipping focus','normal','PUBLIC_NOW_PROBE Reduce capture token usage this week.'),('Personal test focus','private','PRIVATE_NOW_PROBE Do not expose this to Pi.'),('Expired focus','normal','EXPIRED_NOW_PROBE Old focus.')]:
        subprocess.run([str(R/'bin/fm-memory.sh'),'remember','--category','now','--expires','2000-01-01' if title=='Expired focus' else '2999-01-01','--sensitivity',level,title,body],env=e,check=True,text=True,capture_output=True)
    harness=subprocess.run([str(R/'bin/fm-harness.sh')],env=e,text=True,capture_output=True).stdout.strip()
    p=subprocess.run([str(R/'bin/fm-session-start.sh'),'--reemit','--source','compact'],env=e,text=True,capture_output=True,timeout=90)
    (E/'pi-compact-digest.txt').write_text(p.stdout+'\nSTDERR:\n'+p.stderr)
    result={'harness':harness,'exit':p.returncode,'has_NOW_block':'NOW (current captain context' in p.stdout,'has_public':'PUBLIC_NOW_PROBE' in p.stdout,'has_private':'PRIVATE_NOW_PROBE' in p.stdout,'has_expired':'EXPIRED_NOW_PROBE' in p.stdout,'truncated':'●  STARTUP TRUNCATED' in p.stdout}
    (E/'digest-result.json').write_text(json.dumps(result,indent=2)+'\n'); print(json.dumps(result))
    assert harness!='claude' and result['has_NOW_block'] and result['has_public'] and not result['has_private'] and not result['has_expired'] and not result['truncated']
finally: shutil.rmtree(w)
