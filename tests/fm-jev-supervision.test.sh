#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/environment.sh"
fm_test_sanitize_environment
# tests/fm-jev-supervision.test.sh - the two bounded Jev supervision helpers
# (bin/fm-jev-status-triage.sh, bin/fm-jev-wedge-check.sh): verdict parsing off
# the captain_relevant/stuck Noul alone, the corpus-faithful question shape in
# the request body, one JSONL record per attempted call, and the fail-closed
# contract - every error, timeout stand-in, or malformed answer exits nonzero
# with no verdict so the caller's deterministic supervision verdict stands.
# Integration at the supervision call sites lives in fm-watch-triage.test.sh
# (span opt-in + wedge boundary) and fm-daemon.test.sh (housekeeping boundary).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

STATUS_TRIAGE="$ROOT/bin/fm-jev-status-triage.sh"
WEDGE_CHECK="$ROOT/bin/fm-jev-wedge-check.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-supervision)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'
mkdir -p "$HOME_DIR/state" "$LOG"

# The fake curl records argv/body/header and replays FAKE_CURL_RESPONSE, exactly
# the fixture tests/fm-jev-queue-triage.test.sh uses; no case touches the network.
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
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

fresh_home() {
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR/state"
}

status_response() {  # <out-file> <noul> [verb] [confidence]
  local f=$1
  shift
  cat > "$f" <<JSON
{ "model": "jev-1.13.0",
  "answers": {
    "verb": { "type": "choice", "choice": "${2:-note}", "confidence": ${3:-0.7},
      "probabilities": { "note": 0.7, "working": 0.2, "other": 0.1 } },
    "captain_relevant": { "type": "noul", "noul": $1 }
  },
  "usage": { "input_tokens": 40, "output_tokens": 12 } }
JSON
}

wedge_response() {  # <out-file> <noul> [state-choice] [confidence]
  local f=$1
  shift
  cat > "$f" <<JSON
{ "model": "jev-1.13.0",
  "answers": {
    "state": { "type": "choice", "choice": "${2:-idle_finished}", "confidence": ${3:-0.8},
      "probabilities": { "idle_finished": 0.8, "working_busy": 0.15, "genuinely_stuck": 0.05 } },
    "stuck": { "type": "noul", "noul": $1 }
  },
  "usage": { "input_tokens": 40, "output_tokens": 12 } }
JSON
}

# run_helper <helper> <exit-var> <out-var> <err-var>  - stdin from STDIN_FILE.
run_helper() {
  local helper=$1 __exit=$2 __out=$3 __err=$4 _out _code _errfile
  _errfile="$TMP_ROOT/stderr"
  reset_log
  _code=0
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    TYPESAFE_API_KEY="$TS_KEY" FAKE_CURL_LOG="$LOG" \
    FAKE_CURL_RESPONSE="$RESPONSE" FAKE_CURL_HTTP="${FAKE_CURL_HTTP:-200}" \
    FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" \
    "$helper" < "$STDIN_FILE" 2> "$_errfile") || _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$_errfile")"
  unset FAKE_CURL_HTTP FAKE_CURL_FAIL
}

RESPONSE="$TMP_ROOT/response.json"
STDIN_FILE="$TMP_ROOT/stdin.txt"

test_status_triage_verdicts() {
  local code out err
  fresh_home
  printf 'note: deploy window moved to Thursday, tell the captain\n' > "$STDIN_FILE"

  status_response "$RESPONSE" 0.9 note 0.7
  run_helper "$STATUS_TRIAGE" code out err
  expect_code 0 "$code" "a high captain_relevant Noul exits 0"
  assert_equals escalate "$out" "noul 0.9 escalates"

  status_response "$RESPONSE" 0.5 note 0.7
  run_helper "$STATUS_TRIAGE" code out err
  assert_equals escalate "$out" "noul at the 0.5 floor still escalates"

  status_response "$RESPONSE" 0.49 note 0.7
  run_helper "$STATUS_TRIAGE" code out err
  expect_code 0 "$code" "a low Noul still exits 0 (a valid verdict, not an error)"
  assert_equals suppress "$out" "noul 0.49 abstains"

  assert_present "$HOME_DIR/state/jev-status-triage.jsonl" "every call appends the JSONL record"
  jq -e '.purpose == "status-triage" and .advisory == true and .escalate_only == true
      and .status == "suppress" and .noul == 0.49 and .verb_choice == "note"
      and .route == "typesafe" and .http == "200"' \
    "$HOME_DIR/state/jev-status-triage.jsonl" >/dev/null \
    || fail "the JSONL record does not carry the advisory verdict fields: $(cat "$HOME_DIR/state/jev-status-triage.jsonl")"
  pass "status triage gates on the captain_relevant Noul at 0.5 and logs the verdict"
}

test_status_triage_question_shape_and_line_only() {
  local code out err body
  fresh_home
  printf 'resolved [key=api]: took A\n' > "$STDIN_FILE"
  status_response "$RESPONSE" 0.2 resolved 0.8
  run_helper "$STATUS_TRIAGE" code out err
  expect_code 0 "$code" "resolved: line consult exits 0"
  body=$(cat "$LOG/body")
  assert_contains "$body" '"captain_relevant"' "the request carries the Noul question"
  assert_contains "$body" '"noul"' "the request carries the noul type"
  assert_contains "$body" '"verb"' "the request carries the verb Choice for the audit trail"
  assert_contains "$body" 'needs-decision' "the Choice criteria name the corpus verb set"
  assert_contains "$body" 'resolved [key=api]: took A' "the state is the status line itself"
  pass "the status consult sends the corpus question pair with only the line as state"
}

test_status_triage_failure_is_fail_closed() {
  local code out err
  fresh_home
  printf 'progress: halfway through the refactor\n' > "$STDIN_FILE"

  FAKE_CURL_FAIL=1 run_helper "$STATUS_TRIAGE" code out err
  [ "$code" -ne 0 ] || fail "a transport failure must exit nonzero"
  [ -z "$out" ] || fail "a transport failure must print no verdict, got: $out"

  status_response "$RESPONSE" 0.9 note 0.7
  FAKE_CURL_HTTP=500 run_helper "$STATUS_TRIAGE" code out err
  [ "$code" -ne 0 ] || fail "a non-200 must exit nonzero"
  [ -z "$out" ] || fail "a non-200 must print no verdict, got: $out"

  for bad in '"nope"' '"0.9"' '1.4' '-0.2' 'null' 'true'; do
    jq --argjson n "$bad" '.answers.captain_relevant.noul = $n' "$RESPONSE" \
      > "$TMP_ROOT/edited.json" && mv "$TMP_ROOT/edited.json" "$RESPONSE"
    run_helper "$STATUS_TRIAGE" code out err
    [ "$code" -ne 0 ] || fail "noul $bad must exit nonzero"
    [ -z "$out" ] || fail "noul $bad must print no verdict, got: $out"
  done

  # No API key at all: the helper must refuse fast rather than hang the loop.
  reset_log
  code=0
  out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" \
    "$STATUS_TRIAGE" < "$STDIN_FILE" 2>/dev/null) || code=$?
  [ "$code" -ne 0 ] || fail "a keyless environment must exit nonzero"
  [ ! -e "$LOG/argv" ] || fail "a keyless environment must not call curl"
  pass "every status-triage failure is fail-closed: nonzero exit, no verdict, no downgrade"
}

test_wedge_check_verdicts() {
  local code out err
  fresh_home
  printf 'quota exceeded\nRetrying in 5m\n' > "$STDIN_FILE"

  wedge_response "$RESPONSE" 0.69 genuinely_stuck 0.74
  run_helper "$WEDGE_CHECK" code out err
  expect_code 0 "$code" "a high stuck Noul exits 0"
  assert_equals escalate "$out" "noul 0.69 escalates"

  # The corpus counterexample shape: a confident stuck CHOICE with a low Noul.
  # The verdict must ignore the Choice - the Noul alone gates.
  wedge_response "$RESPONSE" 0.31 genuinely_stuck 0.74
  run_helper "$WEDGE_CHECK" code out err
  expect_code 0 "$code" "a low stuck Noul exits 0"
  assert_equals suppress "$out" "choice 0.74 stuck but noul 0.31 suppresses"

  wedge_response "$RESPONSE" 0.5 genuinely_stuck 0.6
  run_helper "$WEDGE_CHECK" code out err
  assert_equals escalate "$out" "noul at the 0.5 floor still escalates"

  assert_present "$HOME_DIR/state/jev-wedge-check.jsonl" "every call appends the JSONL record"
  jq -e '.purpose == "wedge-check" and .advisory == true and .second_opinion == true
      and .status == "escalate" and .noul == 0.5' \
    "$HOME_DIR/state/jev-wedge-check.jsonl" >/dev/null \
    || fail "the JSONL record does not carry the advisory verdict fields: $(cat "$HOME_DIR/state/jev-wedge-check.jsonl")"
  pass "wedge check gates on the stuck Noul alone, never the state Choice"
}

test_wedge_check_question_shape_and_tail_only() {
  local code out err body
  fresh_home
  printf 'some pane text\n$ \n' > "$STDIN_FILE"
  wedge_response "$RESPONSE" 0.2 idle_finished 0.8
  run_helper "$WEDGE_CHECK" code out err
  expect_code 0 "$code" "pane-tail consult exits 0"
  body=$(cat "$LOG/body")
  assert_contains "$body" '"stuck"' "the request carries the stuck Noul question"
  assert_contains "$body" 'genuinely_stuck' "the state Choice carries the corpus classes"
  assert_contains "$body" 'working_busy' "the state Choice carries working_busy"
  assert_contains "$body" 'idle_finished' "the state Choice carries idle_finished"
  assert_contains "$body" 'some pane text' "the state is the pane tail itself"
  pass "the wedge consult sends the corpus question pair with only the pane tail as state"
}

test_wedge_check_failure_is_fail_closed() {
  local code out err
  fresh_home
  printf 'dead prompt\n' > "$STDIN_FILE"

  FAKE_CURL_FAIL=1 run_helper "$WEDGE_CHECK" code out err
  [ "$code" -ne 0 ] || fail "a transport failure must exit nonzero"
  [ -z "$out" ] || fail "a transport failure must print no verdict, got: $out"

  wedge_response "$RESPONSE" 0.9 genuinely_stuck 0.8
  FAKE_CURL_HTTP=503 run_helper "$WEDGE_CHECK" code out err
  [ "$code" -ne 0 ] || fail "a non-200 must exit nonzero"
  [ -z "$out" ] || fail "a non-200 must print no verdict, got: $out"

  jq 'del(.answers.stuck)' "$RESPONSE" > "$TMP_ROOT/edited.json" && mv "$TMP_ROOT/edited.json" "$RESPONSE"
  run_helper "$WEDGE_CHECK" code out err
  [ "$code" -ne 0 ] || fail "a missing stuck answer must exit nonzero"
  [ -z "$out" ] || fail "a missing stuck answer must print no verdict, got: $out"
  pass "every wedge-check failure is fail-closed: nonzero exit, no verdict"
}

test_status_triage_verdicts
test_status_triage_question_shape_and_line_only
test_status_triage_failure_is_fail_closed
test_wedge_check_verdicts
test_wedge_check_question_shape_and_tail_only
test_wedge_check_failure_is_fail_closed
