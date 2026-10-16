#!/usr/bin/env python3
"""Real capture backend probe with authored protocol input (not live primary evidence)."""
import os,pathlib,subprocess,tempfile,json,shutil,datetime
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M52YWSZ3NT93VE6AGZ7RJJBZ')
w=pathlib.Path(tempfile.mkdtemp(prefix='real-extractor-',dir=R/'.validation-tmp'))
e=os.environ.copy()
for k in list(e):
    if k.startswith('FM_'): del e[k]
e.update(FM_HOME=str(w/'home'),TMPDIR=str(R/'.validation-tmp'),TZ='UTC')
log=[]
def run(script,*args,input=None,timeout=330):
    p=subprocess.run([str(R/'bin'/script),*args],env=e,input=input,text=True,capture_output=True,timeout=timeout)
    log.append({'command':script+' '+' '.join(args),'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    return p
try:
    subprocess.run([str(R/'bin/fm-lab-home.sh'),'create',str(w/'home')],check=True,capture_output=True)
    today=datetime.date.today().isoformat(); tr=w/'authored.jsonl'
    rows=[]
    for n,(text,reply) in enumerate([
      ('Please always use plain dashes in commit messages and keep the title under fifty characters.','I will keep commit titles short and use plain dashes.'),
      ('I ended a relationship today and moved out; please keep replies brief while I settle in.','Understood. I will keep replies brief.'),
      (': Firstmate instruction waiting: list the inbox and act on it','Captain, shipshape.')]):
      rows.extend([{'type':'user','origin':{'kind':'human'},'uuid':f'probe-{n}','timestamp':today+f'T10:0{n}:00Z','message':{'content':text}}, {'type':'assistant','uuid':f'reply-{n}','timestamp':today+f'T10:0{n}:30Z','message':{'content':reply,'stop_reason':'end_turn'}}])
    tr.write_text(''.join(json.dumps(r)+'\n' for r in rows))
    assert run('fm-history.sh','capture','--transcript',str(tr)).returncode==0
    run('fm-history.sh','turns')
    p=run('fm-memory-capture.sh','run','--trigger','manual')
    if p.returncode==0:
        run('fm-memory.sh','list'); run('fm-memory.sh','recall','--json','relationship'); run('fm-memory.sh','now')
        run('fm-memory-capture.sh','run','--trigger','manual')
    run('fm-memory-capture.sh','status')
    home=w/'home'
    persisted={str(f.relative_to(home)):f.read_text() for base in [home/'state/memory-capture',home/'data/memories'] if base.exists() for f in base.rglob('*') if f.is_file() and f.suffix in ['.md','.json','.jsonl']}
    (E/'real-extractor-probe.json').write_text(json.dumps({'note':'Authored transcript, real product and backend; not a live primary/session-hook proof.','commands':log,'persisted':persisted},indent=2)+'\n')
    print(json.dumps(log,indent=2))
finally:
    shutil.rmtree(w)
