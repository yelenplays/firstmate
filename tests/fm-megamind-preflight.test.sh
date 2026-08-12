#!/usr/bin/env bash
# Behavior tests for bin/fm-megamind-preflight.sh, Firstmate's harness-neutral
# read-only Megamind preflight surface.
#
# A synthetic megamind-axi stub stands in for proven Megamind 0.3.x, 0.4.x, 0.5.x,
# and 0.6.x releases: it answers
# --version, records its argv for model-class/estate propagation assertions,
# and prints a canned megamind/preflight-result/v2 JSON fixture (or a controlled
# failure). All fixtures are fully synthetic; no real wiki, path, or request
# content appears. The suite proves mandatory-vs-bypass classification against
# the real operational-input marker bytes, payload-free credential provenance,
# model-class propagation, restrictive config defaults with trimming and tilde
# expansion, identity-anchored non-verbatim version gating, optional privacy
# fields with strict typing when present, safe option-value and dash-leading-request
# handling, allowed-path enforcement, safe thresholds/freshness/provenance and
# optional context-budget propagation, host-owned notes,
# ambiguity/no-match/privacy-filtered behavior, malformed/failed/jq-missing
# disclosure, minimal non-verbatim proof logging, the host-owned date binding,
# session-lock ownership of an offer, preflight parity across every accepted
# line against a 0.6-only continuation, the bounded private selection store and
# its owner-recorded lock, and harness/backend neutrality.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# The classifier defers marker bytes to their protocol owner, so the suite
# asserts against that owner's constants rather than restating them.
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

SCRIPT="$ROOT/bin/fm-megamind-preflight.sh"
TMP_ROOT=$(fm_test_tmproot fm-megamind-preflight)

# bounded <seconds> <cmd...>: hard alarm so a hang fails the suite loudly
# instead of stalling it. perl is already a Firstmate tooling dependency.
bounded() {
  local secs="$1"
  shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

# --- fixture builders --------------------------------------------------------

# new_home <name>: scratch FM_HOME with config/, state/, an estate dir, and a
# stub megamind-axi pinned through config/megamind-executable. Prints the home.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/estate"
  printf '%s\n' "$STUB" > "$home/config/megamind-executable"
  printf '%s\n' "$home/estate" > "$home/config/megamind-estate"
  # The offer binding uses Firstmate's own session lock and nothing else, so a
  # scratch home carries the same state/.lock a locked home does.
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s\n' "$home"
}

# The script owns the date and refuses every injection of one, so an assertion
# about it reads the value back instead of predicting it: the suite may straddle
# a UTC midnight, and either side of that boundary is a correct host date.
assert_host_today() {  # <observed value> <label>
  local observed="$1" label="$2"
  [ "$observed" = "$SUITE_TODAY" ] || [ "$observed" = "$(date -u +%Y-%m-%d)" ] \
    || fail "$label used $observed rather than this host's UTC date"
}
SUITE_TODAY=$(date -u +%Y-%m-%d)

STUB="$TMP_ROOT/fakebin/megamind-axi"
mkdir -p "$TMP_ROOT/fakebin"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
# Synthetic megamind-axi stand-in. FM_TEST_STUB_VERSION overrides the reported
# version, FM_TEST_STUB_VERSION_RAW replaces the whole --version stream verbatim
# so identity-free and noisy probes are reachable, FM_TEST_STUB_FIXTURE selects
# the canned preflight document, FM_TEST_SELECTION_FIXTURE selects the governed
# select-offer document, FM_TEST_STUB_EXIT forces a non-zero exit, and every
# preflight argv is appended to FM_TEST_STUB_ARGS for propagation assertions.
#
# The stub also refuses an option the proven megamind-axi parsers would refuse:
# each subcommand declares its own flag set, so a flag that is unknown there, or
# placed where that parser does not accept it, exits as a usage_error instead of
# being silently swallowed by an argv-ignoring stand-in.
set -u
printf 'CALL\n' >> "${FM_TEST_STUB_ARGS:?}"
if [ -n "${FM_TEST_CREDENTIAL_PAYLOAD:-}" ]; then
  printf 'ENV_PAYLOAD=%s\n' "$FM_TEST_CREDENTIAL_PAYLOAD" >> "$FM_TEST_STUB_ARGS"
fi
if [ "${1:-}" = "--version" ]; then
  if [ -n "${FM_TEST_STUB_VERSION_RAW:-}" ]; then
    printf '%s\n' "$FM_TEST_STUB_VERSION_RAW"
  else
    printf 'megamind-axi %s\n' "${FM_TEST_STUB_VERSION:-0.3.0}"
  fi
  exit 0
fi
printf '%s\n' "$@" >> "$FM_TEST_STUB_ARGS"

usage_error() {
  printf '{"schema_version":"megamind/error/v1","code":"usage_error","message":"%s"}\n' "$1"
  exit 2
}
args=("$@")
count=${#args[@]}
i=0
# Options the top-level parser owns, before the subcommand token.
while [ "$i" -lt "$count" ]; do
  case "${args[$i]}" in
    --format|--root|--today) i=$((i + 2)) ;;
    --no-help-hints) i=$((i + 1)) ;;
    -*) usage_error "unrecognized top-level argument ${args[$i]}" ;;
    *) break ;;
  esac
done
[ "$i" -lt "$count" ] || usage_error "a subcommand is required"
sub="${args[$i]}"
i=$((i + 1))
case "$sub" in
  preflight) allowed=' --model-class --estate --today --full --semantic --format --root --no-help-hints ' ;;
  select-offer) allowed=' --request --preflight-result --model-class --estate --today --format --root --no-help-hints ' ;;
  *) usage_error "invalid choice: $sub" ;;
esac
while [ "$i" -lt "$count" ]; do
  case "${args[$i]}" in
    --) break ;;
    --no-help-hints|--full|--semantic) i=$((i + 1)) ;;
    -?*)
      case "$allowed" in
        *" ${args[$i]} "*) i=$((i + 2)) ;;
        *) usage_error "unrecognized arguments: ${args[$i]}" ;;
      esac
      ;;
    *) i=$((i + 1)) ;;
  esac
done

if [ "$sub" = select-offer ] && [ -n "${FM_TEST_SELECTION_FIXTURE:-}" ]; then
  cat "$FM_TEST_SELECTION_FIXTURE"
elif [ -n "${FM_TEST_STUB_FIXTURE:-}" ]; then
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
  c=$("$SCRIPT" classify "/telegram:access")
  [ "$c" = bypass ] || fail "namespaced slash command classified as $c"
  # Only a bare single command token bypasses: slash-leading and path-leading
  # prose is a request, not a control message.
  c=$("$SCRIPT" classify "/Users/captain/firstmate/data/backlog.md shows three stalled tasks - what should we do about the pricing work?")
  [ "$c" = substantive ] || fail "path-leading request classified as $c"
  c=$("$SCRIPT" classify "/afk until tomorrow, and summarize the pricing risks before you go")
  [ "$c" = substantive ] || fail "slash-leading prose classified as $c"
  # Marker bytes come from the protocol owner; the literal variable name is
  # ordinary text a captain can type and must stay substantive.
  c=$("$SCRIPT" classify "FM_INJECT_MARK stale: worker quiet")
  [ "$c" = substantive ] || fail "literal marker text classified as $c"
  # Each explicitly recognized monitoring kind bypasses, through its current
  # typed form and through its landed legacy prefix alike.
  c=$("$SCRIPT" classify "${FM_OPERATIONAL_HEADER_PREFIX}away-supervisor: worker quiet for 40m")
  [ "$c" = bypass ] || fail "typed away-supervisor input classified as $c"
  c=$("$SCRIPT" classify "${FM_LEGACY_AWAY_PREFIX}worker quiet for 40m)")
  [ "$c" = bypass ] || fail "legacy bare-marker escalation classified as $c"
  c=$("$SCRIPT" classify "${FM_LEGACY_WATCHER_PREFIX}queued wake${FM_LEGACY_WATCHER_SUFFIX}")
  [ "$c" = bypass ] || fail "legacy watcher wake classified as $c"
  c=$("$SCRIPT" classify "$FM_LEGACY_SESSIONSTART")
  [ "$c" = bypass ] || fail "legacy session-start classified as $c"
  c=$("$SCRIPT" classify "${FM_LEGACY_TURNEND_PREFIX}recover before ending the turn")
  [ "$c" = bypass ] || fail "legacy turn-end guard classified as $c"
  # Operational inputs that carry a real task brief stay on the mandatory path.
  c=$("$SCRIPT" classify "${FM_FROMFIRST_MARK}Investigate the pricing regression and report back")
  [ "$c" = substantive ] || fail "from-firstmate dispatch classified as $c"
  c=$("$SCRIPT" classify "${FM_OPERATIONAL_HEADER_PREFIX}launch-brief: build the pricing report")
  [ "$c" = substantive ] || fail "launch brief classified as $c"
  # Anything the protocol owner can only place in its untyped catch-all is
  # unrecognized traffic and must run preflight, brief-shaped or not.
  c=$("$SCRIPT" classify "${FM_OPERATIONAL_PREFIX}heartbeat review")
  [ "$c" = substantive ] || fail "untyped operational prefix classified as $c"
  c=$("$SCRIPT" classify "${FM_OPERATIONAL_HEADER_PREFIX}dispatch-v2: build the pricing report")
  [ "$c" = substantive ] || fail "unrecognized typed kind classified as $c"
  c=$("$SCRIPT" classify "${FM_OPERATIONAL_PREFIX}v2 launch-brief: build the pricing report")
  [ "$c" = substantive ] || fail "future version token classified as $c"
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
    "freshness": {"half_life_days": 30, "last_confirmed": "2026-08-10", "stale": false},
    "evidence": {
      "routing_class": "lexical-card",
      "coverage": {"matched_terms": 1, "request_terms": 2, "ratio": 0.5},
      "signal_counts": {"trigger": 1, "name": 0, "scope": 1},
      "provenance": {"source": "canonical-card", "scope": "declared card metadata only", "page_content": false},
      "lexical_classes": ["trigger", "scope"],
      "semantic": null
    },
    "context_budget": {"max_candidates": 3, "max_context_chars": 4000, "root": "/private/root"},
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
    "evidence": {
      "routing_class": "lexical-card",
      "coverage": {"matched_terms": 1, "request_terms": 2, "ratio": 0.5},
      "signal_counts": {"trigger": 0, "name": 1, "scope": 0},
      "provenance": {"source": "canonical-card", "scope": "declared card metadata only", "page_content": false},
      "lexical_classes": ["name"],
      "semantic": null
    },
    "reasons": []
  }],
  "filtered": [{"name": "HiddenWiki", "root": "/synthetic/estate/HiddenWiki", "access": "none", "reason": "cloud access is none for this wiki"}],
  "declined": [],
  "root_issues": [],
  "redacted_count": 0,
  "notes": ["only wikis at or above the reliance floor (0.75) are loadable matches; the weaker ones stay offers with no loadable paths"]
}
JSON

AMBIGUOUS_SELECTION_FIXTURE="$TMP_ROOT/ambiguous-selection.json"
jq '.status = "ambiguous" | .request = "original request" | .canary = "RAW-REQUEST-CANARY" | .confidence = 0.4 | .matches = [] | .filtered = [] | .notes = []' \
  "$MATCHED_FIXTURE" > "$AMBIGUOUS_SELECTION_FIXTURE"
SELECTION_FIXTURE="$TMP_ROOT/selection.json"
cat > "$SELECTION_FIXTURE" <<'JSON'
{
  "schema_version": "megamind/preflight-selection-result/v1",
  "status": "authorized",
  "preflight_id": "pf-matched-1",
  "request_hash": "reqhash-1",
  "catalog_hash": "cat-1",
  "model_class": "cloud",
  "selection_id": "upstream-selection-1",
  "root_facts_hash": "root-facts-1",
  "selection": {
    "status": "explicit-user-selection",
    "basis": "selected-current-offer",
    "source_disposition": "offer",
    "source_status": "ambiguous",
    "preflight_id": "pf-matched-1",
    "confidence_changed": false
  },
  "selected": {
    "name": "OfferWiki",
    "root": "/synthetic/estate/OfferWiki",
    "score": 0.4,
    "confidence": {"score": 0.4, "meets_floor": false},
    "freshness": {"half_life_days": 30, "last_confirmed": "2026-08-10", "stale": false},
    "evidence": {
      "signal_counts": {"trigger": 0, "name": 1, "scope": 0},
      "lexical_classes": ["name"],
      "semantic": null,
      "RAW": "must not escape"
    },
    "provisional": false,
    "access": "digest-only",
    "routing_mode": "bounded",
    "allows": ["wiki/digest.md"],
    "follow_up": "Run the bounded route ladder",
    "context_budget": {"max_candidates": 2, "max_context_chars": 2048},
    "catalog_visibility": "redacted",
    "redacted": true,
    "trust": "trusted"
  },
  "help": ["upstream text must not escape"]
}
JSON

test_credential_provenance_bypasses_without_payload() {
  local home out credential='TEST-CREDENTIAL-CANARY-NOT-A-SECRET'
  home=$(new_home credential-provenance)
  : > "$FM_TEST_STUB_ARGS"
  export FM_TEST_CREDENTIAL_PAYLOAD="$credential"
  out=$(run_in "$home" classify-provenance credential-submission)
  unset FM_TEST_CREDENTIAL_PAYLOAD
  [ "$out" = bypass ] || fail "trusted credential provenance classified as $out"
  [ ! -s "$FM_TEST_STUB_ARGS" ] || fail "credential provenance reached Megamind argv: $(cat "$FM_TEST_STUB_ARGS")"
  [ ! -e "$home/state/megamind-preflight.jsonl" ] || fail "credential provenance created a proof log"
  assert_no_grep "$credential" "$FM_TEST_STUB_ARGS" "credential text reached Megamind argv"
  out=$(run_in "$home" classify-provenance future-credential-kind)
  [ "$out" = substantive ] || fail "unknown credential provenance classified as $out"
  out=$(run_in "$home" classify "Please explain credential rotation")
  [ "$out" = substantive ] || fail "credential-related prose classified as $out"
  out=$(run_in "$home" classify "API key: TEST-SHAPED-TEXT-NOT-A-SECRET")
  [ "$out" = substantive ] || fail "credential-shaped text triggered content-based bypass: $out"
  pass "classify: trusted credential provenance bypasses without carrying payload text"
}

test_matched_run_and_model_class_propagation() {
  local home out safe_evidence reordered="$TMP_ROOT/reordered-classes.json"
  home=$(new_home matched)
  : > "$FM_TEST_STUB_ARGS"
  out=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "how do we price cleanup offers")
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = matched ] || fail "outcome not matched: $out"
  [ "$(printf '%s' "$out" | jq -r '.preflight_id')" = pf-matched-1 ] || fail "preflight_id not propagated"
  [ "$(printf '%s' "$out" | jq -r '.model_class')" = cloud ] || fail "default model class is not cloud"
  [ "$(printf '%s' "$out" | jq -r '.matches[0].wiki')" = ProductWiki ] || fail "match wiki lost"
  [ "$(printf '%s' "$out" | jq -r '.matches[0].allows | length')" = 3 ] || fail "allows not carried"
  [ "$(printf '%s' "$out" | jq -c '.thresholds')" = '{"reliance_floor":0.75,"offer_floor":0.25,"ambiguity_band":0.05}' ] \
    || fail "self-describing thresholds not carried: $out"
  [ "$(printf '%s' "$out" | jq -c '.matches[0].freshness')" = '{"half_life_days":30,"last_confirmed":"2026-08-10","stale":false}' ] \
    || fail "safe freshness not carried: $out"
  [ "$(printf '%s' "$out" | jq -c '.matches[0].provenance')" = '{"semantic_score":null,"lexical_classes":["trigger","scope"],"signal_counts":{"trigger":1,"name":0,"scope":1},"lexical_signal_count":2}' ] \
    || fail "safe v2 provenance summary not carried: $out"
  [ "$(printf '%s' "$out" | jq -c '.matches[0].context_budget')" = '{"max_candidates":3,"max_context_chars":4000}' ] \
    || fail "safe context budget not carried: $out"
  jq '.matches[0].evidence.lexical_classes = ["scope", "trigger"]' "$MATCHED_FIXTURE" > "$reordered"
  [ "$(FM_TEST_STUB_FIXTURE="$reordered" run_in "$home" run --request "pricing" | jq -c '.matches[0].provenance')" \
    = '{"semantic_score":null,"lexical_classes":["trigger","scope"],"signal_counts":{"trigger":1,"name":0,"scope":1},"lexical_signal_count":2}' ] \
    || fail "count-consistent classes in another order were not carried canonically"
  safe_evidence=$(printf '%s' "$out" | jq -c '{thresholds, evidence: [.matches[] | {freshness, provenance, context_budget}]}')
  assert_not_contains "$safe_evidence" "RAW-EVIDENCE-CANARY" "raw evidence tokens must not pass through"
  assert_not_contains "$safe_evidence" "/private/root" "roots and paths must not enter safe evidence"
  assert_not_contains "$safe_evidence" "HiddenWiki" "filtered identities must not enter safe evidence"
  [ "$(printf '%s' "$out" | jq -r '.filtered_count')" = 1 ] || fail "filtered_count lost"
  assert_not_contains "$out" "HiddenWiki" "filtered wiki name must never be echoed"
  assert_not_contains "$out" "RAW-REQUEST-CANARY" "raw request must never be echoed"
  assert_contains "$out" "read_policy" "read policy missing"
  [ "$(printf '%s' "$out" | jq -r '.notes | length')" = 1 ] || fail "notes must be exactly one host-owned line: $out"
  assert_not_contains "$out" "reliance floor" "Megamind's own note text must never pass through"
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

test_unsafe_evidence_values_are_minimized() {
  local home out safe_evidence fixture="$TMP_ROOT/unsafe-evidence.json" case_name mutation
  home=$(new_home unsafe-evidence)
  for case_name in missing-counts missing-classes unknown-count-key boolean-count \
      negative-count fractional-count unknown-class duplicate-class \
      class-count-mismatch request-derived-class string-evidence array-evidence; do
    case "$case_name" in
      missing-counts)
        mutation='del(.matches[0].evidence.signal_counts)' ;;
      missing-classes)
        mutation='del(.matches[0].evidence.lexical_classes)' ;;
      unknown-count-key)
        mutation='.matches[0].evidence.signal_counts["RAW-COUNT-CANARY"] = 1' ;;
      boolean-count)
        mutation='.matches[0].evidence.signal_counts.trigger = true' ;;
      negative-count)
        mutation='.matches[0].evidence.signal_counts.trigger = -1' ;;
      fractional-count)
        mutation='.matches[0].evidence.signal_counts.scope = 1.5' ;;
      unknown-class)
        mutation='.matches[0].evidence.lexical_classes = ["trigger", "RAW-CLASS-CANARY"]' ;;
      duplicate-class)
        mutation='.matches[0].evidence.lexical_classes = ["trigger", "trigger", "scope"]' ;;
      class-count-mismatch)
        mutation='.matches[0].evidence.lexical_classes = ["trigger"]' ;;
      request-derived-class)
        mutation='.matches[0].evidence.lexical_classes = ["pricing"]' ;;
      string-evidence)
        mutation='.matches[0].evidence = "RAW-EVIDENCE-STRING-CANARY"' ;;
      array-evidence)
        mutation='.matches[0].evidence = ["RAW-EVIDENCE-ARRAY-CANARY"]' ;;
    esac
    jq ".matches[0].freshness = {
            \"half_life_days\": \"RAW-FRESHNESS-CANARY\",
            \"last_confirmed\": \"/private/freshness/path\",
            \"stale\": \"HiddenEvidenceWiki\"
          }
        | .matches[0].evidence.semantic = \"RAW-SEMANTIC-CANARY\"
        | .matches[0].context_budget = {
            \"max_candidates\": \"RAW-BUDGET-CANARY\",
            \"max_context_chars\": -1,
            \"root\": \"/private/budget/root\"
          }
        | $mutation" "$MATCHED_FIXTURE" > "$fixture"
    out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "pricing")
    safe_evidence=$(printf '%s' "$out" | jq -c \
      '{thresholds, evidence: [.matches[] | {freshness, provenance, context_budget}]}')
    [ "$(printf '%s' "$out" | jq -c '.matches[0].freshness')" = '{"half_life_days":null,"last_confirmed":null,"stale":null}' ] \
      || fail "$case_name unsafe freshness values survived: $out"
    [ "$(printf '%s' "$out" | jq -c '.matches[0].provenance')" = '{"semantic_score":null,"lexical_classes":[],"signal_counts":null,"lexical_signal_count":null}' ] \
      || fail "$case_name unsafe provenance values were not withheld: $out"
    [ "$(printf '%s' "$out" | jq -c '.matches[0].context_budget')" = '{}' ] \
      || fail "$case_name unsafe context budget values survived: $out"
    assert_not_contains "$safe_evidence" "RAW-" "$case_name raw evidence strings must not pass through"
    assert_not_contains "$safe_evidence" "/private/" "$case_name evidence roots and paths must not pass through"
    assert_not_contains "$safe_evidence" "HiddenEvidenceWiki" "$case_name evidence identities must not pass through"
    assert_not_contains "$safe_evidence" "pricing" "$case_name request-derived class must not pass through"
  done
  pass "run: malformed v2 evidence and unsafe strings, identities, roots, and paths are withheld"
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
  local home out rc consumed baseline
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
  # The established 0.3.x line remains accepted.
  home=$(new_home old-version)
  out=$(FM_TEST_STUB_VERSION=0.3.9 FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing"); rc=$?
  expect_code 0 "$rc" "proven-0.3-version run"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = matched ] || fail "0.3.x result was not authorized: $out"
  # Phase 3's 0.4.0, Phase 4's 0.5.0, and Phase 6's 0.6.0 preserve the v2
  # fields consumed by Firstmate, including additive fields that normalization does not expose.
  # The authorized outcome alone cannot show that: a withheld lexical packet, a
  # dropped context budget, a null freshness, and a dropped allows path all still
  # normalize to `matched` at exit 0. Every proven line is therefore held to the
  # same consumed retrieval surface as the 0.3.x baseline, and the baseline is
  # itself pinned to the carried lexical packet so a globally withheld surface
  # cannot make the comparison vacuous.
  consumed='{outcome, thresholds, notes, filtered_count, redacted_count, dropped_allows,
    matches: [.matches[] | {freshness, provenance, context_budget, allows}]}'
  baseline=$(printf '%s' "$out" | jq -Sc "$consumed")
  assert_contains "$baseline" '"signal_counts":{"name"' \
    "the 0.3.x consumed-surface baseline already withheld the lexical packet"
  for version in 0.4.0 0.5.0 0.6.0; do
    out=$(FM_TEST_STUB_VERSION="$version" FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing"); rc=$?
    expect_code 0 "$rc" "proven-$version run"
    [ "$(printf '%s' "$out" | jq -r '.outcome')" = matched ] || fail "$version result was not authorized: $out"
    [ "$(printf '%s' "$out" | jq -Sc "$consumed")" = "$baseline" ] \
      || fail "$version changed the consumed retrieval surface: $out"
  done
  # Old, malformed, and unproven future releases stay incompatible.
  for version in 0.2.9 0.4 v0.4.0 0.4.0.1 0.4.0-rc.1 0.7.0 1.0.0; do
    out=$(FM_TEST_STUB_VERSION="$version" FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing"); rc=$?
    expect_code 1 "$rc" "unsupported version $version"
    [ "$(printf '%s' "$out" | jq -r '.failure.code')" = version_incompatible ] || fail "unsupported version $version gave: $out"
    [ "$(printf '%s' "$out" | jq -r '.failure.detected')" = "$version" ] || fail "detected version $version not reported: $out"
  done
  # Invalid model class configuration fails closed.
  home=$(new_home bad-class)
  printf 'turbo\n' > "$home/config/megamind-model-class"
  out=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "invalid-class run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = invalid_model_class ] || fail "invalid class gave: $out"
  pass "run: restrictive defaults, version gate, and invalid config fail closed"
}

test_version_probe_is_anchored_and_non_verbatim() {
  local home out rc raw long canary='RAW-VERSION-CANARY'
  home=$(new_home version-probe)
  long=$(awk 'BEGIN { for (i = 0; i < 40; i++) printf "A" }')
  # A supported version number without the megamind-axi identity does not clear
  # the gate, and neither does another tool claiming one.
  for raw in "0.3.1" "megamind 0.4.0" "megamind-axi0.4.0" "MEGAMIND-AXI 0.4.0"; do
    out=$(FM_TEST_STUB_VERSION_RAW="$raw" FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" \
      run_in "$home" run --request "pricing"); rc=$?
    expect_code 1 "$rc" "unidentified version probe '$raw'"
    [ "$(printf '%s' "$out" | jq -r '.failure.code')" = version_incompatible ] \
      || fail "unidentified version probe '$raw' gave: $out"
    [ "$(printf '%s' "$out" | jq -r '.failure.detected')" = unknown ] \
      || fail "unidentified version probe '$raw' disclosed a version: $out"
  done
  # Noise around exactly one identity line is tolerated, as the anchored probe
  # has always tolerated it; the parsed version is the one on that line.
  out=$(FM_TEST_STUB_VERSION_RAW=$'megamind-axi 0.4.0\nbuild 123' \
    FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing"); rc=$?
  expect_code 0 "$rc" "trailing build metadata after the identity line"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = matched ] || fail "noisy 0.4.0 probe was not authorized: $out"
  out=$(FM_TEST_STUB_VERSION_RAW=$'loading estate cache\nmegamind-axi 0.3.5' \
    run_in "$home" check); rc=$?
  expect_code 0 "$rc" "leading noise before the identity line"
  [ "$(printf '%s' "$out" | jq -r '.version')" = 0.3.5 ] || fail "noisy check lost the parsed version: $out"
  # More than one identity line names no single build, so the gate fails closed.
  out=$(FM_TEST_STUB_VERSION_RAW=$'megamind-axi 0.3.0\nmegamind-axi 0.4.0' \
    FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "two identity lines in one probe"
  [ "$(printf '%s' "$out" | jq -r '.failure.detected')" = unknown ] \
    || fail "two identity lines resolved to a single build: $out"
  # Raw probe output never reaches the disclosed document: only the bounded
  # token from the identity line does, and an unbounded token is not one.
  out=$(FM_TEST_STUB_VERSION_RAW="$canary header"$'\n'"megamind-axi 0.2.9"$'\n'"$canary trailer" \
    FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "an unsupported version surrounded by raw output"
  [ "$(printf '%s' "$out" | jq -r '.failure.detected')" = 0.2.9 ] \
    || fail "the parsed version was not the one disclosed: $out"
  assert_not_contains "$out" "$canary" "raw --version output reached the typed document"
  out=$(FM_TEST_STUB_VERSION_RAW="megamind-axi 0.4.0$long" \
    FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "an unbounded version token"
  [ "$(printf '%s' "$out" | jq -r '.failure.detected')" = unknown ] \
    || fail "an unbounded version token was disclosed: $out"
  assert_not_contains "$out" "$long" "an unbounded version token reached the typed document"
  pass "run: the version probe is identity-anchored, single-line, and never verbatim"
}

test_missing_option_values_fail_closed() {
  local out rc
  # `shift 2` with one positional left shifts nothing, so an unguarded loop
  # spins forever here. The alarm turns any regression into a failure.
  out=$(bounded 5 "$SCRIPT" run --request 2>&1); rc=$?
  expect_code 2 "$rc" "run --request with no value"
  assert_contains "$out" "usage:" "missing --request value must print usage"
  out=$(bounded 5 "$SCRIPT" run --request "pricing" --model-class 2>&1); rc=$?
  expect_code 2 "$rc" "run --model-class with no value"
  out=$(bounded 5 "$SCRIPT" run --model-class 2>&1); rc=$?
  expect_code 2 "$rc" "trailing --model-class with no value"
  out=$(bounded 5 "$SCRIPT" run --bogus value 2>&1); rc=$?
  expect_code 2 "$rc" "unknown run option"
  out=$(bounded 5 "$SCRIPT" run 2>&1); rc=$?
  expect_code 2 "$rc" "run with no request"
  out=$(bounded 5 "$SCRIPT" classify-provenance credential-submission unexpected-payload 2>&1); rc=$?
  expect_code 2 "$rc" "credential provenance with payload argument"
  pass "run: a missing or unknown option value fails closed instead of hanging"
}

test_config_values_are_trimmed_and_tilde_expanded() {
  local home out rc tilde='~'
  home=$(new_home padded)
  printf '  %s  \n' "$home/estate" > "$home/config/megamind-estate"
  printf '  %s  \n' "$STUB" > "$home/config/megamind-executable"
  printf '  cloud  \n' > "$home/config/megamind-model-class"
  out=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing"); rc=$?
  expect_code 0 "$rc" "padded-config run"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = matched ] || fail "padded config values not trimmed: $out"
  [ "$(printf '%s' "$out" | jq -r '.model_class')" = cloud ] || fail "padded model class not trimmed: $out"
  # A leading ~ resolves against HOME.
  home=$(new_home tilde)
  mkdir -p "$home/fakehome/estate"
  printf '%s/estate\n' "$tilde" > "$home/config/megamind-estate"
  : > "$FM_TEST_STUB_ARGS"
  out=$(HOME="$home/fakehome" FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing"); rc=$?
  expect_code 0 "$rc" "tilde-estate run"
  assert_grep "$home/fakehome/estate" "$FM_TEST_STUB_ARGS" "leading ~ not expanded to HOME"
  # Nothing beyond the leading tilde expands: a glob stays a literal path.
  printf '%s/est*\n' "$home" > "$home/config/megamind-estate"
  out=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "glob-estate run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = estate_missing ] || fail "glob estate must not expand: $out"
  pass "run: config values are trimmed and leading-tilde expanded, nothing more"
}

test_request_stdin_keeps_adapter_prompt_out_of_coordinator_argv() {
  local home out
  home=$(new_home request-stdin)
  : > "$FM_TEST_STUB_ARGS"
  out=$(printf '%s' 'stdin prompt canary' | FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request-stdin)
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = matched ] || fail "stdin request did not route: $out"
  assert_grep "stdin prompt canary" "$FM_TEST_STUB_ARGS" "stub did not receive the stdin request"
  pass "run: adapter prompt enters through the private stdin coordinator variant"
}

test_dash_leading_request_is_passed_safely() {
  local home out args
  home=$(new_home dash-request)
  : > "$FM_TEST_STUB_ARGS"
  out=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "--model-class how do we price cleanup")
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = matched ] || fail "dash-leading request did not route: $out"
  args="$FM_TEST_STUB_ARGS"
  # The request is the final argv entry and follows the option terminator, so
  # Megamind's argparse can never read it as an option.
  [ "$(tail -n 1 "$args")" = "--model-class how do we price cleanup" ] || fail "dash-leading request not delivered intact: $(cat "$args")"
  [ "$(tail -n 2 "$args" | head -n 1)" = "--" ] || fail "request is not passed after --: $(cat "$args")"
  pass "run: a dash-leading request is passed after -- and stays a request"
}

test_check_probe() {
  local home out rc
  home=$(new_home probe)
  out=$(run_in "$home" check); rc=$?
  expect_code 0 "$rc" "configured check"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = available ] || fail "check not available: $out"
  [ "$(printf '%s' "$out" | jq -r '.version')" = 0.3.0 ] || fail "check lost version: $out"
  # Both proven lines probe as available, and the probe reports the one it read.
  out=$(FM_TEST_STUB_VERSION=0.4.0 run_in "$home" check); rc=$?
  expect_code 0 "$rc" "0.4 configured check"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = available ] || fail "0.4 check not available: $out"
  [ "$(printf '%s' "$out" | jq -r '.version')" = 0.4.0 ] || fail "0.4 check lost version: $out"
  out=$(FM_TEST_STUB_VERSION=0.5.0 run_in "$home" check); rc=$?
  expect_code 0 "$rc" "0.5 configured check"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = available ] || fail "0.5 check not available: $out"
  [ "$(printf '%s' "$out" | jq -r '.version')" = 0.5.0 ] || fail "0.5 check lost version: $out"
  out=$(FM_TEST_STUB_VERSION=0.6.0 run_in "$home" check); rc=$?
  expect_code 0 "$rc" "0.6 configured check"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = available ] || fail "0.6 check not available: $out"
  [ "$(printf '%s' "$out" | jq -r '.version')" = 0.6.0 ] || fail "0.6 check lost version: $out"
  out=$(FM_TEST_STUB_VERSION=0.7.0 run_in "$home" check); rc=$?
  expect_code 1 "$rc" "unproven future check"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = version_incompatible ] \
    || fail "unproven future check gave: $out"
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
      | .request = "pricing"
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

test_notes_are_host_owned() {
  local home out fixture="$TMP_ROOT/leaky-notes.json"
  # Real 0.3.0 notes can name below-floor wikis, out-of-band candidates, and
  # absolute roots on exactly the outcomes that must stay quiet.
  jq '.status = "no-match"
      | .confidence = null
      | .matches = []
      | .offers = []
      | .filtered = []
      | .preflight_id = "pf-leaky-1"
      | .notes = [
          "wikis below the no-match floor (0.75): omitted ProductWiki, OfferWiki",
          "wikis outside the ambiguity band (0.05): omitted HiddenWiki",
          "broken root: /synthetic/estate/ProductWiki is unreadable"
        ]' "$MATCHED_FIXTURE" > "$fixture"
  home=$(new_home leaky-notes)
  out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "quantum llama farming")
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = no-match ] || fail "outcome not no-match: $out"
  [ "$(printf '%s' "$out" | jq -r '.notes | length')" = 1 ] || fail "notes must be exactly one host-owned line: $out"
  assert_not_contains "$out" "ProductWiki" "notes must not name below-floor wikis"
  assert_not_contains "$out" "OfferWiki" "notes must not name out-of-band candidates"
  assert_not_contains "$out" "HiddenWiki" "notes must not name withheld wikis"
  assert_not_contains "$out" "/synthetic/estate" "notes must not carry absolute roots"
  assert_not_contains "$out" "no-match floor" "upstream note text must never pass through"
  assert_not_contains "$out" "broken root" "upstream note text must never pass through"
  pass "run: notes are host-owned and never echo Megamind's own"
}

test_privacy_filtered_never_names_wikis() {
  local home out rc fixture="$TMP_ROOT/filtered.json"
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
  # The same outcome from a release that omits the optional privacy fields still
  # discloses a count and still names nothing.
  jq 'del(.filtered) | del(.redacted_count)' "$fixture" > "$fixture.optional"
  out=$(FM_TEST_STUB_FIXTURE="$fixture.optional" run_in "$home" run --request "pricing"); rc=$?
  expect_code 0 "$rc" "privacy-filtered run without the optional privacy fields"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = privacy-filtered ] \
    || fail "privacy-filtered without the optional fields was not definitive: $out"
  [ "$(printf '%s' "$out" | jq -r '.filtered_count')" = 0 ] || fail "filtered_count is not the safe default: $out"
  [ "$(printf '%s' "$out" | jq -r '.redacted_count')" = 0 ] || fail "redacted_count is not the safe default: $out"
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
  local home out rc mutation fixture="$TMP_ROOT/garbage.json"
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
  # Missing or non-numeric decision thresholds make the v2 document malformed.
  jq 'del(.thresholds)' "$MATCHED_FIXTURE" > "$fixture"
  out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "missing-thresholds run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = malformed_output ] || fail "missing thresholds gave: $out"
  jq '.thresholds.reliance_floor = "RAW-THRESHOLD-CANARY"' "$MATCHED_FIXTURE" > "$fixture"
  out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "malformed-thresholds run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = malformed_output ] || fail "malformed thresholds gave: $out"
  assert_not_contains "$out" "RAW-THRESHOLD-CANARY" "malformed threshold content must not pass through"
  # Missing or incompatible fields are not accepted merely because the outer
  # document has the v2 schema marker.
  jq 'del(.matches)' "$MATCHED_FIXTURE" > "$fixture"
  out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "missing-matches run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = malformed_output ] || fail "missing matches gave: $out"
  jq '.matches[0].allows = "not-an-array"' "$MATCHED_FIXTURE" > "$fixture"
  out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "incompatible-match-field run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = malformed_output ] || fail "incompatible match field gave: $out"
  # The privacy fields are optional: an absent one keeps its existing safe
  # default rather than turning a definitive outcome into a failure.
  jq 'del(.filtered) | del(.redacted_count)' "$MATCHED_FIXTURE" > "$fixture"
  out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "pricing"); rc=$?
  expect_code 0 "$rc" "absent-privacy-fields run"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = matched ] || fail "absent privacy fields blocked a match: $out"
  [ "$(printf '%s' "$out" | jq -r '.filtered_count')" = 0 ] || fail "absent filtered lost its safe default: $out"
  [ "$(printf '%s' "$out" | jq -r '.redacted_count')" = 0 ] || fail "absent redacted_count lost its safe default: $out"
  jq '.filtered = null | .redacted_count = null' "$MATCHED_FIXTURE" > "$fixture"
  out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "pricing"); rc=$?
  expect_code 0 "$rc" "null-privacy-fields run"
  [ "$(printf '%s' "$out" | jq -r '.filtered_count')" = 0 ] || fail "null filtered lost its safe default: $out"
  [ "$(printf '%s' "$out" | jq -r '.redacted_count')" = 0 ] || fail "null redacted_count lost its safe default: $out"
  # A present one is still strictly typed and range-checked.
  jq '.filtered = "RAW-FILTERED-CANARY"' "$MATCHED_FIXTURE" > "$fixture"
  out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "wrong-typed-filtered run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = malformed_output ] || fail "wrong-typed filtered gave: $out"
  assert_not_contains "$out" "RAW-FILTERED-CANARY" "malformed privacy content must not pass through"
  for mutation in '.redacted_count = "2"' '.redacted_count = -1' '.redacted_count = 1.5' '.redacted_count = true'; do
    jq "$mutation" "$MATCHED_FIXTURE" > "$fixture"
    out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "pricing"); rc=$?
    expect_code 1 "$rc" "redacted_count mutation $mutation"
    [ "$(printf '%s' "$out" | jq -r '.failure.code')" = malformed_output ] \
      || fail "redacted_count mutation $mutation gave: $out"
  done
  # A Megamind error document surfaces its upstream code.
  printf '{"schema_version":"megamind/error/v1","code":"registry_invalid","message":"synthetic"}' > "$fixture"
  out=$(FM_TEST_STUB_FIXTURE="$fixture" FM_TEST_STUB_EXIT=1 run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "megamind-error run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = megamind_error ] || fail "megamind error gave: $out"
  [ "$(printf '%s' "$out" | jq -r '.failure.upstream_code')" = registry_invalid ] || fail "upstream code lost: $out"
  # Errors are logged with their failure code, never the request.
  assert_grep '"failure":"megamind_error"' "$home/state/megamind-preflight.jsonl" "error run not logged"
  assert_no_grep "pricing" "$home/state/megamind-preflight.jsonl" "error log must not contain the request"
  # A well-formed v2 document carrying a status outside the known set is not a
  # definitive outcome; it fails closed rather than passing an unknown through.
  jq '.status = "definitely-fine"' "$MATCHED_FIXTURE" > "$fixture"
  out=$(FM_TEST_STUB_FIXTURE="$fixture" run_in "$home" run --request "pricing"); rc=$?
  expect_code 1 "$rc" "unknown-status run"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = malformed_output ] || fail "unknown status gave: $out"
  pass "run: malformed and failed preflights are disclosed, never faked"
}

test_jq_missing_is_disclosed() {
  local home out rc nojq log
  nojq="$TMP_ROOT/nojq"
  mkdir -p "$nojq"
  local tool
  for tool in bash dirname date mkdir; do
    ln -sf "$(command -v "$tool")" "$nojq/$tool"
  done
  [ ! -e "$nojq/jq" ] || fail "jq-missing fixture PATH must not contain jq"
  home=$(new_home nojq)
  out=$(PATH="$nojq" FM_HOME="$home" bash "$SCRIPT" run --request "pricing" 2>/dev/null); rc=$?
  expect_code 1 "$rc" "run without jq"
  [ "$(printf '%s' "$out" | jq -r '.schema_version')" = "fm/megamind-preflight/v1" ] || fail "jq-missing document lost its schema: $out"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = error ] || fail "jq-missing outcome not error: $out"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = jq_missing ] || fail "jq-missing code not emitted: $out"
  [ "$(printf '%s' "$out" | jq -r '.matches | length')" = 0 ] || fail "jq-missing document must carry no evidence: $out"
  log="$home/state/megamind-preflight.jsonl"
  assert_present "$log" "jq-missing proof line was not written"
  assert_grep '"failure":"jq_missing"' "$log" "jq-missing proof line lost its failure code"
  assert_no_grep "pricing" "$log" "jq-missing proof line must not contain the request"
  [ "$(jq -r 'keys | sort | join(",")' "$log")" = "catalog_hash,failure,model_class,outcome,preflight_id,request_hash,ts,wikis" ] \
    || fail "jq-missing proof line field set drifted: $(jq -c 'keys' "$log")"
  pass "run: the typed jq_missing document and proof line are emitted without jq"
}

# --- harness and backend neutrality -------------------------------------------

test_explicit_offer_selection_continuation() {
  # `select-offer` and the selection contract are 0.6.x, so every home that
  # must be able to hold or spend an offer reports that line.
  export FM_TEST_STUB_VERSION=0.6.0
  local home out id pending auth rc fixture mode today
  home=$(new_home explicit-selection)
  : > "$FM_TEST_STUB_ARGS"
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" \
    run_in "$home" run --request "original request"); rc=$?
  expect_code 0 "$rc" "ambiguous selection preflight"
  # The exact argv is pinned, because a flag the real parser would refuse is
  # otherwise invisible: the whole mandatory path depends on this shape.
  today=$(sed -n '9p' "$FM_TEST_STUB_ARGS")
  assert_host_today "$today" "the preflight call"
  [ "$(cat "$FM_TEST_STUB_ARGS")" = "$(printf 'CALL\nCALL\npreflight\n--model-class\ncloud\n--estate\n%s\n--today\n%s\n--format\njson\n--no-help-hints\n--\noriginal request' "$home/estate" "$today")" ] \
    || fail "preflight argv drifted: $(cat "$FM_TEST_STUB_ARGS")"
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  [ "${#id}" -ge 16 ] && [ "${#id}" -le 128 ] && [[ "$id" =~ ^[A-Fa-f0-9]+$ ]] \
    || fail "ambiguous output did not expose an opaque selection id"
  pending="$home/state/megamind-offer-selections/$id.pending.json"
  assert_present "$pending" "ambiguous preflight did not retain private pending evidence"
  if [ "$(uname)" = Darwin ]; then mode=$(stat -f %Lp "$pending"); else mode=$(stat -c %a "$pending"); fi
  [ "$mode" = 600 ] || fail "pending evidence is not mode 0600"
  assert_grep "RAW-REQUEST-CANARY" "$pending" "complete upstream packet was not retained privately"
  assert_not_contains "$out" "RAW-REQUEST-CANARY" "raw request leaked into the normalized output"
  assert_no_grep "RAW-REQUEST-CANARY" "$home/state/megamind-preflight.jsonl" \
    "raw packet leaked into the proof log"

  : > "$FM_TEST_STUB_ARGS"
  out=$(FM_TEST_SELECTION_FIXTURE="$SELECTION_FIXTURE" \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki); rc=$?
  expect_code 0 "$rc" "exact explicit offer selection"
  today=$(sed -n '14p' "$FM_TEST_STUB_ARGS")
  assert_host_today "$today" "the select-offer call"
  [ "$(sed -n '3,5p;7p;9,17p' "$FM_TEST_STUB_ARGS")" = "$(printf 'select-offer\nOfferWiki\n--request\n--preflight-result\n--model-class\ncloud\n--estate\n%s\n--today\n%s\n--format\njson\n--no-help-hints' "$home/estate" "$today")" ] \
    || fail "select-offer argv drifted: $(cat "$FM_TEST_STUB_ARGS")"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = authorized ] || fail "selection was not authorized: $out"
  [ "$(printf '%s' "$out" | jq -r '.selection.threshold_matched')" = false ] || fail "selection became a threshold match"
  [ "$(printf '%s' "$out" | jq -r '.selected.allows[0]')" = wiki/digest.md ] || fail "selected allows changed"
  [ "$(printf '%s' "$out" | jq -r '.selected.context_budget.max_context_chars')" = 2048 ] || fail "positive context budget was lost"
  [ "$(printf '%s' "$out" | jq -r '.selected.evidence.lexical_classes[0]')" = name ] || fail "safe evidence was lost"
  assert_not_contains "$out" "RAW" "raw upstream evidence escaped the authorization projection"
  auth="$home/state/megamind-offer-selections/$id.authorization.json"
  assert_present "$auth" "authorization projection was not retained privately"
  if [ "$(uname)" = Darwin ]; then mode=$(stat -f %Lp "$auth"); else mode=$(stat -c %a "$auth"); fi
  [ "$mode" = 600 ] || fail "authorization projection is not mode 0600"
  assert_absent "$pending" "pending evidence was not retired after successful consumption"

  out=$(FM_TEST_SELECTION_FIXTURE="$SELECTION_FIXTURE" \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki); rc=$?
  expect_code 1 "$rc" "replayed explicit offer selection"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = selection_replayed ] || fail "replay was not refused: $out"

  # A failed select-offer must still print one typed refusal carrying the
  # upstream code, which is exactly what a corrupted extra object would swallow.
  home=$(new_home upstream-error-selection)
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" \
    run_in "$home" run --request "original request")
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  fixture="$TMP_ROOT/upstream-error.json"
  printf '{"schema_version":"megamind/error/v1","code":"selection_refused"}\n' > "$fixture"
  out=$(FM_TEST_SELECTION_FIXTURE="$fixture" FM_TEST_STUB_EXIT=1 \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki); rc=$?
  expect_code 1 "$rc" "failed select-offer"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = upstream_error ] \
    || fail "a failed select-offer did not print a typed refusal: $out"
  [ "$(printf '%s' "$out" | jq -r '.failure.upstream_code')" = selection_refused ] \
    || fail "the typed refusal lost the upstream code: $out"
  assert_present "$home/state/megamind-offer-selections/$id.pending.json" \
    "an upstream error destroyed retryable pending evidence"

  home=$(new_home wrong-offer)
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" \
    run_in "$home" run --request "original request")
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  out=$(FM_TEST_SELECTION_FIXTURE="$SELECTION_FIXTURE" \
    run_in "$home" continue --selection-id "$id" --offer UnknownWiki); rc=$?
  expect_code 1 "$rc" "wrong offer selection"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = offer_invalid ] || fail "wrong offer was accepted: $out"
  assert_present "$home/state/megamind-offer-selections/$id.pending.json" \
    "wrong offer destroyed retryable pending evidence"

  home=$(new_home changed-binding)
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" \
    run_in "$home" run --request "original request")
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  printf 'local\n' > "$home/config/megamind-model-class"
  out=$(FM_TEST_SELECTION_FIXTURE="$SELECTION_FIXTURE" \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki); rc=$?
  expect_code 1 "$rc" "changed model binding"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = binding_changed ] || fail "changed model binding was accepted"

  home=$(new_home malformed-selection)
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" \
    run_in "$home" run --request "original request")
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  fixture="$TMP_ROOT/malformed-selection.json"
  jq '.selected.allows = ["../escape.md"]' "$SELECTION_FIXTURE" > "$fixture"
  out=$(FM_TEST_SELECTION_FIXTURE="$fixture" \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki); rc=$?
  expect_code 1 "$rc" "malformed selection result"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = malformed_result ] || fail "malformed result was accepted"
  assert_present "$home/state/megamind-offer-selections/$id.pending.json" \
    "malformed result did not preserve retryable evidence"

  home=$(new_home absent-budget)
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" \
    run_in "$home" run --request "original request")
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  fixture="$TMP_ROOT/absent-budget.json"
  jq 'del(.selected.context_budget)' "$SELECTION_FIXTURE" > "$fixture"
  out=$(FM_TEST_SELECTION_FIXTURE="$fixture" \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki); rc=$?
  expect_code 0 "$rc" "selection without context budget"
  [ "$(printf '%s' "$out" | jq 'has("selected") and (.selected | has("context_budget") | not)')" = true ] \
    || fail "absent context budget was invented"

  # The shape the real 0.6 build returns for an ambiguity decided inside the
  # band: a raw non-negative rank and an upstream meets_floor of true. Both are
  # Megamind's own facts, so they pass through without becoming a threshold match.
  home=$(new_home upstream-floor-shape)
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" \
    run_in "$home" run --request "original request")
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  fixture="$TMP_ROOT/upstream-floor-shape.json"
  jq '.selected.score = 8 | .selected.confidence = {"score": 1.0, "meets_floor": true}' \
    "$SELECTION_FIXTURE" > "$fixture"
  out=$(FM_TEST_SELECTION_FIXTURE="$fixture" \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki); rc=$?
  expect_code 0 "$rc" "upstream rank and floor shape"
  [ "$(printf '%s' "$out" | jq -r '.selected.score')" = 8 ] || fail "upstream rank was not preserved: $out"
  [ "$(printf '%s' "$out" | jq -r '.selected.confidence.meets_floor')" = true ] \
    || fail "upstream meets_floor was restated instead of preserved: $out"
  [ "$(printf '%s' "$out" | jq -r '.selection.threshold_matched')" = false ] \
    || fail "an upstream floor fact turned the selection into a threshold match: $out"

  home=$(new_home stale-catalog)
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" \
    run_in "$home" run --request "original request")
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  fixture="$TMP_ROOT/stale-catalog.json"
  jq '.catalog_hash = "stale-catalog"' "$SELECTION_FIXTURE" > "$fixture"
  out=$(FM_TEST_SELECTION_FIXTURE="$fixture" \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki); rc=$?
  expect_code 1 "$rc" "stale catalog result"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = malformed_result ] || fail "stale catalog was accepted"

  home=$(new_home changed-version)
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" \
    run_in "$home" run --request "original request")
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  out=$(FM_TEST_SELECTION_FIXTURE="$SELECTION_FIXTURE" FM_TEST_STUB_VERSION=0.5.0 \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki); rc=$?
  expect_code 1 "$rc" "changed executable version"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = binding_changed ] || fail "changed executable version was accepted"

  for governance in provisional pointer no-load; do
    home=$(new_home "governance-$governance")
    out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" \
      run_in "$home" run --request "original request")
    id=$(printf '%s' "$out" | jq -r '.selection_id')
    fixture="$TMP_ROOT/$governance-selection.json"
    case "$governance" in
      provisional) jq '.selected.provisional = true' "$SELECTION_FIXTURE" > "$fixture" ;;
      pointer) jq '.selected.routing_mode = "pointer"' "$SELECTION_FIXTURE" > "$fixture" ;;
      no-load) jq '.selected.access = "none"' "$SELECTION_FIXTURE" > "$fixture" ;;
    esac
    out=$(FM_TEST_SELECTION_FIXTURE="$fixture" \
      run_in "$home" continue --selection-id "$id" --offer OfferWiki); rc=$?
    expect_code 1 "$rc" "$governance selection result"
    [ "$(printf '%s' "$out" | jq -r '.failure.code')" = malformed_result ] \
      || fail "$governance selection was accepted"
  done

  home=$(new_home concurrent-selection)
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" \
    run_in "$home" run --request "original request")
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  FM_TEST_SELECTION_FIXTURE="$SELECTION_FIXTURE" \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki > "$TMP_ROOT/concurrent-a" 2>&1 &
  local first_pid=$!
  FM_TEST_SELECTION_FIXTURE="$SELECTION_FIXTURE" \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki > "$TMP_ROOT/concurrent-b" 2>&1 &
  local second_pid=$!
  wait "$first_pid"; local first_rc=$?
  wait "$second_pid"; local second_rc=$?
  [ "$first_rc" -ne "$second_rc" ] || fail "concurrent continuation did not produce one success and one refusal"
  [ -f "$home/state/megamind-offer-selections/$id.authorization.json" ] \
    || fail "concurrent continuation did not publish one authorization"
  [ ! -f "$home/state/megamind-offer-selections/$id.pending.json" ] \
    || fail "concurrent continuation left pending evidence after success"
  unset FM_TEST_STUB_VERSION
  pass "continue: explicit selection is private, bound, safe, one-time, and concurrency-serialized"
}

test_date_binding_is_host_owned() {
  # `select-offer` and the selection contract are 0.6.x, so every home that
  # must be able to hold or spend an offer reports that line.
  export FM_TEST_STUB_VERSION=0.6.0
  local home out id pending rc today
  home=$(new_home host-owned-date)
  # --today may only assert the host's own date, so it can never reshape the
  # freshness, staleness, or selection-binding semantics of a preflight. A UTC
  # midnight between the read and the call is a correct refusal, not a failure,
  # so the assertion is re-made once against the date that has since become now.
  today=$(date -u +%Y-%m-%d)
  out=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing" --today "$today"); rc=$?
  if [ "$rc" -ne 0 ] && [ "$today" != "$(date -u +%Y-%m-%d)" ]; then
    today=$(date -u +%Y-%m-%d)
    out=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing" --today "$today"); rc=$?
  fi
  expect_code 0 "$rc" "asserted host date"
  out=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing" --today 2020-01-01); rc=$?
  expect_code 1 "$rc" "forged past date"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = invalid_today ] || fail "a forged date was accepted: $out"
  out=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" run_in "$home" run --request "pricing" --today not-a-date); rc=$?
  expect_code 1 "$rc" "malformed date"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = invalid_today ] || fail "a malformed date was accepted: $out"
  # No environment token substitutes for the host clock either.
  : > "$FM_TEST_STUB_ARGS"
  out=$(FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" FM_MEGAMIND_TODAY=2020-01-01 \
    run_in "$home" run --request "pricing"); rc=$?
  expect_code 0 "$rc" "environment date token"
  assert_no_grep "2020-01-01" "$FM_TEST_STUB_ARGS" "an environment date token reached Megamind"
  assert_host_today "$(sed -n '9p' "$FM_TEST_STUB_ARGS")" "the run behind an environment date token"

  # A pending record whose bound date is no longer the host's cannot authorize.
  home=$(new_home stale-date-binding)
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" run_in "$home" run --request "original request")
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  pending="$home/state/megamind-offer-selections/$id.pending.json"
  jq -c '.today = "2020-01-01"' "$pending" > "$pending.next" && mv -f "$pending.next" "$pending"
  chmod 600 "$pending"
  out=$(FM_TEST_SELECTION_FIXTURE="$SELECTION_FIXTURE" \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki); rc=$?
  expect_code 1 "$rc" "stale date binding"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = binding_changed ] || fail "a stale date binding was accepted: $out"
  unset FM_TEST_STUB_VERSION
  pass "run/continue: the date binding is the host's own and no caller can forge it"
}

test_offer_ownership_requires_a_session_lock() {
  # `select-offer` and the selection contract are 0.6.x, so every home that
  # must be able to hold or spend an offer reports that line.
  export FM_TEST_STUB_VERSION=0.6.0
  local home out id rc
  home=$(new_home unowned-offer)
  rm -f "$home/state/.lock"
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" run_in "$home" run --request "original request"); rc=$?
  expect_code 0 "$rc" "ambiguous preflight without a session lock"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = ambiguous ] || fail "an unowned home lost its ambiguous outcome: $out"
  [ "$(printf '%s' "$out" | jq 'has("selection_id")')" = false ] \
    || fail "an unowned home still offered a continuation identity: $out"
  [ ! -d "$home/state/megamind-offer-selections" ] \
    || fail "an unowned home retained pending evidence nobody can consume"

  # An offer captured under one session lock is not the next session's to spend.
  home=$(new_home rotated-session)
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" run_in "$home" run --request "original request")
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  printf '%s\n' "$(( $$ + 1 ))" > "$home/state/.lock"
  out=$(FM_TEST_SELECTION_FIXTURE="$SELECTION_FIXTURE" \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki); rc=$?
  expect_code 1 "$rc" "rotated session lock"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = binding_changed ] || fail "another session consumed the offer: $out"
  rm -f "$home/state/.lock"
  out=$(FM_TEST_SELECTION_FIXTURE="$SELECTION_FIXTURE" \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki); rc=$?
  expect_code 1 "$rc" "absent session lock"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = session_unavailable ] \
    || fail "an unlocked home consumed the offer: $out"
  unset FM_TEST_STUB_VERSION
  pass "continue: only the authoritative session lock that captured an offer can spend it"
}

test_older_lines_keep_preflight_without_offering_continuation() {
  local home out id rc version pending
  # Every accepted line still routes the mandatory preflight with the same argv,
  # including --today, so no proven release loses substantive preflight.
  for version in 0.3.0 0.4.0 0.5.0 0.6.0; do
    home=$(new_home "line-$version")
    : > "$FM_TEST_STUB_ARGS"
    out=$(FM_TEST_STUB_VERSION="$version" FM_TEST_STUB_FIXTURE="$MATCHED_FIXTURE" \
      run_in "$home" run --request "pricing"); rc=$?
    expect_code 0 "$rc" "$version mandatory preflight"
    [ "$(printf '%s' "$out" | jq -r '.outcome')" = matched ] || fail "$version lost its matched outcome: $out"
    [ "$(sed -n '3p;8p' "$FM_TEST_STUB_ARGS")" = "$(printf 'preflight\n--today')" ] \
      || fail "$version did not receive the one proven argv: $(cat "$FM_TEST_STUB_ARGS")"
  done

  # But select-offer is 0.6-only, so an older line takes the uncontinuable path
  # rather than handing out a handle it could never spend.
  for version in 0.3.0 0.4.0 0.5.0; do
    home=$(new_home "ambiguous-$version")
    out=$(FM_TEST_STUB_VERSION="$version" FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" \
      run_in "$home" run --request "original request"); rc=$?
    expect_code 0 "$rc" "$version ambiguous preflight"
    [ "$(printf '%s' "$out" | jq -r '.outcome')" = ambiguous ] || fail "$version lost its ambiguous outcome: $out"
    [ "$(printf '%s' "$out" | jq 'has("selection_id")')" = false ] \
      || fail "$version offered a continuation its build cannot honour: $out"
    [ ! -d "$home/state/megamind-offer-selections" ] \
      || fail "$version retained pending evidence nobody can consume"
  done

  # A build that loses select-offer under an existing record refuses before the
  # command is sent, rather than letting Megamind answer with a usage error.
  home=$(new_home downgraded-line)
  out=$(FM_TEST_STUB_VERSION=0.6.0 FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" \
    run_in "$home" run --request "original request")
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  pending="$home/state/megamind-offer-selections/$id.pending.json"
  jq -c '.executable.version = "0.5.0"' "$pending" > "$pending.next" && mv -f "$pending.next" "$pending"
  chmod 600 "$pending"
  : > "$FM_TEST_STUB_ARGS"
  out=$(FM_TEST_STUB_VERSION=0.5.0 FM_TEST_SELECTION_FIXTURE="$SELECTION_FIXTURE" \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki); rc=$?
  expect_code 1 "$rc" "continuation on a build without select-offer"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = selection_unsupported ] \
    || fail "a build without select-offer was asked to select: $out"
  assert_no_grep "select-offer" "$FM_TEST_STUB_ARGS" "select-offer was sent to a build that lacks it"
  assert_present "$pending" "an unsupported build destroyed retryable pending evidence"
  pass "run/continue: every accepted line keeps preflight and only 0.6.x is offered a continuation"
}

test_pending_evidence_is_bounded_and_reclaimable() {
  # `select-offer` and the selection contract are 0.6.x, so every home that
  # must be able to hold or spend an offer reports that line.
  export FM_TEST_STUB_VERSION=0.6.0
  local home out id rc lock stale count
  home=$(new_home bounded-selections)
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" run_in "$home" run --request "original request")
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  # A record bound to another date can never authorize again, so the next
  # ambiguous run retires it instead of accumulating it forever.
  stale="$home/state/megamind-offer-selections/$(printf 'a%.0s' $(seq 1 32)).pending.json"
  jq -c '.today = "2020-01-01"' "$home/state/megamind-offer-selections/$id.pending.json" > "$stale"
  chmod 600 "$stale"
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" run_in "$home" run --request "another request")
  assert_absent "$stale" "an unconsumable pending record was never retired"
  count=$(find "$home/state/megamind-offer-selections" -name '*.pending.json' | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "the live pending records did not survive pruning: $count"

  # The store's own working artifacts carry the same packet and verbatim
  # request, so the bound covers them and an abandoned lock directory too.
  local store="$home/state/megamind-offer-selections" orphan_lock
  printf '{}' > "$store/.$id.packet.999999"
  printf '{}' > "$store/$id.authorization.json.tmp.999999"
  orphan_lock="$store/.ffffffffffffffff.lock"
  mkdir -p "$orphan_lock"
  printf '2147483646\n' > "$orphan_lock/pid"
  printf 'Thu Jan  1 00:00:00 2015\n' > "$orphan_lock/start"
  printf 'megamind-continue-that-is-gone\n' > "$orphan_lock/command"
  touch -t 202001010000 "$store/.$id.packet.999999" \
    "$store/$id.authorization.json.tmp.999999" "$orphan_lock"
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" run_in "$home" run --request "a third request")
  assert_absent "$store/.$id.packet.999999" "an abandoned packet extract was never retired"
  assert_absent "$store/$id.authorization.json.tmp.999999" "an abandoned publish temporary was never retired"
  assert_absent "$orphan_lock" "an abandoned lock directory was never released"

  # Crossing the retention cap evicts the oldest same-date records and keeps
  # exactly the newest bound, which is the only path that reads file_mtime.
  home=$(new_home capped-selections)
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" run_in "$home" run --request "original request")
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  store="$home/state/megamind-offer-selections"
  local i seeded newest
  for i in $(seq 1 33); do
    seeded=$(printf '%s' "$store/$(printf 'b%.0s' $(seq 1 30))$(printf '%02d' "$i").pending.json")
    cp "$store/$id.pending.json" "$seeded"
    chmod 600 "$seeded"
    touch -t "$(printf '2026010100%02d' "$i")" "$seeded"
  done
  count=$(find "$store" -name '*.pending.json' | wc -l | tr -d ' ')
  [ "$count" = 34 ] || fail "the retention-cap fixture did not seed 34 records: $count"
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" run_in "$home" run --request "one more request")
  count=$(find "$store" -name '*.pending.json' | wc -l | tr -d ' ')
  [ "$count" = 32 ] || fail "the retention cap did not bound the private store: $count"
  newest=$(printf 'b%.0s' $(seq 1 30))
  assert_present "$store/${newest}33.pending.json" "the newest seeded record was evicted"
  assert_absent "$store/${newest}01.pending.json" "the oldest seeded record survived the cap"

  # An abandoned lock names an owner, so it is reclaimed rather than wedging
  # every later continuation of that selection.
  home=$(new_home abandoned-lock)
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" run_in "$home" run --request "original request")
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  lock="$home/state/megamind-offer-selections/.$id.lock"
  mkdir -p "$lock"
  printf '2147483646\n' > "$lock/pid"
  printf 'Thu Jan  1 00:00:00 2015\n' > "$lock/start"
  printf 'megamind-continue-that-is-gone\n' > "$lock/command"
  out=$(FM_TEST_SELECTION_FIXTURE="$SELECTION_FIXTURE" \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki); rc=$?
  expect_code 0 "$rc" "continuation behind an abandoned lock"
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = authorized ] || fail "an abandoned lock wedged the selection: $out"
  assert_absent "$lock" "the reclaimed lock was not released"

  # A live owner still holds it.
  home=$(new_home held-lock)
  out=$(FM_TEST_STUB_FIXTURE="$AMBIGUOUS_SELECTION_FIXTURE" run_in "$home" run --request "original request")
  id=$(printf '%s' "$out" | jq -r '.selection_id')
  lock="$home/state/megamind-offer-selections/.$id.lock"
  mkdir -p "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  ps -p "$$" -o lstart= > "$lock/start"
  ps -p "$$" -o command= > "$lock/command"
  out=$(FM_TEST_SELECTION_FIXTURE="$SELECTION_FIXTURE" \
    run_in "$home" continue --selection-id "$id" --offer OfferWiki); rc=$?
  expect_code 1 "$rc" "continuation behind a live lock"
  [ "$(printf '%s' "$out" | jq -r '.failure.code')" = selection_busy ] || fail "a live lock was stolen: $out"
  assert_present "$home/state/megamind-offer-selections/$id.pending.json" \
    "a refused busy continuation destroyed retryable evidence"
  unset FM_TEST_STUB_VERSION
  pass "continue: pending evidence stays bounded and only a provably dead lock owner is reclaimed"
}

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
test_credential_provenance_bypasses_without_payload
test_matched_run_and_model_class_propagation
test_unsafe_evidence_values_are_minimized
test_proof_log_is_minimal_and_non_verbatim
test_restrictive_defaults
test_version_probe_is_anchored_and_non_verbatim
test_missing_option_values_fail_closed
test_config_values_are_trimmed_and_tilde_expanded
test_request_stdin_keeps_adapter_prompt_out_of_coordinator_argv
test_dash_leading_request_is_passed_safely
test_check_probe
test_allowed_path_enforcement
test_ambiguous_offers_without_loading
test_no_match_stays_quiet
test_notes_are_host_owned
test_privacy_filtered_never_names_wikis
test_unavailable_is_definitive
test_explicit_offer_selection_continuation
test_date_binding_is_host_owned
test_offer_ownership_requires_a_session_lock
test_older_lines_keep_preflight_without_offering_continuation
test_pending_evidence_is_bounded_and_reclaimable
test_malformed_and_failed_disclosure
test_jq_missing_is_disclosed
test_harness_backend_neutrality
