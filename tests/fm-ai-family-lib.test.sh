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

test_single_maker_harnesses() {
  assert_equals anthropic "$(resolve claude claude-opus-5-5)" "claude"
  assert_equals anthropic "$(resolve claude)" "claude without a model"
  assert_equals openai "$(resolve codex gpt-5)" "codex"
  assert_equals xai "$(resolve grok)" "grok"
  assert_equals moonshot "$(resolve kimi)" "kimi"
  assert_equals google "$(resolve gemini)" "gemini"
  assert_equals meta "$(resolve muse)" "muse"
  pass "single-maker harness catalogs name their maker"
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
  assert_equals openai "$(resolve pi openai-codex/gpt-6-luna)" "pi openai-codex"
  assert_equals openai "$(resolve pi codex-native/gpt-6-astra)" "pi codex-native"
  assert_equals openai "$(resolve pi-signed openai-codex/gpt-6-luna)" "pi-signed openai-codex"
  assert_equals anthropic "$(resolve opencode anthropic/claude-opus-5-5)" "opencode anthropic"
  assert_equals xai "$(resolve omp xai/grok-5)" "omp xai"
  assert_equals moonshot "$(resolve pi kimi-coding/kimi-k3)" "pi kimi-coding"
  assert_equals unknown "$(resolve pi openrouter/anthropic/claude-x)" "openrouter is a gateway"
  assert_equals unknown "$(resolve pi opencode-go/gpt-6-luna)" "opencode-go is a gateway"
  fm_ai_family_resolve pi openai-codex/gpt-6-luna
  assert_contains "$FM_AI_FAMILY_SOURCE" "provider openai-codex serves model gpt-6-luna" "source names the catalog provider"
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
  assert_contains "$FM_AI_FAMILY_SOURCE" "does not list model gpt-6-luna under exactly one provider" "ambiguity is explained"
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

test_single_maker_harnesses
test_multi_maker_harnesses_are_unknown
test_provider_qualified_models
test_unqualified_models_read_the_catalog
test_live_catalog_is_the_cli
test_union_and_disjoint
