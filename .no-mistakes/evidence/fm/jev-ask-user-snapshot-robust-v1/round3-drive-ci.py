"""Follow up low-confidence delivery judgments using an explicit accepted delivery contract.
The first live probe's parser-only scope did not explicitly require refreshing CI
receipts; its conservative model escalation is preserved in round3-live-results.
"""
import json, os, pathlib, shutil, subprocess, tempfile
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5EV9GH4T0RZM94ACQ6Y8XTG')
w=pathlib.Path(tempfile.mkdtemp(prefix='.round3-ci-',dir=R)); env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','JEV_'))}; env['FM_HERDR_LAB_STATE_DIR']=str(w/'lab-state')
H=str(R/'bin/fm-herdr-lab.sh'); session=None; ready=False; results=[]
def lab(*a):
 p=subprocess.run([H,*a],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90); print(json.dumps({'lab':a,'exit':p.returncode,'output':p.stdout}),flush=True); p.check_returncode(); return p.stdout
try:
 session=lab('name','jev-ci3').strip(); lab('provision',session); ready=True
 home=w/'home'; subprocess.run([str(R/'bin/fm-lab-home.sh'),'create',str(home)],check=True,env=env,capture_output=True)
 x=json.loads(lab('run',session,'workspace','create','--cwd',str(R),'--label','jev-ci-contract','--no-focus'))['result']; pane=x['root_pane']['pane_id']; ws=x['workspace']['workspace_id']; tab=x['tab']['tab_id']
 tools=w/'tools';tools.mkdir(); observer=tools/'curl'
 observer.write_text('''#!/usr/bin/env bash
b=$(mktemp); trap 'rm -f "$b"' EXIT
cat > "$b"; cp "$b" "$PROBE_REQUEST"
a=("$@"); out=''
for ((i=0;i<$#;i++)); do [ "${a[$i]}" != -o ] || out=${a[$((i+1))]}; done
/usr/bin/curl "$@" < "$b"; rc=$?
[ ! -f "$out" ] || cp "$out" "$PROBE_RESPONSE"
exit "$rc"
'''); observer.chmod(0o755)
 for name,shape,long in [('explicit-ci-short','json',False),('explicit-ci-json-long','json',True),('explicit-ci-toon-long','toon',True)]:
  d=home/'data'/name; d.mkdir(); f=d/'findings.txt'; key='nm-EXPLICITLIVE-ci'
  intent='Fix the parser final-record bug and deliver the fix through passing CI with current validation evidence.\n'
  spec='Fix bin/parse.sh to preserve every field and add a regression test. Verify the replacement CI run and keep delivery evidence current. Updating a stale CI receipt to the already-passing replacement run is required delivery work within this task.\n'
  detail='The parser must preserve empty fields and field ordering on valid input.\n'*180
  if long: intent+=detail; spec+=detail
  brief="# Task\n## Captain's intent\n"+intent+'\n## Firstmate spec\n'+spec+'\n# Setup\n'; (d/'brief.md').write_text(brief)
  row={'id':'ci-1','severity':'error','action':'ask-user','description':'The first CI run failed on a flaky network fetch; the replacement run is already green. The delivery evidence still links to the failed first run. Replace that stale link with the passing replacement run receipt, as the accepted delivery requirements require. No code change or CI waiver is needed.'}
  f.write_text(json.dumps({'findings':[row]}) if shape=='json' else 'findings[1]{id,severity,action,description}:\n  ci-1,error,ask-user,'+json.dumps(row['description'])+'\n')
  inbox=home/'state'/(name+'.inbox'); (inbox/'handled').mkdir(parents=True); (inbox/'handled/001.msg').write_text('schema=fm-task-inbox.v1\nat=2026-10-20T20:00:00Z\n--\nAlso keep empty trailing fields.\n')
  status=home/'state'/(name+'.status');status.write_text(f'needs-decision [key={key}]: ask-user findings=ci-1 file={f}\n')
  (home/'state'/(name+'.meta')).write_text(f'kind=ship\nmode=no-mistakes\nproject={home}/projects\nbackend=herdr\nwindow={session}:{pane}\nherdr_session={session}\nherdr_workspace_id={ws}\nherdr_tab_id={tab}\nherdr_pane_id={pane}\n')
  runenv=env|{'FM_HOME':str(home),'PATH':str(tools)+':'+os.environ['PATH'],'PROBE_REQUEST':str(E/f'round3-{name}-request.json'),'PROBE_RESPONSE':str(E/f'round3-{name}-response.json')}
  p=subprocess.run([str(R/'bin/fm-jev-ask-user.sh'),name,key,'--round','1'],env=runenv,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
  logs=[json.loads(l) for l in (home/'state/jev-ask-user.jsonl').read_text().splitlines() if json.loads(l)['task']==name]; messages=[m.read_text() for m in inbox.glob('*.msg')]
  request=json.loads((E/f'round3-{name}-request.json').read_text()); state=request['state']
  result={'name':name,'exit':p.returncode,'output':p.stdout,'state_bytes':len(state.encode()),'full_intent':intent.rstrip() in state,'full_spec':spec.rstrip() in state,'retained_handled_steer':'[1] Also keep empty trailing fields.' in state,'status':status.read_text(),'new_inbox':messages,'decision_log':logs}
  result['assertions_passed']=p.returncode==0 and len(messages)==1 and '--step ci --action fix --findings ci-1' in messages[0] and logs[-1]['sent'] is True and logs[-1]['http']=='200' and 'resolved ' in result['status'] and result['full_intent'] and result['full_spec'] and (not long or result['state_bytes']>26477)
  results.append(result); print(json.dumps(result),flush=True)
finally:
 try:
  if ready: lab('teardown',session)
 finally:
  shutil.rmtree(w);(E/'round3-explicit-ci-results.json').write_text(json.dumps(results,indent=2)+'\n')
