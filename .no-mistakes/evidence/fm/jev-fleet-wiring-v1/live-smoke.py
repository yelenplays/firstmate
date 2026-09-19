import os, json, subprocess, tempfile, pathlib, shutil, time
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M2XY77TZ4TSJW41MK90CJWZK')
base={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'JEV_', 'TYPESAFE_', 'OPENROUTER_', 'TASKS_AXI_'))}
rows=[]
with tempfile.TemporaryDirectory(prefix='.jev-live-',dir=root) as tmp:
    lab=pathlib.Path(tmp); home=lab/'home'; home.mkdir(); state=lab/'external-state'; state.mkdir()
    env=base|{'FM_HOME':str(home),'FM_ROOT_OVERRIDE':str(home),'FM_STATE_OVERRIDE':str(state)}
    def run(name,args,extra=None,code=0):
        p=subprocess.run([str(root/'bin'/args[0]),*args[1:]],env=env|(extra or {}),capture_output=True,text=True,timeout=30)
        rows.append({'scenario':name,'argv':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
        assert p.returncode==code,rows[-1]
        return p
    run('Unconfigured wiki stays inert',['fm-wiki-ask.sh','synthetic smoke query'])
    assert not (home/'state').exists()
    run('Configured engine without catalog stays inert',['fm-wiki-ask.sh','synthetic smoke query'],{'FM_WIKI_ENGINE':str(root/'bin/fm-wiki-ask.sh')})
    catalog=lab/'catalog.json'; catalog.write_text('{}')
    run('Missing configured engine reports an error',['fm-wiki-ask.sh','synthetic smoke query'],{'FM_WIKI_ENGINE':str(lab/'absent-wiki-tool'),'FM_WIKI_CATALOG':str(catalog)},2)
    envelope=lab/'envelope.json'
    def miss(name,payload,extra=None):
        envelope.write_text(json.dumps(payload))
        run(name,['fm-jev-retrieval-miss.sh','--query','synthetic smoke query','--envelope-file',str(envelope)],extra)
        record=json.loads((home/'state/jev-retrieval-miss.jsonl').read_text().splitlines()[-1]); rows[-1]['persisted_record']=record
        return record
    clean={'status':'no-match','retrieval':{'status':'disabled','mode':'full-corpus-bm25','pages_searched':0}}
    r=miss('No credentials skips classification',clean); assert r['verdict']=='skipped' and not r['sent']
    for key in ['body','excerpts','conflict_lines','citations']:
        r=miss('Refuse content: '+key,clean|{'nested':{key:['SYNTHETIC_PRIVATE_SENTINEL']}},{'TYPESAFE_API_KEY':'synthetic-unused-key'})
        assert r['verdict']=='refused' and not r['sent'] and 'SYNTHETIC_PRIVATE_SENTINEL' not in json.dumps(r)
    r=miss('Real curl connection refusal preserves attempt metadata',clean,{'TYPESAFE_API_KEY':'synthetic-local-only-key','JEV_URL':'http://127.0.0.1:1','JEV_TIMEOUT':'2'})
    assert r['sent'] and r['verdict']=='skipped' and r['http']=='000' and r['route']=='typesafe' and r['latency_ms'] is not None
    status=state/'smoke.status'; original=b'done: synthetic completion\t\r\n'; status.write_bytes(original)
    (home/'.env').write_text('TYPESAFE_API_KEY=""\nOPENROUTER_API_KEY=\'\'\n')
    p=run('Present completion with quoted-empty credentials without dedup record',['fm-wake-drain.sh'])
    time.sleep(1)
    assert 'synthetic completion' in p.stdout and not list(state.glob('*.jev-done.jsonl')) and status.read_bytes()==original
    rows[-1]['state_assertions']={'original_status_bytes_preserved':True,'verification_records':0}
    run('Direct verifier remains advisory and uses external state',['fm-jev-done-verify.sh','smoke','--done-line','done: synthetic completion'])
    r=json.loads((state/'smoke.jev-done.jsonl').read_text()); rows[-1]['persisted_record']=r
    assert r['verdict']=='skipped' and r['close']==False and r['teardown']==False and status.read_bytes()==original
    assert not (home/'state/smoke.jev-done.jsonl').exists()
(evidence/'live-cli-transcript.json').write_text(json.dumps(rows,indent=2)+'\n')
print(json.dumps({'executed_cli_cases':len(rows),'assertions':'passed','wiki_tool_available':bool(shutil.which('wiki-tool')),'credential_environment_available':any(os.environ.get(k) for k in ['TYPESAFE_API_KEY','OPENROUTER_API_KEY']),'worktree_env_file_present':(root/'.env').exists(),'investigation_report_present':(root/'data/jev-everything-rag-v1/report.md').exists()}))
