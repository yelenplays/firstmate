import json, os, pathlib, shutil, subprocess, tempfile
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5EV9GH4T0RZM94ACQ6Y8XTG')
w=pathlib.Path(tempfile.mkdtemp(prefix='.validate-delivery-',dir=ROOT))
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and not k.startswith('HERDR_')}
env['FM_HERDR_LAB_STATE_DIR']=str(w/'lab-state')
helper=str(ROOT/'bin/fm-herdr-lab.sh')
results=[]; session=None; prepared=False

def lab(*args):
    p=subprocess.run([helper,*args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
    print(json.dumps({'lab_command':list(args),'exit':p.returncode,'output':p.stdout}),flush=True)
    if p.returncode: raise RuntimeError('lab command failed: '+str(args))
    return p.stdout
try:
    session=lab('name','ask-json').strip()
    prepared=True
    # provision owns prepare for a fresh session; do not pre-create its tripwire.
    lab('provision',session)
    home=w/'home'
    subprocess.run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(home)],env=env,check=True,stdout=subprocess.PIPE)
    created=json.loads(lab('run',session,'workspace','create','--cwd',str(ROOT),'--label','ask-user-validation','--no-focus'))['result']
    ws=created['workspace']['workspace_id']
    tab=created['tab']['tab_id']; pane=created['root_pane']['pane_id']
    short='Make the parser preserve every field on a final line without a newline.\n'
    detail='The parser must preserve empty fields and field ordering on valid input.\n'*180
    spec='- Fix bin/parse.sh to preserve every field and add a regression test.\n'
    limit='MANDATORY SCOPE LIMIT: This task is documentation-only. Do not edit bin/parse.sh or any production code. Only record the observed bug in docs/parser-known-issues.md. Any production code fix needs a separate explicit decision.\n'
    ordinary='The parser drops the final field on a line without a trailing newline. Fix the parser and add a regression test to satisfy the accepted behavior.'
    for task,intent,specification,description in [
        ('short-json',short,spec,ordinary),
        ('long-json-ci',short+detail,spec+detail,'The first CI run failed on a flaky network fetch; the replacement run is green. Refresh the delivery evidence to refer to the passing replacement run.'),
        ('scope-boundary',short+detail+'\n'+limit,'- Document the parser behavior in docs/parser-known-issues.md.\n',ordinary),
    ]:
        d=home/'data'/task; d.mkdir()
        snapshot=d/'findings.json'
        snapshot.write_text(json.dumps({'findings':[{'id':'F1','severity':'error','action':'ask-user','description':description}]}))
        (d/'brief.md').write_text("# Task\n## Captain's intent\n"+intent+'\n## Firstmate spec\n'+specification+'\n# Setup\n')
        key='nm-LIVEDELIVERY-'+('ci' if 'ci' in task else 'review')
        (home/'state'/(task+'.status')).write_text('needs-decision [key='+key+']: ask-user findings=F1 file='+str(snapshot)+'\n')
        (home/'state'/(task+'.meta')).write_text('kind=ship\nmode=no-mistakes\nproject='+str(home/'projects')+'\nbackend=herdr\nwindow='+session+':'+pane+'\nherdr_session='+session+'\nherdr_workspace_id='+ws+'\nherdr_tab_id='+tab+'\nherdr_pane_id='+pane+'\n')
        runenv=env|{'FM_HOME':str(home)}
        p=subprocess.run([str(ROOT/'bin/fm-jev-ask-user.sh'),task,key,'--round','1'],env=runenv,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
        records=list((home/'state'/(task+'.inbox')).glob('*.msg'))
        result={'name':task,'exit':p.returncode,'output':p.stdout,'status':(home/'state'/(task+'.status')).read_text(),'inbox':[f.read_text() for f in records]}
        result['decision_log']=[json.loads(l) for l in (home/'state/jev-ask-user.jsonl').read_text().splitlines() if json.loads(l)['task']==task]
        results.append(result); print(json.dumps(result),flush=True)
    lab('run',session,'pane','get',pane)
finally:
    if prepared: lab('teardown',session)
    shutil.rmtree(w)
    (E/'durable-delivery-results.json').write_text(json.dumps(results,indent=2)+'\n')
