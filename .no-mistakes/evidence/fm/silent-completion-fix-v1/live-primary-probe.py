import json, os, pathlib, shlex, subprocess, time
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5D5CHGG2K8HYYGHVZ4GNMW7')
lab=root/'.local-test-tmp'/'primary-home'
state=root/'.local-test-tmp'/'herdr-lab-state'
env=os.environ.copy()
env['FM_HERDR_LAB_STATE_DIR']=str(state)
helper=str(root/'bin/fm-herdr-lab.sh')
log=(evidence/'live-primary-probe.log').open('w')
session=subprocess.check_output([helper,'name','completion'],text=True,env=env).strip()
prepared=False

def run(args,timeout=30,check=True):
    log.write('$ '+shlex.join(args)+'\n'); log.flush()
    p=subprocess.run(args,capture_output=True,text=True,env=env,timeout=timeout)
    log.write(p.stdout+p.stderr+'\nexit='+str(p.returncode)+'\n'); log.flush()
    if check and p.returncode: raise RuntimeError('command failed: '+shlex.join(args))
    return p.stdout

def h(*args,**kw):return run([helper,'run',session,*args],**kw)

def screen(pane, label):
    out=h('pane','read',pane,'--source','visible','--format','text')
    (evidence/(label+'.json')).write_text(out)
    return out

try:
    run([str(root/'bin/fm-lab-home.sh'),'create',str(lab)])
    (lab/'config'/'supervision-host').touch()
    prepared=True
    run([helper,'provision',session],timeout=90)
    run([helper,'viewer','start',session],timeout=20)
    creation=json.loads(h('workspace','create','--cwd',str(root),'--label','completion-primary','--env','FM_HOME='+str(lab),'--no-focus'))
    pane=creation['result']['root_pane']['pane_id']
    command='env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='+shlex.quote(str(lab))+' claude'
    h('pane','run',pane,command)
    time.sleep(12)
    text=screen(pane,'primary-startup')
    # The only prompt we may answer is this disposable working directory's trust dialog.
    if 'trust this folder' in text.lower() or 'trust this project' in text.lower() or 'Yes, I trust this folder' in text:
        h('pane','send-keys',pane,'enter')
        time.sleep(12)
        text=screen(pane,'primary-after-trust')
    # Never answer a login prompt or change account preferences.
    if any(x in text for x in ['Select login method','Sign in to Claude','Log in with your Claude account']):
        log.write('UNTESTED: existing login unavailable; no login action taken.\n')
    elif '❯' in text:
        prompt='This is an isolated completion-delivery validation lab, not the operator fleet. For this probe only, do not run commands, spawn agents, initialize anything, or change files. Reply exactly LAB_PRIMARY_READY. The tracked startup and stop hooks should run normally.'
        h('pane','send-text',pane,prompt)
        h('pane','send-keys',pane,'enter')
        h('pane','wait-output',pane,'--match','LAB_PRIMARY_READY','--source','recent-unwrapped','--timeout','90000',timeout=95,check=False)
        time.sleep(5)
        screen(pane,'primary-after-prompt')
    else:
        log.write('UNTESTED: no ready primary prompt was established.\n')
    files=sorted(str(p.relative_to(lab)) for p in lab.rglob('*') if p.is_file())
    log.write('LAB FILES: '+json.dumps(files)+'\n')
    for name in ['.host-mirror.jsonl','.supervision-host','.supervision-host.log','.watcher-pi','.pi-branch-extension-loaded','.lock']:
        p=lab/'state'/name
        if p.exists():
            (evidence/('primary-state-'+name.lstrip('.'))).write_bytes(p.read_bytes())
    # Probe the real primary scope predicate without fabricating hook input.
    run(['bash','-c','. bin/fm-primary-scope-lib.sh; if fm_primary_scope_matches "$PWD" "$1/state"; then echo PRIMARY_SCOPE_ACCEPTED; else echo PRIMARY_SCOPE_REFUSED; fi','_',str(lab)])
finally:
    if prepared:
        try: run([helper,'teardown',session],timeout=30,check=False)
        except Exception as e: log.write('TEARDOWN ERROR '+str(e)+'\n')
    # Remove only the lab home this process minted, after the guarded session teardown.
    import shutil
    if lab.exists():shutil.rmtree(lab)
    log.close()
