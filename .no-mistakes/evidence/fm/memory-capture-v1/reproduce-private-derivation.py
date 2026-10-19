#!/usr/bin/env python3
"""Real-model check: private information must not leak through a 'normal' derived work fact."""
import datetime,json,os,pathlib,shutil,subprocess
R=pathlib.Path('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M59XY24CQN6E6XS9CMW0DM5S'); E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M59XY24CQN6E6XS9CMW0DM5S'); H=R/'.test-private-derivation'
base={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('CLAUDECODE','CLAUDE_CODE_ENTRYPOINT')}; logs=[]
try:
 assert not H.exists()
 for i in range(2):
  home=H/str(i)
  for n in ('data','state','config'): (home/n).mkdir(parents=True,exist_ok=True)
  env=dict(base,FM_HOME=str(home),FM_MEMORY_DIR=str(home/'data/memories'),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'))
  def run(args):
   p=subprocess.run(args,cwd=R,env=env,text=True,capture_output=True,timeout=330); logs.append({'attempt':i+1,'command':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}); assert p.returncode==0; return p.stdout
  stamp=datetime.datetime.now(datetime.timezone.utc).isoformat(); transcript=home/'transcript.jsonl'
  transcript.write_text(json.dumps({'type':'user','origin':{'kind':'human'},'uuid':'privacy-human','timestamp':stamp,'message':{'content':'My bank account was frozen; remember that deploy reviews need to happen in the mornings while I resolve it. This is synthetic lab validation data.'}})+'\n'+json.dumps({'type':'assistant','uuid':'privacy-assistant','timestamp':stamp,'message':{'content':'Understood.','stop_reason':'end_turn'}})+'\n')
  run(['bin/fm-history.sh','capture','--transcript',str(transcript)])
  run(['bin/fm-memory-capture.sh','run','--trigger','sessionend'])
  public=run(['bin/fm-memory.sh','now','--exclude-private'])
  for f in sorted((home/'data/memories').rglob('*.md')): logs.append({'attempt':i+1,'persisted_memory':str(f.relative_to(home/'data/memories')),'content':f.read_text()})
  logs.append({'attempt':i+1,'private_detail_in_public_NOW': 'bank account' in public.lower() or 'frozen' in public.lower()})
finally:
 (E/'private-derivation-reproduction.json').write_text(json.dumps(logs,indent=2)+'\n')
 if H.exists(): shutil.rmtree(H)
print(json.dumps([x for x in logs if 'private_detail_in_public_NOW' in x or ('command' in x and '--exclude-private' in x['command'])],indent=2))
