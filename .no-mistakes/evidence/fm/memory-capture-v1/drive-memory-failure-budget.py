#!/usr/bin/env python3
import datetime,json,os,pathlib,shutil,subprocess
R=pathlib.Path('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M59XY24CQN6E6XS9CMW0DM5S'); E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M59XY24CQN6E6XS9CMW0DM5S'); H=R/'.test-memory-failure'
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('CLAUDECODE','CLAUDE_CODE_ENTRYPOINT')}; env.update(FM_HOME=str(H),FM_MEMORY_DIR=str(H/'data/store'),FM_STATE_OVERRIDE=str(H/'state'),FM_DATA_OVERRIDE=str(H/'data'),FM_CONFIG_OVERRIDE=str(H/'config'))
logs=[]
def run(args,**kwargs):
 p=subprocess.run(args,cwd=R,env=env,text=True,capture_output=True,timeout=330,**kwargs); logs.append({'command':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}); return p
try:
 assert not H.exists()
 for name in ('data','state','config'): (H/name).mkdir(parents=True,exist_ok=True)
 transcript=H/'transcript.jsonl'; stamp=datetime.datetime.now(datetime.timezone.utc).isoformat()
 transcript.write_text(json.dumps({'type':'user','origin':{'kind':'human'},'uuid':'lab-write-failure','timestamp':stamp,'message':{'content':'From now on always format my release notes as plain text, never HTML.'}})+'\n'+json.dumps({'type':'assistant','uuid':'lab-write-failure-r','timestamp':stamp,'message':{'content':'Understood.','stop_reason':'end_turn'}})+'\n')
 assert run(['bin/fm-history.sh','capture','--transcript',str(transcript)]).returncode==0
 # A file where the store directory should be is a real, reversible write failure.
 (H/'data/store').write_text('Deliberate path collision for verification.\n')
 for attempt in (1,2):
  p=run(['bin/fm-memory-capture.sh','run','--trigger','sessionend']); assert p.returncode!=0
  assert not (H/'state/memory-capture/watermark.json').exists()
  rec=json.loads(p.stdout); assert not rec['ok'] and 'remember failed' in rec['why']
  logs.append({'write_failure_attempt':attempt,'watermark_exists':False})
 status=H/'state/memory-capture.status'; assert status.read_text().count('failed [at=')==1
 logs.append({'failure_status':status.read_text()})
 (H/'data/store').unlink()
 p=run(['bin/fm-memory-capture.sh','run','--trigger','sessionend']); assert p.returncode==0
 assert json.loads((H/'state/memory-capture/watermark.json').read_text())['id']=='lab-write-failure'
 assert 'resolved [at=' in status.read_text()
 logs.append({'recovered_status':status.read_text(),'watermark':json.loads((H/'state/memory-capture/watermark.json').read_text())})
 assert run(['bin/fm-memory.sh','recall','--json','release notes plain text']).returncode==0
 # Bound the complete real NOW output, including its omission notice.
 for i in range(18):
  assert run(['bin/fm-memory.sh','remember','--category','now','--expires','2999-01-01','Current lab focus '+str(i),'A detailed current focus. '*35]).returncode==0
 assert run(['bin/fm-memory.sh','remember','--category','now','--expires','2000-01-01','Expired lab sentinel','EXPIRED-SENTINEL']).returncode==0
 assert run(['bin/fm-memory.sh','remember','--category','now','--expires','2999-01-01','--sensitivity','private','Private lab sentinel','PRIVATE-SENTINEL']).returncode==0
 now=run(['bin/fm-memory.sh','now']); assert len(now.stdout)<=6000 and 'EXPIRED-SENTINEL' not in now.stdout
 public=run(['bin/fm-memory.sh','now','--exclude-private']); assert len(public.stdout)<=6000 and 'PRIVATE-SENTINEL' not in public.stdout and 'EXPIRED-SENTINEL' not in public.stdout
 logs.append({'complete_now_characters':len(now.stdout),'public_now_characters':len(public.stdout),'expired_entry_omitted':True,'private_entry_omitted_from_public':True})
finally:
 (E/'memory-failure-budget.json').write_text(json.dumps(logs,indent=2)+'\n')
 if H.exists(): shutil.rmtree(H)
print(json.dumps([x for x in logs if 'command' not in x],indent=2))
