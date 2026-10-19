import datetime, json, os, pathlib, shutil, subprocess
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M59XY24CQN6E6XS9CMW0DM5S')
LAB=ROOT/'.memory-write-validation'
LAB.mkdir()
for d in ['data','state','config']: (LAB/d).mkdir()
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','JEV_','TYPESAFE_'))}
env.update(FM_HOME=str(LAB),FM_MEMORY_DIR=str(LAB/'blocked-store'))
(LAB/'blocked-store').write_text('This regular file deliberately prevents store-directory creation.\n')
log=[]
def run(args,check=True):
    p=subprocess.run([str(ROOT/'bin'/args[0]),*args[1:]],env=env,text=True,capture_output=True,timeout=360)
    log.append('$ '+' '.join(args)+'\n'+p.stdout+p.stderr+f'\nexit={p.returncode}\n')
    if check: assert p.returncode==0,log[-1]
    return p
try:
    transcript=LAB/'conversation.jsonl'
    transcript.write_text(json.dumps(dict(type='user',origin=dict(kind='human'),uuid='write-must-verify',timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(),message=dict(content='From now on please always write my meeting agendas in plain text instead of Markdown. Remember this as a lasting preference. This is synthetic lab data.')))+'\n')
    run(['fm-history.sh','capture','--transcript',str(transcript)])
    mark=LAB/'state/memory-capture/watermark.json'
    for n in range(2):
        p=run(['fm-memory-capture.sh','run','--trigger','sessionend'],False)
        assert p.returncode!=0 and not mark.exists()
        record=json.loads(p.stdout.strip())
        assert not record['ok'] and 'remember failed' in record['why']
    status=LAB/'state/memory-capture.status'
    assert status.read_text().count('failed [at=')==1
    env['FM_MEMORY_DIR']=str(LAB/'data/memories')
    p=run(['fm-memory-capture.sh','run','--trigger','sessionend'])
    r=json.loads(p.stdout.strip())
    assert r['ok'] and r['turns']==1 and r['memories']>0
    assert json.loads(mark.read_text())['id']=='write-must-verify'
    assert 'resolved [at=' in status.read_text()
    run(['fm-memory.sh','recall','--json','meeting agendas plain text'])
    saved=mark.read_bytes()
    runs=LAB/'state/memory-capture/runs.jsonl'
    before=runs.read_bytes()
    p=run(['fm-memory-capture.sh','run','--dry-run','--after','2000-01-01/start'])
    assert json.loads(p.stdout.strip())['model_calls']==1
    assert mark.read_bytes()==saved and runs.read_bytes()==before
    assert not (LAB/'state/memory-capture/lock').exists() and not (LAB/'state/memory-capture/pending').exists()
    p=run(['fm-memory-capture.sh','run','--after','2000-01-01/start','--no-watermark'])
    assert json.loads(p.stdout.strip())['ok'] and mark.read_bytes()==saved
    assert not (LAB/'state/memory-capture/pending').exists()
    run(['fm-memory-capture.sh','status'])
    shutil.copytree(LAB/'state',E/'write-recovery-state',dirs_exist_ok=True)
    shutil.copytree(LAB/'data/memories',E/'write-recovery-memories',dirs_exist_ok=True)
    print('PASS: failed writes preserve watermark; repeated failure alerts once; successful retry resolves and verifies; dry run and explicit replay leave watermark and pending state unchanged.')
finally:
    (E/'live-write-recovery.txt').write_text('\n'.join(log))
    shutil.rmtree(LAB)
