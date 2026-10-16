import os, pathlib, subprocess, json, shutil
ROOT = pathlib.Path.cwd()
E = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M52HZK4E4RZF8MGVM5BH9A8S')
LAB = ROOT / '.test-family-tmp/live'
HOME = LAB / 'home'
PROJ = LAB / 'project'
for p in [HOME/'state', HOME/'data', HOME/'config', PROJ]: p.mkdir(parents=True, exist_ok=True)
env = dict(os.environ)
for key in list(env):
    if key.startswith('FM_') or key in ['NM_HOME', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR']:
        env.pop(key)
env.update(FM_HOME=str(HOME), FM_AI_FAMILY_PI_CATALOG=str(E/'live-model-catalog.txt'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null')
def git(*args):
    return subprocess.check_output(['git','-C',str(PROJ),'-c','user.name=Validation','-c','user.email=validation@example.invalid','-c','core.hooksPath=/dev/null',*args],env=env,stderr=subprocess.STDOUT,text=True).strip()
git('init','-q','-b','main')
(PROJ/'change.txt').write_text('base\n')
git('add','change.txt'); git('commit','-qm','base')
git('checkout','-qb','fm/gateway')
(PROJ/'change.txt').write_text('base\nchange\n'); git('commit','-qam','change')
HEAD = git('rev-parse','HEAD')
BASE = git('rev-parse','main')
git('checkout','-q','main')
transcript = []
results = []
current = None

def run(args, script='bin/fm-cross-review.sh', expected=0):
    r = subprocess.run(['bash',str(ROOT/script),*args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    transcript.append({'scenario':current,'command':['bash',script,*args], 'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
    assert r.returncode == expected, transcript[-1]
    return r.stdout

def task(name,harness='pi',model='opencode-go/deepseek-v4.1-flash',family=None,source='pi catalog provider opencode-go serves several makers'):
    (HOME/'data'/name).mkdir(parents=True,exist_ok=True)
    rows = {'harness':harness,'model':model,'mode':'direct-PR','branch':'fm/gateway','worktree':str(PROJ),'project':str(PROJ)}
    if family is not None: rows.update(ai_family=family,ai_family_source=source)
    text=''.join(f'{k}={v}\n' for k,v in rows.items())
    (HOME/'state'/f'{name}.meta').write_text(text)
    transcript.append({'scenario':current, 'task':name, 'input_metadata':rows})
    return name

def status(name): return json.loads(run(['status',name,'--json']))
def plan(name): return dict(x.split('=',1) for x in run(['plan',name]).splitlines() if '=' in x)
def begin(name):
    global current
    current=name

def end(): results.append({'name':current,'result':'pass','live':True})

def reviewer(taskid,rid,model,family=None,head=HEAD,kind='review'):
    task(rid,'opencode',model,family)
    (HOME/'data'/rid/'cross-review-request').write_text(f'task={taskid}\nhead={HEAD}\nkind={kind}\n')
    report = f'reviewed head {head}\nVerdict: PASS\n' if kind=='review' else f'confirm {head}\n'
    (HOME/'data'/rid/'report.md').write_text(report)
    transcript.append({'scenario':current,'reviewer':rid,'input_report':report, 'note':'Synthetic report input exercises the actual report-consumer CLI, not an AI review.'})
    return run(['collect',taskid,rid])

try:
    begin('Plan recognized DeepSeek and GLM gateway tasks without catalog maker evidence')
    for h in ['pi','pi-signed','opencode']:
        for gateway in ['opencode-go','openrouter']:
            for model,fam in [('deepseek-v4.1-flash','deepseek'),('glm-5.3','zhipu')]:
                n=task(f'new-{h}-{gateway}-{fam}',h,f'{gateway}/{model}')
                s=status(n); p=plan(n)
                assert s['builder']['family']==fam and s['head']==HEAD, s
                assert p['action']=='spawn-reviewer' and p['reviewer_family'] not in [fam,'unknown'], p
                output=json.loads((HOME/'data'/n/'cross-review-model.json').read_text())
                assert output['head']==HEAD and output['profile']['harness']==p['reviewer_harness'], output
    end()

    begin('Re-plan previously recorded unknown DeepSeek and GLM tasks')
    old = pathlib.Path('bin/.fm-cross-review-before-test.sh')
    old.write_bytes(subprocess.check_output(['git','show','1a9afa58:bin/fm-cross-review.sh']))
    for h in ['pi','pi-signed','opencode']:
        for model,fam in [('deepseek-v4.1-flash','deepseek'),('glm-5.3','zhipu')]:
            n=task(f'existing-{h}-{fam}',h,f'opencode-go/{model}','unknown')
            before=json.loads(run(['status',n,'--json'],str(old)))
            oldplan=dict(x.split('=',1) for x in run(['plan',n],str(old)).splitlines() if '=' in x)
            assert before['builder']['family']=='unknown' and oldplan['action']=='escalate'
            s=status(n); p=plan(n)
            assert s['builder']['family']==fam and 're-resolved' in s['builder']['source'],s
            assert p['action']=='spawn-reviewer',p
            assert 'ai_family=unknown\n' in (HOME/'state'/f'{n}.meta').read_text()
    old.unlink()
    end()

    begin('Unknown, unqualified and misleading gateway names still require a decision')
    for i,model in enumerate(['opencode-go/cat-jam-free','opencode-go/deepseek-','opencode-go/glm-', 'opencode-go/x-deepseek-v4.1-flash','opencode-go/x-glm-5','opencode-go/glm-5/other','deepseek-v4.1-flash','glm-5.3']):
        n=task(f'bad-{i}',model=model,family='unknown')
        assert status(n)['builder']['family']=='unknown'
        p=plan(n); assert p['action']=='escalate',p
        assert not (HOME/'data'/n/'cross-review-model.json').exists()
    end()

    begin('Re-resolution preserves known and earlier unknown builder history')
    for i,(family,source) in enumerate([('openai','known earlier builder'),('openai,unknown','mixed builder history'),('unknown,zhipu','mixed builder history'),('unknown','current model; earlier incarnations: unknown')]):
        n=task(f'history-{i}',family=family,source=source)
        s=status(n); assert s['builder']['family']==family,s
        p=plan(n)
        assert p['action']==('escalate' if 'unknown' in family else 'spawn-reviewer'),p
        if family=='openai': assert p['reviewer_family']!='openai',p
    end()

    begin('Same-maker gateway reviews and legacy Z.ai aliases cannot establish independence')
    for i,(builder_model,builder_family,reviewer_model,reviewer_family) in enumerate([
        ('opencode-go/glm-5.3','unknown','openrouter/glm-5',None),
        ('opencode-go/glm-5.3','zai','openrouter/glm-5',None),
        ('opencode-go/glm-5.3','zhipu','zai/glm-5','zai'),
        ('opencode-go/deepseek-v4.1-flash','unknown','openrouter/deepseek-v4-pro',None),
        ('opencode-go/deepseek-v4.1-flash','deepseek,zhipu','openrouter/glm-5',None)]):
        n=task(f'same-{i}','opencode',builder_model,builder_family)
        out=reviewer(n,f'same-reviewer-{i}',reviewer_model,reviewer_family)
        assert 'accepted=no' in out,out
        s=status(n); assert isinstance(s['independent_review'],str) and s['independent_review'].startswith('MISSING:'),s
    end()

    begin('Different gateway makers count only for the exact reviewed or confirmed head')
    n=task('independent','opencode','opencode-go/glm-5.3','unknown')
    out=reviewer(n,'other-maker','openrouter/deepseek-v4.1-flash',head=BASE)
    assert 'accepted=no' in out,out
    out=reviewer(n,'other-maker','openrouter/deepseek-v4.1-flash')
    assert 'accepted=yes' in out and 'reviewer_family=deepseek' in out,out
    s=status(n); assert s['builder']['family']=='zhipu' and s['independent_review']['family']=='deepseek' and s['independent_review']['head']==HEAD,s
    assert plan(n)['action']=='none'
    out=reviewer(n,'confirmer','openrouter/deepseek-v4.1-flash',kind='confirm')
    assert 'accepted=yes' in out,out
    assert 'confirmed' in run(['verify-confirm',n,HEAD])
    run(['verify-confirm',n,BASE],expected=1)
    assert 'not confirmed' in transcript[-1]['stderr'],transcript[-1]
    transcript.append({'scenario':current,'persisted_cross_review_records': [json.loads(x) for x in (HOME/'data'/n/'cross-review.jsonl').read_text().splitlines()], 'persisted_task_metadata':(HOME/'state'/f'{n}.meta').read_text()})
    end()
finally:
    (ROOT/'bin/.fm-cross-review-before-test.sh').unlink(missing_ok=True)
    (E/'live-cli-transcript.json').write_text(json.dumps(transcript,indent=2)+'\n')
    (E/'live-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(LAB)
print(json.dumps(results,indent=2))
