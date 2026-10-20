import pathlib,subprocess,tempfile,shutil,json
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5CSAEF80R6DCD8ED5DJSSM3'); H=pathlib.Path(tempfile.mkdtemp(prefix='.validation-round3-diff-',dir=R)); log=[]
def run(args,cwd=None):
 p=subprocess.run(args,cwd=cwd,capture_output=True,text=True)
 log.append('$ '+repr(args)+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
 return p
try:
 run(['git','init','-q',str(H)])
 (H/'bin').mkdir(); marker=H/'executed'; watcher=H/'bin/fm-watch.sh'
 watcher.write_text('#!/bin/sh\nprintf "invoked through external diff\\n" > "'+str(marker)+'"\n'); watcher.chmod(0o700)
 (H/'before').write_text('before\n');(H/'after').write_text('after\n')
 run(['git','-C',str(H),'config','diff.external',str(watcher)])
 cmd='for f in bin/fm-watch.sh; do git diff --no-index --ext-diff before after; done'
 run(['bash','-c',cmd],cwd=H); assert marker.exists()
 log.append('Without guard external program wrote: '+marker.read_text());marker.unlink()
 p=run([str(R/'bin/fm-arm-pretool-check.sh'),'--claude','--command',cmd]); assert p.returncode==2
 if p.returncode==0:run(['bash','-c',cmd],cwd=H)
 assert not marker.exists();log.append('After guarded attempt: external execution marker absent.')
 run(['git','-C',str(H),'add','bin/fm-watch.sh']);tree=run(['git','-C',str(H),'write-tree']).stdout.strip()
 cmd=f'for f in bin/fm-watch.sh; do git cat-file -s {tree}:$f; done'
 p=run([str(R/'bin/fm-arm-pretool-check.sh'),'--claude','--command',cmd]);assert p.returncode==0
 p=run(['bash','-c',cmd],cwd=H);assert p.returncode==0 and int(p.stdout.strip())==watcher.stat().st_size
 log.append('Allowed size probe matched actual file bytes; external execution marker remains absent: '+str(not marker.exists()))
 print('External-diff execution denied; benign Git object-size read allowed and executed.')
finally:
 (E/'round3-guard-external-diff.txt').write_text('\n'.join(log));shutil.rmtree(H)
