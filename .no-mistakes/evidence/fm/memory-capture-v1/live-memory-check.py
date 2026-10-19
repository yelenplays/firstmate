import os, json, pathlib, subprocess, time, threading, http.server, signal
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M59XY24CQN6E6XS9CMW0DM5S')
home=root/'.local-test-tmp/live-home-drain'
for d in ['data','state','config']: (home/d).mkdir(parents=True,exist_ok=True)
requests=[]
class Observe(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        requests.append({'path':self.path,'body':self.rfile.read(int(self.headers.get('Content-Length','0'))).decode()})
        self.send_response(503); self.end_headers()
    def log_message(self,*a): pass
server=http.server.HTTPServer(('127.0.0.1',0), Observe)
threading.Thread(target=server.serve_forever,daemon=True).start()
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ['CLAUDECODE','CLAUDE_CODE_ENTRYPOINT']: env.pop(k,None)
env.update(FM_HOME=str(home),FM_MEMORY_DIR=str(home/'data/memories'),TMPDIR=str(root/'.local-test-tmp'),TZ='UTC',TYPESAFE_API_KEY='local-privacy-probe',JEV_ROUTE='typesafe',JEV_URL=f'http://127.0.0.1:{server.server_port}/jev')
transcript=home/'conversation.jsonl'
log=[]
def record(s): log.append(s); print(s,flush=True)
def call(script,*args,ok=True):
    p=subprocess.run([str(root/'bin'/script),*args],env=env,text=True,capture_output=True,timeout=45)
    record('$ '+script+' '+' '.join(args)+'\n'+p.stdout+p.stderr+f'[exit {p.returncode}]')
    if ok: assert p.returncode==0
    return p
now=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
def append_turn(id,text):
    with transcript.open('a') as f:
        for row in [{'type':'user','origin':{'kind':'human'},'uuid':id,'timestamp':now,'message':{'content':text}}, {'type':'assistant','uuid':id+'-reply','timestamp':now,'message':{'content':[{'type':'text','text':'Understood.'}],'stop_reason':'end_turn'}}]: f.write(json.dumps(row)+'\n')
first=None
try:
    record('Real CLI manual replay: isolated FM_HOME; real Claude CLI, no model or product stubs. Synthetic captain input; loopback observer detects any configured Jev request.')
    long=('This is temporary release checklist discussion, not a lasting preference. '*205)+'\nFor every release note from now on, always use the exact closing signature OAK-74291-NIMBUS. Please remember this preference across sessions.'
    append_turn('long-release-preference',long)
    call('fm-history.sh','capture','--transcript',str(transcript))
    dry=call('fm-memory-capture.sh','run','--dry-run')
    plan=json.loads(dry.stdout.strip().splitlines()[-1]); assert plan['units']==2 and plan['model_calls']==1
    assert not (home/'state/memory-capture/lock').exists()
    assert not (home/'state/memory-capture/pending').exists()
    assert not (home/'state/memory-capture/watermark.json').exists()
    out=(evidence/'live-precompact-drain.jsonl').open('w')
    first=subprocess.Popen([str(root/'bin/fm-memory-capture.sh'),'run','--trigger','precompact'],env=env,text=True,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
    deadline=time.monotonic()+20
    extraction_started=False
    while first.poll() is None and time.monotonic()<deadline:
        rows=subprocess.run(['ps','-axo','pid=,ppid=,command='],capture_output=True,text=True,check=True).stdout.splitlines()
        processes={}
        for row in rows:
            parts=row.strip().split(None,2)
            if len(parts)==3: processes[int(parts[0])]=(int(parts[1]),parts[2])
        def descendant(pid):
            seen=set()
            while pid in processes and pid not in seen:
                seen.add(pid)
                pid=processes[pid][0]
                if pid==first.pid: return True
            return False
        extraction_started=any('--no-session-persistence' in cmd and '--json-schema' in cmd and descendant(pid) for pid,(parent,cmd) in processes.items())
        if extraction_started: break
        time.sleep(.03)
    assert extraction_started, 'real Claude child did not start before the overlap window'
    record('Observed real Claude extraction child before importing the later turn; first pass has already read its journal slice.')
    append_turn('sessionend-tea-preference','From now on remember that my favorite tea for late-night releases is rooibos, not mint. Also remember that this month I am moving to Bristol after separating from my partner; I may refer to the move without restating it.')
    call('fm-history.sh','capture','--transcript',str(transcript))
    handoff=call('fm-memory-capture.sh','run','--trigger','sessionend')
    record('Pending boundary immediately after overlapping SessionEnd: '+str((home/'state/memory-capture/pending').exists()))
    assert 'drain this boundary' in handoff.stdout, 'SessionEnd did not overlap the first capture'
    assert (home/'state/memory-capture/pending').exists()
    rc=first.wait(timeout=330); out.close()
    record('First capture process exit: '+str(rc))
    record((evidence/'live-precompact-drain.jsonl').read_text())
    if rc!=0:
        record('REAL MODEL EXTRACTION UNAVAILABLE: watermark must remain absent; inspect model diagnostic above.')
        assert not (home/'state/memory-capture/watermark.json').exists()
    else:
        passes=[json.loads(x) for x in (home/'state/memory-capture/runs.jsonl').read_text().splitlines()]
        assert passes[0]['turns']==1 and passes[1]['turns']==1 and passes[1]['trigger']=='sessionend', 'newer turn was not drained as a separate pass'
        call('fm-memory-capture.sh','status')
        call('fm-memory.sh','now')
        call('fm-memory.sh','now','--exclude-private')
        recall=call('fm-memory.sh','recall','--json','OAK-74291-NIMBUS')
        assert json.loads(recall.stdout)['documents'], 'tail preference not recalled'
        tea=call('fm-memory.sh','recall','--json','rooibos')
        assert json.loads(tea.stdout)['documents'], 'overlapping SessionEnd preference not recalled'
        mark=json.loads((home/'state/memory-capture/watermark.json').read_text()); assert mark['id']=='sessionend-tea-preference'
        assert not (home/'state/memory-capture/pending').exists()
        assert not (home/'state/memory-capture/lock').exists()
        call('fm-memory-capture.sh','run','--trigger','sessionend')
        for file in (home/'data/memories').rglob('*.md'): record('Persisted memory '+str(file.relative_to(home))+'\n'+file.read_text())
        (evidence/'live-watermark.json').write_text((home/'state/memory-capture/watermark.json').read_text())
        (evidence/'live-runs.jsonl').write_text((home/'state/memory-capture/runs.jsonl').read_text())
    record('Configured Jev HTTP requests observed: '+str(len(requests)))
    (evidence/'jev-observation.json').write_text(json.dumps(requests,indent=2)+'\n')
    assert not requests, 'capture sent a request to configured Jev endpoint'
    record('Long input length: '+str(len(long))+' characters; signature is after both 2400 and 12000 characters.')
finally:
    if first and first.poll() is None:
        os.killpg(first.pid,signal.SIGTERM)
        try: first.wait(timeout=5)
        except subprocess.TimeoutExpired: os.killpg(first.pid,signal.SIGKILL); first.wait()
    server.shutdown()
    (evidence/'live-memory-drain-cli.log').write_text('\n'.join(log)+'\n')
