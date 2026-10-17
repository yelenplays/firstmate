"""Exact-head public CLI validation; no fake Jev or sender. Isolated homes only.
The Herdr lab supplies a real terminal endpoint; no worker executes gate responses.
"""
import os, json, subprocess, tempfile, pathlib, shutil, time
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M54V5P0VHQHH9M1VDX216GQH') / os.environ.get('LIVE_EVIDENCE_SUBDIR','')
E.mkdir(parents=True,exist_ok=True)
SCRATCH=ROOT/'.test-phase-tmp'
BASE=os.environ.copy()
for k in list(BASE):
    if (k.startswith('FM_') and k.endswith('_OVERRIDE')) or k in ['FM_HOME','FM_GATE_REFUSE_BYPASS','FM_JEV_ASK_USER_SEND','HERDR_SESSION','HERDR_PANE_ID','HERDR_TAB_ID','HERDR_WORKSPACE_ID','HERDR_SOCKET_PATH','HERDR_ENV','TMUX']:
        BASE.pop(k,None)
BASE.update(TMPDIR=str(SCRATCH),FM_HERDR_LAB_STATE_DIR=str(SCRATCH/'herdr-lab-state'))
ORIGINAL_PATH=BASE['PATH']
H=str(ROOT/'bin/fm-herdr-lab.sh')
records=[]
transcript=[]
def cmd(args,env=None,timeout=90):
    p=subprocess.run([str(a) for a in args],env=env or BASE,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    return p.returncode,p.stdout
_,session=cmd([H,'name','jev-validation'])
session=session.strip()
def lab(*args):
    c,o=cmd([H,'run',session,*args]);
    if c: raise RuntimeError('Herdr lab command failed: '+o)
    return json.loads(o)
def report(name,code,out,home,expected):
    logs=home/'state/jev-ask-user.jsonl'
    log=[json.loads(x) for x in logs.read_text().splitlines()] if logs.exists() else []
    inbox=[p.read_text() for p in sorted((home/'state/t1.inbox').glob('*.msg'))]
    status=(home/'state/t1.status').read_text()
    record=dict(name=name,exit=code,output=out,decision_log=log,inbox=inbox,status=status,expected=expected)
    records.append(record)
    transcript.append('\n### '+name+'\nexit='+str(code)+'\n'+out+'\n'+status+'\n'.join(inbox)+'\nlog='+json.dumps(log))
    (E/'live-cli-transcript.txt').write_text('\n'.join(transcript))
    (E/'live-results.json').write_text(json.dumps(records,indent=2))
    return record
INCON='live validation verdict: inconclusive; untested: Parse a live upstream feed that ends without a newline. The gate cannot reach that feed by design. No code defect is named. Outside-gate acceptance is recorded; list this check in the PR description.'
CONTEXT='The focused regression test passed; this note is informational.'
def world(shape='lines',action='no-op',asked='T2',step='test',file='src/a,no-op,b.sh',desc=None,brief_extra=''):
    home=pathlib.Path(tempfile.mkdtemp(prefix='jev-home-',dir=SCRATCH))
    c,o=cmd([ROOT/'bin/fm-lab-home.sh','create',home]); assert c==0,o
    (home/'data/t1').mkdir()
    project=home/'projects/sample'; project.mkdir()
    key='nm-LIVE-'+step
    snapshot=home/'data/t1/findings.txt'
    finding=desc or INCON
    if shape=='toon':
        text='gate:\n  step: '+step+'\n  findings[2]{id,severity,file,action,description}:\n'
        text+='    T1,warning,'+json.dumps(file)+','+action+','+json.dumps(CONTEXT)+'\n'
        text+='    T2,warning,"",ask-user,'+json.dumps(finding)+'\n'
    else:
        text='step: '+step+'\nid: T1\nseverity: warning\nauthority/action: '+action+'\ndescription: '+CONTEXT+'\n\nid: T2\nseverity: warning\nauthority/action: ask-user\ndescription: '+finding+'\n'
    snapshot.write_text(text)
    (home/'data/t1/brief.md').write_text("# Task\n## Captain's intent\nMake the parser keep every field, including a final line without a trailing newline.\n\n## Firstmate spec\nFix bin/parse.sh and add a regression test. An upstream feed cannot be reached inside the gate; record its unchecked live check in the PR description when no code defect exists.\n"+brief_extra)
    (home/'state/t1.status').write_text('needs-decision [key='+key+']: ask-user findings='+asked+' file='+str(snapshot)+'\n')
    meta='kind=ship\nmode=no-mistakes\nproject='+str(project)+'\nbackend=herdr\nwindow='+session+':'+pane+'\nherdr_session='+session+'\nherdr_workspace_id='+ws+'\nherdr_tab_id='+tab+'\nherdr_pane_id='+pane+'\n'
    (home/'state/t1.meta').write_text(meta)
    return home,key,snapshot

def drive(name,expected,shape='lines',action='no-op',asked='T2',step='test',file='src/a,no-op,b.sh',desc=None,brief_extra='',round=1,mutate=None,sut=None):
    selected=os.environ.get('LIVE_ONLY','')
    if selected and name not in selected.split(','): return None
    home,key,snapshot=world(shape,action,asked,step,file,desc,brief_extra)
    if mutate: mutate(home,snapshot)
    env=BASE.copy(); env.update(FM_HOME=str(home),PATH=str(wrapper)+':'+ORIGINAL_PATH,FM_WIKIS_ROOT=str(home/'not-wikis'))
    c,o=cmd([sut or ROOT/'bin/fm-jev-ask-user.sh','t1',key,'--round',str(round)],env=env,timeout=90)
    r=report(name,c,o,home,expected)
    shutil.rmtree(home)
    return r

owned=False
try:
    # provision owns prepare for a new session (a separate prepare first
    # would leave an existing tripwire and is refused by this helper).
    owned=True
    c,o=cmd([H,'provision',session]); transcript.append('provision (includes prepare) '+session+'\n'+o)
    if c: raise RuntimeError('Herdr provision blocked: '+o)
    status=lab('status','--json')
    (E/'lab-status.json').write_text(json.dumps(status,indent=2))
    w=lab('workspace','create','--cwd',str(ROOT),'--label','jev-validation','--no-focus')
    ws=w['result']['workspace']['workspace_id']
    t=lab('tab','create','--workspace',ws,'--cwd',str(ROOT),'--label','fm-t1','--no-focus')
    tab=t['result']['tab']['tab_id']; pane=t['result']['root_pane']['pane_id']
    # Forward every adapter call through the owning helper; this is a real
    # transport wrapper, not a canned backend response.
    wrapper=SCRATCH/'real-herdr-route'; wrapper.mkdir(exist_ok=True)
    script='#!/usr/bin/env bash\nset -eu\nargs=("$@")\nn=${#args[@]}\n[ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ] && [ "${args[$((n-1))]}" = '+repr(session)+' || exit 97\nargs=("${args[@]:0:$((n-2))}")\nexec env PATH='+repr(ORIGINAL_PATH)+' '+repr(H)+' run '+repr(session)+' "${args[@]}"\n'
    (wrapper/'herdr').write_text(script); (wrapper/'herdr').chmod(0o755)
    # Terminal is real and idle; durable inbox, not agent execution, is the
    # delivery contract this change owns. Never execute axi respond here.
    drive('routine-fix-lines','ACT fix T2; only T2 in decision log; durable inbox and resolved status',step='review',desc='The parser drops the last field when the line has no trailing newline, contrary to the accepted intent. Fix that off-by-one error.')
    drive('routine-fix-toon','ACT fix T2; only T2 is judged; no-op T1 stays context',shape='toon',step='review',desc='The parser drops the last field when the line has no trailing newline, contrary to the accepted intent. Fix that off-by-one error.')
    drive('approve-lines-harmless-context','ACT approve T2; reason and Follow-up check instruction recorded')
    drive('approve-toon-quoted-harmless-context','ACT approve T2; quoted comma filename preserves no-op context',shape='toon')
    drive('quoted-comma-actionable-guard','Never approve the unjudged auto-fix T1',shape='toon',action='auto-fix')
    drive('quoted-escape-actionable-guard','Never approve unjudged auto-fix behind escaped quote',shape='toon',action='auto-fix',file='src/a\",no-op,b.sh')
    drive('unknown-authority-guard','Never approve unjudged unknown-authority T1',shape='toon',action='ask-me')
    drive('non-test-guard','Never approve a review gate',step='review')
    for name,opts in [
        ('missing-id',dict(asked='T2,T9')),
        ('repeated-asked-id',dict(asked='T2,T2')),
        ('duplicate-snapshot-id',dict(mutate=lambda h,p:p.write_text(p.read_text()+'id: T2\ndescription: duplicate\n'))),
        ('round-cap',dict(round=4)),
        ('credential-screen',dict(desc=INCON+' The credential boundary needs review.')),
        ('private-email-screen',dict(brief_extra='Contact person@example.com before acting.')),
        ('private-phone-screen',dict(brief_extra='Call 555-123-4567 before acting.')),
        ('wiki-screen',dict(mutate=lambda h,p:(h/'projects/sample/_meta').mkdir() or (h/'projects/sample/_meta/pruefe.sh').touch())),
    ]:
        drive(name,'Refuse or escalate before Jev; no inbox delivery',**opts)
    drive('date-day-range-retained','ACT fix despite benign 2026-10-11/12 date context',step='review',desc='The parser drops the final field contrary to the intent. Fix it.',brief_extra='Acceptance review was recorded on 2026-10-11/12.')
    drive('mixed-fix-and-approve','Escalate a real Jev split between in-scope-fix T1 and approve-followup T2',asked='T1,T2',mutate=lambda h,p:p.write_text(p.read_text().replace(CONTEXT,'The parser drops the last field when a line has no trailing newline. This is an off-by-one code defect violating the accepted intent; fix it.').replace('authority/action: no-op','authority/action: ask-user')))
    drive('typed-security-screen','Separate Jev risk screen must override approval',desc=INCON+' In this parser, tenant A can retrieve tenant B draft records by changing an account id.')
    drive('expansion-class','Escalate new architecture beyond the accepted parser fix',step='review',desc='Add a persistent monitoring service, a new remote synchronization subsystem, and a generalized multi-provider plugin framework; these are not required to fix the final-field parser bug.')
    for phone in ['2026-10-111/12','2026-101-11/12','+2026-10-11/12']:
        drive('phone-sibling-'+phone.replace('/','-'),'Privacy escalation before Jev; date exception must not allow this phone-shaped sibling',brief_extra='Contact number '+phone+'.')
    # Reproduce the prior quoted-field authority bug using the prior public
    # executable with current unchanged dependencies, all in local scratch.
    oldbin=SCRATCH/'before-fix-bin'; oldbin.mkdir(exist_ok=True)
    for f in (ROOT/'bin').glob('*'):
        if f.name!='fm-jev-ask-user.sh' and f.is_file(): (oldbin/f.name).symlink_to(f)
    c,old=cmd(['git','show','904eec651d570bc823dc5a725f8bf99d8bf55f2d^:bin/fm-jev-ask-user.sh'])
    assert c==0
    (oldbin/'fm-jev-ask-user.sh').write_text(old); (oldbin/'fm-jev-ask-user.sh').chmod(0o755)
    drive('before-fix-quoted-comma-reproduction','Prior executable incorrectly ACT approve with unjudged auto-fix T1',shape='toon',action='auto-fix',sut=oldbin/'fm-jev-ask-user.sh')
except Exception as exc:
    transcript.append('BLOCKER: '+str(exc))
    (E/'live-blocker.txt').write_text(str(exc))
finally:
    if owned:
        c,o=cmd([H,'teardown',session]); transcript.append('teardown '+session+' exit='+str(c)+'\n'+o)
    (E/'live-cli-transcript.txt').write_text('\n'.join(transcript))
    (E/'live-results.json').write_text(json.dumps(records,indent=2))
    print(json.dumps(dict(session=session,scenarios=len(records),evidence=str(E/'live-results.json'))))
