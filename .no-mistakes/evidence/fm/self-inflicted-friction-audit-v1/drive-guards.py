import os,pathlib,subprocess,json,shutil
root=pathlib.Path.cwd(); e=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5D7YE13PRVV1C15C2Y5MH6V'); lab=root/'.live-guards'
lab.mkdir(); (lab/'projects'/'other').mkdir(parents=True); (lab/'AGENTS.md').write_text('Isolated primary guard validation.\n'); (lab/'bin').symlink_to(root/'bin',target_is_directory=True); (lab/'home-link').symlink_to(lab,target_is_directory=True)
subprocess.run(['git','init','-q',str(lab)],check=True)
env=os.environ.copy(); env.update(FM_HOME=str(lab),FM_ROOT_OVERRIDE=str(lab)); rows=[]; failures=[]
def check(kind,command,expected):
    p=subprocess.run([str(root/'bin'/f'fm-{kind}-pretool-check.sh'),'--claude','--command',command],env=env,cwd=lab,text=True,capture_output=True)
    rows.append({'guard':kind,'command':command,'exit':p.returncode,'stderr':p.stderr,'stdout':p.stdout})
    if p.returncode!=expected: failures.append((command,p.returncode,expected))
try:
    for command in [f'cd {lab}',f'cd {lab}/projects/..',f'cd {lab}/home-link',f'cd "{lab}" && git status --short',f'cd -- "{lab}"',f'cd -- "{lab}" && git status --short']:
        check('cd',command,0)
    for command in [f'cd {lab}/projects/other',f'cd {lab}; cd projects/other',f'cd {lab}/home-link/projects/other','cd ..']:
        check('cd',command,2)
    for command in ['wc -c bin/fm-watch-arm.sh; printf done','grep -n watcher bin/fm-watch-arm.sh; printf done','cat bin/fm-watch-arm.sh; printf done','git cat-file -s HEAD:bin/fm-watch-arm.sh; printf done','for f in bin/fm-watch.sh bin/fm-watch-arm.sh; do wc -c "$f"; done','for f in bin/fm-watch-arm.sh; do git cat-file -s HEAD:$f; done','while read -r f; do grep watcher "$f"; done < bin/fm-watch.sh']: 
        check('arm',command,0)
    for command in ['bin/fm-watch-arm.sh; printf done','bash bin/fm-watch-arm.sh; printf done','pkill -f bin/fm-watch.sh','for f in bin/fm-watch-arm.sh; do bash "$f"; done','cat "$(bash bin/fm-watch-arm.sh)"; printf done']:
        # Executed substitutions and dynamic script invocations must never reach shell.
        check('arm',command,2)
finally:
    (e/'guards-live.json').write_text(json.dumps(rows,indent=2)); shutil.rmtree(lab)
print(f'{len(rows)} real pretool invocations, primary repository scope and adversarial execution/cwd boundaries; mismatches: {failures}')
assert not failures,failures
