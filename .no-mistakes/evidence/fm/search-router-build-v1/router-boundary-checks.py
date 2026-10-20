#!/usr/bin/env python3
"""Real CLI checks for routing boundaries and the generated worker interface."""
import hashlib,json,os,pathlib,shutil,subprocess,tempfile,time
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5CZS0W61XMJMT1EW98XF3BY')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.router-boundaries-',dir=root))
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_'): env.pop(k)
env.update(FM_HOME=str(lab),HOME=str(lab/'user'),XDG_CACHE_HOME=str(lab/'cache'),XDG_CONFIG_HOME=str(lab/'user-config'), FM_SEARCH_KEY_DIR=str(pathlib.Path.home()/'.config'))
for p in ['user','cache','user-config','config','state/fm-search']: (lab/p).mkdir(parents=True,exist_ok=True)
(lab/'config/fm-search.json').write_text('{"exa":{"monthly_usd_cap":0.02}}')
records=[]
def run(name,script,args):
    p=subprocess.run([str(root/'bin'/script)]+args,env=env,text=True,capture_output=True,timeout=90)
    r={'name':name,'command':script+' '+' '.join(repr(x) for x in args),'exit':p.returncode,'stdout':p.stdout.replace(str(lab),'<isolated-home>'),'stderr':p.stderr.replace(str(lab),'<isolated-home>')}
    records.append(r)
    print(json.dumps(r),flush=True)
    return p
try:
    q='Python asyncio TaskGroup official documentation'
    h=hashlib.sha256(q.lower().encode()).hexdigest()[:24]
    cache=lab/'state/fm-search/route-cache.tsv'
    cache.write_text(f'{h}\t{int(time.time())-86401}\tseo_local\n')
    p=run('Expired cache calls real Jev again','fm-search.sh',['--json','--limit','1',q])
    assert p.returncode==0
    data=json.loads(p.stdout)
    assert data['meta']['route']=='jev' and data['meta']['class']=='docs'
    cache_lines=cache.read_text().splitlines()
    assert len(cache_lines)==2 and cache_lines[-1].split('\t')[2]=='docs'
    (evidence/'expired-cache-after.tsv').write_text(cache.read_text())
    before=(lab/'state/jev-calls.jsonl').read_text().splitlines()
    longquery='Python documentation ' + ('contextlib ExitStack ' * 17)
    assert len(longquery.encode())>300
    p=run('Over-300-byte query skips real Jev','fm-search.sh',['--json','--limit','1',longquery])
    assert p.returncode==0 and json.loads(p.stdout)['meta']['route']=='default'
    assert (lab/'state/jev-calls.jsonl').read_text().splitlines()==before
    env['FM_JEV_BIN']=str(lab/'absent-jev')
    p=run('Missing Jev executable falls back autonomously','fm-search.sh',['--json','--limit','1','Python contextlib documentation'])
    assert p.returncode==0 and json.loads(p.stdout)['meta']['route']=='default'
    env.pop('FM_JEV_BIN')
    # This phase validates generated public briefs, not model interpretation or lifecycle.
    for task,args in [('router-ship',['router-ship','router-validation','--mode','local-only']),('router-scout',['router-scout','router-validation','--scout'])]:
        p=run('Generate '+task+' search instructions','fm-brief.sh',args)
        assert p.returncode==0
        brief=(lab/'data'/task/'brief.md').read_text()
        prior=brief.split('# Prior art',1)[1].split('\n# ',1)[0]
        assert str(root/'bin/fm-search.sh') in prior
        if task=='router-scout':
            rules=brief.split('# Rules',1)[1].split('\n# ',1)[0]
            assert 'For web research, search with' in rules and 'ketch scrape <url>' in rules
        (evidence/(task+'-brief.md')).write_text(brief.replace(str(lab),'<isolated-home>'))
finally:
    (evidence/'router-boundary-transcript.json').write_text(json.dumps(records,indent=2,ensure_ascii=False)+'\n')
    shutil.rmtree(lab)
