import subprocess,pathlib,json,os,shutil
r=pathlib.Path.cwd(); e=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5CSAEF80R6DCD8ED5DJSSM3')
log=[]
arm=[(True,'for f in bin/fm-watch.sh bin/fm-send.sh; do git cat-file -s HEAD:$f; done'),(True,'while read -r f; do wc -l "$f"; done <<< bin/fm-watch.sh'),(True,'if grep -q x bin/fm-watch-arm.sh; then echo yes; else echo no; fi'),(True,'cat bin/fm-watch.sh | wc -l'),(False,'for f in bin/fm-watch.sh; do bash "$f"; done'),(False,'for f in bin/fm-watch.sh; do "$f"; done'),(False,'for f in bin/fm-watch.sh; do cat "$f" | sh; done'),(False,'if true; then bin/fm-watch-arm.sh; fi'),(False,'while true; do pkill -f fm-watch; done'),(False,'bin/fm-watch-arm.sh &'),(False,'for PAGER in bin/fm-watch.sh; do git log; done')]
for allowed,cmd in arm:
 p=subprocess.run(['bin/fm-arm-pretool-check.sh','--claude','--command',cmd],capture_output=True,text=True)
 log.append(f'$ fm-arm-pretool-check.sh --claude --command {cmd!r}\nexit={p.returncode}\n{p.stderr}')
 assert p.returncode==(0 if allowed else 2),log[-1]
 if allowed:
  q=subprocess.run(['bash','-c',cmd],capture_output=True,text=True,timeout=15)
  log.append(f'Allowed read executed: exit={q.returncode}\n{q.stdout[:500]}')
  assert q.returncode==0
# Public classifier interface, with real existing directory resolution and symlink.
home=r/'.validation-guard-home'; home.mkdir(); (home/'child').mkdir(); alias=r/'.validation-guard-alias'; alias.symlink_to(home, target_is_directory=True)
try:
 cases=[(True,f'cd {home}'),(True,f'cd {home}/child/.. && pwd'),(True,f'cd {alias}'),(False,f'cd {home}/child'),(False,f'cd {home} && cd {home}/child'),(False,f'pushd {home}'),(False,'cd "$FM_HOME"'),(False,f'cd -P {home}')]
 for allowed,cmd in cases:
  p=subprocess.run(['node','bin/fm-cd-command-policy.mjs','--home',str(home),'--command',cmd],capture_output=True,text=True)
  log.append(f'$ fm-cd-command-policy.mjs --home <isolated home> --command {cmd!r}\nexit={p.returncode}\n{p.stdout}')
  assert p.stdout.startswith('allow' if allowed else 'deny'),log[-1]
  if allowed:
   q=subprocess.run(['bash','-c',cmd+'; pwd -P'],capture_output=True,text=True)
   assert q.returncode==0 and q.stdout.splitlines()[-1]==str(home)
   log.append('Executed allowed cd; resolved cwd='+q.stdout.strip())
finally:
 alias.unlink(); shutil.rmtree(home)
(e/'live-guard-decisions.txt').write_text('\n'.join(log))
print('Public guard interfaces preserved safe reads and home resolution, and denied executable watcher and cwd-leak attempts.')
