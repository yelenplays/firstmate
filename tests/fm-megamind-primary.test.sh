#!/usr/bin/env bash
# Portable tests for the host-owned primary Megamind coordinator.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
COORDINATOR="$ROOT/bin/fm-megamind-primary.sh"
TMP_ROOT=$(fm_test_tmproot fm-megamind-primary)

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/estate/Wiki/.megamind" "$home/estate/Wiki/wiki"
  printf 'card\n' > "$home/estate/Wiki/.megamind/wiki-card.json"
  printf 'safe synthetic context\n' > "$home/estate/Wiki/wiki/index.md"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf 'on\n' > "$home/config/megamind-primary-automatic"
  printf '%s\n' "$home"
}

install_stub() {
  local home=$1
  cat > "$home/megamind" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  printf 'megamind-axi 0.6.0\n'
  exit 0
fi
if [ -n "${FM_TEST_FIXTURE:-}" ]; then cat "$FM_TEST_FIXTURE"; else exit 2; fi
SH
  chmod 700 "$home/megamind"
  printf '%s\n' "$home/megamind" > "$home/config/megamind-executable"
  printf '%s\n' "$home/estate" > "$home/config/megamind-estate"
}

run_in() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_PRIMARY_SCOPE_OVERRIDE=1 "$COORDINATOR" "$@"
}

make_fixture() {
  local home=$1 status fixture
  status=$2
  fixture="$TMP_ROOT/$status-$$.json"
  cat > "$fixture" <<JSON
{"schema_version":"megamind/preflight-result/v2","request_hash":"request-hash","model_class":"cloud","status":"$status","confidence":null,"preflight_id":"preflight-$status","catalog_hash":"catalog-hash","thresholds":{"reliance_floor":0.75,"offer_floor":0.25,"ambiguity_band":0.05},"matches":[],"offers":[],"filtered":[]}
JSON
  if [ "$status" = matched ]; then
    jq --arg root "$home/estate/Wiki" '.confidence=.9 | .matches=[{"name":"Wiki","root":$root,"access":"full","routing_mode":"bounded","confidence":{"score":.9},"allows":[".megamind/wiki-card.json","wiki/index.md"],"follow_up":"never","context_budget":{"max_candidates":2,"max_context_chars":1000}}]' "$fixture" > "$fixture.tmp"
    mv "$fixture.tmp" "$fixture"
  fi
  printf '%s\n' "$fixture"
}

test_classification_and_disabled_mode() {
  local home out
  home=$(new_home classify); install_stub "$home"
  out=$(run_in "$home" process --harness pi --session-id session-aaaaaaaa --submission-id submission-aaaaaaaa <<< 'ok')
  [ "$(printf '%s' "$out" | jq -r .decision)" = bypass ] || fail "ack was not bypassed"
  out=$(FM_MEGAMIND_PRIMARY_AUTOMATIC=0 run_in "$home" process --harness pi --session-id session-aaaaaaaa --submission-id submission-bbbbbbbb <<< 'substantive prompt')
  [ "$(printf '%s' "$out" | jq -r .decision)" = bypass ] || fail "disabled adapter did not preserve ordinary operation"
  pass "coordinator: classification and opt-in preserve bypass traffic"
}

test_no_match_and_privacy_filter() {
  local home fixture out out2
  home=$(new_home no-match); install_stub "$home"; fixture=$(make_fixture "$home" no-match)
  out=$(FM_TEST_FIXTURE="$fixture" run_in "$home" process --harness pi --session-id session-aaaaaaaa --submission-id submission-cccccccc <<< 'synthetic substantive request')
  [ "$(printf '%s' "$out" | jq -r .decision)" = proceed-no-context ] || fail "no-match did not proceed without context: $out"
  [ "$(printf '%s' "$out" | jq -r .context)" = null ] || fail "no-match carried context"
  out2=$(FM_TEST_FIXTURE="$fixture" run_in "$home" process --harness pi --session-id session-aaaaaaaa --submission-id submission-cccccccc <<< 'different retry text')
  [ "$out2" = "$out" ] || fail "retry did not return the one durable decision"
  fixture=$(make_fixture "$home" privacy-filtered)
  out=$(FM_TEST_FIXTURE="$fixture" run_in "$home" process --harness pi --session-id session-aaaaaaaa --submission-id submission-dddddddd <<< 'another substantive request')
  [ "$(printf '%s' "$out" | jq -r .decision)" = proceed-no-context ] || fail "privacy-filtered did not stay context-free"
  assert_not_contains "$out" 'Wiki' 'privacy-filtered coordinator output named a wiki'
  pass "coordinator: no-match and privacy-filtered outcomes remain quiet"
}

test_matched_reader_context_and_privacy() {
  local home fixture out
  home=$(new_home matched); install_stub "$home"; fixture=$(make_fixture "$home" matched)
  out=$(FM_TEST_FIXTURE="$fixture" run_in "$home" process --harness pi --session-id session-aaaaaaaa --submission-id submission-eeeeeeee <<< 'request contains PROMPT-SECRET-CANARY')
  [ "$(printf '%s' "$out" | jq -r .decision)" = proceed-with-admission ] || fail "matched request was not admitted: $out"
  [ "$(printf '%s' "$out" | jq -r .context.provenance)" = megamind-bounded-reader ] || fail "context provenance missing"
  [ "$(printf '%s' "$out" | jq -r .context.admitted_chars)" -gt 0 ] || fail "admitted character count missing"
  assert_not_contains "$out" PROMPT-SECRET-CANARY 'prompt entered decision output'
  assert_not_contains "$out" "$home/estate" 'absolute root entered decision output'
  [ "$(find "$home/state" -name '*.megamind-preflight.json' | wc -l | tr -d ' ')" = 1 ] || fail "matched authorization was not private and durable"
  pass "coordinator: matched content comes only from the bounded reader with provenance"
}

test_failures_and_unsupported() {
  local home out
  home=$(new_home failed); install_stub "$home"; rm -f "$home/config/megamind-estate"
  out=$(run_in "$home" process --harness pi --session-id session-aaaaaaaa --submission-id submission-ffffffff <<< 'substantive failure request')
  [ "$(printf '%s' "$out" | jq -r .decision)" = block ] || fail "missing binding did not block"
  [ "$(printf '%s' "$out" | jq -r .failure_code)" = not_configured ] || fail "missing binding code changed: $out"
  out=$(run_in "$home" process --harness codex --session-id session-aaaaaaaa --submission-id submission-gggggggg <<< 'substantive unsupported request')
  [ "$(printf '%s' "$out" | jq -r .decision)" = block ] || fail "unsupported harness did not block when automatic mode was requested"
  out=$(FM_MEGAMIND_PRIMARY_AUTOMATIC=1 "$COORDINATOR" check --harness opencode)
  [ "$(printf '%s' "$out" | jq -r .automatic)" = unsupported ] || fail "OpenCode unsupported check missing"
  pass "coordinator: failed bindings block and unsupported harnesses are deterministic"
}

test_classification_and_disabled_mode
test_no_match_and_privacy_filter
test_matched_reader_context_and_privacy
test_failures_and_unsupported
