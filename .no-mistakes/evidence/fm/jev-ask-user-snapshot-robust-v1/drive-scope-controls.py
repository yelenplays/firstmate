import json, os, pathlib, shutil, subprocess, tempfile
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5EV9GH4T0RZM94ACQ6Y8XTG')
work=pathlib.Path(tempfile.mkdtemp(prefix='.validate-scope-',dir=ROOT))
results=[]
try:
    tools=work/'tools'; tools.mkdir()
    curl=tools/'curl'
    curl.write_text('''#!/usr/bin/env bash
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
'''); curl.chmod(0o755)
    oldbin=work/'base-bin'; oldbin.mkdir()
    for f in (ROOT/'bin').iterdir():
        if f.name != 'fm-jev-ask-user.sh': (oldbin/f.name).symlink_to(f)
    old=oldbin/'fm-jev-ask-user.sh'
    old.write_bytes(subprocess.check_output(['git','show','77517e0de3c83c5249361cb8caaf175d9ddd240a:bin/fm-jev-ask-user.sh'])); old.chmod(0o755)
    short='Make the parser preserve every field on a final line without a newline.\n'
    detail='The parser must preserve empty fields and field ordering on valid input.\n'*180
    limit='MANDATORY SCOPE LIMIT: This task is documentation-only. Do not edit bin/parse.sh or any production code. Only record the observed bug in docs/parser-known-issues.md. Any production code fix needs a separate explicit decision.\n'
    description='The parser drops the final field on a line without a trailing newline. Fix the parser and add a regression test to satisfy the accepted behavior.'
    for name,cli,shape,cap,steers in [
        ('base-json-repro',old,'json',8192,False),
        ('base-overcap-repro',old,'lines',8192,False),
        ('full-scope-control',ROOT/'bin/fm-jev-ask-user.sh','json',32768,False),
        ('latest-steer-trimmed',ROOT/'bin/fm-jev-ask-user.sh','json',8192,True),
        ('latest-steer-full-control',ROOT/'bin/fm-jev-ask-user.sh','json',32768,True),
    ]:
        h=work/name
        for d in ['data/t1','state','config','projects/sample']: (h/d).mkdir(parents=True)
        finding=h/'data/t1/findings.txt'
        finding.write_text(json.dumps({'findings':[{'id':'F1','severity':'error','action':'ask-user','description':description}]}) if shape=='json' else 'id: F1\nseverity: error\nauthority/action: ask-user\ndescription: '+description+'\n')
        intent=short if steers else short+detail+'\n'+limit
        spec='- Fix bin/parse.sh to preserve every field and add a regression test.\n' if steers else '- Document the parser behavior in docs/parser-known-issues.md.\n'
        (h/'data/t1/brief.md').write_text("# Task\n## Captain's intent\n"+intent+'\n## Firstmate spec\n'+spec+'\n# Setup\n')
        if steers:
            (h/'state/t1.inbox/handled').mkdir(parents=True)
            (h/'state/t1.inbox/handled/001.msg').write_text('schema=fm-task-inbox.v1\nat=2026-10-04T20:00:00Z\n--\n'+detail)
            (h/'state/t1.inbox/002.msg').write_text('schema=fm-task-inbox.v1\nat=2026-10-04T20:02:00Z\n--\n'+limit)
        (h/'state/t1.meta').write_text('kind=ship\nmode=no-mistakes\nproject='+str(h/'projects/sample')+'\n')
        key='nm-LIVECONTROL-review'
        (h/'state/t1.status').write_text('needs-decision [key='+key+']: ask-user findings=F1 file='+str(finding)+'\n')
        env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}
        env.update(FM_HOME=str(h), PATH=str(tools)+':'+os.environ['PATH'], JEV_STATE_MAX_BYTES=str(cap),PROBE_REQUEST=str(E/(name+'-request.json')),PROBE_RESPONSE=str(E/(name+'-response.json')))
        p=subprocess.run([str(cli),'t1',key,'--round','1'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=70)
        r={'name':name,'exit':p.returncode,'output':p.stdout}
        log=h/'state/jev-ask-user.jsonl'
        if log.exists(): r['decision_log']=[json.loads(l) for l in log.read_text().splitlines()]
        req=E/(name+'-request.json')
        if req.exists():
            s=json.loads(req.read_text())['state']
            r.update(request_state_bytes=len(s.encode()),contains_scope_limit='MANDATORY SCOPE LIMIT' in s)
        results.append(r); print(json.dumps(r),flush=True)
finally:
    shutil.rmtree(work)
    (E/'scope-control-results.json').write_text(json.dumps(results,indent=2)+'\n')
