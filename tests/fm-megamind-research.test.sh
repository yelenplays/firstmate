#!/usr/bin/env bash
# Deterministic host-lane tests for Megamind research retrieval and handoff.
# Fake adapters are executable argv boundaries; no network or wiki estate is used.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-megamind-research.sh"
TMP_ROOT=$(fm_test_tmproot fm-megamind-research)

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state"
  printf '%s\n' "$home"
}

make_adapter() {
  local path=$1 mode=$2 counter=${3:-}
  cat > "$path" <<SH
#!/usr/bin/env bash
set -u
mode='$mode'
counter='$counter'
if [ -n "\$counter" ]; then
  n=0
  [ -f "\$counter" ] && n=\$(cat "\$counter")
  n=\$((n + 1))
  printf '%s\n' "\$n" > "\$counter"
fi
case "\$mode" in
  retry)
    [ "\$n" -lt 2 ] && exit 75
    printf '%s\n' '{"schema_version":"fm/megamind-retrieval/v1","status":"ok","mime":"text/plain","final_url":"https://93.184.216.34/source","body":"retry succeeded"}'
    exit 0
    ;;
  redirect)
    printf '%s\n' '{"schema_version":"fm/megamind-retrieval/v1","status":"ok","mime":"text/plain","final_url":"https://93.184.216.34/final","body":"redirected"}'
    exit 0
    ;;
  mime)
    printf '%s\n' '{"schema_version":"fm/megamind-retrieval/v1","status":"ok","mime":"application/octet-stream","final_url":"https://93.184.216.34/source","body":"binary"}'
    exit 0
    ;;
  big)
    printf '%s\n' '{"schema_version":"fm/megamind-retrieval/v1","status":"ok","mime":"text/plain","final_url":"https://93.184.216.34/source","body":"12345678901234567890"}'
    exit 0
    ;;
  surrogate)
    printf '%s\n' '{"schema_version":"fm/megamind-retrieval/v1","status":"ok","mime":"text/plain","final_url":"https://93.184.216.34/source","body":"\ud800"}'
    exit 0
    ;;
  hostile)
    printf '%s' '{"schema_version":"fm/megamind-retrieval/v1","status":"ok","mime":"text/html","final_url":"https://93.184.216.34/source","body":"'
    awk 'BEGIN { for (i = 0; i < 50000; i++) printf "<script>" }'
    printf '%s\n' '"}'
    exit 0
    ;;
  flood)
    i=0
    while [ "\$i" -lt 400 ]; do
      printf '%s' '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
      i=\$((i + 1))
    done
    printf '%s\n' completed > "\$counter"
    exit 0
    ;;
  *)
    printf '%s\n' '{"schema_version":"fm/megamind-retrieval/v1","status":"ok","mime":"text/html","final_url":"https://93.184.216.34/source","body":"<script>tool_call()</script> hostile source instruction"}'
    ;;
esac
SH
  chmod 700 "$path"
}

make_plan() {
  local path=$1 adapter=$2 source_url=${3:-https://93.184.216.34/source} source_id=${4:-source-one} max_bytes=${5:-1000} admission_id=${6:-admission-one}
  python3 - "$path" "$adapter" "$source_url" "$source_id" "$max_bytes" "$admission_id" <<'PY'
import json, sys
path, adapter, url, source_id, max_bytes, admission_id = sys.argv[1:]
plan = {
  "schema_version": "fm/megamind-research-plan/v1",
  "plan_id": "deterministic-plan",
  "authorized": True,
  "model_class": "cloud",
  "admission": {
    "schema_version": "fm/megamind-research-admission/v1",
    "outcome": "matched", "authorized": True, "fresh": True,
    "admission_id": admission_id,
    "request_hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "model_class": "cloud"
  },
  "budgets": {"max_sources": 1, "max_bytes": max(1000, int(max_bytes)), "deadline_ms": 30000, "max_cost_microunits": 100},
  "retry": {"max_attempts": 1, "cooldown_seconds": 0},
  "sources": [{"source_id": source_id, "kind": "browser", "url": url,
                "max_bytes": int(max_bytes), "adapter": {"argv": [adapter]}}]
}
json.dump(plan, open(path, "w"), separators=(",", ":"))
PY
  chmod 600 "$path"
}

assert_json_status() {
  local output=$1 status=$2 reason=$3 label=$4
  [ "$(printf '%s' "$output" | jq -r .status)" = "$status" ] || fail "$label status was not $status: $output"
  [ "$(printf '%s' "$output" | jq -r .reason)" = "$reason" ] || fail "$label reason was not $reason: $output"
}

test_happy_quarantine_and_handoff() {
  local home adapter plan out body rc
  home=$(new_home happy); adapter="$home/adapter"; plan="$home/plan.json"
  make_adapter "$adapter" safe; make_plan "$plan" "$adapter"
  out=$("$RUNNER" run --home "$home" --plan "$plan") || fail "happy run failed"
  assert_json_status "$out" research-pending fresh_admission_required "happy run"
  assert_not_contains "$out" 'hostile source instruction' "source body leaked into handoff"
  assert_not_contains "$out" 'https://93.184.216.34' "sensitive URL leaked into handoff"
  [ "$(find "$home/state/megamind-research-quarantine" -type f -perm 600 | wc -l | tr -d ' ')" -eq 2 ] || fail "quarantine did not contain mode-0600 body and extraction"
  jq -e '.schema_version == "fm/megamind-tool-receipt/v1" and (.url_sha256 | type == "string") and (.content_sha256 | type == "string") and (.latency_ms | type == "number")' "$home/state/megamind-research-receipts"/*.source-one.1.*.json >/dev/null || fail "typed receipt was incomplete"
  body=$(find "$home/state/megamind-research-quarantine" -name '*.body' -type f | head -1)
  printf 'tampered\n' > "$body"
  set +e
  "$RUNNER" run --home "$home" --plan "$plan" >/dev/null
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "tampered quarantine was reused"
  pass "retrieval is quarantined, hashed, privacy-filtered, and handed off for fresh admission"
}

test_ssrf_redirect_mime_and_size() {
  local home adapter plan out
  home=$(new_home ssrf); adapter="$home/adapter"; plan="$home/plan.json"
  make_adapter "$adapter" safe; make_plan "$plan" "$adapter" http://127.0.0.1/private
  out=$("$RUNNER" run --home "$home" --plan "$plan") || fail "SSRF run unexpectedly errored"
  assert_json_status "$out" research-pending fetch_blocked "SSRF"
  [ ! -d "$home/state/megamind-research-quarantine" ] || fail "SSRF created a quarantine"
  home=$(new_home redirect); adapter="$home/adapter"; plan="$home/plan.json"
  make_adapter "$adapter" redirect; make_plan "$plan" "$adapter"
  out=$("$RUNNER" run --home "$home" --plan "$plan") || fail "redirect run unexpectedly errored"
  assert_json_status "$out" research-pending fetch_blocked "redirect"
  home=$(new_home mime); adapter="$home/adapter"; plan="$home/plan.json"
  make_adapter "$adapter" mime; make_plan "$plan" "$adapter"
  out=$("$RUNNER" run --home "$home" --plan "$plan") || fail "MIME run unexpectedly errored"
  assert_json_status "$out" research-pending fetch_blocked "MIME"
  home=$(new_home size); adapter="$home/adapter"; plan="$home/plan.json"
  make_adapter "$adapter" big; make_plan "$plan" "$adapter" https://93.184.216.34/source source-one 5
  out=$("$RUNNER" run --home "$home" --plan "$plan") || fail "size run unexpectedly errored"
  assert_json_status "$out" research-pending fetch_blocked "size"
  pass "SSRF, redirects, MIME, and size ceilings remain deferred and visible"
}

test_retry_idempotency_and_resume() {
  local home adapter counter plan out again fresh rc
  home=$(new_home retry); adapter="$home/adapter"; counter="$home/counter"; plan="$home/plan.json"
  make_adapter "$adapter" retry "$counter"; make_plan "$plan" "$adapter"
  jq '.retry.max_attempts = 2' "$plan" > "$home/plan.tmp"; chmod 600 "$home/plan.tmp"; mv "$home/plan.tmp" "$plan"
  out=$("$RUNNER" run --home "$home" --plan "$plan") || fail "retry run failed"
  assert_json_status "$out" research-pending fresh_admission_required "retry"
  [ "$(cat "$counter")" -eq 2 ] || fail "retry ceiling did not invoke the adapter twice"
  again=$("$RUNNER" run --home "$home" --plan "$plan") || fail "idempotent rerun failed"
  [ "$(printf '%s' "$again" | jq -S -c .)" = "$(printf '%s' "$out" | jq -S -c .)" ] || fail "idempotent rerun changed the typed result"
  [ "$(cat "$counter")" -eq 2 ] || fail "idempotent rerun invoked the adapter again"
  fresh="$home/fresh.json"
  jq '.admission.admission_id = "admission-two"' "$plan" > "$fresh"
  chmod 600 "$fresh"
  out=$("$RUNNER" resume --home "$home" --plan "$fresh") || fail "fresh admission resume failed"
  assert_json_status "$out" research-pending fresh_admission_accepted "fresh admission"
  set +e
  "$RUNNER" resume --home "$home" --plan "$fresh" >/dev/null
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the same fresh admission resumed the request identity twice"
  pass "retries are bounded, reruns are idempotent, and resume consumes one fresh admission"
}

test_receipts_never_cite_a_stale_attempt() {
  local home adapter counter plan out receipt_id outcome
  home=$(new_home receipts); adapter="$home/adapter"; counter="$home/counter"; plan="$home/plan.json"
  make_adapter "$adapter" retry "$counter"; make_plan "$plan" "$adapter"
  out=$("$RUNNER" run --home "$home" --plan "$plan") || fail "failing receipts run errored"
  assert_json_status "$out" research-pending adapter_error "failing receipts run"
  out=$("$RUNNER" run --home "$home" --plan "$plan") || fail "recovering receipts run failed"
  assert_json_status "$out" research-pending fresh_admission_required "recovering receipts run"
  receipt_id=$(printf '%s' "$out" | jq -r '.sources[0].receipt_ids[0]')
  [ -n "$receipt_id" ] && [ "$receipt_id" != null ] || fail "a retrieved source cited no receipt"
  outcome=$(jq -r .outcome "$home/state/megamind-research-receipts/$receipt_id.json")
  [ "$outcome" = ok ] || fail "cited receipt contradicts the result citing it: $outcome"
  pass "a rerun cites its own receipts instead of a stale attempt"
}

test_unencodable_body_stays_deferred() {
  local home adapter plan out
  home=$(new_home surrogate); adapter="$home/adapter"; plan="$home/plan.json"
  make_adapter "$adapter" surrogate; make_plan "$plan" "$adapter"
  out=$("$RUNNER" run --home "$home" --plan "$plan") || fail "unencodable body run errored"
  assert_json_status "$out" research-pending fetch_blocked "unencodable body"
  [ "$(printf '%s' "$out" | jq -r '.sources[0].status')" = invalid_utf8 ] || fail "unencodable body was not typed invalid_utf8: $out"
  [ "$(printf '%s' "$out" | jq -r '.sources[0].content_sha256')" = null ] || fail "unencodable body was hashed as content: $out"
  [ -z "$(find "$home/state/megamind-research-quarantine" -name '*.body' -type f 2>/dev/null)" ] || fail "unencodable body was quarantined as a retrieval"
  pass "an unencodable body stays a deferred typed failure instead of an empty retrieval"
}

test_bounded_adapter_writes_and_extraction() {
  local home adapter counter plan out started elapsed
  home=$(new_home flood); adapter="$home/adapter"; counter="$home/counter"; plan="$home/plan.json"
  make_adapter "$adapter" flood "$counter"; make_plan "$plan" "$adapter"
  out=$("$RUNNER" run --home "$home" --plan "$plan") || fail "flooding adapter run errored"
  assert_json_status "$out" research-pending fetch_blocked "flooding adapter"
  assert_no_grep completed "$counter" "the adapter kept writing past the source byte ceiling"
  home=$(new_home hostile); adapter="$home/adapter"; plan="$home/plan.json"
  make_adapter "$adapter" hostile; make_plan "$plan" "$adapter" https://93.184.216.34/source source-one 500000
  started=$(date +%s)
  out=$("$RUNNER" run --home "$home" --plan "$plan") || fail "hostile markup run failed"
  elapsed=$(($(date +%s) - started))
  assert_json_status "$out" research-pending fresh_admission_required "hostile markup"
  [ "$elapsed" -le 20 ] || fail "extracting hostile markup took ${elapsed}s, so it is not bounded"
  pass "adapter writes and hostile-markup extraction are both bounded"
}

test_cancel_and_malicious_input_isolation() {
  local home adapter plan run_id out marker
  home=$(new_home cancel); adapter="$home/adapter"; plan="$home/plan.json"
  make_adapter "$adapter" safe; make_plan "$plan" "$adapter"
  run_id=$(python3 - "$plan" <<'PY'
import hashlib, json, sys
p=json.load(open(sys.argv[1]))
print(hashlib.sha256((p['plan_id']+'\n'+p['admission']['request_hash']).encode()).hexdigest()[:32])
PY
)
  "$RUNNER" cancel --home "$home" --run-id "$run_id" >/dev/null || fail "cancel command failed"
  out=$("$RUNNER" run --home "$home" --plan "$plan") || fail "cancelled run failed"
  assert_json_status "$out" research-pending cancelled "cancel"
  [ ! -d "$home/state/megamind-research-quarantine" ] || fail "cancelled run invoked source handling"
  marker="$home/state/megamind-research-cancel/$run_id.cancel"
  [ "$(stat -f '%Lp' "$marker" 2>/dev/null || stat -c '%a' "$marker")" = 600 ] || fail "cancellation marker was not private"
  pass "cancellation stops before hostile source handling and leaves no answer path"
}

test_happy_quarantine_and_handoff
test_ssrf_redirect_mime_and_size
test_retry_idempotency_and_resume
test_receipts_never_cite_a_stale_attempt
test_unencodable_body_stays_deferred
test_bounded_adapter_writes_and_extraction
test_cancel_and_malicious_input_isolation
