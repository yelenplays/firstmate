#!/usr/bin/env python3
import os,pathlib,subprocess,tempfile,json,shutil,datetime
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M52YWSZ3NT93VE6AGZ7RJJBZ')
w=pathlib.Path(tempfile.mkdtemp(prefix='boundaries-',dir=R/'.validation-tmp'))
e=os.environ.copy()
for k in list(e):
    if k.startswith('FM_'): del e[k]
e.update(FM_HOME=str(w/'home'),TMPDIR=str(R/'.validation-tmp'),TZ='UTC')
log=[]
def run(script,*args,input=None,extra=None):
    p=subprocess.run([str(R/'bin'/script),*args],env=e|(extra or {}),input=input,text=True,capture_output=True,timeout=75)
    log.append({'command':script+' '+' '.join(args),'extra_environment':extra or {},'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    return p
try:
    subprocess.run([str(R/'bin/fm-lab-home.sh'),'create',str(w/'home')],check=True,capture_output=True)
    # Real failures, no stand-in: unsupported model refusal must queue work and alert once.
    for i in range(3): assert run('fm-memory-capture.sh','run',extra={'FM_MEMORY_CAPTURE_MODEL':'deepseek-v4'}).returncode!=0
    status=w/'home/state/memory-capture.status'
    before=status.read_text(); assert before.count('failed [')==1
    assert not (w/'home/state/memory-capture/watermark.json').exists()
    assert run('fm-memory-capture.sh','run').returncode==0
    after=status.read_text(); assert after.count('resolved [')==1
    (E/'failure-recovery-status.txt').write_text(after)
    # Actual Jev CLI, no injected stand-in; only nonpersonal task content is submitted.
    run('fm-jev.sh','pick','The deploy script fixes lint. CI is green.','Memory kind?','none=nothing durable','event=dated decision')
    # Durable short fact: authored transcript, real journal and extractor.
    day=datetime.date.today().isoformat(); t=w/'short-fact.jsonl'
    t.write_text(json.dumps({'type':'user','origin':{'kind':'human'},'uuid':'short-durable-fact','timestamp':day+'T11:00:00Z','message':{'content':"I'm vegan."}})+'\n'+json.dumps({'type':'assistant','uuid':'short-reply','timestamp':day+'T11:00:03Z','message':{'content':'Understood. I will avoid suggesting animal products.','stop_reason':'end_turn'}})+'\n')
    assert run('fm-history.sh','capture','--transcript',str(t)).returncode==0
    run('fm-history.sh','turns')
    p=run('fm-memory-capture.sh','run')
    result=json.loads(p.stdout)
    mark=json.loads((w/'home/state/memory-capture/watermark.json').read_text())
    summary={'captain_fact':"I'm vegan.",'capture':result,'watermark':mark,'fact_was_retained':result['units']>0,'store_exists':(w/'home/data/memories').exists()}
    (E/'short-fact-result.json').write_text(json.dumps(summary,indent=2)+'\n')
    (E/'boundary-transcript.json').write_text(json.dumps(log,indent=2)+'\n')
    print(json.dumps(log,indent=2)); print(json.dumps(summary,indent=2))
finally: shutil.rmtree(w)
