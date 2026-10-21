#!/usr/bin/env python3
import os, pathlib, shutil, subprocess, tempfile
ROOT=pathlib.Path('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5GBFQ8RGJCKZH4F73FR0NMT')
E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5GBFQ8RGJCKZH4F73FR0NMT')
D=pathlib.Path(tempfile.mkdtemp(prefix='.qa-regression-',dir=ROOT)); log=[]
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_','GIT_CONFIG_')): env.pop(k,None)
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='QA',GIT_AUTHOR_EMAIL='qa@example.invalid',GIT_COMMITTER_NAME='QA',GIT_COMMITTER_EMAIL='qa@example.invalid',TMPDIR=str(D))
def run(a,**kw): return subprocess.run([str(x) for x in a],cwd=ROOT,env=dict(env,**kw),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
def git(w,*a):
    p=run(['git','-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false','-C',w,*a]); assert p.returncode==0,p.stdout; return p.stdout.strip()
try:
    oldbin=D/'bin'; oldbin.mkdir()
    for p in (ROOT/'bin').glob('*.sh'):
        if p.name!='fm-tdd-split.sh': (oldbin/p.name).symlink_to(p)
    old=run(['git','show','ca9ec295^:bin/fm-tdd-split.sh']); assert old.returncode==0
    (oldbin/'fm-tdd-split.sh').write_text(old.stdout)
    for broken in ['unrelated-base','missing-base','no-tests']:
        c=D/broken; c.mkdir(); wt=c/'wt'; home=c/'home'
        p=run(['bin/fm-lab-home.sh','create',home]); assert p.returncode==0,p.stdout
        git(c,'init','-q','--initial-branch=main',wt); (wt/'README').write_text('base\n'); git(wt,'add','.'); git(wt,'commit','-qm','base')
        base=git(wt,'rev-parse','HEAD'); git(wt,'update-ref','refs/remotes/origin/main',base)
        if broken!='no-tests':
            (wt/'tests').mkdir(); (wt/'tests'/'behavior.test.sh').write_text('test -f feature.sh\n'); git(wt,'add','.'); git(wt,'commit','-qm','tests')
        (wt/'feature.sh').write_text('echo ready\n'); git(wt,'add','.'); git(wt,'commit','-qm','implementation')
        if broken=='unrelated-base':
            unrelated=git(wt,'commit-tree',git(wt,'rev-parse','HEAD^{tree}'),'-m','unrelated root'); git(wt,'update-ref','refs/remotes/origin/main',unrelated)
        elif broken=='missing-base': git(wt,'update-ref','-d','refs/remotes/origin/main')
        meta=home/'state'/'trial.meta'; meta.write_text(f'kind=ship\nmode=local-only\nworktree={wt}\nbase_branch=main\nmodel=claude-opus-5-5\ntdd_split=implement\n')
        (home/'state'/'trial.status').write_text('done: ready\n'); task=home/'data'/'trial'; task.mkdir()
        (task/'brief.md').write_text('Fail-to-pass command: `false`\nMutation command: `echo MUTATION_EXECUTED argc=$#; exit 0`\n')
        log.append('\nScenario: '+broken+'\n')
        for label,script,expected in [('before-fix',oldbin/'fm-tdd-split.sh',0),('candidate',ROOT/'bin'/'fm-tdd-split.sh',1)]:
            p=run(['bash',script,'mutation','trial'],FM_HOME=str(home),FM_ROOT_OVERRIDE=str(ROOT))
            log.append(f'$ {label}: bash {script} mutation trial\n{p.stdout}[exit={p.returncode}]\n')
            assert p.returncode==expected,p.stdout
            ml=task/'tdd-split-mutation.log'
            if label=='before-fix':
                text=ml.read_text(); assert 'MUTATION_EXECUTED argc=0' in text; log.append(text); ml.unlink()
            else:
                assert not ml.exists(); log.append('Observed: mutation command was not invoked.\n')
finally:
    (E/'regression-before-after.log').write_text('\n'.join(log)); shutil.rmtree(D)
print('All three pre-fix zero-argument mutation bypasses reproduced; candidate refuses all three before invocation.')
