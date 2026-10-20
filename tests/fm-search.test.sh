#!/usr/bin/env bash
# Behavior tests for bin/fm-search.sh, offline.
#
# Every provider is a stand-in: a fake ketch and a fake fm-jev.sh through the
# FM_SEARCH_KETCH_BIN and FM_JEV_BIN hooks, and one local HTTP stub that
# answers as Exa (POST /exa) and TinyFish (GET /tinyfish/). No case reaches a
# paid API. Provider payloads under tests/fixtures/fm-search/ are recorded from
# the phase-1 bench (data/search-router-bench-v1, query 1).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-search.sh"
FIX="$ROOT/tests/fixtures/fm-search"
TMP_ROOT=$(fm_test_tmproot fm-search)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
STUB="$TMP_ROOT/stub"
KEYS="$TMP_ROOT/keys"
mkdir -p "$STUB" "$KEYS"
EXA_KEY=stubkey-exa-5d1f0c9a
TF_KEY=stubkey-tinyfish-8b2e47aa
QMARK=quokkaledgerprobe   # every query carries it; the ledger and cache must not
ALL_OUT="$TMP_ROOT/all-output.log"
: > "$ALL_OUT"

# --- stand-ins ------------------------------------------------------------------

# The HTTP stub: each provider's behavior comes from $STUB/<exa|tinyfish>.mode
# (ok, empty, 429, slow, lag, trickle, headers, utf8); each request appends one JSON line to <name>.req.
cat > "$TMP_ROOT/stub_server.py" <<'PY'
import http.server, json, os, sys, threading, time, urllib.parse
stub, fix, exa_key, tf_key = sys.argv[1:5]
def mode(name):
    try:
        return open(os.path.join(stub, name + ".mode")).read().strip()
    except OSError:
        return "ok"
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def answer(self, name, rec):
        with open(os.path.join(stub, name + ".req"), "a") as f:
            f.write(json.dumps(rec) + "\n")
        m = mode(name)
        if m == "429":
            self.send_response(429); self.end_headers(); return
        if m == "slow":
            time.sleep(6)
        if m == "lag":
            time.sleep(0.3)
        if m == "headers":
            # Status and header bytes arrive one at a time, each gap shorter
            # than the socket timeout, for longer than the hop deadline.
            try:
                for ch in b"HTTP/1.1 200 OK\r\nX-Slow: " + b"x" * 120:
                    self.connection.sendall(bytes([ch])); time.sleep(0.05)
            except OSError:
                pass
            self.close_connection = True
            return
        if m == "trickle":
            self.send_response(200)
            self.send_header("Content-Length", "200")
            self.end_headers()
            try:
                for _ in range(120):
                    self.wfile.write(b" "); self.wfile.flush(); time.sleep(0.05)
            except OSError:
                pass
            return
        body = json.dumps({"results": []}) if m == "empty" else json.dumps(["not", "a", "dict"]) if m == "shape" else open(os.path.join(fix, name + ".json")).read()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        try:
            self.wfile.write(b"\xff" if m == "utf8" else body.encode())
        except OSError:
            pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        rec = json.loads(self.rfile.read(n) or b"{}")
        rec["key_ok"] = self.headers.get("x-api-key") == exa_key
        self.answer("exa", rec)
    def do_GET(self):
        rec = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(self.path).query))
        rec["key_ok"] = self.headers.get("X-API-Key") == tf_key
        self.answer("tinyfish", rec)
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
open(os.path.join(stub, "port.tmp"), "w").write(str(srv.server_address[1]))
os.rename(os.path.join(stub, "port.tmp"), os.path.join(stub, "port"))
# Outlive no test run by long: a hard-killed suite leaves no server behind.
threading.Timer(600, lambda: os._exit(0)).start()
srv.serve_forever()
PY
python3 -I "$TMP_ROOT/stub_server.py" "$STUB" "$FIX" "$EXA_KEY" "$TF_KEY" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; fm_test_cleanup' EXIT
for _ in $(seq 1 100); do
  [ -s "$STUB/port" ] && break
  sleep 0.05
done
[ -s "$STUB/port" ] || fail "the HTTP stub never reported its port"
PORT=$(cat "$STUB/port")

# The ketch stand-in: `-b exa` is the exa-keyless hop, `--multi` the last hop.
# Behavior per hop from $STUB/ketch-<exa|multi>.mode (ok, empty, fail, slow).
cat > "$FAKEBIN/ketch" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_SEARCH_STUB/ketch.calls"
case " $* " in *" --multi "*) hop=multi ;; *) hop=exa ;; esac
mode=$(cat "$FM_SEARCH_STUB/ketch-$hop.mode" 2>/dev/null || echo ok)
case "$mode" in
  ok) cat "$FM_SEARCH_FIX/ketch.json" ;;
  empty) echo '[]' ;;
  fail) echo 'ketch: backend down' >&2; exit 1 ;;
  slow) sleep 5; echo '[]' ;;
esac
SH
# The Jev stand-in: $STUB/jev.reply holds "<exit> <class> <confidence>".
cat > "$FAKEBIN/fm-jev.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_SEARCH_STUB/jev.calls"
read -r code cls conf < "$FM_SEARCH_STUB/jev.reply"
[ "$code" = 0 ] || { echo "ESCALATE conf=$conf -> decide yourself"; exit "$code"; }
printf '{"answers":{"pick":{"choice":"%s","p":%s,"confidence":%s}}}\n' "$cls" "$conf" "$conf"
SH
chmod +x "$FAKEBIN/ketch" "$FAKEBIN/fm-jev.sh"

# Short timeouts so the slow modes trip them; a tight TinyFish minute cap.
cat > "$TMP_ROOT/fm-search.json" <<'JSON'
{"tinyfish": {"per_minute": 2},
 "timeouts_s": {"exa-keyless": 3, "exa-lite": 2, "exa-deep": 2, "tinyfish": 2, "ketch-multi": 3}}
JSON

STATE=''
new_case() {  # fresh state, every stand-in back to ok, both keys present
  STATE="$TMP_ROOT/state-$1"
  mkdir -p "$STATE"
  rm -f "$STUB"/*.mode "$STUB"/*.req "$STUB"/*.calls
  printf '0 seo_local 0.95\n' > "$STUB/jev.reply"
  printf '%s\n' "$EXA_KEY" > "$KEYS/exa.key"
  printf '%s\n' "$TF_KEY" > "$KEYS/tinyfish.key"
}
set_mode() { printf '%s\n' "$2" > "$STUB/$1.mode"; }

code='' out='' err=''
search() {  # [args...]; sets code, out (stdout), err (stderr)
  local o="$TMP_ROOT/out" e="$TMP_ROOT/err"
  FM_HOME="$TMP_ROOT/home" FM_SEARCH_STATE="$STATE" FM_SEARCH_KEY_DIR="$KEYS" \
    FM_SEARCH_CONFIG="$TMP_ROOT/fm-search.json" FM_JEV_BIN="$FAKEBIN/fm-jev.sh" \
    FM_SEARCH_KETCH_BIN="$FAKEBIN/ketch" FM_SEARCH_STUB="$STUB" FM_SEARCH_FIX="$FIX" \
    FM_SEARCH_EXA_URL="http://127.0.0.1:$PORT/exa" FM_SEARCH_TINYFISH_URL="http://127.0.0.1:$PORT/tinyfish/" \
    "$TOOL" "$@" > "$o" 2> "$e"
  code=$?
  out=$(cat "$o")
  err=$(cat "$e")
  cat "$o" "$e" >> "$ALL_OUT"
}
# hop_lat <provider>: the ledger's latency for that hop, measured inside the
# router, so host load on process startup cannot blur a deadline check.
hop_lat() { awk -F'\t' -v p="$1" '$2 == p {print $4; exit}' "$STATE/ledger.tsv"; }
trailer() { printf '%s\n' "$out" | tail -n 1; }
reqs() { if [ -f "$STUB/$1.req" ]; then wc -l < "$STUB/$1.req" | tr -d ' '; else echo 0; fi; }
calls() { if [ -f "$STUB/$1.calls" ]; then wc -l < "$STUB/$1.calls" | tr -d ' '; else echo 0; fi; }
ledger_rows() { awk -F'\t' -v p="$1" '$2 == p' "$STATE/ledger.tsv" 2>/dev/null | wc -l | tr -d ' '; }

# --- 1. the Jev class picks the chain --------------------------------------------

new_case jev-docs
printf '0 docs 0.92\n' > "$STUB/jev.reply"
search "asyncio TaskGroup docs $QMARK"
expect_code 0 "$code" "jev docs: $err"
assert_contains "$(trailer)" 'provider=exa-lite hops=1' "jev docs: chain K starts with keyed Exa"
assert_contains "$(trailer)" 'route=jev' "jev docs: the trailer names the Jev route"
assert_equals lite "$(jq -r .type "$STUB/exa.req")" "jev docs: the keyed hop asks for type lite"
assert_equals true "$(jq -r .key_ok "$STUB/exa.req")" "jev docs: the Exa key reaches the provider"
assert_equals 0 "$(calls ketch)" "jev docs: chain K does not start with ketch"
assert_contains "$(cat "$STATE/ledger.tsv")" $'exa-lite\t0.00500\t' "jev docs: the ledger takes costDollars.total"
pass "a Jev pick of docs walks chain K"

new_case jev-seo
search "moving company google business profile $QMARK"
expect_code 0 "$code" "jev seo_local: $err"
assert_contains "$(trailer)" 'provider=exa-keyless hops=1' "jev seo_local: chain F starts keyless"
assert_contains "$(trailer)" 'route=jev' "jev seo_local: the trailer names the Jev route"
assert_equals 0 "$(reqs exa)" "jev seo_local: chain F spends nothing on a first-hop answer"
assert_contains "$(cat "$STUB/ketch.calls")" '-b exa' "jev seo_local: the keyless hop is ketch -b exa"
pass "a Jev pick of seo_local walks chain F"

new_case jev-de
printf '0 de_admin 0.9\n' > "$STUB/jev.reply"
set_mode ketch-exa empty
set_mode exa empty
search "Gewerbeanmeldung Bochum Kosten $QMARK"
expect_code 0 "$code" "jev de_admin: $err"
assert_contains "$(trailer)" 'provider=tinyfish hops=3' "jev de_admin: TinyFish answers after two empty hops"
assert_equals de "$(jq -r .language "$STUB/tinyfish.req")" "jev de_admin: TinyFish is asked in German"
pass "a de_admin pick asks TinyFish in German"

# --- 2. the deterministic chain F default -----------------------------------------

for reply in '2 docs 0.31' '1 docs 0.9' '0 docs 0.69' '0 nonsense 0.99'; do
  new_case "fallback-${reply// /-}"
  printf '%s\n' "$reply" > "$STUB/jev.reply"
  search "fallback probe ${reply// /-} $QMARK"
  expect_code 0 "$code" "jev reply '$reply': $err"
  assert_contains "$(trailer)" 'provider=exa-keyless hops=1' "jev reply '$reply': chain F answers"
  assert_contains "$(trailer)" 'route=default' "jev reply '$reply': the route is the default"
  assert_equals 1 "$(calls jev)" "jev reply '$reply': Jev was asked once"
  assert_absent "$STATE/route-cache.tsv" "jev reply '$reply': a fallback is never cached"
done
pass "Jev exit 2, exit 1, confidence 0.69 and an unknown class fall back to chain F"

new_case long-query
long=$(printf 'x%.0s' $(seq 1 310))
search "$long $QMARK"
expect_code 0 "$code" "long query: $err"
assert_contains "$(trailer)" 'route=default' "long query: chain F by default"
assert_equals 0 "$(calls jev)" "long query: a query over 300 bytes never goes to Jev"
pass "a query over 300 bytes skips Jev"

# --- 9. --no-jev and forced chains never call Jev ------------------------------------

new_case no-jev
search --no-jev "no jev probe $QMARK"
expect_code 0 "$code" "--no-jev: $err"
assert_contains "$(trailer)" 'route=default' "--no-jev: chain F by default"
assert_equals 0 "$(calls jev)" "--no-jev: Jev is never called"
search --chain K "forced chain probe $QMARK"
expect_code 0 "$code" "--chain K: $err"
assert_contains "$(trailer)" 'provider=exa-lite hops=1 ' "--chain K: keyed Exa first"
assert_contains "$(trailer)" 'route=forced' "--chain K: the route is forced"
assert_equals 0 "$(calls jev)" "--chain K: Jev is never called"
pass "--no-jev and --chain never call Jev"

search --no-jev -- "-bash: foo: command not found $QMARK"
expect_code 0 "$code" "-- query: $err"
assert_contains "$(trailer)" 'provider=' "-- lets a query start with a dash"
assert_contains "$(cat "$STUB/ketch.calls")" "-- -bash: foo: command not found" "a dash-leading query reaches ketch after --"
search --no-jev "-bash: foo: command not found"
expect_code 1 "$code" "a dash-leading query without -- is a usage error"
pass "-- ends options so a query can start with a dash"

# --- route cache --------------------------------------------------------------------

new_case cache
printf '0 docs 0.92\n' > "$STUB/jev.reply"
search "Cached Route Probe $QMARK"
expect_code 0 "$code" "cache first call: $err"
search "cached route probe $QMARK"
expect_code 0 "$code" "cache second call: $err"
assert_equals 1 "$(calls jev)" "cache: the same query in other case skips Jev"
assert_contains "$(trailer)" 'route=jev' "cache: a cached pick still reports the Jev route"
assert_contains "$(trailer)" 'provider=exa-lite' "cache: a cached docs pick still walks chain K"
pass "the route cache answers a repeated query without Jev"

# --- 3. hop on empty, 429 and timeout; all empty is exit 3 --------------------------

new_case hops
set_mode ketch-exa empty
set_mode exa 429
set_mode tinyfish slow
search --no-jev "hop probe $QMARK"
expect_code 0 "$code" "hops: $err"
assert_contains "$(trailer)" 'provider=ketch-multi hops=4' "hops: empty, 429 and timeout each hop on"
assert_contains "$(cat "$STUB/ketch.calls")" '--multi' "hops: the last hop is ketch --multi"
assert_equals 1 "$(awk -F'\t' '$2=="exa-lite" && $3==0' "$STATE/ledger.tsv" | wc -l | tr -d ' ')" "hops: an HTTP 429 Exa call has no cost"
pass "an empty list, an HTTP 429 and a timeout each hop to the next provider"

new_case trickle
set_mode exa trickle
search --chain K "trickle probe $QMARK"
expect_code 0 "$code" "trickle: $err"
assert_contains "$(trailer)" 'provider=tinyfish hops=2' "trickle: a trickled body times out and hops on"
awk -v l="$(hop_lat exa-lite)" 'BEGIN {exit !(l < 4.5)}' || fail "trickle: the 2 s hop deadline did not cover the body read (hop took $(hop_lat exa-lite) s)"
assert_equals 1 "$(awk -F'\t' '$2=="exa-lite" && $3==0.004' "$STATE/ledger.tsv" | wc -l | tr -d ' ')" "trickle: an Exa body timeout after HTTP 200 keeps its price"
pass "the hop deadline covers a trickled response body"

new_case trickle-cap
printf '%s\texa-lite\t7.99000\t0.80\t5\tjev\n' "$(date +%s)" > "$STATE/ledger.tsv"
set_mode exa trickle
for i in 1 2 3; do
  search --chain K "trickle cap probe $i $QMARK"
  expect_code 0 "$code" "trickle cap $i: $err"
  assert_not_contains "$(trailer)" 'provider=exa-lite' "trickle cap $i: the chain hops past Exa"
done
assert_equals 2 "$(reqs exa)" "trickle cap: repeated billed body timeouts exhaust the cap and stop keyed calls"
pass "Exa calls whose billing is unknown keep their price until the cap stops them"

new_case slow-headers
set_mode exa headers
search --chain K "slow headers probe $QMARK"
expect_code 0 "$code" "slow headers: $err"
assert_contains "$(trailer)" 'provider=tinyfish hops=2' "slow headers: trickled status and headers time out and hop on"
awk -v l="$(hop_lat exa-lite)" 'BEGIN {exit !(l < 4.5)}' || fail "slow headers: the 2 s hop deadline did not cover status and headers (hop took $(hop_lat exa-lite) s)"
pass "the hop deadline covers a trickled status line and headers"

new_case shape
set_mode exa shape
search --chain K "shape probe $QMARK"
expect_code 0 "$code" "shape: $err"
assert_contains "$(trailer)" 'provider=tinyfish hops=2' "shape: a wrong-shaped reply hops on"
assert_equals 1 "$(awk -F'\t' '$2=="exa-lite" && $3>0' "$STATE/ledger.tsv" | wc -l | tr -d ' ')" "shape: the billed Exa call is ledgered with its price"
pass "a wrong-shaped JSON reply hops on instead of killing the chain"

new_case invalid-utf8
printf '%s\texa-lite\t7.99600\t0.80\t5\tjev\n' "$(date +%s)" > "$STATE/ledger.tsv"
set_mode exa utf8
search --chain K "invalid utf8 probe $QMARK"
expect_code 0 "$code" "invalid utf8: $err"
assert_contains "$(trailer)" 'provider=tinyfish hops=2' "invalid utf8: an undecodable reply hops on"
assert_equals 1 "$(awk -F'\t' '$2=="exa-lite" && $3==0.004' "$STATE/ledger.tsv" | wc -l | tr -d ' ')" "invalid utf8: the HTTP 200 Exa call is ledgered at its configured price"
search --chain K "invalid utf8 cap probe $QMARK"
expect_code 0 "$code" "invalid utf8 cap: $err"
assert_contains "$(trailer)" 'provider=tinyfish hops=2' "invalid utf8 cap: a capped Exa hop falls through"
assert_equals 1 "$(reqs exa)" "invalid utf8 cap: the billed malformed reply prevents another Exa request"
pass "an undecodable HTTP 200 Exa reply still counts toward the spending cap"

new_case all-empty
set_mode ketch-exa empty
set_mode exa 429
set_mode tinyfish empty
set_mode ketch-multi fail
search --no-jev "all empty probe $QMARK"
expect_code 3 "$code" "all empty"
assert_equals '' "$out" "all empty: nothing on stdout"
assert_equals 4 "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" "all empty: one stderr line per hop"
assert_contains "$err" 'fm-search: exa-keyless: empty' "all empty: the keyless hop is named"
assert_contains "$err" 'fm-search: exa-lite: http 429' "all empty: the 429 is named"
assert_contains "$err" 'fm-search: tinyfish: empty' "all empty: the TinyFish hop is named"
assert_contains "$err" 'fm-search: ketch-multi: ketch exit 1' "all empty: the ketch failure is named"
pass "every hop empty exits 3 with one line per hop"

new_case no-keys
rm -f "$KEYS/exa.key" "$KEYS/tinyfish.key"
set_mode ketch-exa empty
set_mode ketch-multi empty
search --chain K "no keys probe $QMARK"
expect_code 3 "$code" "no keys"
assert_contains "$err" 'exa-lite: skipped: no exa key' "no keys: a missing Exa key removes the hop"
assert_contains "$err" 'tinyfish: skipped: no tinyfish key' "no keys: a missing TinyFish key removes the hop"
assert_equals 00 "$(reqs exa)$(reqs tinyfish)" "no keys: no keyed request goes out"
pass "a missing key removes its hop"

# --- 4. the Exa monthly cap ------------------------------------------------------------

new_case exa-cap
now=$(date +%s)
printf '%s\texa-lite\t7.99600\t0.80\t5\tjev\n' "$now" > "$STATE/ledger.tsv"
search --chain K "exa cap crossing probe $QMARK"
expect_code 0 "$code" "exa cap crossing: $err"
assert_contains "$(trailer)" 'provider=exa-lite' "exa cap: under the cap the keyed hop runs"
assert_contains "$err" 'warning: exa spend' "exa cap: crossing 80% warns"
search --chain K "exa cap again probe $QMARK"
assert_not_contains "$err" 'warning: exa spend' "exa cap: the warning is once per month"
assert_contains "$(trailer)" 'provider=tinyfish hops=2' "exa cap: at the cap the keyed hop is skipped"
assert_equals 1 "$(reqs exa)" "exa cap: no Exa request at the cap"
assert_equals 2 "$(ledger_rows exa-lite)" "exa cap: the ledger records no Exa call at the cap"
search --ledger
expect_code 0 "$code" "--ledger"
assert_contains "$out" "exa-lite     calls=2 cost=\$8.0010" "--ledger: month-to-date calls and spend per provider"
assert_contains "$out" 'tinyfish     calls=1' "--ledger: TinyFish calls are counted"
assert_contains "$out" 'warning: exa spend crossed 80%' "--ledger: the cap warning shows"
pass "the Exa monthly cap skips the keyed hop and the ledger reports it"

new_case exa-cap-reserve
printf '%s\texa-lite\t7.99700\t0.80\t5\tjev\n' "$(date +%s)" > "$STATE/ledger.tsv"
search --chain K "exa cap reserve probe $QMARK"
expect_code 0 "$code" "exa cap reserve: $err"
assert_contains "$(trailer)" 'provider=tinyfish hops=2' "exa cap reserve: a call that would cross the cap is skipped"
assert_equals 0 "$(reqs exa)" "exa cap reserve: no Exa request that would cross the cap"
pass "the Exa cap counts the next request's price before calling"

# --- 5. the TinyFish per-minute cap ----------------------------------------------------

new_case tinyfish-cap
now=$(date +%s)
printf '%s\ttinyfish\t0.00000\t0.50\t5\tforced\n' "$now" "$now" > "$STATE/ledger.tsv"
search --urls "tinyfish cap probe $QMARK"
expect_code 0 "$code" "tinyfish cap: $err"
assert_contains "$(trailer)" 'provider=exa-keyless hops=2' "tinyfish cap: over the minute cap the hop is skipped"
assert_equals 0 "$(reqs tinyfish)" "tinyfish cap: no TinyFish request over the cap"
pass "over the TinyFish per-minute cap the hop is skipped"

new_case tinyfish-parallel
set_mode tinyfish lag
pids=()
for i in 1 2 3 4; do
  search --urls "parallel probe $i $QMARK" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
assert_equals 2 "$(reqs tinyfish)" "tinyfish parallel: four workers pass a two-per-minute cap only twice"
assert_equals 2 "$(ledger_rows tinyfish)" "tinyfish parallel: the ledger records only the calls that ran"
pass "parallel workers cannot all pass one TinyFish cap"

# --- 8. --urls and --deep -----------------------------------------------------------------

new_case urls
search --urls "urls probe $QMARK"
expect_code 0 "$code" "--urls: $err"
assert_contains "$(trailer)" 'provider=tinyfish hops=1' "--urls: TinyFish first"
assert_equals true "$(jq -r .key_ok "$STUB/tinyfish.req")" "--urls: the TinyFish key reaches the provider"
assert_not_contains "$out" 'This section outlines' "--urls: no snippets in the URL list"
search --deep "deep probe $QMARK"
expect_code 0 "$code" "--deep: $err"
assert_contains "$(trailer)" 'provider=exa-deep hops=1' "--deep: keyed Exa first"
assert_equals auto "$(jq -r .type "$STUB/exa.req")" "--deep: Exa type auto"
pass "--urls starts with TinyFish and --deep with Exa auto"

# --- 10. normalization is identical across adapters ---------------------------------------

new_case normalize
want=$(jq -S .results "$FIX/normalized.json")
search --json --no-jev "normalize keyless probe $QMARK"
assert_equals "$want" "$(printf '%s' "$out" | jq -S .results)" "normalize: exa-keyless (ketch -b exa)"
search --json --chain K "normalize exa probe $QMARK"
assert_equals "$want" "$(printf '%s' "$out" | jq -S .results)" "normalize: exa-lite"
assert_equals 0.005 "$(printf '%s' "$out" | jq -r .meta.cost)" "normalize: --json meta carries the cost"
search --json --urls "normalize tinyfish probe $QMARK"
assert_equals "$want" "$(printf '%s' "$out" | jq -S .results)" "normalize: tinyfish"
set_mode ketch-exa empty
set_mode exa empty
set_mode tinyfish empty
search --json --no-jev "normalize multi probe $QMARK"
assert_equals ketch-multi "$(printf '%s' "$out" | jq -r .meta.provider)" "normalize: the multi hop answered"
assert_equals "$want" "$(printf '%s' "$out" | jq -S .results)" "normalize: ketch-multi"
pass "every adapter normalizes to the same results"

# --- unwritable state dir ----------------------------------------------------------------

new_case state-unwritable
rm -rf "$STATE"; : > "$STATE"
search "state dir is a file $QMARK"
expect_code 0 "$code" "unwritable state: bookkeeping must not kill the chain: $err"
assert_contains "$(trailer)" 'provider=exa-keyless' "unwritable state: the keyless hop still answers"
search --chain K "state dir is a file $QMARK"
expect_code 0 "$code" "unwritable state K: $err"
assert_contains "$(trailer)" 'provider=exa-keyless' "unwritable state K: capped paid hops are skipped, not run uncapped"
assert_equals 00 "$(reqs exa)$(reqs tinyfish)" "unwritable state: no paid call without a cap check"
rm -f "$STATE"
pass "an unwritable state dir degrades to best-effort bookkeeping"

# A usable lock with a ledger that cannot record or report spend: every paid hop
# is skipped before it reaches the provider, and the free hops still answer.
for broken in read-only unreadable corrupt; do
  new_case "ledger-$broken"
  printf '%s\texa-lite\t0.00400\t   0.10\t  1\tforced\n' "$(date +%s)" > "$STATE/ledger.tsv"
  case "$broken" in
    read-only) chmod 444 "$STATE/ledger.tsv" ;;
    unreadable) chmod 000 "$STATE/ledger.tsv" ;;
    corrupt) printf 'half a line\n' >> "$STATE/ledger.tsv" ;;
  esac
  if [ "$broken" != corrupt ] && [ -w "$STATE/ledger.tsv" ]; then
    chmod 644 "$STATE/ledger.tsv"
    echo "# skip ledger-$broken: file modes do not bind this user"
    continue
  fi
  for i in 1 2 3; do
    search --chain K "ledger $broken probe $i $QMARK"
    expect_code 0 "$code" "ledger $broken $i: $err"
    assert_contains "$(trailer)" 'provider=exa-keyless hops=3' "ledger $broken $i: both paid hops are skipped and the keyless hop answers"
  done
  assert_equals 00 "$(reqs exa)$(reqs tinyfish)" "ledger $broken: no paid call without stored accounting"
  set_mode ketch-exa empty
  set_mode ketch-multi empty
  search --chain K "ledger $broken reasons $QMARK"
  expect_code 3 "$code" "ledger $broken reasons"
  assert_contains "$err" 'exa-lite: skipped: ledger' "ledger $broken: the Exa skip names the ledger"
  assert_contains "$err" 'tinyfish: skipped: ledger' "ledger $broken: the TinyFish skip names the ledger"
  chmod 644 "$STATE/ledger.tsv"
done
pass "a read-only, unreadable or corrupt ledger stops paid calls"

# A paid call killed mid-flight keeps its reservation, so the next cap check counts it.
new_case interrupted
printf '%s\texa-lite\t7.99500\t   0.80\t  5\tjev\n' "$(date +%s)" > "$STATE/ledger.tsv"
set_mode exa slow
FM_HOME="$TMP_ROOT/home" FM_SEARCH_STATE="$STATE" FM_SEARCH_KEY_DIR="$KEYS" \
  FM_SEARCH_CONFIG="$TMP_ROOT/fm-search.json" FM_SEARCH_KETCH_BIN="$FAKEBIN/ketch" \
  FM_SEARCH_STUB="$STUB" FM_SEARCH_FIX="$FIX" FM_SEARCH_EXA_URL="http://127.0.0.1:$PORT/exa" \
  "$TOOL" --chain K "interrupted probe $QMARK" > /dev/null 2>&1 &
victim=$!
for _ in $(seq 1 200); do
  [ -s "$STUB/exa.req" ] && break
  sleep 0.05
done
[ -s "$STUB/exa.req" ] || fail "interrupted: the paid request never reached the stub"
kill -9 "$victim" 2>/dev/null
wait "$victim" 2>/dev/null
assert_equals 1 "$(awk -F'\t' '$2 == "exa-lite" && $3 == 0.004 && $5 == -1' "$STATE/ledger.tsv" | wc -l | tr -d ' ')" "interrupted: the killed call left its reservation at the Exa price"
set_mode exa ok
search --chain K "after interrupt probe $QMARK"
expect_code 0 "$code" "after interrupt: $err"
assert_contains "$(trailer)" 'provider=tinyfish hops=2' "after interrupt: the reservation pushes the next call over the cap"
assert_equals 1 "$(reqs exa)" "after interrupt: no second Exa request past the cap"
pass "an interrupted paid call keeps its reservation against the cap"

new_case settled
search --chain K "settled probe $QMARK"
expect_code 0 "$code" "settled: $err"
assert_equals 1 "$(ledger_rows exa-lite)" "settled: one ledger row per paid call"
assert_equals 0 "$(awk -F'\t' '$5 == -1' "$STATE/ledger.tsv" | wc -l | tr -d ' ')" "settled: a finished call leaves no open reservation"
assert_contains "$(cat "$STATE/ledger.tsv")" $'exa-lite\t0.00500\t' "settled: the reservation is rewritten with the reported cost"
pass "a finished paid call settles its reservation in place"

# --- usage errors ------------------------------------------------------------------------

new_case usage
for args in '' '--urls --deep q' '--chain X q' '--limit 0 q' '--bogus q' '--ledger q' 'a b'; do
  # shellcheck disable=SC2086
  search $args
  expect_code 1 "$code" "usage: '$args'"
  assert_contains "$err" 'usage: fm-search.sh' "usage: '$args' prints the usage"
done
assert_equals 0000 "$(calls jev)$(calls ketch)$(reqs exa)$(reqs tinyfish)" "usage: a usage error calls no provider"
pass "usage errors exit 1 and call nothing"

# --- 6 and 7. no key and no query text at rest or in output ---------------------------------

for f in "$TMP_ROOT"/state-*/*; do
  assert_no_grep "$EXA_KEY" "$f" "privacy: the Exa key is in $f"
  assert_no_grep "$TF_KEY" "$f" "privacy: the TinyFish key is in $f"
  assert_no_grep "$QMARK" "$f" "privacy: query text is in $f"
done
assert_no_grep "$EXA_KEY" "$ALL_OUT" "privacy: the Exa key reached stdout or stderr"
assert_no_grep "$TF_KEY" "$ALL_OUT" "privacy: the TinyFish key reached stdout or stderr"
[ -n "$(ls "$TMP_ROOT"/state-*/route-cache.tsv 2>/dev/null)" ] || fail "privacy: no route cache was written to check"
pass "no key in any output and no query text in the ledger or route cache"

echo "# all fm-search tests passed"
