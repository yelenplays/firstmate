#!/usr/bin/env bash
# Portable behavior tests for the host-owned bounded Megamind content reader.
# Every wiki in this suite is synthetic and lives below a disposable test home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

READER="$ROOT/bin/fm-megamind-content.sh"
PREFLIGHT="$ROOT/bin/fm-megamind-preflight.sh"
TMP_ROOT=$(fm_test_tmproot fm-megamind-content)

new_home() {
  local name=$1 home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data/task" "$home/estate/SyntheticWiki/.megamind" "$home/estate/SyntheticWiki/wiki"
  cat > "$home/bin-megamind" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "megamind-axi ${FM_TEST_VERSION:-0.6.0}"
  exit 0
fi
if [ "${1:-}" = select-offer ]; then
  cat "${FM_TEST_SELECTION_FIXTURE:?}"
else
  cat "${FM_TEST_FIXTURE:?}"
fi
SH
  chmod 700 "$home/bin-megamind"
  printf '%s\n' "$home/bin-megamind" > "$home/config/megamind-executable"
  printf '%s\n' "$home/estate" > "$home/config/megamind-estate"
  printf '%s\n' cloud > "$home/config/megamind-model-class"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf 'synthetic card\n' > "$home/estate/SyntheticWiki/.megamind/wiki-card.json"
  printf 'safe\n' > "$home/estate/SyntheticWiki/wiki/index.md"
  printf 'routing\n' > "$home/data/task/megamind-request.md"
  printf '%s\n' "$home"
}

prepare_auth() {
  local home=$1 allows=$2 max_candidates=$3 max_chars=$4 fixture="$TMP_ROOT/fixture-${RANDOM}-${RANDOM}.json"
  cat > "$fixture" <<JSON
{"schema_version":"megamind/preflight-result/v2","request_hash":"request-hash","model_class":"cloud","status":"matched","confidence":0.9,"preflight_id":"preflight-${RANDOM}","catalog_hash":"catalog-hash","thresholds":{"reliance_floor":0.75,"offer_floor":0.25,"ambiguity_band":0.05},"matches":[{"name":"SyntheticWiki","root":"$home/estate/SyntheticWiki","access":"full","routing_mode":"bounded","confidence":{"score":0.9},"allows":$allows,"follow_up":"This is informational and must never execute","context_budget":{"max_candidates":$max_candidates,"max_context_chars":$max_chars}}],"offers":[],"filtered":[],"redacted_count":0}
JSON
  FM_TEST_FIXTURE="$fixture" FM_HOME="$home" "$PREFLIGHT" run --request routing > "$home/state/task.megamind-preflight.json"
  chmod 600 "$home/state/task.megamind-preflight.json"
  rm -f "$fixture"
}

admit() {
  local home=$1
  FM_HOME="$home" "$READER" admit --task-id task
}

assert_refusal() {
  local out=$1 code=$2 label=$3
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = refused ] || fail "$label was admitted: $out"
  [ "$(printf '%s' "$out" | jq -r '.refusal_code')" = "$code" ] || fail "$label refusal was $(printf '%s' "$out" | jq -r '.refusal_code'), expected $code"
}

test_bounded_admission_and_unicode_counting() {
  local home out id content
  home=$(new_home bounded)
  printf 'e\u0301\n' > "$home/estate/SyntheticWiki/wiki/unicode.md"
  prepare_auth "$home" '[".megamind/wiki-card.json","wiki/unicode.md","wiki/unicode.md"]' 2 18
  out=$(admit "$home")
  [ "$(printf '%s' "$out" | jq -r '.outcome')" = admitted ] || fail "bounded admission refused: $out"
  [ "$(printf '%s' "$out" | jq -r '.wikis[0].candidate_count')" = 2 ] || fail "repeated relative allow was not deduplicated"
  [ "$(printf '%s' "$out" | jq -r '.wikis[0].context_chars')" = 18 ] || fail "newline/combining character count was not exact"
  id=$(printf '%s' "$out" | jq -r '.admission_id')
  content=$(FM_HOME="$home" "$READER" content --admission-id "$id") || fail "content channel refused a fresh admission"
  [ "$(printf '%s' "$content" | grep -F -c 'é')" = 1 ] || fail "content channel lost combining Unicode"
  assert_not_contains "$out" 'informational' 'admission result leaked follow_up prose'
  assert_not_contains "$out" 'synthetic card' 'admission result leaked page content'
  assert_not_contains "$out" "$home/estate" 'admission result leaked an absolute root'
  pass "bounded admission counts Unicode code points and deduplicates repeated allows"
}

test_budget_refusals() {
  local home out fixture
  home=$(new_home budgets)
  printf '12345678901' > "$home/estate/SyntheticWiki/wiki/index.md"
  prepare_auth "$home" '[".megamind/wiki-card.json","wiki/index.md"]' 2 10
  out=$(admit "$home"); assert_refusal "$out" context_budget_exceeded 'over-budget content'
  for fixture in missing zero malformed; do
    case "$fixture" in
      missing) jq 'del(.matches[0].context_budget)' "$home/state/task.megamind-preflight.json" > "$home/state/tmp.json" ;;
      zero) jq '.matches[0].context_budget.max_context_chars = 0' "$home/state/task.megamind-preflight.json" > "$home/state/tmp.json" ;;
      malformed) jq '.matches[0].context_budget.max_candidates = "10"' "$home/state/task.megamind-preflight.json" > "$home/state/tmp.json" ;;
    esac
    chmod 600 "$home/state/tmp.json"; mv -f "$home/state/tmp.json" "$home/state/task.megamind-preflight.json"
    out=$(admit "$home"); assert_refusal "$out" authorization_invalid "$fixture budget"
    prepare_auth "$home" '[".megamind/wiki-card.json","wiki/index.md"]' 2 10
  done
  pass "missing, zero, malformed, and overrun budgets never become unlimited"
}

test_symlinks_and_traversal_refuse() {
  local home out outside
  outside="$TMP_ROOT/outside"; mkdir -p "$outside/wiki"; printf 'outside\n' > "$outside/secret.md"
  home=$(new_home final-symlink); prepare_auth "$home" '[".megamind/wiki-card.json","wiki/secret.md"]' 2 100
  ln -s "$outside/secret.md" "$home/estate/SyntheticWiki/wiki/secret.md"
  out=$(admit "$home"); assert_refusal "$out" path_unavailable 'final symlink'
  home=$(new_home intermediate-symlink); prepare_auth "$home" '[".megamind/wiki-card.json","wiki/index.md"]' 2 100
  rm -rf "$home/estate/SyntheticWiki/wiki"; ln -s "$outside/wiki" "$home/estate/SyntheticWiki/wiki"
  out=$(admit "$home"); assert_refusal "$out" path_unavailable 'intermediate symlink'
  home=$(new_home root-symlink); prepare_auth "$home" '[".megamind/wiki-card.json","wiki/index.md"]' 2 100
  mv "$home/estate/SyntheticWiki" "$home/estate/realwiki"; ln -s "$home/estate/realwiki" "$home/estate/SyntheticWiki"
  out=$(admit "$home"); assert_refusal "$out" path_unavailable 'root symlink'
  home=$(new_home traversal); prepare_auth "$home" '[".megamind/wiki-card.json","wiki/index.md"]' 2 100
  jq '.matches[0].allows += ["../escape.md"]' "$home/state/task.megamind-preflight.json" > "$home/state/tmp.json"; chmod 600 "$home/state/tmp.json"; mv "$home/state/tmp.json" "$home/state/task.megamind-preflight.json"
  out=$(admit "$home"); assert_refusal "$out" authorization_invalid 'path traversal'
  jq '.matches[0].allows = [".megamind/wiki-card.json","/etc/passwd"]' "$home/state/task.megamind-preflight.json" > "$home/state/tmp.json"; chmod 600 "$home/state/tmp.json"; mv "$home/state/tmp.json" "$home/state/task.megamind-preflight.json"
  out=$(admit "$home"); assert_refusal "$out" authorization_invalid 'absolute path'
  pass "root, intermediate, final symlinks, traversal, and absolute paths refuse"
}

test_special_hardlink_and_invalid_utf8_refuse() {
  local home out
  home=$(new_home special); mkfifo "$home/estate/SyntheticWiki/wiki/pipe"
  prepare_auth "$home" '[".megamind/wiki-card.json","wiki/pipe"]' 2 100
  out=$(admit "$home"); assert_refusal "$out" path_unavailable 'FIFO'
  home=$(new_home hardlink); ln "$home/estate/SyntheticWiki/wiki/index.md" "$home/estate/SyntheticWiki/wiki/alias.md"
  prepare_auth "$home" '[".megamind/wiki-card.json","wiki/index.md","wiki/alias.md"]' 3 100
  out=$(admit "$home"); assert_refusal "$out" path_unavailable 'hardlink duplicate'
  home=$(new_home utf8); printf '\377\376\n' > "$home/estate/SyntheticWiki/wiki/index.md"
  prepare_auth "$home" '[".megamind/wiki-card.json","wiki/index.md"]' 2 100
  out=$(admit "$home"); assert_refusal "$out" invalid_utf8 'invalid UTF-8'
  home=$(new_home permissions); prepare_auth "$home" '[".megamind/wiki-card.json","wiki/index.md"]' 2 100; chmod 644 "$home/state/task.megamind-preflight.json"
  out=$(admit "$home"); assert_refusal "$out" authorization_unavailable 'non-private authorization'
  pass "special files, hardlinks, invalid UTF-8, and permissions refuse without blocking"
}

test_changed_binding_and_race_revalidation() {
  local home out id
  home=$(new_home changed); prepare_auth "$home" '[".megamind/wiki-card.json","wiki/index.md"]' 2 100
  out=$(admit "$home"); id=$(printf '%s' "$out" | jq -r .admission_id)
  printf 'changed card\n' > "$home/estate/SyntheticWiki/.megamind/wiki-card.json"
  out=$(FM_HOME="$home" "$READER" content --admission-id "$id"); assert_refusal "$out" card_changed 'changed card'
  home=$(new_home root-swap); prepare_auth "$home" '[".megamind/wiki-card.json","wiki/index.md"]' 2 100
  out=$(admit "$home"); id=$(printf '%s' "$out" | jq -r .admission_id)
  mv "$home/estate/SyntheticWiki" "$home/estate/SyntheticWiki-old"; mkdir -p "$home/estate/SyntheticWiki/.megamind"; cp "$home/estate/SyntheticWiki-old/.megamind/wiki-card.json" "$home/estate/SyntheticWiki/.megamind/wiki-card.json"; printf 'new\n' > "$home/estate/SyntheticWiki/wiki-not-there"
  out=$(FM_HOME="$home" "$READER" content --admission-id "$id"); assert_refusal "$out" root_changed 'root swap'
  home=$(new_home version); prepare_auth "$home" '[".megamind/wiki-card.json","wiki/index.md"]' 2 100
  out=$(admit "$home"); id=$(printf '%s' "$out" | jq -r .admission_id); printf '%s\n' '0.6.1' > "$home/config/megamind-model-class"
  out=$(FM_HOME="$home" "$READER" content --admission-id "$id"); assert_refusal "$out" binding_changed 'model-class change'
  home=$(new_home executable-change); prepare_auth "$home" '[".megamind/wiki-card.json","wiki/index.md"]' 2 100
  out=$(admit "$home"); id=$(printf '%s' "$out" | jq -r .admission_id); printf '# changed executable\n' >> "$home/bin-megamind"
  out=$(FM_HOME="$home" "$READER" content --admission-id "$id"); assert_refusal "$out" binding_changed 'executable change'
  home=$(new_home catalog-change); prepare_auth "$home" '[".megamind/wiki-card.json","wiki/index.md"]' 2 100
  out=$(admit "$home"); id=$(printf '%s' "$out" | jq -r .admission_id); jq '.catalog_hash = "changed"' "$home/state/task.megamind-preflight.json" > "$home/state/tmp.json"; chmod 600 "$home/state/tmp.json"; mv "$home/state/tmp.json" "$home/state/task.megamind-preflight.json"
  out=$(FM_HOME="$home" "$READER" content --admission-id "$id"); assert_refusal "$out" binding_changed 'catalog change'
  pass "changed card, root, executable, model, and catalog bindings refuse on the second validation"
}

test_concurrent_and_home_isolation() {
  local home other out id i pids=()
  home=$(new_home concurrent); prepare_auth "$home" '[".megamind/wiki-card.json","wiki/index.md"]' 2 100
  for i in 1 2 3 4 5; do (admit "$home" > "$TMP_ROOT/concurrent-$i.out") & pids+=("$!"); done
  for i in "${pids[@]}"; do wait "$i" || fail "concurrent admission failed"; done
  id=$(jq -r .admission_id "$TMP_ROOT/concurrent-1.out")
  [ -n "$id" ] && [ "$id" != null ] || fail "concurrent admission did not publish an id"
  for i in 1 2 3 4 5; do [ "$(jq -r .admission_id "$TMP_ROOT/concurrent-$i.out")" = "$id" ] || fail "concurrent admission diverged"; done
  other=$(new_home isolated); out=$(FM_HOME="$other" "$READER" content --admission-id "$id"); assert_refusal "$out" admission_unavailable 'foreign home admission'
  pass "concurrent admissions serialize and home isolation is preserved"
}

test_toctou_race_never_emits_outside_content() {
  local home out id content race_pid outside="$TMP_ROOT/toctou-outside" i
  home=$(new_home toctou); mkdir -p "$outside"; printf 'OUTSIDE-CONTENT\n' > "$outside/secret.md"
  prepare_auth "$home" '[".megamind/wiki-card.json","wiki/index.md"]' 2 100
  (
    while :; do
      mv "$home/estate/SyntheticWiki/wiki/index.md" "$home/estate/SyntheticWiki/wiki/index.tmp" 2>/dev/null || true
      ln -sf "$outside/secret.md" "$home/estate/SyntheticWiki/wiki/index.md" 2>/dev/null || true
      rm -f "$home/estate/SyntheticWiki/wiki/index.md" 2>/dev/null || true
      mv "$home/estate/SyntheticWiki/wiki/index.tmp" "$home/estate/SyntheticWiki/wiki/index.md" 2>/dev/null || true
    done
  ) &
  race_pid=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do
    out=$(admit "$home") || true
    if [ "$(printf '%s' "$out" | jq -r '.outcome // empty' 2>/dev/null)" = admitted ]; then
      id=$(printf '%s' "$out" | jq -r .admission_id)
      content=$(FM_HOME="$home" "$READER" content --admission-id "$id" 2>/dev/null || true)
      assert_not_contains "$content" 'OUTSIDE-CONTENT' 'TOCTOU race leaked outside content'
    fi
  done
  kill "$race_pid" 2>/dev/null || true; wait "$race_pid" 2>/dev/null || true
  pass "TOCTOU replacement races never emit outside-root content"
}

test_relaunch_preserves_admission() {
  local home out id before after
  home=$(new_home relaunch); prepare_auth "$home" '[".megamind/wiki-card.json","wiki/index.md"]' 2 100
  out=$(admit "$home"); id=$(printf '%s' "$out" | jq -r .admission_id); before=$(FM_HOME="$home" "$READER" content --admission-id "$id")
  [ -f "$home/state/megamind-admissions/$id.json" ] || fail "admission was not durable"
  after=$(FM_HOME="$home" "$READER" content --admission-id "$id")
  [ "$before" = "$after" ] || fail "relaunch-preserved admission changed content"
  pass "durable admission survives a relaunch-style second invocation"
}

test_real_synthetic_selection_authorization() {
  local home out selection_id fixture selection auth id
  home=$(new_home selection)
  mkdir -p "$home/estate/OfferWiki/.megamind" "$home/estate/OfferWiki/wiki"
  printf 'offer card\n' > "$home/estate/OfferWiki/.megamind/wiki-card.json"
  printf 'offer content\n' > "$home/estate/OfferWiki/wiki/index.md"
  fixture="$TMP_ROOT/ambiguous-selection.json"
  cat > "$fixture" <<JSON
{"schema_version":"megamind/preflight-result/v2","request":"private request","request_hash":"selection-request","model_class":"cloud","status":"ambiguous","confidence":0.4,"preflight_id":"selection-preflight","catalog_hash":"selection-catalog","thresholds":{"reliance_floor":0.75,"offer_floor":0.25,"ambiguity_band":0.05},"matches":[],"offers":[{"name":"OfferWiki","root":"$home/estate/OfferWiki","score":4,"confidence":{"score":0.4}}],"filtered":[],"redacted_count":0}
JSON
  out=$(FM_TEST_FIXTURE="$fixture" FM_HOME="$home" "$PREFLIGHT" run --request 'private request'); selection_id=$(printf '%s' "$out" | jq -r .selection_id)
  [ "$selection_id" != null ] && [ -n "$selection_id" ] || fail "synthetic ambiguous preflight did not issue selection id"
  fixture="$TMP_ROOT/authorized-selection.json"
  cat > "$fixture" <<JSON
{"schema_version":"megamind/preflight-selection-result/v1","status":"authorized","preflight_id":"selection-preflight","request_hash":"selection-request","catalog_hash":"selection-catalog","model_class":"cloud","selection_id":"upstream-selection","root_facts_hash":"synthetic-root-facts","selection":{"status":"explicit-user-selection","basis":"selected-current-offer","source_disposition":"offer","source_status":"ambiguous","preflight_id":"selection-preflight","confidence_changed":false},"selected":{"name":"OfferWiki","root":"$home/estate/OfferWiki","score":4,"confidence":{"score":0.4,"meets_floor":false},"freshness":null,"evidence":{},"provisional":false,"access":"full","routing_mode":"bounded","allows":[".megamind/wiki-card.json","wiki/index.md"],"follow_up":"must never execute","context_budget":{"max_candidates":2,"max_context_chars":100}},"help":["private"]}
JSON
  out=$(FM_TEST_SELECTION_FIXTURE="$fixture" FM_HOME="$home" "$PREFLIGHT" continue --selection-id "$selection_id" --offer OfferWiki); [ "$(printf '%s' "$out" | jq -r .outcome)" = authorized ] || fail "synthetic selection was not authorized: $out"
  out=$(FM_HOME="$home" "$READER" admit --selection-id "$selection_id"); [ "$(printf '%s' "$out" | jq -r .outcome)" = admitted ] || fail "selection admission refused: $out"
  id=$(printf '%s' "$out" | jq -r .admission_id); auth="$home/state/megamind-offer-selections/$selection_id.authorization.json"
  jq '.authorization_binding.today = "2000-01-01"' "$auth" > "$home/state/tmp.json"; chmod 600 "$home/state/tmp.json"; mv "$home/state/tmp.json" "$auth"
  out=$(FM_HOME="$home" "$READER" content --admission-id "$id"); assert_refusal "$out" binding_changed 'expired selection'
  pass "a real synthetic Megamind 0.6 selection authorizes only once and expires on binding change"
}

test_bounded_admission_and_unicode_counting
test_budget_refusals
test_symlinks_and_traversal_refuse
test_special_hardlink_and_invalid_utf8_refuse
test_changed_binding_and_race_revalidation
test_concurrent_and_home_isolation
test_toctou_race_never_emits_outside_content
test_relaunch_preserves_admission
test_real_synthetic_selection_authorization
