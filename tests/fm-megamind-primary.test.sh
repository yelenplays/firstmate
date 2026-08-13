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
    jq --arg root "$home/estate/Wiki" '.confidence=.9 | .matches=[{"name":"Wiki","root":$root,"access":"full","routing_mode":"full","confidence":{"score":.9},"allows":[".megamind/wiki-card.json","wiki/index.md"],"follow_up":"never","context_budget":{"max_candidates":2,"max_context_chars":1000}}]' "$fixture" > "$fixture.tmp"
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

# The opt-in switch is read with the same first-line semantics as every other
# config/megamind-* file: first non-empty, non-comment line, trimmed, with or
# without a final newline. A switch that silently means off because the value
# carried a space, sat under a comment header, or lacked a trailing newline is
# the one failure mode a switch must not have.
test_optin_switch_uses_sibling_first_line_semantics() {
  local home fixture out value label
  home=$(new_home optin-parse); install_stub "$home"
  fixture=$(make_fixture "$home" no-match)
  # Every shape below states "on" under those semantics and must enable the mode.
  # `run` is reached only when the switch is on, so a no-match decision proves it
  # ran and a bypass decision proves the switch was read as off.
  while IFS='|' read -r label value; do
    [ -n "$label" ] || continue
    printf '%b' "$value" > "$home/config/megamind-primary-automatic"
    out=$(FM_TEST_FIXTURE="$fixture" run_in "$home" process --harness pi \
      --session-id session-aaaaaaaa --submission-id "submission-$label" <<< 'substantive prompt')
    [ "$(printf '%s' "$out" | jq -r .decision)" != bypass ] \
      || fail "the opt-in switch read $label as off: $out"
  done <<'CASES'
padded|  on
comment|# switch\non\n
blank|\non\n
nonewline|on
tabbed|\ton\t\n
CASES
  # And the shapes that genuinely mean off stay off.
  while IFS='|' read -r label value; do
    [ -n "$label" ] || continue
    printf '%b' "$value" > "$home/config/megamind-primary-automatic"
    out=$(FM_TEST_FIXTURE="$fixture" run_in "$home" process --harness pi \
      --session-id session-aaaaaaaa --submission-id "submission-off-$label" <<< 'substantive prompt')
    [ "$(printf '%s' "$out" | jq -r .decision)" = bypass ] \
      || fail "the opt-in switch read $label as on: $out"
  done <<'CASES'
commented|# on\n
off|off\n
empty|\n
CASES
  pass "coordinator: the opt-in switch uses the documented sibling first-line semantics"
}

# Interception is opt-in and off by default, and the hook that reaches this
# coordinator is registered unconditionally. A checkout that never opted in must
# therefore keep its ordinary behavior rather than lose every prompt to a state
# requirement it was never asked to satisfy.
test_optin_gates_precede_the_session_lock() {
  local home outside out
  home=$(new_home lock-order); install_stub "$home"
  rm -f "$home/state/.lock"
  out=$(FM_MEGAMIND_PRIMARY_AUTOMATIC=0 run_in "$home" process --harness claude \
    --session-id session-aaaaaaaa --submission-id submission-hhhhhhhh <<< 'substantive prompt with the guard off')
  [ "$(printf '%s' "$out" | jq -r .decision)" = bypass ] \
    || fail "a home with the guard off lost its prompt to a missing session lock: $out"
  outside="$TMP_ROOT/outside-primary-scope"
  mkdir -p "$outside/bin"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$outside/bin/"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$outside" "$COORDINATOR" process --harness claude \
    --session-id session-aaaaaaaa --submission-id submission-iiiiiiii <<< 'substantive prompt outside the primary scope')
  [ "$(printf '%s' "$out" | jq -r .decision)" = bypass ] \
    || fail "a checkout outside the primary scope blocked instead of staying ordinary: $out"
  # A session that is not a governed primary costs nothing: no store directory,
  # no submission lock, and no durable decision record.
  assert_absent "$home/state/megamind-primary" "a bypassing session still built the coordinator's private store"
  out=$(run_in "$home" process --harness claude \
    --session-id session-aaaaaaaa --submission-id submission-jjjjjjjj <<< 'substantive prompt with the guard on')
  [ "$(printf '%s' "$out" | jq -r .decision)" = block ] \
    || fail "an opted-in session without a live lock did not block: $out"
  [ "$(printf '%s' "$out" | jq -r .failure_code)" = session_unavailable ] \
    || fail "the missing-lock failure code changed: $out"
  pass "coordinator: scope and opt-in are settled before any live-session requirement"
}

# The store the coordinator would write is itself inside the state directory an
# ungoverned checkout never opted into, so a bypass must not need it to succeed.
test_bypass_survives_an_unwritable_state_directory() {
  local home out rc
  home=$(new_home unwritable); install_stub "$home"
  rm -f "$home/state/.lock"
  chmod 500 "$home/state"
  out=$(FM_MEGAMIND_PRIMARY_AUTOMATIC=0 run_in "$home" process --harness claude \
    --session-id session-aaaaaaaa --submission-id submission-kkkkkkkk <<< 'substantive prompt with the guard off'); rc=$?
  chmod 700 "$home/state"
  [ "$rc" -eq 0 ] || fail "an unwritable state directory made the coordinator exit $rc"
  [ "$(printf '%s' "$out" | jq -r .decision)" = bypass ] \
    || fail "an unwritable state directory blocked a prompt the guard never governed: $out"
  pass "coordinator: a bypass needs no directory, no lock, and no durable record"
}

test_no_match_and_privacy_filter() {
  local home fixture out out2
  home=$(new_home no-match); install_stub "$home"; fixture=$(make_fixture "$home" no-match)
  out=$(FM_TEST_FIXTURE="$fixture" run_in "$home" process --harness pi --session-id session-aaaaaaaa --submission-id submission-cccccccc <<< 'synthetic substantive request')
  [ "$(printf '%s' "$out" | jq -r .decision)" = proceed-no-context ] || fail "no-match did not proceed without context: $out"
  [ "$(printf '%s' "$out" | jq -r .context)" = null ] || fail "no-match carried context"
  out2=$(FM_TEST_FIXTURE="$fixture" run_in "$home" process --harness pi --session-id session-aaaaaaaa --submission-id submission-cccccccc <<< 'synthetic substantive request')
  [ "$out2" = "$out" ] || fail "an identical retry did not return the one durable decision"
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

# A cached decision is keyed by submission id on disk, so a submission id
# reused for an unrelated prompt must re-evaluate rather than replay the first
# prompt's decision - including any wiki content it admitted.
test_cached_decision_is_bound_to_the_prompt() {
  local home fixture_matched fixture_nomatch out out2
  home=$(new_home prompt-binding); install_stub "$home"
  fixture_matched=$(make_fixture "$home" matched)
  out=$(FM_TEST_FIXTURE="$fixture_matched" run_in "$home" process --harness pi \
    --session-id session-aaaaaaaa --submission-id submission-llllllll <<< 'first prompt, admitted')
  [ "$(printf '%s' "$out" | jq -r .decision)" = proceed-with-admission ] \
    || fail "the first prompt under the reused submission id was not admitted: $out"
  fixture_nomatch=$(make_fixture "$home" no-match)
  out2=$(FM_TEST_FIXTURE="$fixture_nomatch" run_in "$home" process --harness pi \
    --session-id session-aaaaaaaa --submission-id submission-llllllll <<< 'second, unrelated prompt')
  [ "$(printf '%s' "$out2" | jq -r .decision)" = proceed-with-admission ] \
    && fail "a reused submission id served the first prompt's admitted decision to a different prompt: $out2"
  [ "$(printf '%s' "$out2" | jq -r .decision)" = proceed-no-context ] \
    || fail "the re-evaluated decision for the second prompt was not proceed-no-context: $out2"
  assert_not_contains "$out2" 'megamind-bounded-reader' \
    'a different prompt under a reused submission id still carried the first admitted wiki context'
  pass "coordinator: a cached decision under a reused submission id is bound to the exact prompt"
}

# The other half of the same contract: an identical retry - same submission id,
# same prompt - must still return the one durable cached decision.
test_cached_decision_reused_for_an_identical_retry() {
  local home fixture out out2
  home=$(new_home prompt-retry); install_stub "$home"
  fixture=$(make_fixture "$home" no-match)
  out=$(FM_TEST_FIXTURE="$fixture" run_in "$home" process --harness pi \
    --session-id session-aaaaaaaa --submission-id submission-mmmmmmmm <<< 'identical retry text')
  out2=$(FM_TEST_FIXTURE="$fixture" run_in "$home" process --harness pi \
    --session-id session-aaaaaaaa --submission-id submission-mmmmmmmm <<< 'identical retry text')
  [ "$out2" = "$out" ] || fail "an identical retry under the same submission id did not return the cached decision: $out vs $out2"
  pass "coordinator: an identical retry under the same submission id returns the cached decision"
}

# "A home with the guard off must cost nothing... and must never lose a
# prompt" cannot itself depend on jq: a direct coordinator call on an
# opted-out home must still bypass when jq is absent, never decision()'s own
# jq-less "block jq_missing" fallback.
test_process_bypasses_without_jq_on_an_opted_out_home() {
  local home nojq out tool
  home=$(new_home nojq-optout); install_stub "$home"
  rm -f "$home/config/megamind-primary-automatic"
  nojq="$TMP_ROOT/nojq-primary"
  mkdir -p "$nojq"
  for tool in bash dirname cat; do
    ln -sf "$(command -v "$tool")" "$nojq/$tool"
  done
  [ ! -e "$nojq/jq" ] || fail "jq-missing fixture PATH must not contain jq"
  out=$(PATH="$nojq" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_PRIMARY_SCOPE_OVERRIDE=1 \
    bash "$COORDINATOR" process --harness claude --session-id session-aaaaaaaa \
    --submission-id submission-nnnnnnnn <<< 'substantive prompt with no jq on an opted-out home')
  [ "$(printf '%s' "$out" | jq -r .decision)" = bypass ] \
    || fail "an opted-out home without jq did not bypass: $out"
  [ "$(printf '%s' "$out" | jq -r .failure_code)" = null ] \
    || fail "an opted-out home without jq reported a failure code: $out"
  pass "coordinator: an opted-out home bypasses without jq, never a jq_missing block"
}

test_classification_and_disabled_mode
test_optin_switch_uses_sibling_first_line_semantics
test_optin_gates_precede_the_session_lock
test_bypass_survives_an_unwritable_state_directory
test_no_match_and_privacy_filter
test_matched_reader_context_and_privacy
test_failures_and_unsupported
test_cached_decision_is_bound_to_the_prompt
test_cached_decision_reused_for_an_identical_retry
test_process_bypasses_without_jq_on_an_opted_out_home
