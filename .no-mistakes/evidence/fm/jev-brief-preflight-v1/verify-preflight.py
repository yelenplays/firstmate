import os, json, pathlib, subprocess, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/yelen/.no-mistakes/evidence/01M2X0HH34W4A0VA7J5EJ5GEZZ')
requests = []
choice = 'complete'
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        requests.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        self.send_response(503 if choice == 'outage' else 200)
        self.end_headers()
        self.wfile.write(json.dumps({'answers': {'brief': {'type': 'choice', 'choice': choice, 'confidence': .9}}}).encode())
server = HTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
results = []
try:
    with tempfile.TemporaryDirectory(prefix='.preflight-evidence-', dir=root) as tmp:
        fixture = pathlib.Path(tmp)
        home = fixture / 'home'
        project = fixture / 'project'
        fakebin = fixture / 'bin'
        for p in [home/'state', home/'data', home/'config', project, fakebin]: p.mkdir(parents=True)
        subprocess.run(['git', '-C', str(project), 'init', '-q'], check=True)
        (fakebin/'tmux').write_text('#!/bin/sh\necho "TEST BOUNDARY: worker backend intentionally unavailable" >&2\nexit 1\n')
        (fakebin/'tmux').chmod(0o755)
        env = dict(os.environ)
        for k in list(env):
            if k.startswith(('FM_', 'JEV_', 'TYPESAFE_', 'OPENROUTER_')): env.pop(k)
        env.update(FM_HOME=str(home), FM_STATE_OVERRIDE=str(home/'state'), FM_DATA_OVERRIDE=str(home/'data'), FM_CONFIG_OVERRIDE=str(home/'config'), FM_PROJECTS_OVERRIDE=str(fixture/'unused'), FM_SPAWN_NO_GUARD='1', FM_GATE_REFUSE_BYPASS='1', FM_BACKEND='tmux', TYPESAFE_API_KEY='synthetic-evidence-key', JEV_ROUTE='typesafe', JEV_URL=f'http://127.0.0.1:{server.server_port}/v1/systemone', PATH=str(fakebin)+os.pathsep+env['PATH'])
        for choice in ['complete', 'need_human', 'outage']:
            task = 'evidence-' + choice
            scaffold = ['bin/fm-brief.sh', task, 'project', '--mode', 'direct-PR']
            subprocess.run(scaffold, env=env, check=True, capture_output=True, text=True)
            brief = home/'data'/task/'brief.md'
            brief.write_text(brief.read_text().replace('{TASK}', 'Fix the pager off-by-one.').replace('{FIRSTMATE_SPEC}', 'Change only pager.sh and add a regression test.'))
            if choice == 'complete': (evidence/'generated-brief.md').write_text(brief.read_text())
            cmd = ['bin/fm-spawn.sh', task, str(project), 'claude', '--mode', 'direct-PR', '--yolo', 'off']
            proc = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=30)
            record = json.loads((home/'state'/f'{task}.jev-brief-preflight.jsonl').read_text())
            assert record['verdict'] == ('skipped' if choice == 'outage' else choice)
            assert record['block'] is False
            assert record['http'] == ('503' if choice == 'outage' else '200')
            assert isinstance(record['latency_ms'], (int, float))
            assert ('warning: brief preflight:' in proc.stderr) == (choice == 'need_human')
            assert requests[-1]['state'] == dict(query='Check worker brief structural completeness', kind='ship', delivery_mode='direct-PR', recorded_delivery='direct-PR', has_task=True, has_definition_of_done=True, has_captain_intent=True, has_firstmate_spec=True)
            results.append(dict(scenario=choice, scaffold_command=scaffold, command=cmd, exit_code=proc.returncode, stdout=proc.stdout, stderr=proc.stderr, request=requests[-1], persisted_record=record))
finally:
    server.shutdown()
(evidence/'spawn-preflight-transcript.json').write_text(json.dumps({'boundary': 'Real scaffold, spawn, preflight and curl against a local HTTP fixture. Synthetic responses; worker backend intentionally unavailable. No live model classification evaluated.', 'scenarios': results}, indent=2)+'\n')
print('Captured generated brief, real HTTP request bodies, spawn output, and persisted verdicts for complete, need_human, and HTTP 503 scenarios.')
