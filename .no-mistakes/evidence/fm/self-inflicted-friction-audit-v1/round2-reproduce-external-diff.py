import os, pathlib, subprocess, tempfile, shutil, json
root=pathlib.Path.cwd()
ev=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5CSAEF80R6DCD8ED5DJSSM3')
lab=pathlib.Path(tempfile.mkdtemp(prefix='guard-extdiff.',dir=root/'.test-tmp'))
log=[]
def run(args,**kw):
    p=subprocess.run(args,capture_output=True,text=True,**kw)
    log.append('$ '+str(args)+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
    return p
try:
    run(['git','init','-q',str(lab)])
    (lab/'bin').mkdir()
    marker=lab/'external-watcher-executed'
    watcher=lab/'bin/fm-watch.sh'
    watcher.write_text('#!/bin/sh\nprintf "invoked through git diff\\n" > "'+str(marker)+'"\n')
    watcher.chmod(0o700)
    (lab/'before').write_text('before\n'); (lab/'after').write_text('after\n')
    run(['git','-C',str(lab),'config','diff.external',str(watcher)])
    command='for f in bin/fm-watch.sh; do git diff --no-index --ext-diff before after; done'
    current=run([str(root/'bin/fm-arm-pretool-check.sh'),'--claude','--command',command])
    # Execute exactly what the real gate admitted, in the disposable repository.
    if current.returncode == 0:
        run(['bash','-c',command],cwd=lab)
    base=lab/'base-policy.mjs'
    base.write_text(subprocess.check_output(['git','show','415ba24ad758986931bedaa018ad9a8826a905cf:bin/fm-arm-command-policy.mjs'],text=True))
    old=run(['node',str(base),'--root',str(root),'--home',str(lab),'--command',command])
    result={'current_guard_exit':current.returncode,'external_watcher_executed':marker.exists(),'base_policy':old.stdout.strip(),'command':command}
    log.append(json.dumps(result,indent=2))
    assert current.returncode == 0 and marker.exists() and old.stdout.startswith('deny'),result
    print(json.dumps(result,indent=2))
finally:
    (ev/'round2-guard-external-diff.txt').write_text('\n'.join(log))
    shutil.rmtree(lab)
