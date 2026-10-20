import os, subprocess, pathlib, json
root=pathlib.Path.cwd(); home=root/'.test-tmp/jev-live-home'; home.mkdir()
evidence=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5CZV2BFMDEMPV25T2MSFEWK')
env=dict(os.environ)
for k in ['FM_HOME','FM_TASK_ID','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
    env.pop(k,None)
env['FM_HOME']=str(home); env['TMPDIR']=str(root/'.test-tmp')
log=home/'state/jev-calls.jsonl'
def records(): return [json.loads(x) for x in log.read_text().splitlines()] if log.exists() else []
rows=[]
def invoke(label,args,stdin=None,task=None,refuse=False):
    before=len(records()); e=dict(env)
    if task:e['FM_TASK_ID']=task
    p=subprocess.run(['bin/fm-jev.sh']+args,input=stdin,text=True,capture_output=True,env=e,timeout=50)
    r=records(); added=r[before:]
    row=dict(scenario=label,command=['bin/fm-jev.sh']+args,exit=p.returncode,stdout=p.stdout,stderr=p.stderr,records_appended=added)
    if refuse:
        row['pass']=p.returncode==1 and not p.stdout and len(r)==before and 'caller' in p.stderr
    else:
        row['pass']=p.returncode in (0,2) and len(added)==1 and added[0]['caller']=='test-live' and added[0]['http']=='200' and added[0]['exit']==p.returncode
        if task: row['pass'] &= added[0]['origin']=='task:'+task
        else: row['pass'] &= added[0]['origin']=='home:'+home.name
    rows.append(row); print(json.dumps(row),flush=True)
for sub in ['yes','pick','score','batch']:
    args={'yes':['The room is bright.','Is the room bright?'],'pick':['The room is bright.','Which condition applies?','bright','dark'],'score':['The room is bright.','How bright is the room?','dark','bright'],'batch':[]}[sub]
    invoke('Missing caller refused: '+sub,[sub]+args,stdin='{}' if sub=='batch' else None,refuse=True)
for tag in ['Worker','task:demo','two words','worker\nforged','-worker','a'*41,'']:
    invoke('Invalid caller refused: '+repr(tag),['yes','--caller',tag,'The room is bright.','Is the room bright?'],refuse=True)
invoke('Tagged home yes',['yes','--caller','test-live','The room is bright.','Is the room bright?'])
invoke('Tagged task pick',['pick','--caller=test-live','The room is bright.','Which condition applies?','bright','dark'],task='caller-proof')
invoke('Tagged score',['score','--caller','test-live','The room is very bright.','How bright is the room?','dark','dim','bright'])
invoke('Tagged task batch',['batch','--caller','test-live'],stdin=json.dumps({'state':'The room is bright.','questions':[{'id':'lit','type':'yes','q':'Is the room bright?'},{'id':'condition','type':'pick','q':'Which condition applies?','opts':['bright','dark']},{'id':'brightness','type':'score','q':'How bright is the room?','opts':['dark','dim','bright']}]}),task='caller-batch-proof')
(evidence/'jev-live.json').write_text(json.dumps(rows,indent=2)+'\n')
print('All scenario assertions:',all(x['pass'] for x in rows))
