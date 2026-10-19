#!/usr/bin/env python3
import datetime,json,os,pathlib,shutil,subprocess,time
R=pathlib.Path('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M59XY24CQN6E6XS9CMW0DM5S'); E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M59XY24CQN6E6XS9CMW0DM5S'); H=R/'.test-replay-lock'
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('CLAUDECODE','CLAUDE_CODE_ENTRYPOINT')}; env.update(FM_HOME=str(H),FM_MEMORY_DIR=str(H/'data/memories'),FM_STATE_OVERRIDE=str(H/'state'),FM_DATA_OVERRIDE=str(H/'data'),FM_CONFIG_OVERRIDE=str(H/'config'))
logs=[]; p=None
def run(args):
 p=subprocess.run(args,cwd=R,env=env,text=True,capture_output=True,timeout=330); logs.append({'command':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}); return p
try:
 assert not H.exists()
 for name in ('data','state','config'): (H/name).mkdir(parents=True,exist_ok=True)
 stamp=datetime.datetime.now(datetime.timezone.utc).isoformat(); transcript=H/'transcript.jsonl'
 transcript.write_text(json.dumps({'type':'user','origin':{'kind':'human'},'uuid':'replay-lock-human','timestamp':stamp,'message':{'content':'My bank account was frozen; remember that deploy reviews need to happen in the mornings while I resolve it. This is synthetic lab validation data.'}})+'\n'+json.dumps({'type':'assistant','uuid':'replay-lock-assistant','timestamp':stamp,'message':{'content':'Understood.','stop_reason':'end_turn'}})+'\n')
 assert run(['bin/fm-history.sh','capture','--transcript',str(transcript)]).returncode==0
 with (E/'no-watermark-holder.stdout').open('w') as out, (E/'no-watermark-holder.stderr').open('w') as err:
  p=subprocess.Popen(['bin/fm-memory-capture.sh','run','--no-watermark'],cwd=R,env=env,text=True,stdout=out,stderr=err)
  lock=H/'state/memory-capture/lock/pid'; pending=H/'state/memory-capture/pending'
  until=time.monotonic()+10
  while not lock.exists() and p.poll() is None and time.monotonic()<until: time.sleep(.01)
  assert lock.exists() and p.poll() is None
  owner=lock.read_text(); assert not pending.exists()
  replay=run(['bin/fm-memory-capture.sh','run','--no-watermark']); assert replay.returncode==1
  assert not pending.exists() and lock.read_text()==owner
  dry=run(['bin/fm-memory-capture.sh','run','--dry-run']); assert dry.returncode==0
  assert not pending.exists() and lock.read_text()==owner
  assert p.poll() is None
  logs.append({'real_model_holder_active':True,'concurrent_replay_refused_without_pending':True,'concurrent_dry_run_succeeded_without_lock_change_or_pending':True})
  assert p.wait(timeout=330)==0
 assert not (H/'state/memory-capture/watermark.json').exists()
 logs.append({'no_watermark_preserved_after_real_replay':True,'jev_audit_exists':(H/'state/jev-calls.jsonl').exists()})
 assert run(['bin/fm-memory.sh','now']).returncode==0
 assert run(['bin/fm-memory.sh','now','--exclude-private']).returncode==0
 assert run(['bin/fm-memory-capture.sh','run','--trigger','sessionend']).returncode==0
 logs.append({'final_watermark':json.loads((H/'state/memory-capture/watermark.json').read_text()),'jev_audit_exists':(H/'state/jev-calls.jsonl').exists()})
finally:
 if p and p.poll() is None: p.terminate(); p.wait(timeout=10)
 (E/'replay-lock.json').write_text(json.dumps(logs,indent=2)+'\n')
 if H.exists(): shutil.rmtree(H)
print(json.dumps(logs,indent=2))
