"""Drive the shipped CLI with real Jev and fm-send; never execute its suggested gate response."""
import json, os, pathlib, subprocess, sys
root=pathlib.Path.cwd(); home=pathlib.Path(sys.argv[1]); session=sys.argv[2]; pane=sys.argv[3]
evidence=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M54RFHN24MTHTBZ0N0DVCS3X')
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_') and key.endswith('_OVERRIDE'): env.pop(key)
for key in ['FM_GATE_REFUSE_BYPASS','FM_JEV_ASK_USER_SEND','JEV_URL','JEV_BASE','JEV_ROUTE','JEV_MODEL','FM_JEV_ASK_USER_FLOOR']:
    env.pop(key,None)
env.update(FM_HOME=str(home), JEV_TIMEOUT='15', FM_WIKIS_ROOT=str(home/'no-wikis'))
results=[]; transcript=[]

def finding(id,description,action='ask-user'):
    return f'id: {id}\nseverity: warning\nfile: bin/parser.sh\nline: 12\nauthority/action: {action}\ndescription: {description}\n'

fix='The parser drops the final field when the input has no trailing newline. Preserve that field as explicitly requested.'
inc='live validation verdict: inconclusive. No code defect is named. The remaining check requires an attended hardware device outside this gate; the gate cannot exercise it by design. A fix round cannot change that. Record the physical-device check as follow-up in the PR description.'
brief="""# Task
## Captain's intent
Preserve every field in the parser, including the final field without a trailing newline. Keep the existing behavior otherwise. The attended physical-device check must happen outside this gate; list that check as follow-up in the PR description.

## Firstmate spec
Correct the parser and its regression test. Do not add new functionality. The lab gate cannot perform the attended physical-device check by design; outside-gate acceptance is already recorded. Keep empty trailing fields too.
"""

def run(name, text, ids='F1', step='review', round=1, want='fix', extra=None, no_key=False):
    task='check'+str(len(results)+1); data=home/'data'/task; data.mkdir(parents=True)
    status=home/'state'/f'{task}.status'; meta=home/'state'/f'{task}.meta'
    snapshot=data/'findings.txt'; snapshot.write_text(f'step: {step}\n'+text)
    (data/'brief.md').write_text(brief)
    key=f'nm-JEVLIVE-{step}'
    meta.write_text(f'kind=ship\nmode=no-mistakes\nproject={root}\nbackend=herdr\nwindow={session}:{pane}\nherdr_session={session}\nherdr_pane_id={pane}\n')
    status.write_text(f'needs-decision [at=1791145829] [key={key}]: ask-user findings={ids} file={snapshot}\n')
    local=env.copy()
    if extra: local.update(extra)
    if no_key:
        for keyname in ['TYPESAFE_API_KEY','TYPESAFE_API_KEY_PRIVATE','OPENROUTER_API_KEY','OPENROUTER_API_KEY_PRIVATE']: local.pop(keyname,None)
    cmd=['bin/fm-jev-ask-user.sh',task,key,'--round',str(round)]
    p=subprocess.run(cmd,env=local,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=55)
    out=p.stdout
    log=home/'state'/'jev-ask-user.jsonl'
    record=json.loads(log.read_text().splitlines()[-1]) if log.exists() and json.loads(log.read_text().splitlines()[-1]).get('task')==task else None
    inboxdir=home/'state'/f'{task}.inbox'
    records=[x.read_text() for x in sorted(inboxdir.glob('*.msg'))] if inboxdir.exists() else []
    if want in ('fix','approve'):
        ok=p.returncode==0 and f'Jev decided {want} {ids}' in out and len(records)==1 and record['sent'] is True
        if want=='fix': ok=ok and f'--action fix --findings {ids}' in records[0]
        else: ok=ok and "--action approve --reason 'Jev decided:" in records[0] and "'Follow-up check'" in records[0] and '--findings' not in records[0]
        ok=ok and 'resolved ' in status.read_text()
    elif want=='no-approve':
        ok=p.returncode in (0,2) and 'Jev decided approve' not in out and all('--action approve' not in x for x in records)
    elif want=='record-error': ok=p.returncode==1 and not records
    else: ok=p.returncode==2 and want in out and not records
    item={'name':name,'passed':ok,'exit':p.returncode,'want':want,'audit':record,'output':out,'inbox':records,'status':status.read_text()}
    results.append(item)
    transcript.extend([f'=== {name} ===',f'$ FM_HOME=<disposable lab> {" ".join(cmd)}',f'exit={p.returncode}',out,'Durable inbox:\n'+('\n'.join(records) or '(none)'),'Decision ledger:\n'+status.read_text(),'Audit: '+json.dumps(record)])
    (evidence/'live-cli-transcript.txt').write_text('\n'.join(transcript))
    (evidence/'live-results.json').write_text(json.dumps(results,indent=2))
    print(f'{name}: {"PASS" if ok else "NOT SATISFIED"}; exit={p.returncode}; '+out.splitlines()[0],flush=True)

run('Routine fix with extra no-op context (plain snapshot)',finding('F1',fix)+finding('C1','The existing behavior is unchanged.','no-op'))
run('Routine fix with extra no-op context (TOON snapshot)','findings[2]{id,severity,file,line,action,description}:\n  F1,warning,bin/parser.sh,12,ask-user,'+fix+'\n  C1,info,,,no-op,Existing behavior is unchanged.\n')
run('Inconclusive test gets approval reason and follow-up instruction',finding('F1',inc)+finding('C1','Other local checks passed.','no-op'),step='test',want='approve')
run('Unjudged actionable context prevents whole-gate approval',finding('F1',inc)+finding('C1',fix,'auto-fix'),step='test',want='no-approve')
run('Inconclusive no-op does not grant approval to another asked finding',finding('F1',fix)+finding('C1',inc,'no-op'),step='test',want='fix')
run('Approval is unavailable outside the test step',finding('F1',inc),step='review',want='no-approve')
run('Mixed fix and approval choices escalate',finding('F1',fix)+finding('F2',inc),ids='F1,F2',step='test',want='jev-class')
run('Uncertain judgment stays below the configured confidence floor',finding('F1',inc)+finding('C1',fix,'auto-fix'),step='test',want='jev-low-confidence',extra={'FM_JEV_ASK_USER_FLOOR':'1'})
run('TOON inconclusive test gets approval and follow-up instruction','findings[2]{id,severity,file,line,action,description}:\n  F1,warning,,,ask-user,'+inc+'\n  C1,info,,,no-op,Other checks passed.\n',step='test',want='approve')
run('Date-range context reaches real Jev unchanged',finding('F1',fix+' The requested window is 2026-10-11/12.'),want='fix')
run('Phone contact stays local',finding('F1',fix+' Call 555-123-4567.'),want='privacy')
run('Destructive finding stays human-owned',finding('F1','Cleanup runs rm -rf on the cache root.'),want='always-escalate')
run('Review round beyond cap stays human-owned',finding('F1',fix),round=4,want='round-cap')
run('Missing asked ID is rejected',finding('OTHER',fix),want='record-error')
run('Duplicate snapshot IDs are rejected',finding('F1',fix)+finding('F1',fix),want='record-error')
run('Missing Jev key escalates without sending',finding('F1',fix),want='jev-unavailable',no_key=True)
print('Live runs complete; no generated no-mistakes response command was executed.',flush=True)
