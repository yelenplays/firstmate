"""Focused live CLI verification; real Jev and real fm-send, isolated Herdr sink.
The sink records delivery only and never executes the suggested pipeline command.
"""
import json, os, pathlib, subprocess, sys, time
ROOT = pathlib.Path.cwd()
EVID = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5EV9GH4T0RZM94ACQ6Y8XTG')
TMP = pathlib.Path((ROOT / '.jev-validation-root').read_text().strip())
SESSION = (TMP / 'session').read_text().strip()
BASE = dict(os.environ, FM_HERDR_LAB_STATE_DIR=str(TMP/'herdr-state'))
HELPER = ROOT/'bin/fm-herdr-lab.sh'
HOME = TMP/'home'
transcript = []
results = []
def run(args, env=None):
    p = subprocess.run([str(x) for x in args], env=env or BASE, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=65)
    return p.returncode, p.stdout

def lab(*args):
    code, output = run([HELPER,'run',SESSION,*args])
    if code: raise RuntimeError(output)
    return output

def fixture(name, findings, intent=None, spec=None, steer=None, ids='F1', step='review', shape='json', setup=False):
    data = HOME/'data'/name
    data.mkdir(parents=True)
    (HOME/'state'/f'{name}.inbox'/'handled').mkdir(parents=True)
    gate = 'nm-01M4TEST0000000000000000AB-'+step
    snapshot = data/'findings.txt'
    if shape == 'json': snapshot.write_text(json.dumps({'step':step,'findings':findings}))
    elif shape == 'array': snapshot.write_text(json.dumps(findings))
    elif shape == 'toon':
        rows = [','.join(json.dumps(r.get(k,'')) if k!='id' else r[k] for k in ['id','severity','file','action','description']) for r in findings]
        snapshot.write_text('step: '+step+'\nfindings['+str(len(rows))+']{id,severity,file,action,description}:\n  '+'\n  '.join(rows)+'\n')
    intent = intent or 'Make the parser keep every field, including on a final line with no trailing newline.'
    spec = spec or 'Fix bin/parse.sh and keep a regression test for a final line without a trailing newline.'
    (data/'brief.md').write_text("# Task\n## Captain's intent\n"+intent+'\n\n## Firstmate spec\n'+spec+'\n\n# Setup\n'+(('Setup detail: standard worker startup instructions.\n'*300) if setup else 'No setup needed.\n'))
    if steer:
        (HOME/'state'/f'{name}.inbox'/'handled'/'001.msg').write_text('schema=fm-task-inbox.v1\nat=2026-10-20T20:00:00Z\n--\n'+steer+'\n')
    (HOME/'state'/f'{name}.status').write_text(f'needs-decision [at=1791145829] [key={gate}]: ask-user findings={ids} file={snapshot}\n')
    (HOME/'state'/f'{name}.meta').write_text(f'kind=ship\nmode=no-mistakes\nproject={HOME / "projects" / "sample"}\nbackend=herdr\nherdr_session={SESSION}\nherdr_pane_id={PANE}\nwindow={SESSION}:{PANE}\nharness=claude\n')
    return gate

def exercise(name, gate, expected_code, expected_text, decision=False, round=1, script=None):
    code, out = run([script or ROOT/'bin/fm-jev-ask-user.sh',name,gate,'--round',str(round)], ENV)
    status = (HOME/'state'/f'{name}.status').read_text()
    logsfile=HOME/'state'/'jev-ask-user.jsonl'
    logs=[json.loads(x) for x in logsfile.read_text().splitlines()] if logsfile.exists() else []
    record=next((x for x in reversed(logs) if x['task']==name),None)
    inbox={p.name:p.read_text() for p in sorted((HOME/'state'/f'{name}.inbox').glob('*.msg'))}
    ok = code==expected_code and expected_text in out
    if decision: ok = ok and bool(inbox) and 'resolved' in status and record and record['sent'] is True
    else: ok = ok and not inbox and 'resolved' not in status
    if expected_text=='contract-too-large': ok = ok and record and record['jev_called'] is False
    detail={'name':name,'exit':code,'output':out,'status':status,'inbox':inbox,'metadata_log':record,'pass':bool(ok)}
    (EVID/(name+'.json')).write_text(json.dumps(detail,indent=2)+'\n')
    transcript.append(f'=== {name} ===\nexit={code}\n{out}\nstatus:\n{status}\nmetadata: {json.dumps(record)}\n')
    results.append({'name':name,'pass':bool(ok)})
    print(name, 'PASS' if ok else 'FAIL', out.splitlines()[0] if out else '(no output)', flush=True)

try:
    code,out=run([ROOT/'bin/fm-lab-home.sh','create',HOME]); assert code==0,out
    (HOME/'projects'/'sample').mkdir()
    created=json.loads(lab('workspace','create','--cwd',str(ROOT),'--label','fm-jev-validation','--no-focus'))
    PANE=created['result']['root_pane']['pane_id']
    # A real running OS process receives doorbells, never pipeline-control commands.
    lab('pane','run',PANE,'/bin/cat')
    original_path=BASE['PATH']
    shim=TMP/'shim'; shim.mkdir()
    wrapper=shim/'herdr'
    wrapper.write_text('#!/usr/bin/env bash\nset -eu\nargs=("$@")\nn=${#args[@]}\n[ "${args[$((n-2))]}" = --session ] && [ "${args[$((n-1))]}" = '+repr(SESSION)+' ] || exit 97\nargs=("${args[@]:0:$((n-2))}")\nexec env PATH='+repr(original_path)+' '+repr(str(HELPER))+' run '+repr(SESSION)+' "${args[@]}"\n')
    wrapper.chmod(0o755)
    ENV=dict(BASE,FM_HOME=str(HOME),PATH=str(shim)+':'+original_path,FM_WIKIS_ROOT=str(TMP/'no-wikis'))
    for k in list(ENV):
        if (k.startswith('FM_') and k.endswith('_OVERRIDE')) or k in ['FM_GATE_REFUSE_BYPASS','FM_JEV_ASK_USER_SEND','HERDR_ENV','HERDR_PANE_ID','HERDR_TAB_ID','HERDR_WORKSPACE_ID','HERDR_SOCKET_PATH','HERDR_SESSION','TMUX']:
            ENV.pop(k,None)
    defect={'id':'F1','severity':'error','file':'bin/parse.sh','line':12,'action':'ask-user','description':'The parser drops the final field on input without a trailing newline. Correct the parser and retain the regression test so it keeps that field as explicitly requested.'}
    gate=fixture('json-review',[defect])
    exercise('json-review',gate,0,'ACT ',True)
    gate=fixture('bare-array',[defect],shape='array')
    exercise('bare-array',gate,0,'ACT ',True)
    ci={'id':'ci-1','severity':'error','file':'','line':None,'action':'ask-user','description':'The first CI run failed on a flaky network fetch; the replacement run is green. The parser regression now passes.'}
    gate=fixture('json-ci-long-setup',[ci],ids='ci-1',step='ci',setup=True)
    exercise('json-ci-long-setup',gate,0,'ACT ',True)
    gate=fixture('toon-long-setup',[defect],shape='toon',setup=True)
    exercise('toon-long-setup',gate,0,'ACT ',True)
    for section in ['intent','spec','steer']:
        contract='The parser must preserve every field.\n'*300+'MANDATORY SCOPE LIMIT: documentation-only; do not edit production code.'
        kwargs={section:contract}
        gate=fixture('late-scope-'+section,[defect],**kwargs)
        exercise('late-scope-'+section,gate,2,'contract-too-large')
    gate=fixture('missing-id',[defect],ids='F1,F9')
    exercise('missing-id',gate,1,'does not list: F9')
    gate=fixture('duplicate-id',[defect,defect])
    exercise('duplicate-id',gate,1,'repeats a finding id')
    risk=dict(defect,description='The proposed fix exposes credentials to other tenants; adjust the security boundary.')
    gate=fixture('json-risk',[risk])
    exercise('json-risk',gate,2,'always-escalate')
    gate=fixture('json-round-cap',[defect])
    exercise('json-round-cap',gate,2,'round-cap',round=4)
    # Capture the actual worker-side transport surface, not a generic test count.
    (EVID/'herdr-doorbells.json').write_text(lab('pane','read',PANE,'--source','recent','--lines','100'))
finally:
    code,out=run([HELPER,'teardown',SESSION])
    transcript.append(f'=== lab teardown ===\nexit={code}\n{out}')
    (EVID/'live-cli-transcript.log').write_text('\n'.join(transcript))
    (EVID/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    print('teardown exit',code, out,flush=True)
    if code: sys.exit(code)
if not all(x['pass'] for x in results): sys.exit(1)
