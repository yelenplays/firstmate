import os,pathlib,subprocess,json
R=pathlib.Path.cwd(); W=R/'.validation-tmp/live'; H=W/'main-home'; P=H/'projects/demo'; E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5G90CKM6QB4XMMX9E8JHPP3')
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_','GIT_','GH_','TASKS_AXI_')): env.pop(k,None)
env.update(FM_HOME=str(H),FM_ROOT_OVERRIDE=str(W/'installation-root'),TMPDIR=str(W),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Validation',GIT_AUTHOR_EMAIL='validation@example.invalid',GIT_COMMITTER_NAME='Validation',GIT_COMMITTER_EMAIL='validation@example.invalid',GH_CONFIG_DIR=str(W/'gh-config'))
log=[]
def run(*args):
    p=subprocess.run(list(map(str,args)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
    log.append('$ '+' '.join(map(str,args))+'\n'+p.stdout)
    assert p.returncode==0,(args,p.stdout)
    return p.stdout.strip()
def git(*args): return run('git','-C',P,*args)
def ready(id):
    (H/'state'/f'{id}.meta').write_text(f'kind=ship\nmode=local-only\nproject={P}\nbranch=fm/{id}\nspawn_gen=regression.{id}\n')
    (H/'state'/f'{id}.status').write_text(f'done: ready branch fm/{id}\n')
main=git('rev-parse','main'); status=git('status','--porcelain'); old=git('rev-parse','fm/clean^1')
git('branch','fm/regression',old); ready('regression')
run(R/'.validation-tmp/before/bin/fm-main-sync.sh','regression')
assert git('rev-parse','fm/regression')==old
assert not (H/'state/regression.main-sync').exists()
log.append('BEFORE: the previous product skipped the local-only ready branch; it still cannot fast-forward-land on main.\n')
run(R/'bin/fm-main-sync.sh','regression'); git('merge-base','--is-ancestor','main','fm/regression')
assert git('rev-parse','fm/regression')!=old
log.append('AFTER: the current product updates the ready branch, and ancestry now permits fast-forward landing. No landing was performed.\n')
# Same default choice as local landing: origin/HEAD wins over the presence of main.
git('branch','trunk','main'); git('symbolic-ref','refs/remotes/origin/HEAD','refs/remotes/origin/trunk')
git('branch','fm/default-choice',old); ready('default-choice')
run(R/'bin/fm-main-sync.sh','default-choice')
record=dict(l.split('=',1) for l in (H/'state/default-choice.main-sync').read_text().splitlines())
assert record['base']=='trunk' and record['result']=='synced'
assert git('rev-parse','fm/default-choice^2')==main
assert git('rev-parse','main')==main and git('rev-parse','trunk')==main
assert git('status','--porcelain')==status
log.append('DEFAULT CHOICE: origin/HEAD selected trunk even while main existed; both local defaults and the dirty main copy stayed untouched.\n')
(E/'before-after-and-default-choice.txt').write_text('\n'.join(log))
print('\n'.join(log[-12:]))
