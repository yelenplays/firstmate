#!/usr/bin/env python3
"""Manual CLI validation: real executables, isolated homes, persisted output contracts."""
import os, subprocess, pathlib, tempfile, json, hashlib, shutil
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M52YWSZ3NT93VE6AGZ7RJJBZ')
work=pathlib.Path(tempfile.mkdtemp(prefix='manual-memory-', dir=ROOT/'.validation-tmp'))
env=os.environ.copy()
for k in list(env):
    if (k.startswith('FM_') and (k.endswith('_OVERRIDE') or k in ['FM_MEMORY_DIR','FM_CLAUDE_BIN','FM_MEMORY_CAPTURE_MODEL','FM_MEMORY_CAPTURE_JEV_BIN'])):
        del env[k]
env.update(FM_HOME=str(work/'home'), TMPDIR=str(ROOT/'.validation-tmp'))
log=[]
def run(script,*args,env_=None,input=None):
    r=subprocess.run([str(ROOT/'bin'/script),*args],env=env_ or env,input=input,text=True,capture_output=True,timeout=45)
    log.append({'command':script+' '+' '.join(args),'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
    return r
try:
    home=work/'home'
    subprocess.run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(home)],check=True,capture_output=True)
    def mem(*args,**kw): return run('fm-memory.sh',*args,**kw)
    assert mem('remember','--category','now','--expires','2999-01-01','--sensitivity','private','Personal situation','Personal test context stays Claude-only.').returncode==0
    assert mem('remember','--category','now','--expires','2999-01-01','Shipping focus','Focus on reducing memory capture usage.').returncode==0
    assert mem('remember','--category','now','--expires','2000-01-01','Old focus','EXPIRED_TEST_CONTEXT').returncode==0
    current=mem('now').stdout
    public=mem('now','--exclude-private').stdout
    assert 'Personal test context' in current and 'Personal test context' not in public
    assert 'EXPIRED_TEST_CONTEXT' not in current and 'reducing memory capture' in public
    assert (home/'data/memories/now/old-focus.md').exists()
    (E/'now-cli.txt').write_text('Claude-facing NOW:\n'+current+'\nNon-Claude-facing NOW:\n'+public)
    # merge-from: two absent memories across orphan stores plus one conflicting topic.
    before=(home/'data/memories/now/shipping-focus.md').read_bytes()
    for n in [1,2]:
        src=work/f'orphan{n}'
        se=env|{'FM_MEMORY_DIR':str(src)}
        assert mem('remember','--category','entities',f'Orphan {n}',f'Unique fact from isolated store {n}.',env_=se).returncode==0
        assert mem('remember','--category','now','Shipping focus',f'Conflicting source {n}.',env_=se).returncode==0
        result=mem('merge-from',str(src))
        assert result.returncode==1 and 'conflict (kept this store): now/shipping-focus.md' in result.stdout
        assert (home/'data/memories/now/shipping-focus.md').read_bytes()==before
        recall=json.loads(mem('recall','--json',f'Orphan {n}').stdout)
        assert any(d['path']==f'entities/orphan-{n}.md' for d in recall['documents'])
    # Adversarial budget: fill almost all 6000 characters then force an omitted row.
    ce=env|{'FM_MEMORY_DIR':str(work/'cap-store')}
    for n in range(11):
        assert mem('remember','--category','now',f'Focus {n:02d}','x'*586,env_=ce).returncode==0
    capped=mem('now',env_=ce).stdout
    (E/'now-cap-output.txt').write_text(capped)
    cap_result={'configured_cap':6000,'actual_characters':len(capped),'within_cap':len(capped)<=6000,'last_line':capped.splitlines()[-1]}
    (E/'now-cap-result.json').write_text(json.dumps(cap_result,indent=2)+'\n')
    print(json.dumps(cap_result))
    # Hook guards: actual gate root must stand down even with a marked lab home.
    for flag in [{},{'FM_TASK_ID':'manual-crew'},{'FM_SUPERVISION_ACTOR':'host'},{'FM_MEMORY_CAPTURE_CHILD':'1'},{'FM_MEMORY_CAPTURE':'off'}]:
        r=run('fm-memory-capture.sh','hook','precompact',env_=env|flag,input='{}')
        assert r.returncode==0
        assert not (home/'state/memory-capture').exists()
    # Disallowed model must be refused before it can advance the cursor or write memories.
    r=run('fm-memory-capture.sh','run',env_=env|{'FM_MEMORY_CAPTURE_MODEL':'deepseek-v4'})
    assert r.returncode!=0 and 'refusing model' in r.stderr
    assert not (home/'state/memory-capture/watermark.json').exists()
    (E/'manual-cli-transcript.json').write_text(json.dumps(log,indent=2)+'\n')
finally:
    shutil.rmtree(work)
