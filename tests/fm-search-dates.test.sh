#!/usr/bin/env bash
# Offline regression for the router's public JSON and text date contracts.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-search-dates)
python3 -I - "$ROOT" "$TMP_ROOT" <<'PY'
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading

root, tmp = map(Path, sys.argv[1:])
# Natural-language TinyFish dates must not lose the year; unsupported and
# impossible dates must be empty, not merely truncated to ten characters.
cases = [
    ("Aug 27, 2021", "2021-08-27"),
    ("August 27, 2021", "2021-08-27"),
    ("2026-03-04", "2026-03-04"),
    ("2026-03-04T12:34:56.000Z", "2026-03-04"),
    ("Feb 29, 2024", "2024-02-29"),
    ("Feb 29, 2023", ""),
    ("2026-02-30", ""),
    ("yesterday", ""),
    ("Aug 27, 20", ""),
    ("", ""),
    (None, ""),
]
items = [dict(title=f"Result {i}", url=f"https://example.test/{i}",
              date=date, snippet="A snippet")
         for i, (date, _) in enumerate(cases)]
exa = [dict(title=x["title"], url=x["url"], publishedDate=x["date"],
            highlights=[x["snippet"]]) for x in items]
ketch = [dict(title=x["title"], url=x["url"],
              description="Published: " + (x["date"] or "N/A"),
              content=x["snippet"]) for x in items]

class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, results):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps({"results": results}).encode())

    def do_GET(self):
        self.reply(items)

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.reply(exa)

keys = tmp / "keys"
keys.mkdir()
for name in ("exa", "tinyfish"):
    (keys / (name + ".key")).write_text("offline-stub-key")
fake = tmp / "ketch"
fake.write_text("#!/bin/sh\nprintf '%s\\n' '" + json.dumps(ketch) + "'\n")
fake.chmod(0o755)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_port}/"
env = dict(os.environ, FM_HOME=str(tmp), FM_SEARCH_STATE=str(tmp / "state"),
           FM_SEARCH_KEY_DIR=str(keys), FM_SEARCH_CONFIG=str(tmp / "missing.json"),
           FM_SEARCH_KETCH_BIN=str(fake), FM_SEARCH_EXA_URL=url,
           FM_SEARCH_TINYFISH_URL=url)
try:
    for provider, flags in (("tinyfish", ["--urls"]), ("exa-lite", ["--chain", "K"]),
                            ("exa-keyless", ["--no-jev"])):
        command = [str(root / "bin/fm-search.sh"), *flags, "--limit", "20"]
        for as_json in (True, False):
            run = subprocess.run(command + (["--json"] if as_json else []) +
                                 ["Python contextlib ExitStack official documentation"],
                                 env=env, capture_output=True, text=True, timeout=10)
            assert run.returncode == 0, (provider, run.stderr)
            if as_json:
                data = json.loads(run.stdout)
                assert data["meta"]["provider"] == provider, data
                expected = [dict(x, date=date) for x, (_, date) in zip(items, cases)]
                assert data["results"] == expected, (provider, data["results"])
            else:
                lines = run.stdout.splitlines()
                for x, (_, date) in zip(items, cases):
                    expected = "   " + x["url"] + (f" ({date})" if date else "")
                    assert expected in lines, (provider, expected, run.stdout)
finally:
    server.shutdown()
    server.server_close()
PY
pass "provider dates normalize consistently in JSON and text"
