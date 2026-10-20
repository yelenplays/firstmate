#!/usr/bin/env python3
"""Drive actual Firstmate CLI interfaces against worktree-local disposable homes.
No implementation-source assertions and no harness/CLI mocks.
"""
import os, pathlib, subprocess, json, shutil
ROOT = pathlib.Path('/Users/yelen/.no-mistakes/worktrees/548b8aa73bec/01M5CCAH0SEX7ZN7PXPC274FMA')
EVIDENCE = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5CCAH0SEX7ZN7PXPC274FMA')
LAB = ROOT / '.gate-validation' / 'home'
ENV = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
ENV['FM_HOME'] = str(LAB)
LOG=[]
RESULTS=[]
def run(*args, code=0, env=None):
    p=subprocess.run([str(x) for x in args],cwd=ROOT,env=env or ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60)
    LOG.extend(['$ '+ ' '.join(str(x) for x in args), p.stdout, p.stderr, 'exit: '+str(p.returncode)])
    if code is not None: assert p.returncode==code, (args,p.returncode,p.stdout,p.stderr)
    return p

def cli(name,*args,**kw): return run(ROOT/'bin'/('fm-'+name+'.sh'),*args,**kw)
def check(name, fn):
    try:
        fn()
        RESULTS.append({'name':name,'result':'pass'})
    except Exception as e:
        RESULTS.append({'name':name,'result':'fail','error':str(e)})
        LOG.append('ASSERTION FAILURE '+repr(e))

def brief(task,project,kind='scout'):
    args=['--scout'] if kind=='scout' else ['--mode','local-only']
    cli('brief',task,project,*args)
    text=(LAB/'data'/task/'brief.md').read_text()
    shutil.copyfile(LAB/'data'/task/'brief.md',EVIDENCE/(task+'-brief.md'))
    return text

def facts():
    for task,project,kind in [('moving-scout','moving-site','scout'),('moving-ship','moving-v2','ship')]:
        text=brief(task,project,kind)
        assert 'Gewerbe: nein' in text and 'VAT: nicht registriert' in text and 'Legal owner: Test Owner' in text
        assert 'Other Owner' not in text
        assert text.index('# Task') < text.index('# Business facts') < text.index('# Setup')
    text=brief('unmapped-scout','unmapped')
    assert '# Business facts' not in text

def invalid():
    registry=LAB/'data/projects.md'
    original=registry.read_text()
    for n,token in enumerate(['[facts: ../escape]','[facts: moving] [facts: other]','[facts: ]']):
        registry.write_text(original+'\n- bad-project '+token+' - Bad\n')
        task='invalid-'+str(n)
        p=cli('brief',task,'bad-project','--scout',code=None)
        assert p.returncode!=0 and 'facts' in p.stderr
        assert not (LAB/'data'/task/'brief.md').exists()
    registry.write_text(original)

def posture():
    a=cli('project-mode','moving-site').stdout.strip()
    b=cli('project-mode','moving-v2').stdout.strip()
    assert a == b == 'local-only off', {'facts_after_mode':a,'facts_before_mode':b}

def inherit():
    dest=ROOT/'.gate-validation/second-home'
    (dest/'config').mkdir(parents=True,exist_ok=True)
    (dest/'data').mkdir(exist_ok=True)
    run('bash','-c','. bin/fm-config-inherit-lib.sh; propagate_inheritable_config "$1" "$2"', 'inherit',str(LAB/'config'),str(dest/'config'))
    assert (dest/'config/business-facts.md').read_bytes()==(LAB/'config/business-facts.md').read_bytes()
    (dest/'data/projects.md').write_bytes((LAB/'data/projects.md').read_bytes())
    env=dict(ENV, FM_HOME=str(dest))
    run(ROOT/'bin/fm-brief.sh','inherited-scout','moving-site','--scout',env=env)
    text=(dest/'data/inherited-scout/brief.md').read_text()
    assert 'Gewerbe: nein' in text and 'Other Owner' not in text
    shutil.copyfile(dest/'data/inherited-scout/brief.md',EVIDENCE/'inherited-scout-brief.md')

def completion():
    cli('memory','remember','--category','now','--task','headroom-retest-v1','Headroom comparison','Vergleichstest 0.41 laeuft, Ergebnis steht noch aus')
    cli('memory','remember','--category','now','--task','other-task','Other investigation','other investigation running')
    cli('memory','remember','--category','now','Unlinked note','unlinked pending')
    cli('memory','remember','--category','events','--task','headroom-retest-v1','Headroom history','Historical context')
    store=LAB/'data/memories'
    untouched={p:p.read_bytes() for p in [store/'now/other-investigation.md',store/'now/unlinked-note.md',store/'events/headroom-history.md']}
    before=cli('memory','recall','--json','Headroom').stdout
    (EVIDENCE/'headroom-before.json').write_text(before)
    report=LAB/'data/headroom-retest-v1/report.md'
    report.parent.mkdir(parents=True,exist_ok=True)
    report.write_text('# Headroom comparison\n\nVersion 0.41 reduced retained memory in this validation scenario.\n')
    cli('memory','complete-task','headroom-retest-v1','--report',report,'--outcome','0.41 wins')
    note=store/'now/headroom-comparison.md'
    text=note.read_text()
    assert 'completed:' in text and '0.41 wins' in text and str(report) in text
    assert 'laeuft' not in text and 'steht noch aus' not in text
    after=cli('memory','recall','--json','Headroom').stdout
    assert '0.41 wins' in after and 'steht noch aus' not in after
    (EVIDENCE/'headroom-after.json').write_text(after)
    (EVIDENCE/'headroom-completed-note.md').write_text(text)
    now=cli('memory','now').stdout
    assert '0.41 wins' in now
    snapshot=note.read_bytes()
    cli('memory','complete-task','headroom-retest-v1','--outcome','SHOULD NOT OVERWRITE')
    assert note.read_bytes()==snapshot
    cli('memory','complete-task','missing-task')
    assert all(p.read_bytes()==data for p,data in untouched.items())

def invalid_memory():
    for task in ['../escape','bad task','-leading']:
        p=cli('memory','remember','--category','now','--task',task,'Invalid note','body',code=None)
        assert p.returncode==3
        p=cli('memory','complete-task',task,code=None)
        assert p.returncode==3
    assert not (LAB/'data/memories/now/invalid-note.md').exists()

try:
    cli('lab-home','create',LAB)
    (LAB/'config/business-facts.md').write_text('## moving\nGewerbe: nein\nVAT: nicht registriert\nLegal owner: Test Owner\n\n## other\nLegal owner: Other Owner\n')
    (LAB/'data/projects.md').write_text('- moving-site [local-only] [facts: moving] - First site\n- moving-v2 [facts: moving] [local-only] - Second site\n- unmapped [local-only] - No business mapping\n')
    check('Ship and scout briefs receive only their shared business facts',facts)
    check('Malformed and duplicate business links refuse brief creation',invalid)
    check('Business facts preserve local-only delivery posture in either token order',posture)
    check('Inherited business facts reach second-home generated brief',inherit)
    check('Complete linked work updates recall and now, preserves unrelated notes, and is idempotent',completion)
    check('Unsafe memory task identifiers are rejected without creating a note',invalid_memory)
finally:
    (EVIDENCE/'cli-scenarios.log').write_text('\n'.join(LOG))
    (EVIDENCE/'cli-results.json').write_text(json.dumps(RESULTS,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(RESULTS,ensure_ascii=False,indent=2))
    shutil.rmtree(ROOT/'.gate-validation',ignore_errors=True)
