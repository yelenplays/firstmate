import os, json, pathlib, subprocess, shutil
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M54V5P0VHQHH9M1VDX216GQH')
BASE=ROOT/'.validation-tmp'
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('JEV_ROUTE','JEV_MODEL','JEV_URL','JEV_BASE','JEV_STATE_MAX_BYTES'):
        env.pop(k)
env['TMPDIR']=str(BASE)
results=[]

def run_case(name, *, ids='T2', shape='lines', context='no-op', round=1, text=None, sensitive=None, vault=False, step='test', duplicate=False, model=True, context_text=None, context_file='""'):
    home=BASE/name
    subprocess.run(['bin/fm-lab-home.sh','create',str(home)],env=env,check=True,stdout=subprocess.DEVNULL)
    project=home/'projects/sample'; project.mkdir()
    data=home/'data/t1'; data.mkdir()
    if vault:
        (project/'_meta').mkdir(); (project/'_meta/pruefe.sh').touch()
    metadata=f'kind=ship\nmode=no-mistakes\nproject={project}\n'
    if env.get('LAB_ENDPOINT'):
        session,workspace,tab,pane=env['LAB_ENDPOINT'].split('|')
        metadata+=f'backend=herdr\nwindow={session}:{pane}\nendpoint_task_id=t1\nherdr_session={session}\nherdr_workspace_id={workspace}\nherdr_tab_id={tab}\nherdr_pane_id={pane}\n'
    (home/'state/t1.meta').write_text(metadata)
    (data/'brief.md').write_text("# Task\n## Captain's intent\nMake the parser keep every field, including on a final line with no trailing newline.\n\n## Firstmate spec\nFix the parser and add a regression test.\n")
    inc=text or 'live validation verdict: inconclusive; untested: Parse a live upstream feed ending without a newline. The upstream feed cannot be reached inside this gate by design; acceptance outside the gate is recorded. No code defect was found.'
    context_text=context_text or 'The local regression checks passed. The gate cannot reach the live upstream feed by design.'
    snapshot=data/'findings.txt'
    if shape=='toon':
        snapshot.write_text(f'gate:\n  step: {step}\n  findings[2]{{id,severity,file,action,description}}:\n    T1,warning,{context_file},{context},"{context_text}"\n    T2,warning,"",ask-user,"{inc}"\n')
    else:
        snapshot.write_text(f'step: {step}\nid: T1\nauthority/action: {context}\ndescription: {context_text}\n\nid: T2\nauthority/action: ask-user\ndescription: {inc}\n')
    if duplicate:
        with snapshot.open('a') as f: f.write('\nid: T2\nauthority/action: ask-user\ndescription: repeated finding\n')
    if sensitive:
        inbox=home/'state/t1.inbox'; inbox.mkdir()
        (inbox/'001.msg').write_text('schema=fm-task-inbox.v1\nat=2026-10-11T20:00:00Z\n--\n'+sensitive+'\n')
    key='nm-liveprobe-'+step
    (home/'state/t1.status').write_text(f'needs-decision [at=1791145829] [key={key}]: ask-user findings={ids} file={snapshot}\n')
    caseenv=env|{'FM_HOME':str(home),'FM_WIKIS_ROOT':str(BASE/'no-wikis')}
    p=subprocess.run(['bin/fm-jev-ask-user.sh','t1',key,'--round',str(round)],env=caseenv,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=70)
    log=home/'state/jev-ask-user.jsonl'
    records=[json.loads(x) for x in log.read_text().splitlines()] if log.exists() else []
    result={'scenario':name,'snapshot':snapshot.read_text(),'command':f'FM_HOME=<disposable-lab> bin/fm-jev-ask-user.sh t1 {key} --round {round}','exit':p.returncode,'output':p.stdout,'decision_log':records,'status':(home/'state/t1.status').read_text(),'inbox_records':[f.read_text() for f in (home/'state/t1.inbox').glob('*.msg')]} 
    results.append(result)
    (E/'live-cli.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(result,indent=2),flush=True)
    shutil.rmtree(home)
    return result

if __name__ == '__main__':
  try:
    run_case('missing-id',ids='T2,T9')
    run_case('duplicate-asked-id',ids='T2,T2')
    run_case('duplicate-snapshot-id',duplicate=True)
    run_case('round-cap',round=4)
    run_case('credential-concern',text='live validation verdict: inconclusive; the credential store cannot be checked.')
    run_case('wiki-project',vault=True)
    run_case('private-contact',sensitive='reach synthetic-person@example.com')
    run_case('phone-sibling',sensitive='Replay 2026-10-11/12, then call 415-555-0199')
    run_case('routine-fix',step='review',text='The parser drops the final field when the input has no trailing newline. Correct this bug so that every field is kept, as required by the accepted intent.')
    run_case('approve-noop-lines')
    run_case('approve-noop-toon',shape='toon')
  finally:
    for child in BASE.iterdir():
        if child.is_dir() and (child/'.fm-lab-home').exists(): shutil.rmtree(child)
