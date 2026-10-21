import json, os, pathlib, shutil, subprocess, tempfile

ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5EV9GH4T0RZM94ACQ6Y8XTG')
work = pathlib.Path(tempfile.mkdtemp(prefix='.validate-ask-user-', dir=ROOT))
results = []
try:
    tools = work / 'tools'
    tools.mkdir()
    # Transparent transport observation: the real curl reaches the real API.
    wrapper = tools / 'curl'
    wrapper.write_text('''#!/usr/bin/env bash
body=$(mktemp)
trap 'rm -f "$body"' EXIT
cat > "$body"
cp "$body" "$PROBE_REQUEST"
out=''
args=("$@")
for ((i=0; i<$#; i++)); do
  if [ "${args[$i]}" = -o ]; then out=${args[$((i+1))]}; fi
done
/usr/bin/curl "$@" < "$body"
rc=$?
[ ! -f "$out" ] || cp "$out" "$PROBE_RESPONSE"
exit "$rc"
''')
    wrapper.chmod(0o755)
    short = 'Make the parser preserve every field on a final line without a newline.\n'
    detail = ''.join('The parser must preserve empty fields and field ordering on valid input.\n' for _ in range(180))
    spec = '- Fix bin/parse.sh to preserve every field and add a regression test.\n'
    ordinary = {'id':'F1','severity':'error','action':'ask-user','description':'The parser drops the final field on a line without a trailing newline. Fix the parser and add a regression test to satisfy the accepted behavior.'}
    ci = {'id':'ci-1','severity':'error','action':'ask-user','description':'The first CI run failed on a flaky network fetch; the replacement run is green. Refresh the delivery evidence to refer to the passing replacement run.'}
    cases = [
        ('json-short', short, spec, [ordinary], None, False),
        ('json-long-ci', short+detail, spec+detail, [ci], None, False),
        ('toon-long-ci', short+detail, spec+detail, [ci], None, True),
        ('bare-json-array', short, spec, [ordinary], None, False),
        ('missing-json-id', short, spec, [ordinary], 'F9', False),
        ('duplicate-json-id', short, spec, [ordinary,ordinary], None, False),
        ('json-sensitive-finding', short, spec, [dict(ordinary, description='Fixing the parser requires deleting persisted customer records irreversibly.')], None, False),
        ('secret-in-trimmed-tail', short+detail+'\napi_key: sk-test-EXAMPLEONLYnotarealsecret123456789\n', spec, [ordinary], None, False),
        ('oversized-finding', short, spec, [dict(ordinary,description=ordinary['description']+' '+('Detailed finding evidence. '*500))], None, False),
        ('late-scope-restriction', short+detail+'\nMANDATORY SCOPE LIMIT: This task is documentation-only. Do not edit bin/parse.sh or any production code. Only record the observed bug in docs/parser-known-issues.md. Any production code fix needs a separate explicit decision.\n', '- Document the parser behavior in docs/parser-known-issues.md.\n', [ordinary], None, False),
        ('early-scope-restriction-control', 'MANDATORY SCOPE LIMIT: This task is documentation-only. Do not edit bin/parse.sh or any production code. Only record the observed bug in docs/parser-known-issues.md. Any production code fix needs a separate explicit decision.\n'+short, '- Document the parser behavior in docs/parser-known-issues.md.\n', [ordinary], None, False),
    ]
    for name, intent, specification, rows, asked, toon in cases:
        home = work / name
        (home/'data/t1').mkdir(parents=True)
        (home/'state').mkdir()
        (home/'config').mkdir()
        (home/'projects/sample').mkdir(parents=True)
        step = 'ci' if 'ci' in name else 'review'
        key = 'nm-LIVEVALIDATION-'+step
        ids = asked or rows[0]['id']
        snapshot = home/'data/t1/findings.txt'
        if toon:
            snapshot.write_text('findings[1]{id,severity,action,description}:\n  '+','.join([rows[0]['id'],'error','ask-user',json.dumps(rows[0]['description'])])+'\n')
        else:
            snapshot.write_text(json.dumps(rows if name=='bare-json-array' else {'findings':rows}))
        (home/'data/t1/brief.md').write_text("# Task\n## Captain's intent\n"+intent+'\n## Firstmate spec\n'+specification+'\n# Setup\n')
        (home/'state/t1.meta').write_text('kind=ship\nmode=no-mistakes\nproject='+str(home/'projects/sample')+'\n')
        (home/'state/t1.status').write_text('needs-decision [key='+key+']: ask-user findings='+ids+' file='+str(snapshot)+'\n')
        env = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
        env.update(FM_HOME=str(home), PATH=str(tools)+':'+os.environ['PATH'],
                   PROBE_REQUEST=str(EVIDENCE/(name+'-request.json')), PROBE_RESPONSE=str(EVIDENCE/(name+'-response.json')))
        p = subprocess.run([str(ROOT/'bin/fm-jev-ask-user.sh'),'t1',key,'--round','1'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=70)
        record={'name':name,'exit':p.returncode,'output':p.stdout}
        log = home/'state/jev-ask-user.jsonl'
        if log.exists(): record['decision_log']=[json.loads(l) for l in log.read_text().splitlines()]
        req = EVIDENCE/(name+'-request.json')
        if req.exists():
            state=json.loads(req.read_text())['state']
            record['request_state_bytes']=len(state.encode())
            record['contains_scope_limit']='MANDATORY SCOPE LIMIT' in state
            record['trimmed']='[... trimmed to fit the Jev state cap ...]' in state
        results.append(record)
        print(json.dumps(record),flush=True)
finally:
    shutil.rmtree(work)
    (EVIDENCE/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
