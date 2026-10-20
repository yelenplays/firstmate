import json, os, pathlib, shutil, subprocess, tempfile, time
ROOT = pathlib.Path.cwd()
EVID = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5CTFAEA75YTPC3VMXP327HQ')
lab = pathlib.Path(tempfile.mkdtemp(prefix='live-search-', dir=ROOT / '.test-tmp'))
env = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
env.update(FM_HOME=str(lab), FM_SEARCH_CONFIG=str(lab/'config.json'))
(lab/'config.json').write_text('{}')
records=[]
queries=[]
def run(name, args, expected=0):
    started=time.monotonic()
    p=subprocess.run([str(ROOT/'bin/fm-search.sh'), *args], env=env, text=True, capture_output=True, timeout=100)
    text='$ bin/fm-search.sh '+ ' '.join(repr(a) for a in args)+'\n'+p.stdout+'\n[stderr]\n'+p.stderr+f'\nexit={p.returncode} elapsed={time.monotonic()-started:.2f}s\n'
    for keyname in ('exa','tinyfish'):
        keypath=pathlib.Path.home()/'.config'/f'{keyname}.key'
        if keypath.exists():
            key=keypath.read_text().strip()
            assert not key or key not in text, 'provider credential leaked'
    (EVID/(name+'.txt')).write_text(text)
    record={'name':name,'exit':p.returncode,'artifact':name+'.txt','passed':p.returncode==expected}
    records.append(record)
    assert p.returncode==expected, f'{name}: exit {p.returncode}; inspect evidence'
    return json.loads(p.stdout) if '--json' in args and p.returncode==0 else p.stdout

def valid(r):
    assert r['results'] and len(r['results'])<=2
    for x in r['results']:
        assert set(x)=={'title','url','date','snippet'}
        assert all(isinstance(v,str) for v in x.values()) and x['url'].startswith('http')
    assert r['meta']['route'] in ('jev','default','forced')
try:
    q='Python asyncio TaskGroup official documentation'
    queries.append(q)
    a=run('live-auto-docs',['--json','--limit','2',q]); valid(a)
    assert a['meta'].get('class')=='docs' and a['meta']['route']=='jev'
    assert a['meta']['provider']=='exa-lite'
    jevlog=lab/'state/jev-calls.jsonl'
    before=jevlog.read_bytes()
    a=run('live-cache-casefold',['--json','--limit','2',q.lower()]); valid(a)
    assert a['meta'].get('class')=='docs' and a['meta']['route']=='jev'
    assert jevlog.read_bytes()==before, 'cached query called Jev again'
    q='How to improve Google Business Profile visibility for a local plumber'
    queries.append(q)
    a=run('live-auto-local-seo',['--json','--limit','2',q]); valid(a)
    assert a['meta']['route']=='jev' and a['meta'].get('class')=='seo_local'
    assert a['meta']['provider']=='exa-keyless'
    before=jevlog.read_bytes()
    a=run('live-no-jev-text',['--no-jev','--limit','2','Python pathlib documentation'])
    assert 'provider=' in a and 'route=default' in a
    assert 'exa-keyless' in (lab/'state/fm-search/ledger.tsv').read_text()
    assert jevlog.read_bytes()==before
    a=run('live-urls',['--urls','--json','--limit','2','Python asyncio TaskGroup documentation']); valid(a)
    assert a['meta']['provider']=='tinyfish' and a['meta']['route']=='forced'
    a=run('live-deep',['--deep','--json','--limit','2','Python asyncio TaskGroup exception handling documentation']); valid(a)
    assert a['meta']['provider']=='exa-deep' and a['meta']['route']=='forced'
    longq='Python asyncio documentation ' + ('TaskGroup ' * 32)
    a=run('live-long-query',['--json','--limit','2',longq]); valid(a)
    assert a['meta']['route']=='default' and jevlog.read_bytes()==before
    # Real CLI privacy guard refuses an email; router must still answer using F.
    q='Python documentation contact nobody@example.com'
    a=run('live-jev-refusal-fallback',['--json','--limit','2',q]); valid(a)
    assert a['meta']['route']=='default'
    # No synthetic provider: empty key directory removes keyed hops; actual ketch answers.
    (lab/'empty-keys').mkdir()
    env['FM_SEARCH_KEY_DIR']=str(lab/'empty-keys')
    a=run('live-missing-keys',['--chain','K','--json','--limit','2','Python asyncio documentation']); valid(a)
    assert (a['meta']['provider'],a['meta']['hops']) in [('exa-keyless',3),('ketch-multi',4)]
    del env['FM_SEARCH_KEY_DIR']
    # Real limits set to zero: no permission to spend or call TinyFish. Actual ketch answers.
    (lab/'config.json').write_text(json.dumps({'exa':{'monthly_usd_cap':0},'tinyfish':{'per_minute':0}}))
    state=lab/'state/fm-search'
    old= (state/'ledger.tsv').read_text().splitlines()
    a=run('live-cap-skip',['--chain','K','--json','--limit','2','Python pathlib official documentation']); valid(a)
    assert (a['meta']['provider'],a['meta']['hops']) in [('exa-keyless',3),('ketch-multi',4)]
    new=(state/'ledger.tsv').read_text().splitlines()[len(old):]
    assert new and all(row.split('\t')[1] in ('exa-keyless','ketch-multi') for row in new)
    run('live-ledger',['--ledger'])
    for name,args in [('live-usage-conflict',['--urls','--deep','q']),('live-usage-limit',['--limit','0','q']),('live-usage-chain',['--chain','X','q'])]:
        run(name,args,expected=1)
    for path in state.iterdir():
        if path.is_file():
            text=path.read_text()
            assert all(q.lower() not in text.lower() for q in queries)
            shutil.copyfile(path,EVID/('live-state-'+path.name))
    shutil.copyfile(jevlog,EVID/'live-jev-metadata.jsonl')
    (EVID/'live-checks.txt').write_text('Real fm-search.sh + fm-jev.sh + ketch + Exa/TinyFish endpoints used; no provider stand-ins.\nNormalized result fields checked; case-folded repeat made no additional Jev call; forced/no-jev/long query made no Jev call; missing keys and cap guards reached real keyless fallback without keyed ledger rows; persisted router state contains no query text.\n')
finally:
    (EVID/'live-run-results.json').write_text(json.dumps(records,indent=2)+'\n')
    shutil.rmtree(lab)
