#!/usr/bin/env python3
"""Compare executable gate behavior before the CI fix and at target HEAD."""
import os,pathlib,subprocess,tempfile,shutil
root=pathlib.Path.cwd()
ev=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5DNQYW054A2EFMRB2C5X2BE')
lab=pathlib.Path(tempfile.mkdtemp(prefix='regression-',dir=root/'.test-runtime'))
fd,previous=tempfile.mkstemp(prefix='.fm-dod-before-validation-',suffix='.sh',dir=root/'bin')
os.close(fd)
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','GIT_CONFIG','GIT_DIR','GIT_WORK_TREE'))}
env.update(NM_HOME=str(lab/'nm'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Validation',GIT_AUTHOR_EMAIL='validation@example.invalid',GIT_COMMITTER_NAME='Validation',GIT_COMMITTER_EMAIL='validation@example.invalid')
log=[]
def run(args):
    return subprocess.run([str(a) for a in args],cwd=root,env=env,text=True,capture_output=True,timeout=30)
try:
    old=run(['git','show','d1c223e9^:bin/fm-dod-lib.sh']); assert old.returncode==0,old.stderr
    pathlib.Path(previous).write_text(old.stdout)
    missing=lab/'missing'
    nobase=lab/'no-origin'; nobase.mkdir()
    for args in [('init','-q'),('commit','-qm','base','--allow-empty')]:
        p=run(['git','-C',nobase,*args]); assert p.returncode==0,p.stderr
    for shape,wt in [('missing-copy',missing),('no-origin',nobase)]:
        for lane in ['opus','sonnet']:
            meta=lab/(shape+'-'+lane+'.meta')
            meta.write_text('kind=ship\nmode=no-mistakes\nmodel=claude-'+lane+'-5-5\n'+('test_ban_model=claude-sonnet-5-5\n' if lane=='sonnet' else ''))
            for revision,lib in [('before-CI-fix',pathlib.Path(previous)),('target-16ff368',root/'bin/fm-dod-lib.sh')]:
                p=run(['bash','-c','. "$1"; fm_test_ban_accept_done ship no-mistakes "$2" "done: PR https://github.com/yelenplays/firstmate/pull/187 checks green" "$3" 1','_',lib,wt,meta])
                log.append(f'{revision} {shape} {lane}: exit={p.returncode}; stdout={p.stdout!r}; stderr={p.stderr!r}')
                expected=0 if revision=='target-16ff368' and lane=='opus' else 1
                assert p.returncode==expected,log[-1]
                if expected==0: assert p.stdout==p.stderr=='',log[-1]
    log.append('The same history inputs reproduce the Opus refusal before the fix and silent acceptance after it; Sonnet remains refused in both revisions.')
finally:
    pathlib.Path(previous).unlink()
    shutil.rmtree(lab)
    (ev/'history-regression-before-after.log').write_text('\n'.join(log)+'\n')
print('\n'.join(log))
