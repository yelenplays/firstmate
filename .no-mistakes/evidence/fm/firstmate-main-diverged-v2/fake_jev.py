#!/usr/bin/env python3
"""Local stand-in for the TypeSafe /v1/systemone endpoint.
Records every request body (and the Authorization header) to $REC/requests.jsonl
and answers from $REC/mode: `noul=<x>` | `http=<code>` | `hang` | `garbage`."""
import http.server, json, os, sys, time
REC = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n).decode()
        with open(os.path.join(REC, 'requests.jsonl'), 'a') as f:
            f.write(json.dumps({'path': self.path, 'auth': self.headers.get('Authorization'), 'body': json.loads(body)}) + '\n')
        mode = open(os.path.join(REC, 'mode')).read().strip()
        if mode == 'hang':
            time.sleep(30); return
        if mode.startswith('http='):
            self.send_response(int(mode[5:])); self.end_headers(); self.wfile.write(b'{"error":"x"}'); return
        if mode == 'garbage':
            out = {'answers': {'captain_relevant': {'noul': 7}, 'stuck': {'noul': 'high'}}}
        else:
            x = float(mode.split('=')[1])
            out = {'answers': {'captain_relevant': {'noul': x}, 'stuck': {'noul': x},
                               'verb': {'choice': 'note', 'confidence': 0.9},
                               'state': {'choice': 'genuinely_stuck', 'confidence': 0.8}}}
        b = json.dumps(out).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
