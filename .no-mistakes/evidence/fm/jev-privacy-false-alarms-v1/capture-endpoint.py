# Local stand-in for the Jev HTTP endpoint: records every request body it
# receives (proving what left the CLI) and answers with a canned Jev response.
import http.server, json, os, sys
OUT = sys.argv[2]
RESP = json.dumps({"model": "jev-1.13.0",
  "answers": {"f1": {"type": "choice", "choice": "in-scope-fix", "confidence": 0.99,
    "probabilities": {"in-scope-fix": 0.9925, "expands-contract": 0.0025, "unsettled-call": 0.0025, "destructive-or-security": 0.0025}},
    "s1": {"type": "noul", "noul": 0.01}},
  "usage": {"input_tokens": 900, "output_tokens": 12}}).encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        k = len([f for f in os.listdir(OUT) if f.startswith("req-")]) + 1
        with open(os.path.join(OUT, "req-%04d.json" % k), "wb") as f: f.write(body)
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(RESP))); self.end_headers(); self.wfile.write(RESP)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
