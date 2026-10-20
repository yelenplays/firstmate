import http.server, json, os, pathlib, shutil, subprocess, tempfile, threading
root=pathlib.Path.cwd()
evid=pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M5CTFAEA75YTPC3VMXP327HQ')
lab=pathlib.Path(tempfile.mkdtemp(prefix='billing-regression-',dir=root/'.test-tmp'))
calls=[]
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_POST(self):
        self.rfile.read(int(self.headers['Content-Length']))
        calls.append(1)
        self.send_response(200); self.end_headers(); self.wfile.write(b'\xff')
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
logs=[]
try:
    (lab/'keys').mkdir()
    (lab/'keys/exa.key').write_text('offline-only-placeholder')
    (lab/'config.json').write_text(json.dumps({'exa':{'monthly_usd_cap':0.005,'per_query_usd':0.004}}))
    prior=subprocess.check_output(['git','show','c88f5b19:bin/fm-search.py'],text=True)
    (lab/'prior.py').write_text(prior)
    env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}
    env.update(FM_HOME=str(lab),FM_SEARCH_KEY_DIR=str(lab/'keys'),FM_SEARCH_CONFIG=str(lab/'config.json'),FM_SEARCH_EXA_URL=f'http://127.0.0.1:{server.server_port}/exa',FM_SEARCH_KETCH_BIN='/usr/bin/false')
    for label,cmd in [('before',['python3','-I',str(lab/'prior.py')]),('after',[str(root/'bin/fm-search.sh')])]:
        env['FM_SEARCH_STATE']=str(lab/label)
        count=len(calls)
        logs.append(f'=== {label}: two public CLI calls, HTTP 200 with invalid UTF-8, price $0.004 / cap $0.005 ===\n')
        for i in range(2):
            p=subprocess.run(cmd+['--chain','K','billing regression public test'],env=env,text=True,capture_output=True,timeout=15)
            logs.append(f'call {i+1} exit={p.returncode}\n'+p.stdout+p.stderr)
            assert p.returncode==3
        ledger=(lab/label/'ledger.tsv').read_text()
        logs.append('persisted ledger:\n'+ledger)
        p=subprocess.run(cmd+['--ledger'],env=env,text=True,capture_output=True,timeout=15)
        logs.append(p.stdout)
        paid=[row.split('\t') for row in ledger.splitlines() if row.split('\t')[1]=='exa-lite']
        if label=='before':
            assert len(calls)-count==2 and len(paid)==2 and sum(float(row[2]) for row in paid)==0
        else:
            assert len(calls)-count==1 and len(paid)==1 and float(paid[0][2])==0.004
            assert 'exa monthly cap reached' in logs[-3]
        logs.append(f'Observed Exa HTTP requests: {len(calls)-count}\n')
finally:
    server.shutdown(); server.server_close(); shutil.rmtree(lab)
    (evid/'billing-before-after.txt').write_text('\n'.join(logs))
