import json, os, subprocess, time
from pathlib import Path
root=Path.cwd()
home=root/'.test-outcome-home'
evidence=Path('/Users/yelen/.no-mistakes/evidence/01M5CSNV4CBJJ0M8YPZZK3BZXV')
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
 env.pop(k,None)
env['FM_HOME']=str(home)
log=[]
def run(*args,extra=None):
 e=env.copy(); e.update(extra or {})
 p=subprocess.run([str(root/'bin/fm-branch-outcome.sh'),*args],env=e,text=True,capture_output=True,timeout=20)
 log.append({'command':['fm-branch-outcome.sh',*args],'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
 assert p.returncode==0,p.stderr
 return p.stdout.strip()
initial=json.loads(run('lookup','--seqs','1'))
assert initial['verdict']=='captain',initial
for task,silent in [('license-bench','true'),('fleet','false'),('never-launched','false')]:
 seq=run('append','--promote-finished','--task',task,'--verdict','routine','--summary','No new result','--silent',silent)
 assert json.loads(run('lookup','--seqs',seq))['verdict']=='routine'
# A retired task still has its actual report but no active metadata or status.
(home/'data/license-bench').mkdir(parents=True,exist_ok=True)
(home/'state/license-bench.meta').unlink()
(home/'state/license-bench.status').unlink()
seq=run('append','--promote-finished','--task','license-bench','--verdict','routine','--summary',initial['summary'])
assert json.loads(run('lookup','--seqs',seq))['verdict']=='captain'
# Deliberately hung dependency, NOT a live model or end-to-end chat check.
hung=home/'hung-crew-state.sh'; hung.write_text('#!/bin/bash\nexec sleep 30\n'); hung.chmod(0o755)
(home/'state/hung-task.meta').write_text('kind=scout\n')
start=time.monotonic()
seq=run('append','--promote-finished','--task','hung-task','--verdict','routine','--summary','Dependency timeout must not block durable reporting',extra={'FM_CREW_STATE_BIN':str(hung)})
elapsed=time.monotonic()-start
assert 9<=elapsed<16,elapsed
assert json.loads(run('lookup','--seqs',seq))['verdict']=='routine'
log.append({'dependency_timeout_elapsed_seconds':round(elapsed,2),'contract':'Visible routine outcomes remain durable without an unbounded crew-state dependency; timed-out state is not promoted.'})
(evidence/'outcome-cli-probes.json').write_text(json.dumps(log,indent=2)+'\n')
print('Public outcome CLI preserved completion promotion, silence/progress boundaries, and bounded dependency failure.')
