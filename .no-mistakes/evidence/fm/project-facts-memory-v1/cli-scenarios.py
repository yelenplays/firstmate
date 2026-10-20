import os, pathlib, subprocess, json, hashlib, shutil
root=pathlib.Path.cwd(); scratch=root/'.test-project-facts'/'cli'; scratch.mkdir(parents=True,exist_ok=True)
evidence=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5CCAH0SEX7ZN7PXPC274FMA')
base={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
base['TMPDIR']=str(scratch)
home=scratch/'home'; home.mkdir(); subprocess.run(['bin/fm-lab-home.sh','create',str(home)],check=True,env=base,stdout=subprocess.DEVNULL)
env=base|{'FM_HOME':str(home)}
log=[]
def run(args, code=0, e=env):
    p=subprocess.run([str(root/args[0]),*args[1:]],env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    log.append('$ '+ ' '.join(args)+'\n'+p.stdout+p.stderr+f'[exit {p.returncode}]\n')
    assert p.returncode==code, log[-1]
    return p.stdout
try:
    reg=home/'data/projects.md'
    reg.write_text('''- moving-site [local-only] [facts: moving] - main website
- moving-v2 [facts: moving] [local-only] - new website
- delivery-first [direct-PR +yolo branch=work/ forge=forgejo witness=https://example.test/health] [facts: moving] [wiki: Moving Wiki] - first
- facts-first [facts: moving] [wiki: Moving Wiki] [direct-PR +yolo branch=work/ forge=forgejo witness=https://example.test/health] - last
- wiki-first [wiki: Moving Wiki] [facts: moving] [direct-PR +yolo branch=work/ forge=forgejo witness=https://example.test/health] - reversed
- bad [facts: ../moving] [local-only] - invalid
- duplicate [local-only] [facts: moving] [facts: unrelated] - duplicate
- plain [local-only] - unbound
- missing [local-only] [facts: absent] - no block
''')
    facts='Gewerbe: nein; noch nicht angemeldet.\nVAT: keine Umsatzsteuer-ID.\nLegal owner: Max Muster (Privatperson).\n'
    (home/'config/business-facts.md').write_text('## moving\n'+facts+'\n## unrelated\nGewerbe: ja.\nLegal owner: Unrelated GmbH.\n')
    for project in ('moving-site','moving-v2'):
        assert run(['bin/fm-project-mode.sh',project]).strip()=='local-only off'
    for project in ('delivery-first','facts-first','wiki-first'):
        for query,expected in [('--raw','direct-PR on'),('--branch-prefix','work/'),('--forge','forgejo'),('--witness','https://example.test/health')]:
            assert run(['bin/fm-project-mode.sh',query,project]).strip()==expected
    for task,project,flags in [('ship-facts','moving-site',['--mode','local-only']),('scout-facts','moving-v2',['--scout'])]:
        run(['bin/fm-brief.sh',task,project,*flags,'--herdr-lab'])
        brief=(home/'data'/task/'brief.md').read_text()
        assert facts in brief and 'Unrelated GmbH' not in brief
        assert brief.index('# Task')<brief.index('# Business facts')<brief.index('# Setup')
        (evidence/(task+'-brief.md')).write_text(brief)
        log.append('Generated '+task+' brief business-facts block:\n'+brief[brief.index('# Business facts'):brief.index('# Business facts')+700]+'\n')
    for project in ('bad','duplicate'):
        run(['bin/fm-brief.sh',project,project,'--scout'],code=1)
        assert not (home/'data'/project/'brief.md').exists()
    for project in ('plain','missing'):
        run(['bin/fm-brief.sh',project,project,'--scout'])
        assert '# Business facts' not in (home/'data'/project/'brief.md').read_text()
    # Drive the actual inheritance implementation, then the second home's public scaffold.
    second=scratch/'second'; second.mkdir()
    subprocess.run(['bin/fm-lab-home.sh','create',str(second)],check=True,env=base,stdout=subprocess.DEVNULL)
    script='. bin/fm-config-inherit-lib.sh; propagate_secondmate_inheritance "$FM_HOME" "$DEST"'
    p=subprocess.run(['bash','-c',script],env=env|{'DEST':str(second)},text=True,capture_output=True)
    log.append('$ propagate_secondmate_inheritance\n'+p.stdout+p.stderr+f'[exit {p.returncode}]\n'); assert p.returncode==0
    assert (second/'config/business-facts.md').read_bytes()==(home/'config/business-facts.md').read_bytes()
    shutil.copyfile(reg,second/'data/projects.md')
    run(['bin/fm-brief.sh','inherited-scout','moving-v2','--scout'],e=env|{'FM_HOME':str(second)})
    b=(second/'data/inherited-scout/brief.md').read_text(); assert facts in b
    (evidence/'inherited-scout-brief.md').write_text(b)
    # Memory: linked notes in now, multiple matches, unrelated and other-category guards.
    mem=['bin/fm-memory.sh']; task='headroom-retest-v1'
    run(mem+['remember','--category','now','--task',task,'Headroom comparison','Headroom-Vergleichstest 0.41 laeuft, Ergebnis steht noch aus'])
    run(mem+['remember','--category','now','--task',task,'Headroom followup','Headroom result pending'])
    run(mem+['remember','--category','now','--task','other-task','Other pending','Other still running'])
    run(mem+['remember','--category','now','Unlinked situation','Unlinked still running'])
    run(mem+['remember','--category','events','--task',task,'Headroom historic','Historical started record'])
    store=home/'data/memories'
    protected={p:p.read_bytes() for p in [store/'now/other-pending.md',store/'now/unlinked-situation.md',store/'events/headroom-historic.md']}
    run(mem+['recall','Headroom'])
    report=home/'data'/task/'report.md'; report.parent.mkdir(exist_ok=True); report.write_text('# Headroom\nThe comparison finished: version 0.41 remains preferred.\n')
    run(mem+['complete-task',task,'--report',str(report),'--outcome','Untersuchung abgeschlossen; Version 0.41 bleibt bevorzugt'])
    out=run(mem+['recall','Headroom']); assert 'Erledigt' in out
    assert 'Bericht:' in run(mem+['recall','Bericht'])
    assert 'Ergebnis steht noch aus' not in out and 'result pending' not in out
    run(mem+['now'])
    for p,original in protected.items(): assert p.read_bytes()==original
    completed={p:p.read_bytes() for p in (store/'now').glob('headroom-*.md')}
    assert len(completed)==2
    for p in completed: assert 'completed:' in p.read_text() and str(report) in p.read_text()
    assert run(mem+['complete-task',task,'--outcome','Overwrite attempt'])==''
    for p,original in completed.items(): assert p.read_bytes()==original
    assert run(mem+['complete-task','unknown-task'])==''
    run(mem+['remember','--category','now','--task','landed-ship','Ship landing','Implementation running'])
    run(mem+['complete-task','landed-ship','--pr','https://example.test/pull/42','--outcome','abgeschlossen'])
    assert 'https://example.test/pull/42' in run(mem+['recall','https://example.test/pull/42'])
    before={str(p):p.read_bytes() for p in store.rglob('*.md')}
    run(mem+['complete-task','../escape'],code=3)
    run(mem+['remember','--task','bad/task','Invalid link','body'],code=3)
    assert before=={str(p):p.read_bytes() for p in store.rglob('*.md')}
    (evidence/'memory-final-state.json').write_text(json.dumps({str(p.relative_to(store)):p.read_text() for p in store.rglob('*.md')},indent=2,ensure_ascii=False))
    log.append('All real CLI scenario assertions passed.\n')
finally:
    (evidence/'cli-transcript.log').write_text('\n'.join(log))
    shutil.rmtree(scratch)
