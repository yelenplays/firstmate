#!/usr/bin/env python3
"""Drive the public router CLI against real installed ketch/Jev/provider endpoints.
All mutable homes live in a disposable directory inside the gate worktree.
Only public documentation queries are sent; no credential values are recorded.
"""
import hashlib, json, os, pathlib, shutil, subprocess, tempfile, time
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5CZS0W61XMJMT1EW98XF3BY')
lab = pathlib.Path(tempfile.mkdtemp(prefix='.router-live-', dir=ROOT))
key_dir = pathlib.Path.home()/'.config'
secrets = [os.environ.get('TYPESAFE_API_KEY',''), os.environ.get('OPENROUTER_API_KEY','')]
for provider in ['exa', 'tinyfish']:
    p = key_dir/(provider+'.key')
    if p.is_file(): secrets.append(p.read_text().strip())
def scrub(s):
    for k in secrets:
        if k: s=s.replace(k, '[REDACTED]')
    return s.replace(str(lab), '<isolated-home>')
env = os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('JEV_ROUTE','JEV_URL','JEV_TYPESAFE_ORIGIN','JEV_OPENROUTER_ORIGIN'):
        env.pop(k)
env.update(FM_HOME=str(lab/'home'), HOME=str(lab/'user'),
    XDG_CACHE_HOME=str(lab/'cache'), XDG_CONFIG_HOME=str(lab/'user-config'),
    XDG_DATA_HOME=str(lab/'user-data'), FM_SEARCH_KEY_DIR=str(key_dir))
for k in ('FM_HOME','HOME','XDG_CACHE_HOME','XDG_CONFIG_HOME','XDG_DATA_HOME'):
    pathlib.Path(env[k]).mkdir(parents=True,exist_ok=True)
config=lab/'home/config'
config.mkdir()
(config/'fm-search.json').write_text(json.dumps({'exa':{'monthly_usd_cap':0.04}}))
state=lab/'home/state/fm-search'
records=[]
def run(name,args,extra=None):
    e=dict(env); e.update(extra or {})
    start=time.monotonic()
    try:
        p=subprocess.run([str(ROOT/'bin/fm-search.sh')]+args,env=e,cwd=ROOT,text=True,capture_output=True,timeout=90)
        rec={'name':name,'command':'bin/fm-search.sh '+ ' '.join(repr(a) for a in args),
             'exit':p.returncode,'elapsed_seconds':round(time.monotonic()-start,2),
             'stdout':scrub(p.stdout),'stderr':scrub(p.stderr)}
    except subprocess.TimeoutExpired as ex:
        rec={'name':name,'exit':'outer-timeout','elapsed_seconds':90,'stdout':scrub(str(ex.stdout)), 'stderr':scrub(str(ex.stderr))}
    records.append(rec)
    (EVIDENCE/'live-router-transcript.json').write_text(json.dumps(records,indent=2,ensure_ascii=False)+'\n')
    print(json.dumps(rec,ensure_ascii=False),flush=True)
    return rec
try:
    run('Keyless JSON documentation lookup', ['--no-jev','--json','--limit','2','Python asyncio TaskGroup official documentation'])
    run('Autonomous docs query', ['--json','--limit','2','Python asyncio TaskGroup official documentation'])
    run('Case-insensitive route cache repeat', ['--json','--limit','2','python asyncio taskgroup official documentation'])
    run('Autonomous local SEO query', ['--json','--limit','2','Google Business Profile local search ranking guide'])
    run('TinyFish URL-first text lookup', ['--urls','--limit','2','Python asyncio TaskGroup official documentation'])
    run('Deep Exa auto lookup', ['--deep','--json','--limit','2','Python asyncio TaskGroup cancellation exception group official documentation'])
    run('Current ledger report', ['--ledger'])
    # Validate the persisted public state contract and copy it to evidence.
    for filename in ['ledger.tsv','route-cache.tsv']:
        p=state/filename
        if p.exists():
            text=p.read_text()
            assert not any(k and k in text for k in secrets), 'credential in persisted state'
            for q in ['Python asyncio TaskGroup','Google Business Profile']:
                assert q.lower() not in text.lower(), 'query in persisted state'
            (EVIDENCE/('live-'+filename)).write_text(text)
    jev=lab/'home/state/jev-calls.jsonl'
    if jev.exists():
        text=jev.read_text()
        assert not any(k and k in text for k in secrets), 'credential in Jev log'
        (EVIDENCE/'live-jev-calls.jsonl').write_text(text)
    # Exercise real router cap decisions using synthetic accounting, not fake providers.
    state.mkdir(parents=True,exist_ok=True)
    (state/'ledger.tsv').write_text(f'{int(time.time())}\texa-lite\t0.04000\t0.1\t2\tforced\n')
    run('Exa cap forces next real provider', ['--chain','K','--json','--limit','2','Python contextlib ExitStack official documentation'])
    (state/'ledger.tsv').write_text(''.join(f'{int(time.time())}\ttinyfish\t0.00000\t0.1\t2\tforced\n' for _ in range(25)))
    run('TinyFish minute cap forces keyless provider', ['--urls','--json','--limit','2','Python contextlib ExitStack official documentation'])
    # Directory-as-file is a portable adversarial E_NOTDIR, including when tests run as root.
    broken=lab/'not-a-directory'; broken.write_text('not a directory')
    run('Unwritable accounting skips paid providers safely', ['--chain','K','--json','--limit','2','Python pathlib Path documentation'], {'FM_SEARCH_STATE':str(broken)})
    run('Usage error rejects conflicting modes', ['--urls','--deep','public documentation'])
    # No network replies are mocked. Remove dependencies to exercise exhaustion diagnostics.
    empty=lab/'no-keys'; empty.mkdir()
    run('Missing keys and missing ketch exhaust cleanly', ['--no-jev','public documentation'],
        {'FM_SEARCH_KEY_DIR':str(empty),'FM_SEARCH_KETCH_BIN':str(lab/'absent-ketch')})
finally:
    shutil.rmtree(lab)
    print('Isolated live router home removed.',flush=True)
