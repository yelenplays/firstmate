#!/usr/bin/env python3
"""Manual product replay: real Claude, real journal, real store; synthetic input only."""
import datetime, json, os, pathlib, shutil, subprocess, time
ROOT=pathlib.Path('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M59XY24CQN6E6XS9CMW0DM5S')
E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M59XY24CQN6E6XS9CMW0DM5S')
HOME=ROOT/'.test-memory-live'
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('CLAUDECODE','CLAUDE_CODE_ENTRYPOINT','TYPESAFE_API_KEY','JEV_URL','JEV_ROUTE')}
env.update(FM_HOME=str(HOME),FM_MEMORY_DIR=str(HOME/'data/memories'),FM_DATA_OVERRIDE=str(HOME/'data'),FM_STATE_OVERRIDE=str(HOME/'state'),FM_CONFIG_OVERRIDE=str(HOME/'config'))
log=[]
def run(args, **kw):
    p=subprocess.run(args,cwd=ROOT,env=env,text=True,capture_output=True,timeout=340,**kw)
    log.append({'command':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    return p

def turn(id,text):
    stamp=datetime.datetime.now(datetime.timezone.utc).isoformat()
    with (HOME/'transcript.jsonl').open('a') as f:
        f.write(json.dumps({'type':'user','origin':{'kind':'human'},'uuid':id,'timestamp':stamp,'message':{'content':text}})+'\n')
        f.write(json.dumps({'type':'assistant','uuid':id+'-r','timestamp':stamp,'message':{'content':'Understood.','stop_reason':'end_turn'}})+'\n')
    assert run(['bin/fm-history.sh','capture','--transcript',str(HOME/'transcript.jsonl')]).returncode==0

p=None
try:
    assert not HOME.exists()
    for name in ('data','state','config'): (HOME/name).mkdir(parents=True,exist_ok=True)
    # This message tests facts after both the removed 2400-char clip and a 12000-char boundary.
    turn('lab-long', 'Temporary validation narration; this sentence has no lasting significance. '*185 + ' From now on my release-note signature is LAB-CORAL-7129. Always preserve that exact signature.')
    turn('lab-private','Remember that I moved to Pebble Bay this week and am still unpacking. Keep that current context in mind when planning the deploy backlog. This is synthetic validation data.')
    turn('lab-short','I use Emacs.')
    turn('lab-ack','merge it')
    run(['bin/fm-history.sh','turns'])
    # Dry-run must plan the lossless units but take no lock or mark a boundary.
    dry=run(['bin/fm-memory-capture.sh','run','--dry-run'])
    assert dry.returncode==0
    assert not (HOME/'state/memory-capture/lock').exists()
    assert not (HOME/'state/memory-capture/pending').exists()
    assert not (HOME/'state/memory-capture/watermark.json').exists()
    # An explicitly forbidden non-Claude model must be refused without retiring the journal.
    old=env.get('FM_MEMORY_CAPTURE_MODEL')
    env['FM_MEMORY_CAPTURE_MODEL']='deepseek-v4'
    refused=run(['bin/fm-memory-capture.sh','run'])
    assert refused.returncode!=0
    assert not (HOME/'state/memory-capture/watermark.json').exists()
    env.pop('FM_MEMORY_CAPTURE_MODEL')
    # Use genuine model latency, not a fake Claude process, for the overlapping boundary.
    bgout=(E/'real-precompact.stdout').open('w')
    bgerr=(E/'real-precompact.stderr').open('w')
    p=subprocess.Popen(['bin/fm-memory-capture.sh','run','--trigger','precompact'],cwd=ROOT,env=env,text=True,stdout=bgout,stderr=bgerr)
    observed=False
    until=time.monotonic()+30
    while time.monotonic()<until and p.poll() is None:
        table=subprocess.run(['ps','-axo','pid,ppid,args'],text=True,capture_output=True).stdout
        # Exact model CLI child: the real extractor has consumed the initial journal slice.
        rows=table.splitlines(); parents={}; modelpid=None
        for row in rows:
            cells=row.strip().split(None,2)
            if len(cells)!=3: continue
            try: pid,ppid=int(cells[0]),int(cells[1])
            except ValueError: continue
            parents[pid]=ppid
            if 'claude' in cells[2] and '--model claude-haiku-5-5' in cells[2]:
                q=pid
                for _ in range(12):
                    if q==p.pid: modelpid=pid; break
                    q=parents.get(q,0)
        if modelpid:
            log.append({'observation':'real Claude Haiku extractor active','pid':modelpid})
            observed=True; break
        time.sleep(.05)
    if observed:
        turn('lab-overlap','Remember that my lab-only deployment approval code is LAB-LANTERN-3382; always require this code before a deployment.')
        overlap=run(['bin/fm-memory-capture.sh','run','--trigger','sessionend'])
        log.append({'pending_after_overlap':(HOME/'state/memory-capture/pending').exists(),'first_capture_still_running':p.poll() is None})
    rc=p.wait(timeout=340)
    bgout.close(); bgerr.close()
    log.append({'first_capture_exit':rc,'overlap_drove_real_model':observed})
    run(['bin/fm-memory-capture.sh','status'])
    if (HOME/'state/memory-capture/runs.jsonl').exists():
        shutil.copy2(HOME/'state/memory-capture/runs.jsonl',E/'real-capture-runs.jsonl')
    if rc==0:
        for query in ('LAB-CORAL-7129','Pebble Bay','Emacs','LAB-LANTERN-3382'):
            run(['bin/fm-memory.sh','recall','--json',query])
        run(['bin/fm-memory.sh','now'])
        run(['bin/fm-memory.sh','now','--exclude-private'])
        run(['bin/fm-memory-capture.sh','run','--trigger','sessionend'])
        for f in sorted((HOME/'data/memories').rglob('*.md')):
            log.append({'persisted_memory':str(f.relative_to(HOME/'data/memories')),'content':f.read_text()})
    # Real scope guards, no root override or bypass: gate context must emit no private NOW.
    run(['bin/fm-memory-capture.sh','now'])
    for flag in ('FM_TASK_ID','FM_SUPERVISION_ACTOR','FM_MEMORY_CAPTURE_CHILD'):
        env[flag]='lab-adversary'
        out=run(['bin/fm-memory-capture.sh','now'])
        assert out.returncode==0 and out.stdout==''
        out=run(['bin/fm-memory-capture.sh','hook','precompact'],input='{}')
        assert out.returncode==0
        env.pop(flag)
    log.append({'scope_checks':'gate/worker/supervision/extractor emit no NOW; hooks return silently','pending_after_completion':(HOME/'state/memory-capture/pending').exists(),'lock_after_completion':(HOME/'state/memory-capture/lock').exists()})
finally:
    if p and p.poll() is None:
        p.terminate(); p.wait(timeout=10)
    (E/'real-memory-replay.json').write_text(json.dumps(log,indent=2)+'\n')
    if HOME.exists(): shutil.rmtree(HOME)
print(json.dumps(log,indent=2))
