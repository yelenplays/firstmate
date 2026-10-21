#!/usr/bin/env python3
"""Public CLI checks, no mocks or lifecycle replacements; all state is disposable."""
import os, pathlib, shutil, subprocess, tempfile, json
ROOT = pathlib.Path('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5GBFQ8RGJCKZH4F73FR0NMT')
EVIDENCE = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5GBFQ8RGJCKZH4F73FR0NMT')
scratch = pathlib.Path(tempfile.mkdtemp(prefix='.qa-tdd-', dir=ROOT))
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'GIT_CONFIG_', 'TASKS_AXI_')) or key in ('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE'):
        env.pop(key, None)
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='QA', GIT_AUTHOR_EMAIL='qa@example.invalid', GIT_COMMITTER_NAME='QA', GIT_COMMITTER_EMAIL='qa@example.invalid', TMPDIR=str(scratch))
log = []
results = []
def run(args, rc=0, extra=None, show=True):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=dict(env, **(extra or {})), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=35)
    if show:
        log.append('$ ' + ' '.join(str(a) for a in args) + '\n' + p.stdout + f'[exit={p.returncode}]\n')
    assert p.returncode == rc, f'Expected {rc}, got {p.returncode}: {p.stdout}'
    return p.stdout.strip()
def git(wt, *args):
    return run(['git','-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false','-C',wt,*args], show=False)
def case(name, phase='tests', model='claude-opus-5-5', red='for t; do bash "$t" || exit 1; done', mutation='echo MUTATION_EXECUTED; printf "arg=%s\\n" "$@"; test "$#" -gt 0'):
    d=scratch/name; d.mkdir(); home=d/'home'; wt=d/'wt'; origin=d/'origin'
    run(['bin/fm-lab-home.sh','create',home], show=False)
    git(d,'init','-q','--initial-branch=main',origin)
    (origin/'README').write_text('QA disposable example\n')
    git(origin,'add','.'); git(origin,'commit','-qm','base')
    git(d,'clone','-q',origin,wt); git(wt,'checkout','-qb','fm/'+name)
    task=home/'data'/name; task.mkdir()
    (task/'brief.md').write_text('# Brief\n\nFail-to-pass command: `'+red+'`\nMutation command: `'+mutation+'`\n')
    meta=home/'state'/(name+'.meta')
    meta.write_text(f'kind=ship\nmode=local-only\nworktree={wt}\nproject={origin}\nbase_branch=main\nharness=claude\nmodel={model}\neffort=medium\nspawn_gen=s1.1.qa\ntdd_split={phase}\ntdd_split_impl_harness=claude\ntdd_split_impl_model=claude-sonnet-5-5\ntdd_split_impl_effort=medium\n')
    return dict(name=name,home=home,wt=wt,meta=meta,task=task)
def commit(c, path, text):
    p=c['wt']/path; p.parent.mkdir(exist_ok=True,parents=True); p.write_text(text)
    git(c['wt'],'add','--',path); git(c['wt'],'commit','-qm','QA '+path)
def report(c, line):
    (c['home']/'state'/(c['name']+'.status')).write_text(line+'\n')
def cli(c, verb, rc, *args):
    return run(['bin/fm-tdd-split.sh',verb,c['name'],*args], rc, {'FM_HOME':str(c['home'])})
def no_command(c):
    assert not (c['task']/'tdd-split-mutation.log').exists(), 'Mutation was invoked despite refused precondition'
    log.append('Observed: no mutation log was created; task metadata remains on '+('tests' if 'tdd_split=tests\n' in c['meta'].read_text() else 'implement')+' seat.\n')
def done(name):
    results.append({'name':name,'result':'pass','live':True})
try:
    log.append('Candidate: '+run(['git','rev-parse','HEAD'],show=False)+'\nNo stubs, no FM_CONTROL_BIN override, no alternate harness.\n')
    for name, red, test, want in [
        ('green','for t; do bash "$t" || exit 1; done','true\n','pass on the base'),
        ('unrunnable','qa-command-that-does-not-exist "$@"','false\n','could not run (exit 127)'),
        ('timeout','sleep 3','false\n','hit its 1s bound'),
        ('mixed','for t; do bash "$t" || exit 1; done','false\n','not tests: feature.sh')]:
        c=case(name,red=red); commit(c,'tests/feature.test.sh',test)
        if name=='mixed': commit(c,'feature.sh','echo forbidden\n')
        report(c,'done: tests-ready '+git(c['wt'],'rev-parse','HEAD'))
        out=cli(c,'handoff',1,'--timeout','1'); assert want in out
        assert 'tdd_split=tests\n' in c['meta'].read_text()
        redlog=c['task']/'tdd-split-red.log'
        if redlog.exists(): log.append('Red-run output:\n'+redlog.read_text())
    done('Handoff refuses green, unexecutable, timed-out, and production-writing test seats')

    c=case('mutation-pass',phase='implement',mutation='echo MUTATION_EXECUTED; printf "arg=%s\\n" "$@"; for t; do bash "$t" || exit 1; done; touch clone-only-marker')
    commit(c,'tests/feature.test.sh','test "$(bash feature.sh)" = ready\n'); commit(c,'feature.sh','echo ready\n')
    report(c,'done: ready'); out=cli(c,'mutation',0,'--timeout','5'); assert 'mutation gate passed' in out
    mutation_log=(c['task']/'tdd-split-mutation.log').read_text()
    assert 'arg=tests/feature.test.sh' in mutation_log and 'exit=0' in mutation_log
    assert not (c['wt']/'clone-only-marker').exists()
    assert git(c['wt'],'status','--porcelain') == ''
    log.append('Mutation log:\n'+mutation_log+'\nObserved: clone-only-marker absent from worker copy; worker copy clean.\n')
    done('Mutation executes branch tests at the implementation head without changing the worker copy')

    for name in ['missing-base','unrelated-base','no-tests']:
        c=case(name,phase='implement')
        if name!='no-tests': commit(c,'tests/feature.test.sh','test -f feature.sh\n')
        commit(c,'feature.sh','echo ready\n'); report(c,'done: ready')
        if name=='missing-base': git(c['wt'],'update-ref','-d','refs/remotes/origin/main')
        elif name=='unrelated-base':
            tree=git(c['wt'],'rev-parse','HEAD^{tree}')
            unrelated=git(c['wt'],'commit-tree',tree,'-m','unrelated root')
            git(c['wt'],'update-ref','refs/remotes/origin/main',unrelated)
        expected={'missing-base':'cannot resolve the base branch','unrelated-base':'no merge-base','no-tests':'no test file'}[name]
        assert expected in cli(c,'mutation',1)
        no_command(c)
    done('Mutation refuses missing base, unrelated history, and zero test arguments before running its command')

    for action in ['edit','delete']:
        for model in ['opencode-go/deepseek-v4.1-flash','zhipu/glm-5.2','claude-sonnet-5-5']:
            c=case('locked-'+action+'-'+model.split('/')[-1],phase='implement',model=model)
            commit(c,'tests/feature.test.sh','test -f feature.sh\n'); seat=git(c['wt'],'rev-parse','HEAD')
            with c['meta'].open('a') as f: f.write(f'test_ban_model={model}\ntest_ban_since={seat}\n')
            if action=='edit': commit(c,'tests/feature.test.sh','true\n')
            else:
                git(c['wt'],'rm','-q','tests/feature.test.sh'); git(c['wt'],'commit','-qm','delete locked test')
            report(c,'blocked [key=test-dispute]: tests/feature.test.sh: too strict')
            out=cli(c,'dispute',1)
            assert 'no test authoring on '+model in out and 'tests/feature.test.sh' in out
            assert 'tdd_split=implement\n' in c['meta'].read_text()
    done('Sonnet, DeepSeek and GLM cannot edit or delete handed-over tests and then dispute them')

    c=case('rounds',phase='implement',model='claude-sonnet-5-5')
    def escalation(cmd, rc=0, *args):
        return run(['bin/fm-escalate.sh',cmd,c['name'],*args],rc,{'FM_HOME':str(c['home'])})
    commit(c,'feature.sh','echo first\n')
    assert 'failed_rounds=1' in escalation('record-failure',0,'--reason','first review failure')
    assert 'failed_rounds=1' in escalation('record-failure',0,'--reason','same head repeated')
    assert 'action=none' in escalation('check')
    commit(c,'feature.sh','echo second\n')
    out=escalation('record-failure',0,'--reason','second review failure')
    assert 'failed_rounds=2' in out and 'next_model=claude-opus-5-5' in out
    log.append('Persisted round records:\n'+(c['task']/'rounds.jsonl').read_text())
    done('Two distinct failed Sonnet heads request Opus, while repeating a head does not advance the ladder')

    c=case('top-step',phase='implement'); commit(c,'feature.sh','echo first\n')
    escalation('record-failure',0,'--reason','first'); commit(c,'feature.sh','echo second\n'); escalation('record-failure',0,'--reason','second')
    out=escalation('run',3); assert 'action=captain' in out and 'top of the escalation ladder' in out
    done('Two failed Opus rounds return a captain decision instead of attempting another relaunch')
finally:
    (EVIDENCE/'cli-transcript.log').write_text('\n'.join(log))
    (EVIDENCE/'cli-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(scratch)
print(json.dumps(results,indent=2))
