"""Use the real resolver, real quota tool and configured-default route; no network response fixtures."""
import json, os, pathlib, shutil, subprocess, tempfile
root=pathlib.Path.cwd(); base=pathlib.Path(tempfile.mkdtemp(prefix='.test-dispatch-',dir=root))
env=dict(os.environ)
for k in list(env):
    if k.startswith('FM_') or k in ('CLAUDE_CONFIG_DIR','NM_HOME'):
        env.pop(k)
env.update(FM_HOME=str(base), FM_SPEND_SESSIONS=str(base/'sessions'), FM_SPEND_CLAUDE_SESSIONS=str(base/'claude-sessions'))
try:
    for name in ('config','data','state','sessions','claude-sessions','other-pool'): (base/name).mkdir()
    (base/'brief.md').write_text('# Task\nCheck an isolated local calculator addition.\n')
    (base/'config/crew-dispatch.json').write_text(json.dumps({'rules':[], 'default':{'harness':'claude','model':'claude-opus-5-5','effort':'medium'}}))
    for pin in ('ordinary',str(base/'other-pool')):
        (base/'config/claude-account').write_text(pin+'\n')
        argv=[str(root/'bin/fm-dispatch-resolve.sh'),str(base/'brief.md')]
        print('$', ' '.join(argv), 'pool='+('ordinary' if pin=='ordinary' else 'custom'),flush=True)
        p=subprocess.run(argv,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=150)
        print(p.stdout,end='',flush=True); print('exit:',p.returncode,flush=True)
        p.check_returncode()
        if pin != 'ordinary':
            assert 'quota and runway unknown' in p.stdout,p.stdout
            assert 'profile:' in p.stdout and '--effort' in p.stdout,p.stdout
            print('Verified: actual quota snapshot cannot rank or refuse the unmatched custom Claude pool.',flush=True)
finally:
    shutil.rmtree(base); print('Disposable dispatch home removed.',flush=True)
