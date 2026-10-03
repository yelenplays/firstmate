#!/usr/bin/env bash
# Behavioral tests for bin/fm-ai-family-lib.sh: which AI family (model maker)
# a harness and model resolve to, read from the harness catalog and never from
# a name.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-ai-family-lib.sh
. "$ROOT/bin/fm-ai-family-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ai-family-lib-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CATALOG="$TMP_ROOT/pi-models.txt"
cat > "$CATALOG" <<'EOF'
provider      model                 context  max-out  thinking  images
openai-codex  gpt-6-luna            400K     128K     yes       yes
opencode-go   gpt-6-luna            400K     128K     yes       yes
openai-codex  gpt-6-astra           400K     128K     yes       yes
xai           grok-5                256K     64K      yes       yes
openrouter    anthropic/claude-x    200K     64K      yes       yes
kimi-coding   kimi-k3               256K     32K      yes       no
EOF

resolve() {  # <harness> [<model>] -> "<family>"
  fm_ai_family_resolve "$@"
  printf '%s\n' "$FM_AI_FAMILY"
}

test_harness_names_do_not_prove_family() {
  local h
  for h in claude codex grok kimi gemini muse; do
    assert_equals unknown "$(resolve "$h")" "harness '$h' alone cannot prove its model family"
    assert_equals unknown "$(resolve "$h" claude-opus-5-5)" "a model name cannot prove the family for harness '$h'"
  done
  pass "a harness or model name alone never proves the AI family"
}

test_multi_maker_harnesses_are_unknown() {
  local h
  for h in cursor devin rovo agy something-new ''; do
    assert_equals unknown "$(resolve "$h" claude-opus-5-5)" "harness '$h' must not be named from its model"
  done
  # A model id that names a maker is still not proof on a gateway.
  assert_equals unknown "$(resolve cursor gpt-6-luna)" "cursor with an OpenAI-looking id"
  pass "harnesses that serve several makers resolve to unknown whatever the model is called"
}

test_provider_qualified_models() {
  assert_equals openai "$(FM_AI_FAMILY_PI_CATALOG=$CATALOG resolve pi openai-codex/gpt-6-luna)" "pi catalog row openai-codex"
  assert_equals unknown "$(FM_AI_FAMILY_PI_CATALOG=$CATALOG resolve pi codex-native/gpt-6-astra)" "a provider not listing this model is refused"
  assert_equals openai "$(FM_AI_FAMILY_PI_CATALOG=$CATALOG resolve pi-signed openai-codex/gpt-6-luna)" "pi-signed catalog row openai-codex"
  assert_equals unknown "$(FM_AI_FAMILY_PI_CATALOG=$CATALOG resolve opencode anthropic/claude-opus-5-5)" "opencode has no catalog evidence"
  assert_equals unknown "$(FM_AI_FAMILY_PI_CATALOG=$CATALOG resolve omp xai/grok-5)" "omp has no catalog evidence"
  assert_equals moonshot "$(FM_AI_FAMILY_PI_CATALOG=$CATALOG resolve pi kimi-coding/kimi-k3)" "the exact kimi-coding catalog row proves Moonshot"
  assert_equals unknown "$(resolve pi openrouter/anthropic/claude-x)" "openrouter is a gateway"
  assert_equals unknown "$(resolve pi opencode-go/gpt-6-luna)" "opencode-go is a gateway"
  FM_AI_FAMILY_PI_CATALOG=$CATALOG fm_ai_family_resolve pi openai-codex/gpt-6-luna
  assert_contains "$FM_AI_FAMILY_SOURCE" "provider openai-codex lists model gpt-6-luna" "source names the matching catalog row"
  pass "a provider-qualified model resolves through its catalog provider key"
}

test_unqualified_models_read_the_catalog() {
  assert_equals openai "$(FM_AI_FAMILY_PI_CATALOG=$CATALOG resolve pi gpt-6-astra)" "one provider row"
  assert_equals xai "$(FM_AI_FAMILY_PI_CATALOG=$CATALOG resolve pi grok-5)" "one xai row"
  assert_equals unknown "$(FM_AI_FAMILY_PI_CATALOG=$CATALOG resolve pi gpt-6-luna)" "listed under two providers"
  assert_equals unknown "$(FM_AI_FAMILY_PI_CATALOG=$CATALOG resolve pi not-listed)" "not listed"
  assert_equals unknown "$(resolve pi)" "pi with no model"
  assert_equals unknown "$(resolve pi default)" "pi with the default model"
  FM_AI_FAMILY_PI_CATALOG=$CATALOG fm_ai_family_resolve pi gpt-6-luna
  assert_contains "$FM_AI_FAMILY_SOURCE" "does not list model gpt-6-luna under exactly one matching provider" "ambiguity is explained"
  pass "an unqualified pi model resolves only when exactly one catalog provider lists it"
}

test_live_catalog_is_the_cli() {
  cat > "$FAKEBIN/pi" <<SH
#!/usr/bin/env bash
[ "\$*" = "--list-models" ] || exit 9
cat '$CATALOG'
SH
  chmod +x "$FAKEBIN/pi"
  assert_equals openai "$(PATH="$FAKEBIN:$PATH" FM_AI_FAMILY_PI_CATALOG='' resolve pi gpt-6-astra)" "live listing"
  assert_equals unknown "$(PATH="$FAKEBIN:$PATH" FM_AI_FAMILY_PI_CATALOG='' resolve pi gpt-6-luna)" "live ambiguous listing"
  pass "without a captured listing the pi catalog is read from pi --list-models"
}

test_union_and_disjoint() {
  assert_equals "anthropic,openai" "$(fm_ai_family_union openai anthropic,openai)" "union is sorted and deduped"
  assert_equals "anthropic" "$(fm_ai_family_union anthropic '')" "empty sets are ignored"
  fm_ai_family_disjoint anthropic openai || fail "anthropic and openai are disjoint"
  fm_ai_family_disjoint anthropic,xai openai || fail "a known set without overlap is disjoint"
  ! fm_ai_family_disjoint anthropic,openai openai || fail "an overlapping set is not disjoint"
  ! fm_ai_family_disjoint anthropic unknown || fail "unknown never proves a different family"
  ! fm_ai_family_disjoint unknown,openai anthropic || fail "a set containing unknown is not provably disjoint"
  ! fm_ai_family_disjoint '' openai || fail "an empty set is not provably disjoint"
  pass "family sets are disjoint only when both are fully known and share no maker"
}

test_harness_names_do_not_prove_family
test_multi_maker_harnesses_are_unknown
test_provider_qualified_models
test_unqualified_models_read_the_catalog
test_live_catalog_is_the_cli
test_union_and_disjoint
