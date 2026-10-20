#!/usr/bin/env python3
"""Drive the unmodified registration CLI with real Git/GitHub, no tool stubs.
All task/config/history inputs are disposable scenario data, not real model runs.
"""
import os, pathlib, shutil, subprocess, tempfile, json
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5DNQYW054A2EFMRB2C5X2BE')
URL = 'https://github.com/yelenplays/firstmate/pull/187'
ROOT.joinpath('.test-runtime').mkdir(exist_ok=True)
lab = pathlib.Path(tempfile.mkdtemp(prefix='registration-', dir=ROOT / '.test-runtime'))
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'GIT_CONFIG', 'GIT_DIR', 'GIT_WORK_TREE', 'TASKS_AXI'))}
env.update(FM_HOME=str(lab), NM_HOME=str(lab/'nm'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Live validation', GIT_AUTHOR_EMAIL='validation@example.invalid', GIT_COMMITTER_NAME='Live validation', GIT_COMMITTER_EMAIL='validation@example.invalid')
log = []
results = []
def run(args, cwd=ROOT):
    p = subprocess.run([str(a) for a in args], cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
    return p

def git(wt, *args):
    p=run(['git','-c','core.hooksPath=/dev/null','-C',wt,*args]); assert p.returncode == 0, p.stderr
    return p.stdout.strip()

def commit(wt, path, text, subject):
    target=wt/path; target.parent.mkdir(parents=True,exist_ok=True); target.write_text(text)
    git(wt,'add','--',path); git(wt,'commit','-qm',subject)
    return git(wt,'rev-parse','HEAD')

def setup(id, model='claude-opus-5-5', banned=False, base=True, extra=()):
    wt=lab/'projects'/id
    wt.mkdir(); git(wt,'init','-q','-b','main'); git(wt,'commit','-qm','base','--allow-empty')
    if base: git(wt,'update-ref','refs/remotes/origin/main','HEAD')
    git(wt,'checkout','-qb','fm/'+id)
    meta=lab/'state'/(id+'.meta')
    lines=['kind=ship','mode=no-mistakes','model='+model,'branch=fm/'+id,'worktree='+str(wt),'project='+str(wt)]
    if banned: lines.append('test_ban_model='+model)
    meta.write_text('\n'.join(lines+list(extra))+'\n'); meta.chmod(0o600)
    return wt,meta

def check(label,id,meta,expected,contains=None,require_head=True):
    log.append('\n## '+label+'\n$ FM_HOME=<disposable marked lab> NM_HOME=<lab>/nm bin/fm-pr-check.sh '+id+' '+URL)
    p=run([ROOT/'bin/fm-pr-check.sh',id,URL])
    log.extend(['exit='+str(p.returncode),'stdout:\n'+p.stdout,'stderr:\n'+p.stderr])
    state=meta.read_text(); poll=lab/'state'/(id+'.check.sh')
    log.extend(['Persisted task metadata:\n'+state,'merge poll present='+str(poll.is_file())])
    if expected == 0:
        assert p.returncode==0, label+': '+p.stderr
        assert 'pr='+URL+'\n' in state and poll.is_file(),label
        if require_head:
            assert any(s.startswith('pr_head=') and len(s)==48 for s in state.splitlines()),label+': no actual forge head'
    else:
        assert p.returncode==1, label+': '+p.stdout+p.stderr
        assert 'pr=' not in state and not poll.exists(),label+': refusal persisted registration'
    if contains: assert contains in p.stdout+p.stderr,label
    results.append({'name':label,'result':'pass','live':True,'evidence':'live-pr-registration.log','reason':''})

try:
    p=run([ROOT/'bin/fm-lab-home.sh','create',lab]); assert p.returncode==0,p.stderr
    (lab/'nm').mkdir()
    (lab/'nm'/'config.yaml').write_text('agent: [claude]\nagent_config:\n  claude:\n    model: claude-opus-5-5\nreview_agents:\n  fixer:\n    agent: claude\n    model: claude-sonnet-5-5\n')
    log.append('HEAD='+git(ROOT,'rev-parse','HEAD')+'\nReal GitHub reads only; no external writes, no fake harness/forge. Histories and lane metadata are synthetic inputs.\n')
    wt,m=setup('opus-no-origin',base=False)
    check('Opus registers without a readable origin base and records the real forge head','opus-no-origin',m,0)
    wt,m=setup('sonnet-no-origin','claude-sonnet-5-5',True,False)
    check('Banned Sonnet cannot register without an origin base','sonnet-no-origin',m,1,'test-file check cannot resolve the base branch')
    wt,m=setup('opus-missing')
    check('Opus initially registers a readable worker copy','opus-missing',m,0)
    shutil.rmtree(wt)
    check('Opus re-registers after worker removal using the already recorded forge head','opus-missing',m,0,require_head=False)
    wt,m=setup('sonnet-missing','claude-sonnet-5-5',True)
    shutil.rmtree(wt)
    check('Banned Sonnet cannot register a missing worker copy','sonnet-missing',m,1,'test-file check cannot read the worker copy')
    wt,m=setup('opus-unrelated')
    orphan=git(wt,'commit-tree','HEAD^{tree}','-m','unrelated origin')
    git(wt,'update-ref','refs/remotes/origin/main',orphan)
    check('Opus registers when origin and HEAD have no merge-base','opus-unrelated',m,0)
    wt,m=setup('sonnet-unrelated','claude-sonnet-5-5',True)
    orphan=git(wt,'commit-tree','HEAD^{tree}','-m','unrelated origin')
    git(wt,'update-ref','refs/remotes/origin/main',orphan)
    check('Banned Sonnet is still refused when origin has no merge-base','sonnet-unrelated',m,1,'test-file check found no merge-base')
    wt,m=setup('pipeline-banned')
    commit(wt,'tests/existing.test.sh','original contract\n','Opus-authored test input')
    modified=commit(wt,'tests/existing.test.sh','changed contract\n','no-mistakes(review): change existing test')
    added=commit(wt,'tests/fixer.test.sh','new test\n','no-mistakes(review): add test')
    check('Opus task refuses Sonnet-fixer added and modified tests despite real forge head','pipeline-banned',m,1,'pipeline fixer commits')
    assert 'tests/existing.test.sh' in log[-3] or 'tests/existing.test.sh' in '\n'.join(log[-5:])
    git(wt,'revert','--no-edit',added); git(wt,'revert','--no-edit',modified)
    check('Reverting unauthorized fixer changes restores PR registration','pipeline-banned',m,0)
    wt,m=setup('pipeline-allowed')
    commit(wt,'tests/allowed.test.sh','test\n','no-mistakes(test): allowlisted test author')
    check('Allowlisted test-step changes register successfully','pipeline-allowed',m,0)
    wt,m=setup('pipeline-exception',extra=['test_ban_allowed=tests/exact.test.sh'])
    commit(wt,'tests/exact.test.sh','test\n','no-mistakes(review): named exception')
    check('Exact captain-authorized fixer test path registers','pipeline-exception',m,0)
    for id,model in [('deepseek','opencode-go/deepseek-v4.1-flash'),('glm','zai/glm-5.3-flash')]:
        wt,m=setup(id,model,True)
        commit(wt,'tests/banned.test.sh','unit\n','worker authors test')
        check(model+' worker cannot register unauthorized unit tests',id,m,1,'no test authoring on '+model)
        git(wt,'revert','--no-edit','HEAD')
        commit(wt,'src/implementation.sh','implementation\n','implement')
        commit(wt,'tests/workflow.e2e.test.sh','e2e\n','end-to-end test')
        check(model+' worker can register implementation and e2e only',id,m,0)
    wt,m=setup('handoff','claude-sonnet-5-5',True)
    since=commit(wt,'tests/locked.test.sh','failing contract\n','Opus tests-first handoff input')
    m.write_text(m.read_text()+'test_ban_since='+since+'\n')
    commit(wt,'src/fix.sh','fixed\n','Sonnet implementation input')
    check('Sonnet registers unchanged tests inherited at handoff','handoff',m,0)
    # A new independent task record ensures a refusal cannot reuse a previous registration.
    bad=lab/'state'/'handoff-tamper.meta'
    bad.write_text('\n'.join(x for x in m.read_text().splitlines() if not x.startswith(('pr=','pr_head=')))+'\n'); bad.chmod(0o600)
    commit(wt,'tests/locked.test.sh','weakened contract\n','implementer tampers with locked test')
    check('Changing a handed-over test blocks registration','handoff-tamper',bad,1,'tests/locked.test.sh')
except Exception as exc:
    log.append('DRIVER ERROR: '+repr(exc))
    raise
finally:
    shutil.rmtree(lab)
    log.append('Disposable lab removed; no supervisor or worker process was launched.')
    (EVIDENCE/'live-pr-registration.log').write_text('\n'.join(log)+'\n')
    (EVIDENCE/'live-pr-registration-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
