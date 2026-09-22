#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-act-first.sh: the session-start digest's local
# ACT FIRST list and the deferred network stage's advisory Jev ranking.
#
# Drives the helper with a fake curl on PATH that records argv, the request
# body, and the header read from file descriptor 3. No case touches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TYPESAFE_API_KEY OPENROUTER_API_KEY TYPESAFE_API_KEY_PRIVATE \
  OPENROUTER_API_KEY_PRIVATE JEV_ROUTE JEV_MODEL JEV_TIMEOUT JEV_URL JEV_BASE \
  JEV_CONFIDENCE_FLOOR JEV_STATE_MAX_BYTES FM_STATE_OVERRIDE

HELPER="$ROOT/bin/fm-jev-act-first.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-act-first)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
RESPONSE="$TMP_ROOT/response.json"
DRAIN="$TMP_ROOT/drain.txt"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'

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

respond() {  # <choice> <confidence> <probabilities-json>
  jq -n --arg c "$1" --argjson conf "$2" --argjson p "$3" \
    '{model: "jev-1.13.0", answers: {first: {type: "choice", choice: $c, confidence: $conf, probabilities: $p}}}' \
    > "$RESPONSE"
}

fresh_home() {
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR/state"
  {
    printf '1790000000\t7\tsignal\tship-a.status\tworking: tests running\n'
    printf '1790000001\t8\theartbeat\tfleet\t\n'
    printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 8 --recovery-generation 3\n'
    printf 'UNREAD STATUS (new since last drain, not re-printed after this presentation):\n'
    printf 'ship-a note: routine note\n'
    printf 'OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):\n'
    printf 'scout-b [key=pick-lib] needs-decision: pick a library for the parser\n'
    printf "OPEN DECISIONS: close one by answering it: bin/fm-send.sh <task> --resolve-key <key> '<answer>'\n"
    printf 'UNFINISHED EXECUTION (task, accountable owner, next action; acknowledgement is not handling):\n'
    printf 'ship-c\tfirstmate\timplementation owner missing; dispatch or promote within approved intent\n'
  } > "$DRAIN"
  printf 'working: started\nfailed: build broke on main\n' > "$HOME_DIR/state/ship-d.status"
  printf 'kind=ship\n' > "$HOME_DIR/state/ship-d.meta"
  printf 'blocked: gone task\n' > "$HOME_DIR/state/gone-e.status"
}

run_helper() {  # <out-var> [args...]
  local __out=$1 _out
  shift
  rm -rf "$LOG"
  mkdir -p "$LOG"
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="${KEY-}" \
    FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" "$HELPER" "$@" </dev/null 2>"$TMP_ROOT/stderr")
  RUN_CODE=$?
  printf -v "$__out" '%s' "$_out"
}

test_usage() {
  local out
  run_helper out
  expect_code 2 "$RUN_CODE" "a missing drain file should be a usage error"
  pass "the drain file is required"
}

test_off_is_silent() {
  local out
  fresh_home
  KEY='' run_helper out --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  expect_code 0 "$RUN_CODE" "off should exit 0"
  [ -z "$out" ] || fail "off printed output: $out"
  [ ! -e "$LOG/body" ] || fail "off made a model call"
  pass "with no key the helper is silent and makes no call"
}

test_ranks_collected_items() {
  local out lines
  fresh_home
  respond i1 0.7 '{"i1":0.7,"i2":0.12,"i3":0.1,"i4":0.05,"i5":0.03}'
  KEY=$TS_KEY run_helper out --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  expect_code 0 "$RUN_CODE" "a clear answer should exit 0"
  lines=$(printf '%s\n' "$out" | grep -c .)
  [ "$lines" -eq 5 ] || fail "printed $lines lines, want at most five"$'\n'"$out"
  assert_contains "$out" "1. decision scout-b [key=pick-lib] needs-decision: pick a library for the parser (p=0.7)" \
    "the top pick was not first"$'\n'"$out"
  assert_contains "$out" "2. execution ship-c owner=firstmate next=implementation owner missing" \
    "the execution row was not ranked second"$'\n'"$out"
  assert_contains "$out" "3. status ship-d failed: build broke on main (p=0.1)" \
    "the live task's failed status tail was not offered"$'\n'"$out"
  jq -e '.questions.first.type == "choice" and (.questions.first.criteria | length) == 5' "$LOG/body" >/dev/null \
    || fail "the request was not one Choice over the five items"
  jq -e '[.questions.first.criteria[]] | any(startswith("wake signal ship-a.status: working"))' "$LOG/body" >/dev/null \
    || fail "a raw wake record was not offered"
  jq -e '[.questions.first.criteria[]] | all(test("gone task|routine note|WAKE_ACK") | not)' "$LOG/body" >/dev/null \
    || fail "a dead task's status, an unread note, or the ack line was offered"
  assert_no_grep "$TS_KEY" "$LOG/argv" "the key reached curl argv"
  assert_grep "Bearer $TS_KEY" "$LOG/header" "the key did not travel on fd 3"
  jq -e 'select(.purpose == "act-first" and .item_count == 5 and .choice == "i1")' \
    "$HOME_DIR/state/jev-act-first.jsonl" >/dev/null || fail "the call was not logged"
  pass "the collected items are ranked by Jev probabilities, at most five lines"
}

test_local_lists_priority_order_without_a_call() {
  local out
  fresh_home
  KEY='' run_helper out --local --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  expect_code 0 "$RUN_CODE" "--local should exit 0"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 5 ] || fail "--local did not print five lines"$'\n'"$out"
  assert_contains "$out" "1. decision scout-b [key=pick-lib] needs-decision: pick a library for the parser" \
    "--local did not put the open decision first"$'\n'"$out"
  assert_contains "$out" "3. status ship-d failed: build broke on main" \
    "--local did not order failures after unfinished execution"$'\n'"$out"
  assert_contains "$out" "5. wake heartbeat fleet" "--local did not end with the wakes"$'\n'"$out"
  assert_not_contains "$out" "(p=" "--local printed a model probability"
  [ ! -e "$LOG/body" ] || fail "--local made a model call"
  pass "--local lists the items in priority order with no key and no call"
}

test_failures_are_silent() {
  local out
  fresh_home
  FAKE_CURL_FAIL=1 KEY=$TS_KEY run_helper out --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  expect_code 0 "$RUN_CODE" "a transport failure should exit 0"
  [ -z "$out" ] || fail "a transport failure printed output: $out"
  respond i99 0.9 '{"i99":0.9,"i1":0.1}'
  KEY=$TS_KEY run_helper out --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  [ -z "$out" ] || fail "an unoffered pick printed output: $out"
  pass "a failed call or an unoffered pick prints nothing"
}

test_single_item_makes_no_call() {
  local out
  fresh_home
  rm -f "$HOME_DIR/state/ship-d.status"
  printf '1790000000\t7\tsignal\tship-a.status\tblocked: need a key\n' > "$DRAIN"
  KEY=$TS_KEY run_helper out --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  [ -z "$out" ] || fail "a single item printed output: $out"
  [ ! -e "$LOG/body" ] || fail "a single item made a model call"
  pass "fewer than two items makes no call"
}

test_usage
test_off_is_silent
test_ranks_collected_items
test_local_lists_priority_order_without_a_call
test_failures_are_silent
test_single_item_makes_no_call

echo "# all fm-jev-act-first tests passed"
