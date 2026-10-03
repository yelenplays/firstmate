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
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-supervision)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'
mkdir -p "$HOME_DIR/state" "$LOG"

# The fake curl records argv/body/header and replays FAKE_CURL_RESPONSE; no case
# touches the network.
unset FAKE_CURL_HANG
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
max_time=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --max-time) max_time=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
printf '%s\n' "$max_time" > "$FAKE_CURL_LOG/max_time"
cat > "$FAKE_CURL_LOG/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
printf 'call\n' >> "$FAKE_CURL_LOG/calls"
if [ "${FAKE_CURL_HANG:-0}" = 1 ]; then
  sleep "$max_time"
  exit 28
fi
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

# A task record the supervision data boundary admits for free text: a ship task
# whose project is this firstmate repository, in a primary home (HOME_DIR has no
# .fm-secondmate-home marker). FREE_TEXT_ARGS names it to a helper.
write_task_meta() {  # <task> <kind> <project>
  printf 'kind=%s\nproject=%s\n' "$2" "$3" > "$HOME_DIR/state/$1.meta"
}
FREE_TEXT_ARGS=(--task fmtask --state-dir "$HOME_DIR/state")

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

# run_helper <helper> <exit-var> <out-var> <err-var> [helper-arg...]
#   - stdin from STDIN_FILE.
run_helper() {
  local helper=$1 __exit=$2 __out=$3 __err=$4 _out _code _errfile
  shift 4
  _errfile="$TMP_ROOT/stderr"
  reset_log
  _code=0
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    TYPESAFE_API_KEY="$TS_KEY" FAKE_CURL_LOG="$LOG" \
    FAKE_CURL_RESPONSE="$RESPONSE" FAKE_CURL_HTTP="${FAKE_CURL_HTTP:-200}" \
    FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" \
    "$helper" "$@" < "$STDIN_FILE" 2> "$_errfile") || _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$_errfile")"
  unset FAKE_CURL_HTTP FAKE_CURL_FAIL
}

RESPONSE="$TMP_ROOT/response.json"
STDIN_FILE="$TMP_ROOT/stdin.txt"

test_status_triage_verdicts() {
  local code out _err
  fresh_home
  printf 'note: deploy window moved to Thursday, tell the captain\n' > "$STDIN_FILE"

  status_response "$RESPONSE" 0.9 note 0.7
  run_helper "$STATUS_TRIAGE" code out _err
  expect_code 0 "$code" "a high captain_relevant Noul exits 0"
  assert_equals escalate "$out" "noul 0.9 escalates"

  status_response "$RESPONSE" 0.5 note 0.7
  run_helper "$STATUS_TRIAGE" code out _err
  assert_equals escalate "$out" "noul at the 0.5 floor still escalates"

  status_response "$RESPONSE" 0.49 note 0.7
  run_helper "$STATUS_TRIAGE" code out _err
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
  local code out _err body
  fresh_home
  write_task_meta fmtask ship "$ROOT"
  printf 'resolved [key=api]: took A\n' > "$STDIN_FILE"
  status_response "$RESPONSE" 0.2 resolved 0.8
  run_helper "$STATUS_TRIAGE" code out _err "${FREE_TEXT_ARGS[@]}"
  expect_code 0 "$code" "resolved: line consult exits 0"
  body=$(cat "$LOG/body")
  assert_contains "$body" '"captain_relevant"' "the request carries the Noul question"
  assert_contains "$body" '"noul"' "the request carries the noul type"
  assert_contains "$body" '"verb"' "the request carries the verb Choice for the audit trail"
  assert_contains "$body" 'needs-decision' "the Choice criteria name the corpus verb set"
  assert_contains "$body" 'resolved [key=api]: took A' "the state is the status line itself"
  pass "the status consult sends the corpus question pair with only the line as state"
}

test_status_triage_redacts_credentials() {
  local code out _err password secret token api_key
  fresh_home
  password='hunter2'
  secret='secret-value'
  token='token-value'
  api_key='api-key-value'
  write_task_meta fmtask ship "$ROOT"
  printf 'note: DB_PASSWORD=%s CLIENT_SECRET: %s access_token=%s API key: %s\n' \
    "$password" "$secret" "$token" "$api_key" > "$STDIN_FILE"
  status_response "$RESPONSE" 0.2 note 0.7
  run_helper "$STATUS_TRIAGE" code out _err "${FREE_TEXT_ARGS[@]}"
  expect_code 0 "$code" "a credential-bearing note line is still classified"
  jq -e --arg password "$password" --arg secret "$secret" --arg token "$token" --arg api_key "$api_key" '
    .state as $state
    | ([$password, $secret, $token, $api_key] | all(.[]; . as $credential | $state | contains($credential) | not))
      and ($state | startswith("note: [redacted]"))
  ' "$LOG/body" >/dev/null || fail "a credential reached the Jev request body unredacted"
  jq -e --arg password "$password" --arg secret "$secret" --arg token "$token" --arg api_key "$api_key" '
    .line_excerpt as $excerpt
    | ([$password, $secret, $token, $api_key] | all(.[]; . as $credential | $excerpt | contains($credential) | not))
      and ($excerpt | startswith("note: [redacted]"))
  ' "$HOME_DIR/state/jev-status-triage.jsonl" >/dev/null \
    || fail "a credential reached the Jev audit excerpt unredacted"
  pass "status triage redacts credential fields before sending and auditing"
}

test_status_triage_redacts_escaped_quotes_and_github_tokens() {
  local code out _err
  fresh_home
  write_task_meta fmtask ship "$ROOT"
  printf '%s\n' 'note: DB_PASSWORD="alpha\"omega" then gho_oauthSECRET1 ghu_userSECRET2 ghs_srvSECRET3 ghr_refSECRET4 ghp_patSECRET5' > "$STDIN_FILE"
  status_response "$RESPONSE" 0.2 note 0.7
  run_helper "$STATUS_TRIAGE" code out _err "${FREE_TEXT_ARGS[@]}"
  expect_code 0 "$code" "a line carrying an escaped-quote password and GitHub tokens is still classified"
  for secret in alpha omega oauthSECRET1 userSECRET2 srvSECRET3 refSECRET4 patSECRET5; do
    jq -e --arg s "$secret" '.state | contains($s) | not' "$LOG/body" >/dev/null \
      || fail "secret fragment $secret reached the Jev request body: $(cat "$LOG/body")"
    grep -q -- "$secret" "$HOME_DIR/state/jev-status-triage.jsonl" \
      && fail "secret fragment $secret reached the Jev audit record"
  done
  pass "escaped-quote credential values and every GitHub token prefix are redacted before sending and auditing"
}

test_supervision_redacts_authorization_header_values() {
  local helper code out _err basic negotiate excerpt_field audit_path state_text compact fn
  basic='QWxhZGRpbjpvcGVuIHNlc2FtZQ=='
  negotiate='YIIGgAYJKoZIhvcSAQICAQBuggZ8MIIGeA=='
  state_text=$(printf 'note: captured response headers\nAuthorization: Basic %s\nauthorization: Negotiate %s\n' "$basic" "$negotiate")

  for fn in fm_jev_compact_state fm_jev_supervision_state; do
    compact=$(FM_HOME="$HOME_DIR" bash -c '
      . "$1/bin/fm-jev-lib.sh"
      case "$2" in
        fm_jev_compact_state) fm_jev_compact_state "$3" ;;
        fm_jev_supervision_state) fm_jev_supervision_state pane-tail "$3" 1 ;;
      esac
    ' _ "$ROOT" "$fn" "$state_text") || fail "$fn rejected authorization-bearing state"
    for secret in "$basic" "$negotiate"; do
      case "$compact" in *"$secret"*) fail "$fn exposed an Authorization header value" ;; esac
    done
    case "$compact" in *'[redacted]'*) ;; *) fail "$fn did not mark Authorization values redacted" ;; esac
  done

  for helper in "$STATUS_TRIAGE" "$WEDGE_CHECK"; do
    fresh_home
    write_task_meta fmtask ship "$ROOT"
    case "$helper" in
      "$STATUS_TRIAGE")
        excerpt_field=line_excerpt
        audit_path="$HOME_DIR/state/jev-status-triage.jsonl"
        printf '%s\n' "$state_text" > "$STDIN_FILE"
        status_response "$RESPONSE" 0.2 note 0.7
        ;;
      *)
        excerpt_field=tail_excerpt
        audit_path="$HOME_DIR/state/jev-wedge-check.jsonl"
        printf '%s\n' "$state_text" > "$STDIN_FILE"
        wedge_response "$RESPONSE" 0.2 idle_finished 0.8
        ;;
    esac
    run_helper "$helper" code out _err "${FREE_TEXT_ARGS[@]}"
    expect_code 0 "$code" "$(basename "$helper") handles Authorization headers in eligible free text"
    jq -e --arg basic "$basic" --arg negotiate "$negotiate" '
      .state as $state
      | ($state | type == "string")
        and ([$basic, $negotiate] | all(.[]; . as $secret | $state | contains($secret) | not))
        and ($state | contains("[redacted]"))
    ' "$LOG/body" >/dev/null || fail "an Authorization value reached the $(basename "$helper") request body"
    jq -e --arg field "$excerpt_field" --arg basic "$basic" --arg negotiate "$negotiate" '
      .[$field] as $excerpt
      | ([$basic, $negotiate] | all(.[]; . as $secret | $excerpt | contains($secret) | not))
        and ($excerpt | contains("[redacted]"))
    ' "$audit_path" >/dev/null \
      || fail "an Authorization value reached the $(basename "$helper") local excerpt"
  done
  pass "Authorization values are redacted from compact state, supervision state, helper requests, and excerpts"
}

# The captain's data boundary: free text leaves the home only for a firstmate
# repository task in the primary home. Each other side of the line - no task
# named, a secondmate home, another project, or an unrelated repo spoofing the
# firstmate origin - sends only structured facts and records no excerpt.
test_supervision_payload_boundary() {
  local helper kind marker code out _err case_name other spoofed root_origin
  other="$TMP_ROOT/other-project"
  spoofed="$TMP_ROOT/spoofed-origin"
  rm -rf "$other" "$spoofed"
  mkdir -p "$other" "$spoofed"
  git -C "$other" init -q
  git -C "$other" remote add origin https://example.invalid/someone/website.git
  git -C "$spoofed" init -q
  root_origin=$(git -C "$ROOT" config --get remote.origin.url) || fail "the firstmate test checkout has no origin to spoof"
  git -C "$spoofed" remote add origin "$root_origin"
  for helper in "$STATUS_TRIAGE" "$WEDGE_CHECK"; do
    case "$helper" in
      "$STATUS_TRIAGE") marker='MARKERWORD'; printf 'note: MARKERWORD please tell the captain?\n' > "$STDIN_FILE"
        status_response "$RESPONSE" 0.2 note 0.7; kind='status-line' ;;
      *) marker='MARKERWORD'; printf 'MARKERWORD compiling\nerror: rate limit reached\n$ \n' > "$STDIN_FILE"
        wedge_response "$RESPONSE" 0.2 idle_finished 0.8; kind='pane-tail' ;;
    esac

    fresh_home
    write_task_meta fmtask ship "$ROOT"
    run_helper "$helper" code out _err "${FREE_TEXT_ARGS[@]}"
    expect_code 0 "$code" "$kind: an eligible firstmate task consult succeeds"
    jq -e --arg m "$marker" '.state | type == "string" and contains($m)' "$LOG/body" >/dev/null \
      || fail "$kind: an eligible firstmate-repo task in the primary home did not send its compacted text"
    grep -q '"payload":"free-text"' "$HOME_DIR/state"/jev-*.jsonl \
      || fail "$kind: the eligible audit record does not name its free-text payload"

    for case_name in no-task secondmate-home secondmate-task other-project spoofed-origin; do
      fresh_home
      write_task_meta fmtask ship "$ROOT"
      case "$case_name" in
        no-task) run_helper "$helper" code out _err ;;
        secondmate-home)
          printf 'sm-test\n' > "$HOME_DIR/.fm-secondmate-home"
          run_helper "$helper" code out _err "${FREE_TEXT_ARGS[@]}" ;;
        secondmate-task)
          write_task_meta fmtask secondmate "$ROOT"
          run_helper "$helper" code out _err "${FREE_TEXT_ARGS[@]}" ;;
        other-project)
          write_task_meta fmtask ship "$other"
          run_helper "$helper" code out _err "${FREE_TEXT_ARGS[@]}" ;;
        spoofed-origin)
          write_task_meta fmtask ship "$spoofed"
          run_helper "$helper" code out _err "${FREE_TEXT_ARGS[@]}" ;;
      esac
      expect_code 0 "$code" "$kind/$case_name: a structured consult still yields a verdict"
      jq -e --arg k "$kind" '.state | type == "object" and .payload == "structured" and .kind == $k' "$LOG/body" >/dev/null \
        || fail "$kind/$case_name: the request state is not the structured facts object: $(cat "$LOG/body")"
      grep -q "$marker" "$LOG/body" && fail "$kind/$case_name: free text reached the Jev request body"
      grep -q "$marker" "$HOME_DIR/state"/jev-*.jsonl && fail "$kind/$case_name: free text reached the audit record"
      grep -q '"payload":"structured"' "$HOME_DIR/state"/jev-*.jsonl \
        || fail "$kind/$case_name: the audit record does not name its structured payload"
    done
  done
  pass "free text requires trusted project identity; a spoofed origin stays structured-only"
}

test_supervision_accepts_shared_git_common_directory() {
  local primary linked
  fresh_home
  primary="$TMP_ROOT/trusted-checkout"
  linked="$TMP_ROOT/trusted-worktree"
  mkdir -p "$primary"
  git -C "$primary" init -q
  printf 'trusted identity\n' > "$primary/identity.txt"
  git -C "$primary" add identity.txt
  git -C "$primary" -c user.name=Firstmate -c user.email=firstmate@example.invalid \
    -c commit.gpgsign=false commit -qm 'seed trusted checkout'
  git -C "$primary" worktree add -q --detach "$linked" HEAD
  write_task_meta fmtask ship "$linked"
  FM_HOME="$HOME_DIR" bash -c '
    . "$1/bin/fm-jev-lib.sh"
    _FM_JEV_ROOT=$2
    fm_jev_supervision_free_text_ok "$3/state" fmtask
  ' _ "$ROOT" "$primary" "$HOME_DIR" \
    || fail "a linked project worktree with the trusted common directory was rejected"
  pass "a linked worktree sharing the code root's Git common directory is eligible"
}

# A structured status payload names its verb only from the Firstmate status
# vocabulary: a nonstandard leading token is itself free text, so it maps to
# "other" and nothing from the line reaches the request or the audit record.
test_structured_status_verb_is_vocabulary_only() {
  local code out _err fragment
  fresh_home
  write_task_meta fmtask secondmate "$ROOT"
  printf 'acme-confidential-merger: draft ready for contoso\n' > "$STDIN_FILE"
  status_response "$RESPONSE" 0.2 note 0.7
  run_helper "$STATUS_TRIAGE" code out _err "${FREE_TEXT_ARGS[@]}"
  expect_code 0 "$code" "a nonstandard-verb line from a non-eligible task is still classified"
  jq -e '.state | type == "object" and .payload == "structured" and .verb == "other"' "$LOG/body" >/dev/null \
    || fail "a nonstandard verb was not sent as \"other\": $(cat "$LOG/body")"
  for fragment in acme confidential merger draft contoso; do
    grep -qi -- "$fragment" "$LOG/body" && fail "line text '$fragment' reached the Jev request body"
    grep -qi -- "$fragment" "$HOME_DIR/state/jev-status-triage.jsonl" && fail "line text '$fragment' reached the audit record"
  done

  fresh_home
  write_task_meta fmtask secondmate "$ROOT"
  printf 'note: draft ready for contoso\n' > "$STDIN_FILE"
  run_helper "$STATUS_TRIAGE" code out _err "${FREE_TEXT_ARGS[@]}"
  expect_code 0 "$code" "a known-verb line from a non-eligible task is still classified"
  jq -e '.state.verb == "note"' "$LOG/body" >/dev/null \
    || fail "a known status verb was not sent as itself: $(cat "$LOG/body")"
  grep -qi contoso "$LOG/body" && fail "line text reached the Jev request body alongside a known verb"
  pass "structured status payloads carry only a vocabulary verb, never a free-text leading token"
}

test_wedge_check_caps_free_text_to_the_pane_end() {
  local code out _err tail_text
  fresh_home
  write_task_meta fmtask ship "$ROOT"
  tail_text="HEADMARK$(printf '%9000s' '' | tr ' ' 'x')TAILMARK"
  printf '%s\n' "$tail_text" > "$STDIN_FILE"
  wedge_response "$RESPONSE" 0.2 idle_finished 0.8
  run_helper "$WEDGE_CHECK" code out _err "${FREE_TEXT_ARGS[@]}"
  expect_code 0 "$code" "a pane tail past the state cap is capped, not refused"
  jq -e '.state | (length <= 4000) and contains("TAILMARK") and (contains("HEADMARK") | not)' "$LOG/body" >/dev/null \
    || fail "the free-text pane state is not capped to its last characters"
  pass "free-text pane tails are size-capped to their most recent characters"
}

test_helpers_honor_dotenv_timeout() {
  local helper code out _err
  for helper in "$STATUS_TRIAGE" "$WEDGE_CHECK"; do
    fresh_home
    printf 'JEV_TIMEOUT=1\n' > "$HOME_DIR/.env"
    printf 'note: anything\n' > "$STDIN_FILE"
    status_response "$RESPONSE" 0.2 note 0.7
    jq '.answers.stuck = {type: "noul", noul: 0.2}' "$RESPONSE" > "$TMP_ROOT/edited.json" && mv "$TMP_ROOT/edited.json" "$RESPONSE"
    run_helper "$helper" code out _err
    expect_code 0 "$code" "$(basename "$helper") consult with a .env timeout"
    assert_equals 1 "$(cat "$LOG/max_time")" "$(basename "$helper") honors JEV_TIMEOUT from \$FM_HOME/.env"
  done
  fresh_home
  printf 'JEV_TIMEOUT=1\n' > "$HOME_DIR/.env"
  FM_HOME="$HOME_DIR" bash -c '
    . "$1/bin/fm-classify-lib.sh"
    unset JEV_TIMEOUT
    FM_JEV_SUPERVISION_TIMEOUT_SECS=3
    fm_jev_supervision_cycle_reset
    _fm_jev_supervision_cycle_prepare || exit 1
    [ "$_FM_JEV_SUPERVISION_CYCLE_CALL_HTTP_SECS" = 1 ]
  ' _ "$ROOT" || fail "the cycle bound ignored JEV_TIMEOUT from \$FM_HOME/.env"
  pass "the helpers and the cycle bound read JEV_TIMEOUT from the environment or \$FM_HOME/.env"
}

test_status_triage_failure_is_fail_closed() {
  local code out _err
  fresh_home
  printf 'progress: halfway through the refactor\n' > "$STDIN_FILE"

  FAKE_CURL_FAIL=1 run_helper "$STATUS_TRIAGE" code out _err
  [ "$code" -ne 0 ] || fail "a transport failure must exit nonzero"
  [ -z "$out" ] || fail "a transport failure must print no verdict, got: $out"

  status_response "$RESPONSE" 0.9 note 0.7
  FAKE_CURL_HTTP=500 run_helper "$STATUS_TRIAGE" code out _err
  [ "$code" -ne 0 ] || fail "a non-200 must exit nonzero"
  [ -z "$out" ] || fail "a non-200 must print no verdict, got: $out"

  for bad in '"nope"' '"0.9"' '1.4' '-0.2' 'null' 'true'; do
    jq --argjson n "$bad" '.answers.captain_relevant.noul = $n' "$RESPONSE" \
      > "$TMP_ROOT/edited.json" && mv "$TMP_ROOT/edited.json" "$RESPONSE"
    run_helper "$STATUS_TRIAGE" code out _err
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
  local code out _err
  fresh_home
  printf 'quota exceeded\nRetrying in 5m\n' > "$STDIN_FILE"

  wedge_response "$RESPONSE" 0.69 genuinely_stuck 0.74
  run_helper "$WEDGE_CHECK" code out _err
  expect_code 0 "$code" "a high stuck Noul exits 0"
  assert_equals escalate "$out" "noul 0.69 escalates"

  # The corpus counterexample shape: a confident stuck CHOICE with a low Noul.
  # The verdict must ignore the Choice - the Noul alone gates.
  wedge_response "$RESPONSE" 0.31 genuinely_stuck 0.74
  run_helper "$WEDGE_CHECK" code out _err
  expect_code 0 "$code" "a low stuck Noul exits 0"
  assert_equals suppress "$out" "choice 0.74 stuck but noul 0.31 suppresses"

  wedge_response "$RESPONSE" 0.5 genuinely_stuck 0.6
  run_helper "$WEDGE_CHECK" code out _err
  assert_equals escalate "$out" "noul at the 0.5 floor still escalates"

  assert_present "$HOME_DIR/state/jev-wedge-check.jsonl" "every call appends the JSONL record"
  jq -e '.purpose == "wedge-check" and .advisory == true and .second_opinion == true
      and .status == "escalate" and .noul == 0.5' \
    "$HOME_DIR/state/jev-wedge-check.jsonl" >/dev/null \
    || fail "the JSONL record does not carry the advisory verdict fields: $(cat "$HOME_DIR/state/jev-wedge-check.jsonl")"
  pass "wedge check gates on the stuck Noul alone, never the state Choice"
}

test_wedge_check_question_shape_and_tail_only() {
  local code out _err body
  fresh_home
  write_task_meta fmtask ship "$ROOT"
  printf 'some pane text\n$ \n' > "$STDIN_FILE"
  wedge_response "$RESPONSE" 0.2 idle_finished 0.8
  run_helper "$WEDGE_CHECK" code out _err "${FREE_TEXT_ARGS[@]}"
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
  local code out _err
  fresh_home
  printf 'dead prompt\n' > "$STDIN_FILE"

  FAKE_CURL_FAIL=1 run_helper "$WEDGE_CHECK" code out _err
  [ "$code" -ne 0 ] || fail "a transport failure must exit nonzero"
  [ -z "$out" ] || fail "a transport failure must print no verdict, got: $out"

  wedge_response "$RESPONSE" 0.9 genuinely_stuck 0.8
  FAKE_CURL_HTTP=503 run_helper "$WEDGE_CHECK" code out _err
  [ "$code" -ne 0 ] || fail "a non-200 must exit nonzero"
  [ -z "$out" ] || fail "a non-200 must print no verdict, got: $out"

  jq 'del(.answers.stuck)' "$RESPONSE" > "$TMP_ROOT/edited.json" && mv "$TMP_ROOT/edited.json" "$RESPONSE"
  run_helper "$WEDGE_CHECK" code out _err
  [ "$code" -ne 0 ] || fail "a missing stuck answer must exit nonzero"
  [ -z "$out" ] || fail "a missing stuck answer must print no verdict, got: $out"
  pass "every wedge-check failure is fail-closed: nonzero exit, no verdict"
}

test_supervision_cycle_budget_and_breaker() {
  local state start_ms finished_ms elapsed_ms file record rc n call_count line saved_path=$PATH
  [ "$FM_JEV_SUPERVISION_CYCLE_BUDGET_SECS" = 6 ] || fail "the default cycle budget is not 6 seconds"
  state="$TMP_ROOT/cycle-state"
  mkdir -p "$state"
  reset_log
  export FM_JEV_STATUS_TRIAGE_BIN="$STATUS_TRIAGE"
  export FM_JEV_SUPERVISION_TIMEOUT_SECS=1
  export FM_JEV_SUPERVISION_CYCLE_BUDGET_SECS=6
  export FM_HOME="$HOME_DIR"
  export FM_STATE_OVERRIDE="$HOME_DIR/state"
  export TYPESAFE_API_KEY="$TS_KEY"
  export FAKE_CURL_LOG="$LOG"
  export FAKE_CURL_HANG=1
  export PATH="$FAKEBIN:$BASE_PATH"
  fm_jev_supervision_cycle_reset
  start_ms=$(_fm_jev_supervision_now_ms)
  n=1
  while [ "$n" -le 4 ]; do
    file="$state/task-$n.status"
    : > "$file"
    line=1
    while [ "$line" -le 8 ]; do
      printf 'note: routine line %s for task %s\n' "$line" "$n" >> "$file"
      line=$((line + 1))
    done
    printf 'failed: deterministic failure for task %s\n' "$n" >> "$file"
    record=''
    status_span_first_actionable_record "$file" 0 record '' jev
    rc=$?
    [ "$rc" -eq 0 ] || fail "the deterministic failure for task $n was not actionable"
    case "$record" in *"failed: deterministic failure for task $n"*) ;; *) fail "the deterministic result was lost: $record" ;; esac
    n=$((n + 1))
  done
  finished_ms=$(_fm_jev_supervision_now_ms)
  elapsed_ms=$((finished_ms - start_ms))
  [ "$elapsed_ms" -lt 6000 ] || fail "one Jev cycle took ${elapsed_ms}ms past its 6000ms budget"
  call_count=$(wc -l < "$LOG/calls" | tr -d '[:space:]')
  [ "$call_count" = 1 ] || fail "the black-holed endpoint received $call_count calls in one cycle"

  export FAKE_CURL_HANG=0
  status_response "$RESPONSE" 0.2 note 0.7
  export FAKE_CURL_RESPONSE="$RESPONSE"
  printf 'note: next cycle consult\n' > "$state/next.status"
  fm_jev_supervision_cycle_reset
  record=''
  status_span_first_actionable_record "$state/next.status" 0 record '' jev
  rc=$?
  [ "$rc" -eq 1 ] || fail "a valid low Noul changed the deterministic note verdict"
  call_count=$(wc -l < "$LOG/calls" | tr -d '[:space:]')
  [ "$call_count" = 2 ] || fail "the next cycle did not reset the Jev breaker"
  unset FM_JEV_STATUS_TRIAGE_BIN FM_JEV_SUPERVISION_TIMEOUT_SECS \
    FM_JEV_SUPERVISION_CYCLE_BUDGET_SECS FM_HOME FM_STATE_OVERRIDE \
    TYPESAFE_API_KEY FAKE_CURL_LOG FAKE_CURL_HANG FAKE_CURL_RESPONSE
  PATH=$saved_path
  export PATH
  pass "one Jev timeout trips the cycle breaker, preserves deterministic surfaces, and resets next cycle"
}

# wedge_class_response <out-file> <noul> <class> <class-confidence>
#   a wedge answer that also carries the stuck-class Choice.
wedge_class_response() {
  local f=$1
  shift
  cat > "$f" <<JSON
{ "model": "jev-1.13.0",
  "answers": {
    "state": { "type": "choice", "choice": "genuinely_stuck", "confidence": 0.7,
      "probabilities": { "idle_finished": 0.1, "working_busy": 0.2, "genuinely_stuck": 0.7 } },
    "verdict": { "type": "choice", "choice": "$2", "confidence": $3 },
    "stuck": { "type": "noul", "noul": $1 }
  },
  "usage": { "input_tokens": 40, "output_tokens": 12 } }
JSON
}

test_wedge_check_reports_stuck_classes() {
  local code out _err body
  fresh_home
  printf 'npm test\nnpm test\nnpm test\n$ \n' > "$STDIN_FILE"

  wedge_class_response "$RESPONSE" 0.7 looping 0.72
  run_helper "$WEDGE_CHECK" code out _err --class
  expect_code 0 "$code" "a classed escalate exits 0"
  assert_equals 'escalate looping' "$out" "an act-band class follows the verdict"
  body=$(cat "$LOG/body")
  for class in progressing looping rate_limited stalled unclear; do
    assert_contains "$body" "\"$class\"" "the request offers the $class class"
  done

  wedge_class_response "$RESPONSE" 0.7 rate_limited 0.4
  run_helper "$WEDGE_CHECK" code out _err --class
  assert_equals 'escalate rate_limited' "$out" "a review-band class still labels the warning"

  wedge_class_response "$RESPONSE" 0.7 stalled 0.2
  run_helper "$WEDGE_CHECK" code out _err --class
  assert_equals 'escalate unclear' "$out" "a class below the review band reads as unclear"

  wedge_class_response "$RESPONSE" 0.7 bogus 0.9
  run_helper "$WEDGE_CHECK" code out _err --class
  assert_equals 'escalate unclear' "$out" "an unknown class reads as unclear"

  wedge_response "$RESPONSE" 0.7 genuinely_stuck 0.7
  run_helper "$WEDGE_CHECK" code out _err --class
  expect_code 0 "$code" "a missing class never fails the call"
  assert_equals 'escalate unclear' "$out" "a missing class reads as unclear"

  wedge_class_response "$RESPONSE" 0.2 progressing 0.8
  run_helper "$WEDGE_CHECK" code out _err --class
  assert_equals 'suppress progressing' "$out" "the Noul alone still gates suppress"

  wedge_class_response "$RESPONSE" 0.7 looping 0.72
  run_helper "$WEDGE_CHECK" code out _err
  assert_equals escalate "$out" "without --class the one-word verdict contract is unchanged"
  jq -e 'select(.class != null) | .class == "looping" and .band == "act" and .class_confidence == 0.72' \
    "$HOME_DIR/state/jev-wedge-check.jsonl" >/dev/null \
    || fail "the JSONL record does not carry the class and band: $(tail -1 "$HOME_DIR/state/jev-wedge-check.jsonl")"
  pass "the wedge check reports progressing, looping, rate_limited, stalled, and unclear without changing its gate"
}

test_wedge_check_warning_window() {
  local code out _err ledger args
  fresh_home
  printf 'error: 429 rate_limit_error\n$ \n' > "$STDIN_FILE"
  args=(--class --task wtask --state-dir "$HOME_DIR/state")
  ledger="$HOME_DIR/state/wtask.jev-wedge-warned"

  wedge_class_response "$RESPONSE" 0.8 rate_limited 0.8
  run_helper "$WEDGE_CHECK" code out _err "${args[@]}"
  assert_equals 'escalate rate_limited' "$out" "the first warning escalates"
  [ ! -e "$ledger" ] || fail "a verdict alone recorded a warning before any wake went out"

  code=0
  FM_HOME="$HOME_DIR" "$WEDGE_CHECK" --mark-warned rate_limited --task wtask --state-dir "$HOME_DIR/state" \
    < /dev/null || code=$?
  expect_code 0 "$code" "marking a warning exits 0"
  run_helper "$WEDGE_CHECK" code out _err "${args[@]}"
  assert_equals 'held rate_limited' "$out" "the same class inside the hour is held"
  jq -e 'select(.status == "held")' "$HOME_DIR/state/jev-wedge-check.jsonl" >/dev/null \
    || fail "the held verdict is not in the audit log"

  wedge_class_response "$RESPONSE" 0.8 stalled 0.8
  run_helper "$WEDGE_CHECK" code out _err "${args[@]}"
  assert_equals 'escalate stalled' "$out" "a different class escalates at once"

  wedge_class_response "$RESPONSE" 0.8 rate_limited 0.8
  run_helper "$WEDGE_CHECK" code out _err --class --task other --state-dir "$HOME_DIR/state"
  assert_equals 'escalate rate_limited' "$out" "another task is not held by this task's warning"
  run_helper "$WEDGE_CHECK" code out _err --task wtask --state-dir "$HOME_DIR/state"
  assert_equals escalate "$out" "without --class nothing is held"
  FM_JEV_WEDGE_WARN_EVERY_SECS=0 run_helper "$WEDGE_CHECK" code out _err "${args[@]}"
  assert_equals 'escalate rate_limited' "$out" "a zero window turns the hold off"

  printf 'rate_limited %s\n' "$(( $(date +%s) - 3700 ))" > "$ledger"
  run_helper "$WEDGE_CHECK" code out _err "${args[@]}"
  assert_equals 'escalate rate_limited' "$out" "a warning older than the window no longer holds"

  FM_HOME="$HOME_DIR" "$WEDGE_CHECK" --mark-warned stalled --task wtask --state-dir "$HOME_DIR/state" < /dev/null
  FM_HOME="$HOME_DIR" "$WEDGE_CHECK" --mark-warned stalled --task wtask --state-dir "$HOME_DIR/state" < /dev/null
  [ "$(grep -c '^stalled ' "$ledger")" = 1 ] || fail "the ledger repeats a class: $(cat "$ledger")"
  grep -q '^rate_limited ' "$ledger" || fail "marking one class dropped another: $(cat "$ledger")"
  code=0
  FM_HOME="$HOME_DIR" "$WEDGE_CHECK" --mark-warned bogus --task wtask --state-dir "$HOME_DIR/state" \
    < /dev/null 2>/dev/null || code=$?
  expect_code 2 "$code" "an unknown class is a usage error"
  pass "at most one warning per hour per task and stuck class, recorded only by the caller after its wake"
}

test_wedge_check_idle_fact_and_redaction() {
  local code out _err token
  fresh_home
  printf 'Retrying the request now\nRetrying the request now\nRetrying the request now\n$ \n' > "$STDIN_FILE"
  wedge_class_response "$RESPONSE" 0.7 looping 0.7
  run_helper "$WEDGE_CHECK" code out _err --idle-secs 600
  jq -e '.state.idle_secs == 600 and .state.repeated_line_max == 3 and (.state | tostring | contains("Retrying") | not)' \
    "$LOG/body" >/dev/null || fail "the structured state lacks the idle age or repeat count: $(cat "$LOG/body")"

  token='a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0'
  write_task_meta fmtask ship "$ROOT"
  printf 'pushing with %s\nusing token abcdefghij0123456789xyz\n$ \n' "$token" > "$STDIN_FILE"
  run_helper "$WEDGE_CHECK" code out _err "${FREE_TEXT_ARGS[@]}" --idle-secs 600
  jq -e --arg t "$token" '.state | type == "string" and startswith("Supervisor facts: the pane has been idle for 600s")
      and (contains($t) | not) and (contains("abcdefghij0123456789xyz") | not) and contains("[redacted]")' \
    "$LOG/body" >/dev/null || fail "free-text state leaked a long token or lost the idle fact: $(cat "$LOG/body")"

  printf '%9000s' '' | tr ' ' 'y' > "$STDIN_FILE"
  run_helper "$WEDGE_CHECK" code out _err "${FREE_TEXT_ARGS[@]}" --idle-secs 600
  jq -e '.state | length <= 4000' "$LOG/body" >/dev/null \
    || fail "the idle fact pushed the free-text state past its cap"
  pass "the wedge check adds the idle age, counts repeats without text, and masks long tokens"
}

test_wedge_consult_call_budget() {
  local stubdir rc n
  stubdir="$TMP_ROOT/wedge-budget"
  rm -rf "$stubdir"; mkdir -p "$stubdir"
  fm_install_jev_stubs "$stubdir"
  export FM_JEV_WEDGE_CHECK_BIN="$stubdir/jev-wedge-stub" FM_JEV_STUB_DIR="$stubdir" \
    FM_JEV_STUB_WEDGE_VERDICT=escalate FM_JEV_STUB_WEDGE_CLASS=stalled FM_JEV_WEDGE_CYCLE_MAX_CALLS=2
  # The earlier cycle-budget case unsets the shared budget; restore its default.
  FM_JEV_SUPERVISION_CYCLE_BUDGET_SECS=6
  fm_jev_supervision_cycle_reset
  n=1
  while [ "$n" -le 3 ]; do
    rc=0
    wedge_jev_consult "pane $n" task-a "$TMP_ROOT" 300 || rc=$?
    case "$n" in
      3) [ "$rc" -eq 1 ] && [ -z "$WEDGE_JEV_VERDICT" ] || fail "the third consult ran past the call budget" ;;
      *) [ "$rc" -eq 0 ] && [ "$WEDGE_JEV_VERDICT $WEDGE_JEV_CLASS" = 'escalate stalled' ] \
           || fail "consult $n did not report escalate stalled: $WEDGE_JEV_VERDICT $WEDGE_JEV_CLASS" ;;
    esac
    n=$((n + 1))
  done
  [ "$(wc -l < "$stubdir/wedge.args" | tr -d ' ')" = 2 ] || fail "the budget did not stop the helper call"
  fm_jev_supervision_cycle_reset
  wedge_jev_consult "pane again" task-a "$TMP_ROOT" || fail "the next cycle did not reset the call budget"
  FM_JEV_STUB_WEDGE_VERDICT=suppress
  wedge_jev_suppress "pane quiet" task-a "$TMP_ROOT" || fail "wedge_jev_suppress lost the suppress answer"
  FM_JEV_STUB_WEDGE_VERDICT=held
  ! wedge_jev_suppress "pane held" task-a "$TMP_ROOT" || fail "wedge_jev_suppress read held as suppress"
  unset FM_JEV_WEDGE_CHECK_BIN FM_JEV_STUB_DIR FM_JEV_STUB_WEDGE_VERDICT FM_JEV_STUB_WEDGE_CLASS FM_JEV_WEDGE_CYCLE_MAX_CALLS
  pass "the wedge consult spends at most its per-cycle call budget and resets next cycle"
}

test_status_triage_verdicts
test_status_triage_question_shape_and_line_only
test_status_triage_redacts_credentials
test_status_triage_redacts_escaped_quotes_and_github_tokens
test_supervision_redacts_authorization_header_values
test_supervision_payload_boundary
test_supervision_accepts_shared_git_common_directory
test_structured_status_verb_is_vocabulary_only
test_wedge_check_caps_free_text_to_the_pane_end
test_helpers_honor_dotenv_timeout
test_status_triage_failure_is_fail_closed
test_wedge_check_verdicts
test_wedge_check_question_shape_and_tail_only
test_wedge_check_failure_is_fail_closed
test_supervision_cycle_budget_and_breaker
test_wedge_check_reports_stuck_classes
test_wedge_check_warning_window
test_wedge_check_idle_fact_and_redaction
test_wedge_consult_call_budget
