#!/usr/bin/env bash
# Public-interface regressions for Megamind's governed existing-wiki picker path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-megamind-existing-selection)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/estate/OfferedWiki" "$HOME_DIR/estate/EligibleWiki/.megamind" "$HOME_DIR/estate/EligibleWiki/wiki"
printf '%s\n' 'synthetic card' > "$HOME_DIR/estate/EligibleWiki/.megamind/wiki-card.json"
printf '%s\n' 'synthetic content' > "$HOME_DIR/estate/EligibleWiki/wiki/index.md"
printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
printf '%s\n' "$HOME_DIR/estate" > "$HOME_DIR/config/megamind-estate"
STUB="$TMP_ROOT/megamind-axi"
printf '%s\n' "$STUB" > "$HOME_DIR/config/megamind-executable"

cat > "$STUB" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "--version" ]; then
  printf 'megamind-axi 0.6.0\n'
  exit 0
fi
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --root|--format|--today) i=$((i + 2)) ;;
    --no-help-hints) i=$((i + 1)) ;;
    *) break ;;
  esac
done
sub="${args[$i]:-}"
i=$((i + 1))
request=""; model=""; owner=""; session=""; today=""; selection=""; wiki=""
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --request) request="${args[$((i + 1))]}"; i=$((i + 2)) ;;
    --model-class) model="${args[$((i + 1))]}"; i=$((i + 2)) ;;
    --owner-id) owner="${args[$((i + 1))]}"; i=$((i + 2)) ;;
    --session-id) session="${args[$((i + 1))]}"; i=$((i + 2)) ;;
    --today) today="${args[$((i + 1))]}"; i=$((i + 2)) ;;
    --estate|--format) i=$((i + 2)) ;;
    --no-help-hints) i=$((i + 1)) ;;
    --selection-id) selection="${args[$((i + 1))]}"; i=$((i + 2)) ;;
    --full) i=$((i + 1)) ;;
    --) request="${args[$((i + 1))]}"; i=$((i + 2)) ;;
    -*) i=$((i + 1)) ;;
    *) [ -n "$wiki" ] || wiki="${args[$i]}"; i=$((i + 1)) ;;
  esac
done
request_hash=$(printf '%s' "$request" | shasum -a 256 | awk '{print $1}')
estate_root=$(head -n 1 "$FM_HOME/config/megamind-estate")
case "$sub" in
  preflight)
    jq -n --arg request_hash "$request_hash" '{schema_version:"megamind/preflight-result/v2",request_hash:$request_hash,model_class:"cloud",status:"ambiguous",confidence:0.4,preflight_id:"preflight-existing",catalog_hash:"cat-1",thresholds:{reliance_floor:0.75,offer_floor:0.25,ambiguity_band:0.05},matches:[],offers:[{name:"OfferedWiki",root:"/synthetic/estate/OfferedWiki",confidence:{score:0.4}}],filtered:[],redacted_count:0}'
    ;;
  select-existing)
    if [ "${FM_TEST_EXISTING_MODE:-ready}" = refuse ]; then
      printf '%s\n' '{"schema_version":"megamind/error/v1","code":"selection_refused"}'
      exit 1
    fi
    if [ "${FM_TEST_EXISTING_MODE:-ready}" = malformed ]; then
      printf '%s\n' '{"schema_version":"megamind/existing-selection-list/v1","status":"ready","wikis":"not-an-array"}'
      exit 0
    fi
    if [ -z "$wiki" ]; then
      if [ "${FM_TEST_EXISTING_MODE:-ready}" = catalog-drift ]; then
        catalog="cat-2"
      else
        catalog="cat-1"
      fi
      if printf '%s\n' "${args[*]}" | grep -q -- '--full'; then
        notes='[]'
        names=$(jq -cn --arg root "$estate_root/EligibleWiki" '[{name:"EligibleWiki",root:$root,access:"full",root_facts_hash:"root-facts",context_budget:{max_candidates:2,max_context_chars:1000}}]')
      else
        notes='["wikis truncated to 1 of 2; re-run with --full"]'
        names=$(jq -cn --arg root "$estate_root/EligibleWiki" '[{name:"EligibleWiki",root:$root,access:"full",root_facts_hash:"root-facts",context_budget:{max_candidates:2,max_context_chars:1000}}]')
      fi
      jq -n --arg request_hash "$request_hash" --arg catalog "$catalog" --arg model "$model" --arg owner "$owner" --arg session "$session" --arg today "$today" --argjson names "$names" --argjson notes "$notes" '{schema_version:"megamind/existing-selection-list/v1",status:"ready",request_hash:$request_hash,catalog_hash:$catalog,model_class:$model,owner_id:$owner,session_id:$session,today:$today,selection_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",wikis:$names,notes:$notes}'
    else
      printf '%s\n' "$wiki" >> "$FM_HOME/state/select-existing-calls"
      [ -z "${FM_TEST_EXISTING_DELAY:-}" ] || sleep "$FM_TEST_EXISTING_DELAY"
      if [ "${FM_TEST_EXISTING_MODE:-ready}" = root-facts-drift ]; then
        root_facts_hash="changed-root-facts"
      else
        root_facts_hash="root-facts"
      fi
      if [ "${FM_TEST_EXISTING_MODE:-ready}" = authorization-catalog-drift ]; then
        catalog="cat-2"
      else
        catalog="cat-1"
      fi
      if [ "${FM_TEST_EXISTING_MODE:-ready}" = provisional ]; then
        provisional=true
      else
        provisional=false
      fi
      result=$(jq -n --arg request_hash "$request_hash" --arg catalog "$catalog" --arg model "$model" --arg owner "$owner" --arg session "$session" --arg today "$today" --arg wiki "$wiki" --arg selection "$selection" --arg root "$estate_root/EligibleWiki" --arg root_facts_hash "$root_facts_hash" --argjson provisional "$provisional" '{schema_version:"megamind/existing-selection-result/v1",status:"authorized",request_hash:$request_hash,catalog_hash:$catalog,model_class:$model,owner_id:$owner,session_id:$session,today:$today,selection_id:$selection,root_facts_hash:$root_facts_hash,selection:{status:"explicit-user-selection",basis:"selected-eligible-existing",source_disposition:"eligible-existing",threshold_matched:false,confidence_changed:false},selected:{name:$wiki,root:$root,access:"full",routing_mode:"full",provisional:$provisional,allows:["wiki/index.md"],context_budget:{max_candidates:2,max_context_chars:1000},follow_up:"bounded follow-up"}}')
      printf '%s' "$result" > "$FM_HOME/state/last-upstream"
      printf '%s\n' "$result"
    fi
    ;;
  *) exit 2 ;;
esac
SH
chmod 700 "$STUB"

run_in() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-megamind-preflight.sh" "$@"
}

run_mode() {
  local mode="$1"
  shift
  FM_TEST_EXISTING_MODE="$mode" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-megamind-preflight.sh" "$@"
}

out=$(run_in run --request "original request")
selection=$(printf '%s' "$out" | jq -r '.selection_id')
[ "$(printf '%s' "$out" | jq -r '.outcome')" = ambiguous ] || fail "ambiguous request was not retained: $out"
[ -n "$selection" ] && [ "$selection" != null ] || fail "ambiguous request had no pending identity: $out"

list=$(run_in existing-list --selection-id "$selection")
[ "$(printf '%s' "$list" | jq -r '.status')" = ready ] || fail "Megamind list was not returned: $list"
[ "$(printf '%s' "$list" | jq -r '.catalog_hash')" = cat-1 ] || fail "list catalog binding was not retained"
[ "$(printf '%s' "$list" | jq -r '[.wikis[].wiki] | join(",")')" = EligibleWiki ] || fail "the host exposed more than Megamind returned"
[ "$(printf '%s' "$list" | jq -r '.truncated')" = true ] || fail "producer truncation was not preserved: $list"
[ "$(printf '%s' "$list" | jq -r '.can_show_more')" = true ] || fail "producer show-more capability was not preserved"

full=$(run_in existing-list --selection-id "$selection" --full)
[ "$(printf '%s' "$full" | jq -r '.truncated')" = false ] || fail "bounded full interaction remained truncated"

for forged in HiddenWiki OtherWiki; do
  refused=$(run_in existing-continue --selection-id "$selection" --existing-selection-id "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" --wiki "$forged" 2>/dev/null || true)
  [ "$(printf '%s' "$refused" | jq -r '.failure.code')" = selection_invalid ] || fail "forged or withheld name was not refused: $forged $refused"
done

authorized=$(run_in existing-continue --selection-id "$selection" --existing-selection-id "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" --wiki EligibleWiki)
[ "$(printf '%s' "$authorized" | jq -r '.outcome')" = authorized ] || fail "returned eligible wiki was not authorized: $authorized upstream=$(cat "$HOME_DIR/state/last-upstream" 2>/dev/null || true)"
[ "$(printf '%s' "$authorized" | jq -r '.selection.basis')" = selected-eligible-existing ] || fail "authorization basis changed"
[ "$(printf '%s' "$authorized" | jq -r '.selected.threshold_matched')" = false ] || fail "explicit selection became a threshold match"
[ "$(printf '%s' "$authorized" | jq -r '.selected.allows[0]')" = wiki/index.md ] || fail "bounded allows were not preserved"
[ "$(printf '%s' "$authorized" | jq -r '.selected.root_identity | length')" = 64 ] || fail "selected root identity was not bound"
admitted=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-megamind-content.sh" admit --selection-id "$selection")
[ "$(printf '%s' "$admitted" | jq -r '.outcome')" = admitted ] || fail "selected existing authorization did not enter bounded admission: $admitted"
admission_id=$(printf '%s' "$admitted" | jq -r '.admission_id')
content=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-megamind-content.sh" content --admission-id "$admission_id")
[ "$(printf '%s' "$content" | grep -c 'synthetic content')" = 1 ] || fail "bounded reader did not deliver selected wiki content"

replay=$(run_in existing-continue --selection-id "$selection" --existing-selection-id "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" --wiki EligibleWiki 2>/dev/null || true)
[ "$(printf '%s' "$replay" | jq -r '.failure.code')" = selection_missing ] || fail "authorization replay did not stop: $replay"

# A producer refusal, malformed output, and catalog drift are all typed stops, not
# reasons for the host to invent a list or fall back to the offered wiki.
out=$(run_in run --request "refusal request")
selection=$(printf '%s' "$out" | jq -r '.selection_id')
refused=$(run_mode refuse existing-list --selection-id "$selection" 2>/dev/null || true)
[ "$(printf '%s' "$refused" | jq -r '.failure.code')" = upstream_error ] || fail "producer refusal got a fallback: $refused"
malformed=$(run_mode malformed existing-list --selection-id "$selection" 2>/dev/null || true)
[ "$(printf '%s' "$malformed" | jq -r '.failure.code')" = malformed_result ] || fail "malformed list was not refused: $malformed"
drift=$(run_mode catalog-drift existing-list --selection-id "$selection" 2>/dev/null || true)
[ "$(printf '%s' "$drift" | jq -r '.failure.code')" = malformed_result ] || fail "catalog drift was not refused: $drift"

for mode in authorization-catalog-drift root-facts-drift provisional; do
  out=$(run_in run --request "$mode request")
  selection=$(printf '%s' "$out" | jq -r '.selection_id')
  list=$(run_in existing-list --selection-id "$selection")
  existing_selection=$(printf '%s' "$list" | jq -r '.existing_selection_id')
  rejected=$(run_mode "$mode" existing-continue --selection-id "$selection" --existing-selection-id "$existing_selection" --wiki EligibleWiki 2>/dev/null || true)
  [ "$(printf '%s' "$rejected" | jq -r '.failure.code')" = malformed_result ] || fail "$mode authorization was not refused: $rejected"
done

out=$(run_in run --request "concurrent selection request")
selection=$(printf '%s' "$out" | jq -r '.selection_id')
list=$(run_in existing-list --selection-id "$selection")
existing_selection=$(printf '%s' "$list" | jq -r '.existing_selection_id')
rm -f -- "$HOME_DIR/state/select-existing-calls"
race_one="$TMP_ROOT/race-one.json"
race_two="$TMP_ROOT/race-two.json"
FM_TEST_EXISTING_DELAY=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-megamind-preflight.sh" existing-continue --selection-id "$selection" --existing-selection-id "$existing_selection" --wiki EligibleWiki >"$race_one" 2>/dev/null &
race_one_pid=$!
FM_TEST_EXISTING_DELAY=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-megamind-preflight.sh" existing-continue --selection-id "$selection" --existing-selection-id "$existing_selection" --wiki EligibleWiki >"$race_two" 2>/dev/null &
race_two_pid=$!
wait "$race_one_pid" || true
wait "$race_two_pid" || true
[ "$(wc -l < "$HOME_DIR/state/select-existing-calls" | tr -d '[:space:]')" = 1 ] || fail "concurrent selection invoked Megamind more than once"
race_authorized=$(cat "$race_one" "$race_two" | jq -r 'select(.outcome == "authorized") | .outcome' | wc -l | tr -d '[:space:]')
[ "$race_authorized" = 1 ] || fail "concurrent selection did not authorize exactly once"

pass "Megamind existing-wiki list and authorization: producer-only names, truncation, bounded admission, replay, drift, provisional refusal, and concurrency"
