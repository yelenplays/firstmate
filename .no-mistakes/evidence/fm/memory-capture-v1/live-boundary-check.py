import os,json,pathlib,subprocess,time,signal
root=pathlib.Path.cwd(); evidence=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M59XY24CQN6E6XS9CMW0DM5S')
home=root/'.local-test-tmp/live-home-drain'; capture=home/'state/memory-capture'
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ['CLAUDECODE','CLAUDE_CODE_ENTRYPOINT']: env.pop(k,None)
env.update(FM_HOME=str(home),FM_MEMORY_DIR=str(home/'data/memories'),TMPDIR=str(root/'.local-test-tmp'),TZ='UTC')
log=[]; p=None

def record(s): log.append(s); print(s,flush=True)
def call(script,*args,changes=None):
    e=env.copy(); e.update(changes or {})
    r=subprocess.run([str(root/'bin'/script),*args],env=e,text=True,capture_output=True,timeout=40,input='')
    record('$ '+script+' '+' '.join(args)+'\n'+r.stdout+r.stderr+f'[exit {r.returncode}]')
    return r
try:
    transcript=home/'conversation.jsonl'
    with transcript.open('a') as f:
        f.write(json.dumps({'type':'user','origin':{'kind':'human'},'uuid':'ephemeral-release-work','timestamp':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'message':{'content':'This release build just completed and the CI tests passed; no enduring personal facts or preferences changed.'}})+'\n')
    assert call('fm-history.sh','capture','--transcript',str(transcript)).returncode==0
    out=(evidence/'live-replay-holder.jsonl').open('w')
    p=subprocess.Popen([str(root/'bin/fm-memory-capture.sh'),'run','--trigger','precompact'],env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
    deadline=time.monotonic()+20
    while p.poll() is None and time.monotonic()<deadline:
        rows=subprocess.run(['ps','-axo','pid=,ppid=,command='],capture_output=True,text=True,check=True).stdout.splitlines(); table={}
        for row in rows:
            fields=row.strip().split(None,2)
            if len(fields)==3: table[int(fields[0])]=(int(fields[1]),fields[2])
        def child(pid):
            seen=set()
            while pid in table and pid not in seen:
                seen.add(pid); pid=table[pid][0]
                if pid==p.pid:return True
            return False
        if any('--no-session-persistence' in cmd and '--json-schema' in cmd and child(pid) for pid,(parent,cmd) in table.items()):break
        time.sleep(.03)
    assert p.poll() is None and (capture/'lock/pid').exists()
    before={f:(capture/f).read_bytes() for f in ['lock/pid','watermark.json','runs.jsonl','failures']}
    r=call('fm-memory-capture.sh','run','--dry-run'); assert r.returncode==0 and json.loads(r.stdout)['turns']==1
    assert all((capture/f).read_bytes()==body for f,body in before.items()), 'dry-run changed live capture records or lock'
    assert not (capture/'pending').exists()
    mark=json.loads((capture/'watermark.json').read_text())
    for args in [('--no-watermark',),('--after',mark['day']+'/'+mark['id']),('--until-day',mark['day'])]:
        r=call('fm-memory-capture.sh','run',*args)
        assert r.returncode==1 and 'retry the replay' in r.stderr
        assert not (capture/'pending').exists(), 'a replay queued a boundary'
    rc=p.wait(timeout=330);out.close();record('Real holder completed: '+str(rc)+'\n'+(evidence/'live-replay-holder.jsonl').read_text()); assert rc==0
    assert not (capture/'pending').exists() and not (capture/'lock').exists()
    r=call('fm-memory-capture.sh','run','--dry-run',changes={'FM_MEMORY_CAPTURE_MODEL':'deepseek-v4'})
    assert r.returncode==2 and 'refusing model' in r.stderr
    record('Hook guard: explicit FM_HOME is isolated, code root remains this real linked gate worktree; no guard bypass or synthetic primary root.')
    old_runs=(capture/'runs.jsonl').read_bytes()
    for boundary in ['precompact','sessionend']:
        assert call('fm-memory-capture.sh','hook',boundary).returncode==0
    time.sleep(.3); assert (capture/'runs.jsonl').read_bytes()==old_runs
    record('Neither hook started extraction from the gate worktree.')
    sizehome=root/'.local-test-tmp/now-budget-home'
    sizing={'FM_HOME':str(sizehome),'FM_MEMORY_DIR':str(sizehome/'data/memories')}
    for i in range(11):
        # Store real CLI outputs without flooding the evidence with every input body.
        r=subprocess.run([str(root/'bin/fm-memory.sh'),'remember','--category','now',f'Release focus {i}','x'*585],env={**env,**sizing},capture_output=True,text=True,timeout=10)
        assert r.returncode==0
    record('Created 11 current entries with real fm-memory.sh remember --category now (585-character bodies).')
    r=call('fm-memory.sh','now',changes=sizing); assert len(r.stdout)<=6000 and 'omitted by the size cap' in r.stdout
    record('Complete default NOW output length: '+str(len(r.stdout))+' characters (cap 6000).')
    for cap in [0,1,20,45,60,620,1000]:
        r=call('fm-memory.sh','now','--max-chars',str(cap),changes=sizing)
        assert r.returncode==0 and len(r.stdout)<=cap
    (evidence/'live-final-runs.jsonl').write_bytes((capture/'runs.jsonl').read_bytes())
finally:
    if p and p.poll() is None:
        os.killpg(p.pid,signal.SIGTERM)
        try:p.wait(timeout=5)
        except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
    (evidence/'live-boundaries-and-now.log').write_text('\n'.join(log)+'\n')
