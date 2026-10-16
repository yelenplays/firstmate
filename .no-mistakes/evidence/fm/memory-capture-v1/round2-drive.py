#!/usr/bin/env python3
"""Direct public-CLI checks; replay is explicitly supplemental, not a live session."""
import os, pathlib, subprocess, tempfile, shutil, json, datetime
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M52YWSZ3NT93VE6AGZ7RJJBZ')
w=pathlib.Path(tempfile.mkdtemp(prefix='round2-',dir=R/'.test-tmp'))
e={k:v for k,v in os.environ.items() if not k.startswith('FM_')}
e.update(FM_HOME=str(w/'home'),TMPDIR=str(R/'.test-tmp'),TZ='UTC')
log=[]; results={}
def run(script,*args,input=None,extra=None,timeout=90):
    p=subprocess.run([str(R/'bin'/script),*args],env=e|(extra or {}),input=input,text=True,capture_output=True,timeout=timeout)
    log.append(dict(command=' '.join([script,*args]),extra_environment=extra or {},exit=p.returncode,stdout=p.stdout,stderr=p.stderr))
    return p
def mem(*args,**kw):
    p=run('fm-memory.sh',*args,**kw); assert p.returncode==0,p.stderr; return p.stdout
try:
    assert run('fm-lab-home.sh','create',str(w/'home')).returncode==0
    mem('remember','--category','now','--sensitivity','private','--expires','2999-01-01','Private focus','PRIVATE_R2 Current personal situation.')
    mem('remember','--category','now','--expires','2999-01-01','Public focus','PUBLIC_R2 Reduce memory overhead this week.')
    mem('remember','--category','now','--expires','2000-01-01','Expired focus','EXPIRED_R2 No longer current.')
    full=mem('now'); public=mem('now','--exclude-private')
    assert 'PRIVATE_R2' in full and 'PUBLIC_R2' in full and 'EXPIRED_R2' not in full
    assert 'PRIVATE_R2' not in public and 'PUBLIC_R2' in public
    results['now_privacy_expiry']='pass'
    harness=run('fm-harness.sh').stdout.strip()
    digest=run('fm-session-start.sh','--reemit','--source','compact')
    (E/'round2-compact-digest.txt').write_text(digest.stdout+'\nSTDERR:\n'+digest.stderr)
    assert digest.returncode==0 and 'NOW (current captain context' in digest.stdout and 'PUBLIC_R2' in digest.stdout
    assert harness!='claude' and 'PRIVATE_R2' not in digest.stdout and 'EXPIRED_R2' not in digest.stdout
    results['non_claude_digest']={'result':'pass','detected_harness':harness}
    budget_env={'FM_MEMORY_DIR':str(w/'budget')}
    for i in range(11): mem('remember','--category','now',f'Entry {i}','x'*585,extra=budget_env)
    out=mem('now',extra=budget_env); (E/'round2-now-budget.txt').write_text(out)
    assert len(out)<=6000 and 'more now/ entries omitted by the size cap' in out
    sizes={'default':len(out)}
    for cap in [0,1,20,45,60,620,1000]:
        out=mem('now','--max-chars',str(cap),extra=budget_env)
        assert len(out)<=cap,(cap,len(out)); sizes[str(cap)]=len(out)
    results['now_budget']={'result':'pass','output_characters':sizes}
    donor={'FM_MEMORY_DIR':str(w/'donor')}
    mem('remember','--category','entity','Orphan fact','R2_ORPHAN Only in the donor store.',extra=donor)
    mem('remember','--category','now','Public focus','Different donor focus.',extra=donor)
    before=(w/'home/data/memories/now/public-focus.md').read_bytes()
    merged=run('fm-memory.sh','merge-from',str(w/'donor'))
    assert merged.returncode==1 and 'copied: entities/orphan-fact.md' in merged.stdout and 'conflict (kept this store): now/public-focus.md' in merged.stdout
    assert before==(w/'home/data/memories/now/public-focus.md').read_bytes()
    assert 'entities/orphan-fact.md' in mem('recall','--json','R2_ORPHAN')
    (w/'donor/now/public-focus.md').unlink()
    assert 'copied=0 identical=1 conflict=0' in mem('merge-from',str(w/'donor'))
    results['merge_non_overwrite']='pass'
    # Real rejected calls and actual empty-input recovery, no injected model.
    for i in range(3):
        assert run('fm-memory-capture.sh','run',extra={'FM_MEMORY_CAPTURE_MODEL':'deepseek-v4'}).returncode!=0
    status=w/'home/state/memory-capture.status'
    assert status.read_text().count('failed [')==1
    assert not (w/'home/state/memory-capture/watermark.json').exists()
    recovery=run('fm-memory-capture.sh','run')
    assert recovery.returncode==0 and json.loads(recovery.stdout)['model_calls']==0
    assert status.read_text().count('resolved [')==1
    (E/'round2-failure-recovery.txt').write_text(status.read_text())
    results['model_refusal_failure_recovery']='pass'
    # Actual linked gate worktree must never detach a capture.
    for flag in [{'FM_TASK_ID':'test-worker'},{'FM_SUPERVISION_ACTOR':'branch'},{'FM_MEMORY_CAPTURE_CHILD':'1'},{'FM_MEMORY_CAPTURE':'off'},{}]:
        scoped={'FM_HOME':str(w/'guard-home'),**flag}
        assert run('fm-memory-capture.sh','hook','precompact',input='{}',extra=scoped).returncode==0
        assert not (w/'guard-home/state/memory-capture').exists()
    results['gate_hook_refusal']='pass'
    # Authored short-fact replay through the real journal and real Haiku.
    day=datetime.date.today().isoformat(); tr=w/'authored-short-fact.jsonl'
    tr.write_text(json.dumps({'type':'user','origin':{'kind':'human'},'uuid':'r2-short-fact','timestamp':day+'T11:00:00Z','message':{'content':"I'm vegan."}})+'\n'+json.dumps({'type':'assistant','uuid':'r2-short-reply','timestamp':day+'T11:00:03Z','message':{'content':'Understood. I will avoid suggesting animal products.','stop_reason':'end_turn'}})+'\n')
    assert run('fm-history.sh','capture','--transcript',str(tr)).returncode==0
    replay=run('fm-memory-capture.sh','run',timeout=330)
    if replay.returncode==0:
        record=json.loads(replay.stdout)
        assert record['units']==1 and record['dropped']==0 and record['model_calls']==1 and record['memories']>=1
        recalled=json.loads(mem('recall','--json','vegan'))
        assert recalled['documents']
        assert not run('fm-history.sh','turns','--after',day+'/r2-short-fact').stdout.strip()
        again=run('fm-memory-capture.sh','run'); assert again.returncode==0 and json.loads(again.stdout)['model_calls']==0
        results['short_fact_replay']={'result':'pass','live':False,'record':record,'recall':recalled}
    else:
        results['short_fact_replay']={'result':'untested','live':False,'reason':replay.stderr+replay.stdout}
    run('fm-memory-capture.sh','status')
    memories={str(f.relative_to(w/'home')):f.read_text() for f in (w/'home/data/memories').rglob('*.md')}
    (E/'round2-cli-transcript.json').write_text(json.dumps({'results':results,'commands':log,'persisted_memories':memories},indent=2)+'\n')
    print(json.dumps(results,indent=2))
finally:
    shutil.rmtree(w)
