import os, pathlib, subprocess, time, json
root=pathlib.Path.cwd(); lab=root/'.test-runtime'; evidence=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M2XZP7TZP7BX3XKCJW5VH6H6')
shim=lab/'routing'; shim.mkdir(exist_ok=True)
(shim/'tmux').write_text('#!/bin/sh\nexec /opt/homebrew/bin/tmux -S "'+str(root/'.test-socket')+'" "$@"\n'); (shim/'tmux').chmod(0o755)
results=[]
def env_for(home):
 e={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_'))}; e.update(FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_GATE_REFUSE_BYPASS='1',FM_POLL='1',FM_SIGNAL_GRACE='10',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',TMPDIR=str(lab),PATH=str(shim)+':'+os.environ['PATH']);return e
def run(args,e):
 p=subprocess.run(args,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40);return p.returncode,p.stdout
def home_for(name):
 h=lab/name
 for d in ['state','data','config']: (h/d).mkdir(parents=True,exist_ok=True)
 (h/'config/backend').write_text('tmux\n');(h/'config/backlog-backend').write_text('manual\n');return h
for task in ['task-x1','release.v1']:
 h=home_for('live-'+task);e=env_for(h);s=h/'state'
 (s/(task+'.meta')).write_text(f'window=firstmate:fm-{task}\nendpoint_task_id={task}\nbackend=tmux\nworktree={h}/already-returned\nproject={h}/absent-project\nkind=ship\nmode=local-only\nspawn_gen=live-{task}\n')
 (s/(task+'.turn-ended')).touch(); marker=s/('.seen-'+(task+'.turn-ended').replace('.','_'));marker.touch();(s/'.last-watcher-beat').touch()
 with open(evidence/(task+'-watch.log'),'w') as out:
  w=subprocess.Popen([str(root/'bin/fm-watch.sh')],env=e,stdout=out,stderr=subprocess.STDOUT)
  captured=False
  for _ in range(150):
   ps=subprocess.check_output(['ps','-axo','ppid=,command='],text=True)
   if any(line.strip().startswith(str(w.pid)+' ') and 'sleep 10' in line for line in ps.splitlines()):captured=True;break
   if w.poll() is not None:break
   time.sleep(.1)
  assert captured,'watcher did not enter real signal grace'
  rc,txt=run([str(root/'bin/fm-teardown.sh'),task],e);(evidence/(task+'-teardown.log')).write_text(txt);assert rc==0,txt
  (s/'live.turn-ended').touch()
  try:w.wait(timeout=35)
  except: w.terminate();w.wait();raise
 log=(evidence/(task+'-watch.log')).read_text();rc,drain=run([str(root/'bin/fm-wake-drain.sh')],e)
 (evidence/(task+'-drain.log')).write_text(drain)
 assert 'live.turn-ended' in log and task+'.turn-ended' not in log+drain,log+drain
 assert not marker.exists() and not (s/(task+'.turn-ended')).exists() and not (s/(task+'.meta')).exists()
 results.append(dict(task=task,grace_observed=True,teardown=txt,watch=log,drain=drain,retired_marker_exists=marker.exists(),live_marker_exists=(s/'.seen-live_turn-ended').exists()))
(evidence/'live-results.json').write_text(json.dumps(results,indent=2));print(json.dumps(results,indent=2))
