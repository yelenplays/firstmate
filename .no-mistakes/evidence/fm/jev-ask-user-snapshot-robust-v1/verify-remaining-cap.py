"""Reproduce the reported mechanical cap failure through the executable CLI.
Compare the submitted base and target on identical realistic repeated contracts.
No fake Jev transport or sender is installed; these checks stop before transport.
"""
import json, os, pathlib, subprocess
ROOT=pathlib.Path.cwd()
EVID=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5EV9GH4T0RZM94ACQ6Y8XTG')
TMP=pathlib.Path((ROOT/'.jev-validation-root').read_text().strip())
HOME=TMP/'home'
base_script=ROOT/'bin/.jev-base-validation.sh'
base=subprocess.run(['git','show','77517e0de3c83c5249361cb8caaf175d9ddd240a:bin/fm-jev-ask-user.sh'],capture_output=True,text=True,check=True).stdout
base_script.write_text(base)
base_script.chmod(0o755)
env=dict(os.environ,FM_HOME=str(HOME))
for k in list(env):
    if (k.startswith('FM_') and k.endswith('_OVERRIDE')) or k in ['FM_GATE_REFUSE_BYPASS','FM_JEV_ASK_USER_SEND']:
        env.pop(k,None)
rows=[]
try:
    for name,old,shape,long in [('base-json',True,'json',False),('base-toon-overcap',True,'toon',True),('target-json-overcap',False,'json',True),('target-toon-overcap',False,'toon',True)]:
        task=HOME/'data'/name;task.mkdir()
        gate='nm-01M4TEST0000000000000000AB-ci'
        brief="""# Task
## Captain's intent
Make the parser preserve every field on a final line without a newline.
"""+('The parser must preserve empty fields and field ordering on valid input.\n'*180 if long else '')+"""
## Firstmate spec
- Fix bin/parse.sh to preserve every field and add a regression test.
"""+('The parser must preserve empty fields and field ordering on valid input.\n'*180 if long else '')+'\n# Setup\n'
        (task/'brief.md').write_text(brief)
        row={'id':'ci-1','severity':'error','action':'ask-user','description':'The first CI run failed on a flaky network fetch; the replacement run is green. Refresh the delivery evidence to refer to the passing replacement run.'}
        snapshot=task/'findings.txt'
        snapshot.write_text(json.dumps({'findings':[row]}) if shape=='json' else 'findings[1]{id,severity,action,description}:\n  ci-1,error,ask-user,'+json.dumps(row['description'])+'\n')
        status=HOME/'state'/(name+'.status')
        status.write_text(f'needs-decision [key={gate}]: ask-user findings=ci-1 file={snapshot}\n')
        (HOME/'state'/(name+'.meta')).write_text('kind=ship\nmode=no-mistakes\nproject='+str(HOME/'projects/sample')+'\n')
        before=(HOME/'state'/'jev-ask-user.jsonl').read_text().splitlines()
        p=subprocess.run([str(base_script if old else ROOT/'bin/fm-jev-ask-user.sh'),name,gate,'--round','1'],env=env,capture_output=True,text=True,timeout=60)
        after=(HOME/'state'/'jev-ask-user.jsonl').read_text().splitlines()
        result={'name':name,'version':'base' if old else 'target','snapshot_format':shape,'brief_bytes':len(brief.encode()),'finding':row,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'new_metadata':[json.loads(x) for x in after[len(before):]],'decision_status':status.read_text()}
        rows.append(result)
        print(json.dumps(result),flush=True)
finally:
    base_script.unlink(missing_ok=True)
    (EVID/'remaining-cap-regression.json').write_text(json.dumps(rows,indent=2)+'\n')
