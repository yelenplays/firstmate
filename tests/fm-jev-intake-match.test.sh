#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-intake-match.sh.
#
# Drives the helper against a real tasks-axi backlog and data/<id>/ records,
# with a fake curl on PATH that records argv, the request body, and the header
# read from file descriptor 3. No case touches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TYPESAFE_API_KEY OPENROUTER_API_KEY TYPESAFE_API_KEY_PRIVATE \
  OPENROUTER_API_KEY_PRIVATE JEV_ROUTE JEV_MODEL JEV_TIMEOUT JEV_URL JEV_BASE \
  JEV_CONFIDENCE_FLOOR JEV_STATE_MAX_BYTES FM_STATE_OVERRIDE FM_DATA_OVERRIDE

HELPER="$ROOT/bin/fm-jev-intake-match.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-intake-match)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
RESPONSE="$TMP_ROOT/response.json"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'
BODY_MARKER='PRIVATE-REPORT-BODY-MARKER'

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
cat > "$FAKE_CURL_LOG/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '200'
SH
chmod +x "$FAKEBIN/curl"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE"

# respond <choice> <confidence> <probabilities-json>
respond() {
  jq -n --arg c "$1" --argjson conf "$2" --argjson p "$3" \
    '{model: "jev-1.13.0", answers: {match: {type: "choice", choice: $c, confidence: $conf, probabilities: $p}}}' \
    > "$RESPONSE"
}

add_record() {  # <id> <file> <heading>
  mkdir -p "$HOME_DIR/data/$1"
  printf '# %s\n\n%s body text for %s.\n' "$3" "$BODY_MARKER" "$1" > "$HOME_DIR/data/$1/$2"
}

fresh_home() {
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  : > "$HOME_DIR/data/backlog.md"
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi add wf-p0-privacy-ceiling "Wiki family p0: privacy-ceiling" \
    --body "Phase 0 of the plan in data/wiki-layer-plan-v1/report.md." --file data/backlog.md) >/dev/null
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi add wf-p1-register "Wiki family p1: register" \
    --body "Next phase of wiki-layer-plan-v1." --file data/backlog.md) >/dev/null
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi add deck-refresh-v1 "Refresh the pitch deck colors" \
    --file data/backlog.md) >/dev/null
  add_record wiki-layer-plan-v1 report.md "Wiki layer: verdict and prioritized plan"
  add_record bochum-hero-v1 brief.md "Task"
  add_record mail-plane-v1 report.md "Mail plane transport audit"
}

# run_match <exit-var> <out-var> [args...]
run_match() {
  local __exit=$1 __out=$2 _out _code
  shift 2
  rm -rf "$LOG"
  mkdir -p "$LOG"
  _code=0
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="${KEY-}" \
    FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" "$HELPER" "$@" </dev/null 2>"$TMP_ROOT/stderr") || _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
}

test_usage() {
  local code out
  run_match code out
  expect_code 2 "$code" "no reference should be a usage error"
  pass "an empty invocation is a usage error"
}

test_off_falls_back_to_keyword_ranking() {
  local code out first
  fresh_home
  KEY='' run_match code out get our wiki plan which I had in one prompt
  expect_code 0 "$code" "off should still exit 0"
  assert_contains "$out" "ranking: keyword" "off did not use the keyword ranking"
  assert_contains "$out" "fallback: off" "off did not say it fell back"
  first=$(printf '%s\n' "$out" | grep -m1 '^    1\. ')
  assert_contains "$first" "wiki-layer-plan-v1 score=2/" "the plan record was not ranked first"$'\n'"$out"
  assert_contains "$first" "record=$HOME_DIR/data/wiki-layer-plan-v1/report.md" "the record path was not shown"
  assert_not_contains "$out" "deck-refresh-v1" "an unrelated candidate was listed"
  [ ! -e "$LOG/body" ] || fail "off made a model call"
  pass "with no key the helper says so and ranks by keywords"
}

test_jev_ranking_sends_only_ids_and_titles() {
  local code out
  fresh_home
  respond wiki-layer-plan-v1 0.84 \
    '{"wiki-layer-plan-v1":0.84,"wf-p0-privacy-ceiling":0.1,"mail-plane-v1":0.02,"deck-refresh-v1":0.01,"bochum-hero-v1":0.01,"none":0.02}'
  KEY=$TS_KEY run_match code out get our wiki plan which I had in one prompt
  expect_code 0 "$code" "a clear answer should exit 0"
  assert_contains "$out" "ranking: jev" "a clear answer did not rank by Jev"$'\n'"$out"
  assert_contains "$out" "fallback: none" "a clear answer reported a fallback"
  assert_contains "$out" "    1. wiki-layer-plan-v1 confidence=0.84" "the pick was not first"$'\n'"$out"
  assert_contains "$out" "    2. wf-p0-privacy-ceiling confidence=0.1 state=queued" \
    "the runner-up backlog item was not second with its state"$'\n'"$out"
  jq -e '.questions.match.type == "choice" and (.questions.match.criteria | has("none"))' "$LOG/body" >/dev/null \
    || fail "the request was not one Choice with a none option"
  jq -e '.questions.match.criteria["wiki-layer-plan-v1"] | contains("Wiki layer: verdict")' "$LOG/body" >/dev/null \
    || fail "the record title did not reach the criteria"
  jq -e '.state | contains("get our wiki plan")' "$LOG/body" >/dev/null || fail "the reference did not reach state"
  assert_no_grep "$BODY_MARKER" "$LOG/body" "a file body reached the request"
  assert_no_grep "$TS_KEY" "$LOG/argv" "the key reached curl argv"
  assert_grep "Bearer $TS_KEY" "$LOG/header" "the key did not travel on fd 3"
  jq -e 'select(.purpose == "intake-match" and .ranking == "jev" and .choice == "wiki-layer-plan-v1")' \
    "$HOME_DIR/state/jev-intake-match.jsonl" >/dev/null || fail "the call was not logged"
  jq -e 'select(.reference_chars == 43 and (.reference_sha256 | test("^[0-9a-f]{64}$")) and (has("reference") | not))' \
    "$HOME_DIR/state/jev-intake-match.jsonl" >/dev/null || fail "the log did not keep only the reference length and hash"
  assert_no_grep "get our wiki plan" "$HOME_DIR/state/jev-intake-match.jsonl" "the log stored the reference text"
  pass "a clear Jev answer ranks by probabilities and sends only ids and titles"
}

test_related_tasks_follow_a_matched_record() {
  local code out
  fresh_home
  respond wiki-layer-plan-v1 0.9 '{"wiki-layer-plan-v1":0.9,"none":0.1}'
  KEY=$TS_KEY run_match code out wiki plan
  assert_contains "$out" "  related:" "a matched record listed no related tasks"$'\n'"$out"
  assert_contains "$out" "    - wiki-layer-plan-v1 -> wf-p0-privacy-ceiling state=queued title=Wiki family p0: privacy-ceiling" \
    "a task whose body names the record was not listed"$'\n'"$out"
  assert_contains "$out" "    - wiki-layer-plan-v1 -> wf-p1-register state=queued" \
    "a second related task was not listed"$'\n'"$out"
  assert_not_contains "$out" "-> deck-refresh-v1" "a task that does not name the record was listed"
  [ "$(jq '.questions | length' "$LOG/body")" -eq 1 ] || fail "related tasks cost an extra question"
  KEY='' run_match code out wiki plan
  assert_contains "$out" "    - wiki-layer-plan-v1 -> wf-p0-privacy-ceiling" \
    "the keyword fallback did not list related tasks"$'\n'"$out"
  pass "a matched record brings the backlog tasks that name it, with no extra Jev question"
}

test_reference_is_one_bounded_line() {
  local code out long
  fresh_home
  KEY=$TS_KEY run_match code out "$(printf 'wiki\nplan')"
  expect_code 2 "$code" "a multi-line reference should be refused"
  assert_grep "one line" "$TMP_ROOT/stderr" "the refusal did not say why"
  long=$(printf 'w%.0s' $(seq 1 301))
  KEY=$TS_KEY run_match code out "$long"
  expect_code 2 "$code" "a 301-character reference should be refused"
  assert_grep "limit is 300" "$TMP_ROOT/stderr" "the refusal did not name the limit"
  [ ! -e "$LOG/body" ] || fail "a refused reference reached Jev"
  pass "a multi-line or over-300-character reference is refused before any call"
}

test_ties_put_recent_records_before_backlog_items() {
  local code out first
  fresh_home
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi add alpha-sync-v1 "Alpha sync" --file data/backlog.md) >/dev/null
  add_record zeta-sync-v1 report.md "Zeta sync"
  KEY='' run_match code out sync
  first=$(printf '%s\n' "$out" | grep -m1 '^    1\. ')
  assert_contains "$first" "zeta-sync-v1" "a tied backlog-only item outranked the recent record"$'\n'"$out"
  pass "tied candidates list recent records before backlog-only items"
}

test_low_confidence_falls_back() {
  local code out
  fresh_home
  respond wiki-layer-plan-v1 0.41 '{"wiki-layer-plan-v1":0.41,"wf-p0-privacy-ceiling":0.39,"none":0.2}'
  KEY=$TS_KEY run_match code out wiki plan
  assert_contains "$out" "ranking: keyword" "a low-confidence answer was trusted"
  assert_contains "$out" "fallback: low-confidence" "the low-confidence fallback was not stated"
  assert_contains "$out" "confidence: 0.41" "the low confidence was not shown"
  pass "a pick below the floor falls back to keywords and says so"
}

test_failures_fall_back() {
  local code out
  fresh_home
  FAKE_CURL_FAIL=1 KEY=$TS_KEY run_match code out wiki plan
  expect_code 0 "$code" "a transport failure should exit 0"
  assert_contains "$out" "fallback: error" "a transport failure was not reported"
  respond none 0.9 '{"none":0.9,"wiki-layer-plan-v1":0.1}'
  KEY=$TS_KEY run_match code out wiki plan
  assert_contains "$out" "fallback: no-match" "a none answer was not reported"
  respond not-offered 0.95 '{"not-offered":0.95,"none":0.05}'
  KEY=$TS_KEY run_match code out wiki plan
  assert_contains "$out" "fallback: error" "an unoffered pick was accepted"
  pass "transport failure, none, and an unoffered pick all fall back to keywords"
}

test_candidate_list_is_bounded() {
  local code out i offered
  fresh_home
  for i in $(seq 1 40); do
    add_record "extra-plan-$i" report.md "Extra plan $i"
  done
  respond wiki-layer-plan-v1 0.9 '{"wiki-layer-plan-v1":0.9,"none":0.1}'
  KEY=$TS_KEY run_match code out wiki plan
  offered=$(jq '.questions.match.criteria | length' "$LOG/body")
  [ "$offered" -eq 25 ] || fail "offered $offered choices, want 24 candidates plus none"
  jq -e '.questions.match.criteria | has("wiki-layer-plan-v1")' "$LOG/body" >/dev/null \
    || fail "the best keyword match was cut from the bounded offer"
  pass "the offer is bounded to 24 candidates and keeps the best keyword match"
}

test_usage
test_off_falls_back_to_keyword_ranking
test_jev_ranking_sends_only_ids_and_titles
test_related_tasks_follow_a_matched_record
test_reference_is_one_bounded_line
test_ties_put_recent_records_before_backlog_items
test_low_confidence_falls_back
test_failures_fall_back
test_candidate_list_is_bounded

echo "# all fm-jev-intake-match tests passed"
