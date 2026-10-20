import os, pathlib, shutil, subprocess, tempfile
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5DHR1T6KYVV9PN7CDD65ME0')
lab=pathlib.Path(tempfile.mkdtemp(prefix='guard-',dir=root/'.test-tmp'))
log=(evidence/'live-guard-transcript.log').open('w')
env=os.environ.copy()
for k in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE'):
    env.pop(k,None)
try:
    subprocess.run(['git','init','-q',str(lab)],check=True)
    (lab/'bin').mkdir(); (lab/'projects/foo').mkdir(parents=True)
    (lab/'AGENTS.md').touch()
    for name in ['fm-cd-pretool-check.sh','fm-cd-command-policy.mjs','fm-arm-command-policy.mjs','fm-hook-host-lib.sh']:
        shutil.copy2(root/'bin'/name,lab/'bin'/name)
    home_alias=lab/'home-alias'; home_alias.symlink_to(lab,target_is_directory=True)
    def check(cmd,allow,guard,cwd,extra=None):
        e=env.copy(); e.update(extra or {})
        p=subprocess.run([str(guard),'--command',cmd],cwd=cwd,env=e,capture_output=True,text=True)
        log.write(f'$ {guard.name} --command {cmd!r}\nexit={p.returncode}\nstdout={p.stdout}\nstderr={p.stderr}\n')
        assert p.returncode==(0 if allow else 2),(cmd,p.returncode,p.stdout,p.stderr)
        return e
    for cmd in [f'cd {lab}',f'cd -- {lab}',f'cd {lab}/bin/..',f'command cd -- {home_alias}']:
        e=check(cmd,True,lab/'bin/fm-cd-pretool-check.sh',lab/'projects/foo',{'FM_HOME':str(lab)})
        p=subprocess.run(['bash','-c',cmd+'; pwd -P'],cwd=lab/'projects/foo',env=e,capture_output=True,text=True,check=True)
        log.write('Executed permitted command; resulting cwd: '+p.stdout)
        assert pathlib.Path(p.stdout.strip())==lab
    for cmd in ['cd projects/foo',f'cd {lab}/bin',f'cd -- {lab} && cd projects/foo',f'cd -P {lab}','cd "$FM_HOME"',f'pushd {lab}']:
        check(cmd,False,lab/'bin/fm-cd-pretool-check.sh',lab,{'FM_HOME':str(lab)})
    # Read real tracked watcher files as data through the executable guard.
    allowed=['for f in bin/fm-watch.sh bin/fm-send.sh; do git cat-file -s HEAD:$f; done',
             'wc -l bin/fm-watch.sh',
             'grep -n -m 1 "#!/" bin/fm-watch.sh',
             'cat bin/fm-watch.sh >/dev/null',
             'while read -r f; do echo "$f" >/dev/null; done < bin/fm-watch.sh']
    for cmd in allowed:
        e=check(cmd,True,root/'bin/fm-arm-pretool-check.sh',root,{'FM_HOME':str(lab)})
        p=subprocess.run(['bash','-c',cmd],cwd=root,env=e,capture_output=True,text=True,check=True)
        log.write('Executed permitted read; output: '+p.stdout+'\n')
    for cmd in ['bin/fm-watch.sh','bin/fm-watch-arm.sh &','pkill -f bin/fm-watch.sh',
                'for f in bin/fm-watch.sh; do bash "$f"; done',
                'for f in bin/fm-watch.sh; do cat "$f" | sh; done',
                'for f in bin/fm-watch.sh; do echo "${BASH_CMDS[cat]:=$f}"; cat; done',
                'for f in bin/fm-watch.sh; do git diff --ext-diff; done']:
        check(cmd,False,root/'bin/fm-arm-pretool-check.sh',root,{'FM_HOME':str(lab)})
    log.write('All permitted home returns and data reads executed; all unsafe candidates were refused without execution.\n')
finally:
    log.close(); shutil.rmtree(lab)
