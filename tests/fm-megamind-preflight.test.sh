#!/usr/bin/env bash
# Behavior tests for bin/fm-megamind-preflight.sh, Firstmate's harness-neutral
# read-only Megamind preflight surface.
#
# A synthetic megamind-axi stub stands in for Megamind 0.3.x: it answers
# --version, records its argv for model-class/estate propagation assertions,
# and prints a canned megamind/preflight-result/v2 JSON fixture (or a controlled
# failure). All fixtures are fully synthetic; no real wiki, path, or request
# content appears. The suite proves mandatory-vs-bypass classification,
# model-class propagation, restrictive config defaults and version gating,
# allowed-path enforcement, ambiguity/no-match/privacy-filtered behavior,
# malformed/failed disclosure, minimal non-verbatim proof logging, and
# harness/backend neutrality.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

SCRIPT="$ROOT/bin/fm-megamind-preflight.sh"
TMP_ROOT=$(fm_test_tmproot fm-megamind-preflight)

# --- fixture builders --------------------------------------------------------

# new_home <name>: scratch FM_HOME with config/, state/, an estate dir, and a
# stub megamind-axi pinned through config/megamind-executable. Prints the home.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/estate"
  printf '%s\n' "$STUB" > "$home/config/megamind-executable"
  printf '%s\n' "$home/estate" > "$home/config/megamind-estate"
  printf '%s\n' "$home"
}

STUB="$TMP_ROOT/fakebin/megamind-axi"
mkdir -p "$TMP_ROOT/fakebin"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
# Synthetic megamind-axi stand-in. FM_TEST_STUB_VERSION overrides the reported
# version, FM_TEST_STUB_FIXTURE selects the canned preflight document,
# FM_TEST_STUB_EXIT forces a non-zero exit, and every preflight argv is
# appended to FM_TEST_STUB_ARGS for propagation assertions.
set -u
if [ "${1:-}" = "--version" ]; then
  printf 'megamind-axi %s\n' "${FM_TEST_STUB_VERSION:-0.3.0}"
  exit 0
fi
printf '%s\n' "$@" >> "${FM_TEST_STUB_ARGS:?}"
if [ -n "${FM_TEST_STUB_FIXTURE:-}" ]; then
  cat "$FM_TEST_STUB_FIXTURE"
fi
exit "${FM_TEST_STUB_EXIT:-0}"
SH
chmod +x "$STUB"

export FM_TEST_STUB_ARGS="$TMP_ROOT/stub-args"
: > "$FM_TEST_STUB_ARGS"

# run_in <home> <args...>: invoke the script against a scratch home.
run_in() {
  local home="$1"
  shift
  FM_HOME="$home" "$SCRIPT" "$@"
}

# --- classification ----------------------------------------------------------

test_classify_bypass_vs_substantive() {
  local c
  c=$("$SCRIPT" classify "How does the release process work?")
  [ "$c" = substantive ] || fail "substantive question classified as $c"
  c=$("$SCRIPT" classify "Please review the fleet digest and summarize risks")
  [ "$c" = substantive ] || fail "multi-word request classified as $c"
  c=$("$SCRIPT" classify "ok")
  [ "$c" = bypass ] || fail "ack classified as $c"
  c=$("$SCRIPT" classify "Thank You")
  [ "$c" = bypass ] || fail "case-insensitive ack classified as $c"
  c=$("$SCRIPT" classify "/afk")
  [ "$c" = bypass ] || fail "slash command classified as $c"
  c=$("$SCRIPT" classify "FM_INJECT_MARK stale: worker quiet")
  [ "$c" = bypass ] || fail "injection mark classified as $c"
  c=$("$SCRIPT" classify "$(printf '\xe2\x81\xa3')FIRSTMATE_OP: heartbeat review")
  [ "$c" = bypass ] || fail "operational prefix classified as $c"
  c=$("$SCRIPT" classify "   ")
  [ "$c" = bypass ] || fail "whitespace classified as $c"
  c=$("$SCRIPT" classify "yes, merge it now")
  [ "$c" = substantive ] || fail "multi-word answer must stay substantive, got $c"
  pass "classify: mandatory-vs-bypass screen is conservative"
}

# --- matched run, propagation, proof log -------------------------------------

MATCHED_FIXTURE="$TMP_ROOT/matched.json"
cat > "$MATCHED_FIXTURE" <<'JSON'
{
  "schema_version": "megamind/preflight-result/v2",
  "request": "RAW-REQUEST-CANARY must never be echoed",
  "request_hash": "reqhash-1",
  "model_class": "cloud",
  "status": "matched",
  "confidence": 0.9,
  "thresholds": {"reliance_floor": 0.75, "offer_floor": 0.25, "ambiguity_band": 0.05},
  "semantic": {"status": "disabled", "backend": "none", "reason": "semantic reranking not enabled"},
  "preflight_id": "pf-matched-1",
  "catalog_hash": "cat-1",
  "matches": [{
    "name": "ProductWiki",
    "root": "/synthetic/estate/ProductWiki",
    "score": 9,
    "confidence": {"score": 0.9, "meets_floor": true},
    "freshness": null,
    "evidence": {"lexical": ["trigger match: pricing"], "semantic": null},
    "reasons": ["trigger match: pricing"],
    "access": "full",
    "routing_mode": "bounded",
    "allows": [".megamind/wiki-card.json", "wiki/digest.md", "wiki/index.md"],
    "follow_up": "Run `megamind-axi --root /synthetic/estate/ProductWiki route pricing` for the bounded ladder"
  }],
  "offers": [{
    "name": "OfferWiki",
    "root": "/synthetic/estate/OfferWiki",
    "score": 4,
    "confidence": {"score": 0.4, "meets_floor": false},
    "freshness": null,
    "evidence": {"lexical": [], "semantic": null},
    "reasons": []
  }],
  "filtered": [{"name": "HiddenWiki", "root": "/synthetic/estate/HiddenWiki", "access": "none", "reason": "cloud access is none for this wiki"}],
  "declined": [],
  "root_issues": [],
  "redacted_count": 0,
  "notes": ["only wikis at or above the reliance floor (0.75) are loadable matches; the weaker ones stay offers with no loadable paths"]
}
JSON

test_matched_run_and_model_class_propagation() {
  local home out
  home=$(new_home matched)
  : > "$FM_TEST_STUB_ARGS"
  out=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "how do we price cleanup offers")
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = matched ] || fail "outcome not matched: $out"
  [ "$(printf '%s' "$out" | jq -r '.preflight_id')" = pf-matched-1 ] || fail "preflight_id not propagated"
  [ "$(printf '%s' "$out" | jq -r '.model_class')" = cloud ] || fail "default model class is not cloud"
  [ "$(printf '%s' "$out" | jq -r '.matches[0].wiki')" = ProductWiki ] || fail "match wiki lost"
  [ "$(printf '%s' "$out" | jq -r '.matches[0].allows | length')" = 3 ] || fail "allows not carried"
  [ "$(printf '%s' "$out" | jq -r '.filtered_count')" = 1 ] || fail "filtered_count lost"
  assert_not_contains "$out" "HiddenWiki" "filtered wiki name must never be echoed"
  assert_not_contains "$out" "RAW-REQUEST-CANARY" "raw request must never be echoed"
  assert_contains "$out" "read_policy" "read policy missing"
  # Offer entries must carry no loadable paths.
  [ "$(printf '%s' "$out" | jq '[.offers[] | has("allows")] | any')" = false ] || fail "offers must not carry allows"
  # Megamind saw the declared class, the configured estate, and the request.
  assert_grep "--model-class" "$FM_TEST_STUB_ARGS" "stub did not receive --model-class"
  assert_grep "cloud" "$FM_TEST_STUB_ARGS" "stub did not receive default cloud class"
  assert_grep "--estate" "$FM_TEST_STUB_ARGS" "stub did not receive --estate"
  assert_grep "$home/estate" "$FM_TEST_STUB_ARGS" "stub did not receive configured estate"
  assert_grep "how do we price cleanup offers" "$FM_TEST_STUB_ARGS" "stub did not receive the request"
  # Config and flag overrides propagate.
  printf 'local\n' > "$home/config/megamind-model-class"
  : > "$FM_TEST_STUB_ARGS"
  FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing" >/dev/null
  assert_grep "local" "$FM_TEST_STUB_ARGS" "config model-class not propagated"
  rm "$home/config/megamind-model-class"
  : > "$FM_TEST_STUB_ARGS"
  FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing" --model-class local >/dev/null
  assert_grep "local" "$FM_TEST_STUB_ARGS" "flag model-class not propagated"
  pass "run: matched outcome, evidence minimization, and model-class propagation"
}

test_proof_log_is_minimal_and_non_verbatim() {
  local home log
  home=$(new_home logging)
  FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "price it with sk-canarysecret123 attached" >/dev/null
  log="$home/state/megamind-preflight.jsonl"
  assert_present "$log" "proof log was not written"
  [ "$(wc -l < "$log" | tr -d ' ')" = 1 ] || fail "proof log must hold exactly one line per run"
  assert_no_grep "sk-canarysecret123" "$log" "proof log must never contain request text"
  assert_no_grep "price it with" "$log" "proof log must never contain request words"
  assert_grep "pf-matched-1" "$log" "proof log lost preflight_id"
  assert_grep '"outcome":"matched"' "$log" "proof log lost outcome"
  assert_grep '"model_class":"cloud"' "$log" "proof log lost model class"
  assert_grep '"catalog_hash":"cat-1"' "$log" "proof log lost catalog hash"
  assert_grep '"wikis":["ProductWiki"]' "$log" "proof log lost matched wiki names"
  [ "$(jq -r 'keys | sort | join(",")' "$log")" = "catalog_hash,failure,model_class,outcome,preflight_id,request_hash,ts,wikis" ] \
    || fail "proof log carries more than the minimal proof fields: $(jq -c 'keys' "$log")"
  pass "run: proof log is minimal, structured, and non-verbatim"
}

# --- restrictive config defaults and version gate ----------------------------

test_restrictive_defaults() {
  local home out rc
  # No estate config at all: never guess roots.
  home="$TMP_ROOT/unconfigured"
  mkdir -p "$home/config" "$home/state"
  printf '%s\n' "$STUB" > "$home/config/megamind-executable"
  out=$(run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "unconfigured run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = not_configured ] || fail "unconfigured run gave: $out"
  # Configured estate that does not exist.
  home=$(new_home missing-estate)
  printf '%s\n' "$home/no-such-dir" > "$home/config/megamind-estate"
  out=$(run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "missing-estate run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = estate_missing ] || fail "missing estate gave: $out"
  # Executable not found.
  home=$(new_home no-exe)
  printf '%s\n' "$home/no-such-megamind" > "$home/config/megamind-executable"
  out=$(run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "missing-executable run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = executable_missing ] || fail "missing executable gave: $out"
  # Version gate: only 0.3.x is accepted.
  home=$(new_home old-version)
  out=$(FM_TEST_STUB_VERSION=0.2.9 FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "old-version run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = version_incompatible ] || fail "old version gave: $out"
  [ "$(printf '%s' "$out" | jq -r '.failure.detected')" = 0.2.9 ] || fail "detected version not reported: $out"
  out=$(FM_TEST_STUB_VERSION=0.4.0 FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "new-version run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = version_incompatible ] || fail "newer major gave: $out"
  # Invalid model class configuration fails closed.
  home=$(new_home bad-class)
  printf 'turbo\n' > "$home/config/megamind-model-class"
  out=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "invalid-class run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = invalid_model_class ] || fail "invalid class gave: $out"
  pass "run: restrictive defaults, version gate, and invalid config fail closed"
}

test_check_probe() {
  local home out rc
  home=$(new_home probe)
  out=$(run_in "$home" check); rc=$?
  expect_code 0 "$rc" "configured check"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = available ] || fail "check not available: $out"
  [ "$(printf '%s' "$out" | jq -r '.version')" = 0.3.0 ] || fail "check lost version: $out"
  home="$TMP_ROOT/probe-unconfigured"
  mkdir -p "$home/config" "$home/state"
  out=$(run_in "$home" check); rc=$?
  expect_code 1 "$rc" "unconfigured check"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = not_configured ] || fail "unconfigured check gave: $out"
  pass "check: availability probe reports configuration honestly"
}

# --- allowed-path enforcement -------------------------------------------------

test_allowed_path_enforcement() {
  local home out fixture="$TMP_ROOT/escape.json"
  jq '.matches[0].allows = ["wiki/index.md", "../escape.md", "/etc/passwd", "~/secret.md", "a/../../b.md", ""]' \
    "$MATCHED_FIXTURE" > "$fixture"
  home=$(new_home escape)
  out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "pricing")
  [ "$(printf '%s' "$out" | jq -c '.matches[0].allows')" = '["wiki/index.md"]' ] \
    || fail "unsafe allows not dropped: $(printf '%s' "$out" | jq -c '.matches[0].allows')"
  [ "$(printf '%s' "$out" | jq -r '.dropped_allows')" = 5 ] || fail "dropped_allows miscounted: $out"
  pass "run: absolute, tilde, dot-dot, and empty allows paths are dropped"
}

# --- ambiguity, no-match, privacy, unavailable --------------------------------

test_ambiguous_offers_without_loading() {
  local home out fixture="$TMP_ROOT/ambiguous.json"
  jq '.status = "ambiguous"
      | .confidence = 0.4
      | .matches = []
      | .filtered = []' "$MATCHED_FIXTURE" > "$fixture"
  home=$(new_home ambiguous)
  out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "pricing")
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = ambiguous ] || fail "outcome not ambiguous: $out"
  [ "$(printf '%s' "$out" | jq -r '.matches | length')" = 0 ] || fail "ambiguous must not carry matches"
  assert_not_contains "$out" '"allows":' "ambiguous output must expose no loadable paths"
  [ "$(printf '%s' "$out" | jq -r '.offers[0].wiki')" = OfferWiki ] || fail "offer choice lost: $out"
  pass "run: ambiguity offers a choice without loading"
}

test_no_match_stays_quiet() {
  local home out fixture="$TMP_ROOT/no-match.json"
  jq '.status = "no-match"
      | .confidence = null
      | .matches = []
      | .offers = []
      | .filtered = []
      | .preflight_id = "pf-nomatch-1"
      | .notes = ["no wiki matched this request"]' "$MATCHED_FIXTURE" > "$fixture"
  home=$(new_home no-match)
  out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "quantum llama farming")
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = no-match ] || fail "outcome not no-match: $out"
  assert_not_contains "$out" "ProductWiki" "no-match must stay quiet about wikis"
  assert_not_contains "$out" "OfferWiki" "no-match must stay quiet about wikis"
  assert_not_contains "$out" "HiddenWiki" "no-match must stay quiet about wikis"
  pass "run: no-match stays quiet about wikis"
}

test_privacy_filtered_never_names_wikis() {
  local home out fixture="$TMP_ROOT/filtered.json"
  jq '.status = "privacy-filtered"
      | .confidence = null
      | .matches = []
      | .offers = []
      | .preflight_id = "pf-filtered-1"
      | .notes = ["matching wikis are not accessible to this model class"]' "$MATCHED_FIXTURE" > "$fixture"
  home=$(new_home filtered)
  out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "pricing")
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = privacy-filtered ] || fail "outcome not privacy-filtered: $out"
  [ "$(printf '%s' "$out" | jq -r '.filtered_count')" = 1 ] || fail "filtered_count lost: $out"
  assert_not_contains "$out" "HiddenWiki" "privacy-filtered must never name withheld wikis"
  pass "run: privacy-filtered discloses a count, never names"
}

test_unavailable_is_definitive() {
  local home out fixture="$TMP_ROOT/unavailable.json"
  jq '.status = "unavailable"
      | .confidence = null
      | .matches = []
      | .offers = []
      | .filtered = []
      | .preflight_id = "pf-unavail-1"
      | .notes = ["no usable wiki cards: every root is broken, unreadable, or withheld"]' "$MATCHED_FIXTURE" > "$fixture"
  home=$(new_home unavailable)
  out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "pricing")
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = unavailable ] || fail "outcome not unavailable: $out"
  [ "$(printf '%s' "$out" | jq -r '.preflight_id')" = pf-unavail-1 ] || fail "unavailable lost its proof id: $out"
  pass "run: unavailable is a definitive typed outcome"
}

# --- malformed and failed preflight disclosure --------------------------------

test_malformed_and_failed_disclosure() {
  local home out rc fixture="$TMP_ROOT/garbage.json"
  printf 'this is not json\n' > "$fixture"
  home=$(new_home garbage)
  out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "garbage run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = malformed_output ] || fail "garbage gave: $out"
  # Well-formed JSON with the wrong schema is still malformed.
  printf '{"schema_version":"megamind/route-result/v2","query":"pricing"}' > "$fixture"
  out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "wrong-schema run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = malformed_output ] || fail "wrong schema gave: $out"
  # A Megamind error document surfaces its upstream code.
  printf '{"schema_version":"megamind/error/v1","code":"registry_invalid","message":"synthetic"}' > "$fixture"
  out=$(FM_TEST_STUB_FIXTURE="$fixture" FM_TEST_STUB_EXIT=1 run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "megamind-error run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = megamind_error ] || fail "megamind error gave: $out"
  [ "$(printf '%s' "$out" | jq -r '.failure.upstream_code')" = registry_invalid ] || fail "upstream code lost: $out"
  # Errors are logged with their failure code, never the request.
  assert_grep '"failure":"megamind_error"' "$home/state/megamind-preflight.jsonl" "error run not logged"
  assert_no_grep "pricing" "$home/state/megamind-preflight.jsonl" "error log must not contain the request"
  pass "run: malformed and failed preflights are disclosed, never faked"
}

# --- harness and backend neutrality -------------------------------------------

test_harness_backend_neutrality() {
  local home baseline variant
  home=$(new_home neutral)
  baseline=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing")
  variant=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" CLAUDECODE=1 run_in "$home" run --request "pricing")
  [ "$variant" = "$baseline" ] || fail "output differs under claude markers"
  variant=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" GROK_AGENT=1 run_in "$home" run --request "pricing")
  [ "$variant" = "$baseline" ] || fail "output differs under grok markers"
  variant=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" PI_CODING_AGENT=true run_in "$home" run --request "pricing")
  [ "$variant" = "$baseline" ] || fail "output differs under pi markers"
  variant=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" TMUX=/tmp/fake,123,0 run_in "$home" run --request "pricing")
  [ "$variant" = "$baseline" ] || fail "output differs under tmux"
  variant=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" HERDR_ENV=1 run_in "$home" run --request "pricing")
  [ "$variant" = "$baseline" ] || fail "output differs under herdr"
  variant=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" FM_BACKEND=cmux CMUX_WORKSPACE_ID=ws-1 run_in "$home" run --request "pricing")
  [ "$variant" = "$baseline" ] || fail "output differs under cmux"
  pass "run: output is identical across harness and backend environments"
}

test_classify_bypass_vs_substantive
test_matched_run_and_model_class_propagation
test_proof_log_is_minimal_and_non_verbatim
test_restrictive_defaults
test_check_probe
test_allowed_path_enforcement
test_ambiguous_offers_without_loading
test_no_match_stays_quiet
test_privacy_filtered_never_names_wikis
test_unavailable_is_definitive
test_malformed_and_failed_disclosure
test_harness_backend_neutrality
