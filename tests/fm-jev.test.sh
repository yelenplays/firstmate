#!/usr/bin/env bash
# Behavior tests for bin/fm-jev.sh, the lean worker-facing Jev command.
#
# A fake curl on PATH records the request body and the Authorization header
# read from file descriptor 3, then answers with a canned TypeSafe response.
# No case touches the network. Key discovery runs against disposable copies of
# the command inside temporary checkouts, so the operator's own home .env is
# never read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
HOME_DIR="$TMP_ROOT/home"
RESPONSE="$TMP_ROOT/response.json"
KEY='ts-cli-test-key-0123456789'
JEV="$ROOT/bin/fm-jev.sh"
mkdir -p "$LOG" "$HOME_DIR/state"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: records the stdin body and the fd 3 header, then answers with
# FAKE_CURL_RESPONSE and FAKE_CURL_HTTP.
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat > "${FAKE_CURL_LOG:?}/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE"

respond() {
  printf '%s\n' "$1" > "$RESPONSE"
}

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# run_jev <exit-var> <out-var> <err-var> [args...] - runs with the key in the
# environment and FM_HOME on the temporary home; stdin passes through.
run_jev() {
  local __code=$1 __out=$2 __err=$3 __o __e __c
  shift 3
  __o="$TMP_ROOT/run.out"
  __e="$TMP_ROOT/run.err"
  PATH="$FAKEBIN:$PATH" TYPESAFE_API_KEY="$KEY" FM_HOME="$HOME_DIR" \
    "$JEV" "$@" > "$__o" 2> "$__e"
  __c=$?
  printf -v "$__code" '%s' "$__c"
  printf -v "$__out" '%s' "$(cat "$__o")"
  printf -v "$__err" '%s' "$(cat "$__e")"
}

test_help_is_short_and_complete() {
  local out lines
  out=$("$JEV" --help)
  lines=$(printf '%s\n' "$out" | wc -l)
  lines=${lines// /}
  [ "$lines" -lt 15 ] || fail "--help is $lines lines, want under 15"
  for word in pick yes score batch --json --min ESCALATE TYPESAFE_API_KEY; do
    assert_contains "$out" "$word" "--help names $word"
  done
  pass "fm-jev.sh: --help is the whole interface in under 15 lines"
}

test_pick_answers_one_line() {
  local code out err
  reset_log
  respond '{"model":"jev-1.13.0","answers":{"vault":{"type":"choice","choice":"PlacementWiki","confidence":0.94,"probabilities":{"PlacementWiki":0.96,"FinanzWiki":0.04}}},"usage":{"input_tokens":120,"output_tokens":9}}'
  run_jev code out err --id vault pick "topic: trainee hiring" "Which vault?" PlacementWiki "FinanzWiki=money and budgets"
  assert_equals "$code" 0 "a confident pick exits 0"
  assert_equals "$out" "vault: PlacementWiki p=0.96 conf=0.94" "a pick prints one TOON line"
  assert_equals "$err" "" "a confident pick prints nothing on stderr"
  assert_equals "$(jq -c '.questions.vault' "$LOG/body")" \
    '{"type":"choice","instructions":"Which vault?","criteria":{"PlacementWiki":"PlacementWiki","FinanzWiki":"money and budgets"}}' \
    "a pick becomes one choice question with label=meaning criteria"
  assert_equals "$(jq -r '.state' "$LOG/body")" "topic: trainee hiring" "the state is sent as a string"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY" "the key travels only as the fd 3 header"
  pass "fm-jev.sh: pick sends one choice question and prints one line"
}

test_yes_and_score_lines() {
  local code out err
  respond '{"answers":{"yes":{"type":"noul","noul":0.02}}}'
  run_jev code out err yes "diff touches docs only" "Does the diff change runtime code?"
  assert_equals "$code" 0 "a clear yes/no exits 0"
  assert_equals "$out" "yes: no p=0.02 conf=0.96" "yes/no confidence is estimated as 2*|p-0.5|"
  assert_equals "$(jq -c '.questions.yes' "$LOG/body")" \
    '{"type":"noul","instructions":"Does the diff change runtime code?"}' "yes becomes a noul question"

  respond '{"answers":{"score":{"type":"score","score":0.52,"confidence":0.81,"probabilities":{"0":0.1,"1":0.8,"2":0.1}}}}'
  run_jev code out err score "one flaky test quarantined" "How risky is merging?" routine "worth a look" incident
  assert_equals "$code" 0 "a confident score exits 0"
  assert_equals "$out" "score: worth a look s=0.52 p=0.8 conf=0.81" "a score names its most probable level"
  assert_equals "$(jq -c '.questions.score.criteria' "$LOG/body")" '["routine","worth a look","incident"]' \
    "score levels are sent in order"

  respond '{"answers":{"score":{"type":"score","score":1.43,"confidence":0.6}}}'
  run_jev code out err score "one issue blocks progress" "How severe is it?" Cosmetic Workaround Blocking
  assert_equals "$code" 0 "a confident score without probabilities exits 0"
  assert_equals "$out" "score: Workaround s=1.43 conf=0.6" \
    "a probability-free score rounds to its fractional level index"
  pass "fm-jev.sh: yes and score print one line each"
}

test_batch_one_call_many_lines() {
  local code out err
  reset_log
  respond '{"answers":{"vault":{"choice":"A","confidence":0.9,"probabilities":{"A":0.95,"B":0.05}},"private":{"noul":0.9},"q3":{"score":0.1,"confidence":0.7,"probabilities":{"0":0.85,"1":0.15}}}}'
  run_jev code out err batch <<'JSON'
{"state":"s","questions":[
  {"id":"vault","type":"pick","q":"Which?","opts":["A=first","B=second"]},
  {"id":"private","type":"yes","q":"Private?"},
  {"type":"score","q":"How big?","opts":["small","large"]}]}
JSON
  assert_equals "$code" 0 "a confident batch exits 0"
  assert_equals "$out" "$(printf '%s\n' 'vault: A p=0.95 conf=0.9' 'private: yes p=0.9 conf=0.8' 'q3: small s=0.1 p=0.85 conf=0.7')" \
    "a batch prints one line per question in input order"
  assert_equals "$(jq -c '.questions | keys_unsorted' "$LOG/body")" '["vault","private","q3"]' \
    "a batch sends every question in one request"
  assert_equals "$(jq -c '.questions.vault.criteria' "$LOG/body")" '{"A":"first","B":"second"}' \
    "batch options accept label=meaning strings"
  pass "fm-jev.sh: batch asks several questions in one call"
}

test_escalation_exits_two() {
  local code out err
  respond '{"answers":{"pick":{"choice":"merge","confidence":0.31,"probabilities":{"merge":0.55,"hold":0.45}}}}'
  run_jev code out err pick "state" "Next?" merge hold
  assert_equals "$code" 2 "a low-confidence verdict exits 2"
  assert_equals "$out" "pick: ESCALATE conf=0.31 prior=merge -> decide yourself" "an escalation names its prior"

  respond '{"answers":{"pick":{"choice":"merge","confidence":0.8,"probabilities":{"merge":0.9,"hold":0.1}}}}'
  run_jev code out err --min 0.9 pick "state" "Next?" merge hold
  assert_equals "$code" 2 "--min raises the escalation floor"
  run_jev code out err pick --min 0.7 "state" "Next?" merge hold
  assert_equals "$code" 0 "--min after the command is accepted and can lower the bar"

  respond '{"answers":{"yes":{"noul":0.6}}}'
  run_jev code out err yes "state" "Done?"
  assert_equals "$code" 2 "a near-even yes/no escalates"
  assert_equals "$out" "yes: ESCALATE conf=0.2 prior=yes -> decide yourself" "a yes/no escalation reports its estimate"
  pass "fm-jev.sh: low confidence escalates with exit 2"
}

test_json_prints_raw_response() {
  local code out err raw
  raw='{"model":"jev-1.13.0","answers":{"yes":{"type":"noul","noul":0.97}},"usage":{"input_tokens":5,"output_tokens":2}}'
  respond "$raw"
  run_jev code out err --json yes "state" "Done?"
  assert_equals "$code" 0 "--json keeps the exit contract"
  assert_equals "$(printf '%s' "$out" | jq -c .)" "$raw" "--json prints the full response"
  pass "fm-jev.sh: --json prints the raw response"
}

test_errors_exit_one_with_one_line() {
  local code out err
  respond '{"error":"overloaded"}'
  FAKE_CURL_HTTP=529 run_jev code out err yes "state" "Done?"
  assert_equals "$code" 1 "a transport failure exits 1"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 "a transport failure prints one stderr line"
  assert_contains "$err" "http 529" "the reason names the failure"
  assert_contains "$err" "decide yourself" "the reason says what to do"
  assert_equals "$out" "" "a failure prints nothing on stdout"

  respond '{"answers":{}}'
  run_jev code out err yes "state" "Done?"
  assert_equals "$code" 1 "a missing answer is an error, never a silent low confidence"
  assert_contains "$err" "missing answer for yes" "the missing answer is named"

  for args in "frob" "pick s q only" "yes s" "--min 2 yes s q" "--id a.b yes s q"; do
    # shellcheck disable=SC2086 # Deliberate word splitting of the case args.
    run_jev code out err $args
    assert_equals "$code" 1 "usage error '$args' exits 1"
    assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 "usage error '$args' is one line"
  done
  run_jev code out err batch <<'JSON'
{"state":"s","questions":[{"id":"a","type":"yes","q":"x"},{"id":"a","type":"yes","q":"y"}]}
JSON
  assert_equals "$code" 1 "duplicate batch ids exit 1"
  assert_contains "$err" "ids must be unique" "the duplicate is explained"

  reset_log
  run_jev code out err batch <<'JSON'
{"state":"s","questions":[{"id":"q","type":"pick","q":"Choose?","opts":{"A":"first","B":"second"}}]}
JSON
  assert_equals "$code" 1 "batch object-map options are rejected"
  assert_contains "$err" "opts must be an array of strings" "the batch option format is explained"
  assert_absent "$LOG/body" "invalid batch options are never sent"
  pass "fm-jev.sh: errors exit 1 with one line"
}

test_privacy_guard_refuses_before_sending() {
  local code out err big
  respond '{"answers":{"yes":{"noul":0.9}}}'
  reset_log
  big=$(head -c 4097 /dev/zero | tr '\0' a)
  run_jev code out err yes "$big" "Done?"
  assert_equals "$code" 1 "state over 4096 bytes is refused"
  assert_contains "$err" "4096-byte cap" "the cap is named"
  assert_absent "$LOG/body" "an oversized state is never sent"

  respond '{"answers":{"yes":{"noul":0.97}}}'
  reset_log
  run_jev code out err yes "worktree for task-execution-receipt-retry is clean" "Done?"
  assert_equals "$code" 0 "a hyphenated task slug is accepted"
  assert_equals "$(jq -r '.state' "$LOG/body")" "worktree for task-execution-receipt-retry is clean" \
    "the complete task slug is sent unchanged"

  for token in sk-abcdefghijklmnop sk-or-abcdefghijklmnop ghp_abcdefghijklmnop github_pat_abcdefghijklmnop; do
    reset_log
    run_jev code out err yes "credential: $token" "Done?"
    assert_equals "$code" 1 "a token boundary before $token is refused"
    assert_contains "$err" "secret" "the token refusal says why"
    assert_absent "$LOG/body" "a secret-looking token is never sent"
  done

  run_jev code out err yes "GITHUB_TOKEN=ghp_abcdefghijklmnopqrst" "Done?"
  assert_equals "$code" 1 "secret-shaped state is refused"
  assert_contains "$err" "secret" "the refusal says why"
  assert_absent "$LOG/body" "a secret-shaped state is never sent"

  run_jev code out err pick "state" "Which?" "a=Bearer abcdef123456" b
  assert_equals "$code" 1 "secret-shaped option text is refused"
  assert_absent "$LOG/body" "secret-shaped option text is never sent"

  run_jev code out err yes "the key is $KEY" "Done?"
  assert_equals "$code" 1 "the live key value is refused"
  assert_not_contains "$err" "$KEY" "the refusal never echoes the key"
  assert_absent "$LOG/body" "the live key is never sent"
  pass "fm-jev.sh: privacy guard refuses before anything is sent"
}

# The guard must screen the same .env the library resolves the key from, even
# when the environment carries only the other route's key and FM_HOME is unset.
test_privacy_guard_screens_checkout_env_without_fm_home() {
  local code main
  respond '{"answers":{"yes":{"noul":0.97}}}'
  main="$TMP_ROOT/guard-checkout"
  make_checkout "$main"
  printf 'TYPESAFE_API_KEY=%s\n' "$KEY-checkout" > "$main/.env"
  reset_log
  env -u FM_HOME -u TYPESAFE_API_KEY OPENROUTER_API_KEY="$KEY-or" PATH="$FAKEBIN:$PATH" \
    "$main/bin/fm-jev.sh" yes "the key is $KEY-checkout" "Done?" \
    > "$TMP_ROOT/guard.out" 2> "$TMP_ROOT/guard.err"
  code=$?
  assert_equals "$code" 1 "the checkout .env key is refused with FM_HOME unset"
  assert_contains "$(cat "$TMP_ROOT/guard.err")" "Jev API key itself" "the refusal names the live key"
  assert_not_contains "$(cat "$TMP_ROOT/guard.err")" "$KEY-checkout" "the refusal never echoes the key"
  assert_absent "$LOG/body" "the checkout .env key is never sent"
  pass "fm-jev.sh: the guard screens the checkout .env the library resolves"
}

test_log_records_metadata_only() {
  local code out err line
  rm -f "$HOME_DIR/state/jev-calls.jsonl"
  respond '{"answers":{"yes":{"noul":0.97}},"usage":{"input_tokens":274,"output_tokens":20}}'
  run_jev code out err yes "secret-free state text" "Unique question text?"
  line=$(tail -n 1 "$HOME_DIR/state/jev-calls.jsonl")
  assert_equals "$(printf '%s' "$line" | jq -c '{purpose, http, usage, questions, escalated, exit}')" \
    '{"purpose":"worker-cli","http":"200","usage":{"in":274,"out":20},"questions":1,"escalated":0,"exit":0}' \
    "the call is logged with usage and outcome"
  assert_not_contains "$line" "secret-free state text" "the log never holds the state"
  assert_not_contains "$line" "Unique question text" "the log never holds the question"
  assert_not_contains "$line" "$KEY" "the log never holds the key"
  pass "fm-jev.sh: every call is logged as metadata only"
}

# make_checkout <dir> - a disposable copy of the command and its libraries.
make_checkout() {
  mkdir -p "$1/bin"
  cp "$ROOT/bin/fm-jev.sh" "$ROOT/bin/fm-jev-lib.sh" "$ROOT/bin/fm-env-lib.sh" "$1/bin/"
}

test_key_discovery_needs_no_env_setup() {
  local main wt nokey code out
  respond '{"answers":{"yes":{"noul":0.97}}}'

  # The command's own checkout .env, called from an unrelated directory.
  main="$TMP_ROOT/own-checkout"
  make_checkout "$main"
  printf 'TYPESAFE_API_KEY=%s\n' "$KEY-own" > "$main/.env"
  reset_log
  out=$(cd "$TMP_ROOT" && env -u FM_HOME -u TYPESAFE_API_KEY -u OPENROUTER_API_KEY PATH="$FAKEBIN:$PATH" \
    "$main/bin/fm-jev.sh" yes s q)
  assert_equals "$out" "yes: yes p=0.97 conf=0.94" "the checkout .env answers with no env setup"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY-own" "the checkout .env key is used"

  # A linked worktree of that checkout falls back to the main worktree .env.
  git -C "$main" init -q
  git -C "$main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  wt="$TMP_ROOT/pooled-worktree"
  git -C "$main" worktree add -q --detach "$wt"
  make_checkout "$wt"
  reset_log
  out=$(cd "$TMP_ROOT" && env -u FM_HOME -u TYPESAFE_API_KEY -u OPENROUTER_API_KEY PATH="$FAKEBIN:$PATH" \
    "$wt/bin/fm-jev.sh" yes s q)
  assert_equals "$out" "yes: yes p=0.97 conf=0.94" "a pooled worktree copy finds the main worktree .env"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY-own" "the main worktree key is used"

  # FM_HOME wins when its .env holds a key.
  printf 'TYPESAFE_API_KEY=%s\n' "$KEY-home" > "$HOME_DIR/.env"
  reset_log
  out=$(env -u TYPESAFE_API_KEY -u OPENROUTER_API_KEY FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" \
    "$wt/bin/fm-jev.sh" yes s q)
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY-home" "FM_HOME .env wins over the checkout"
  rm -f "$HOME_DIR/.env"

  # No key anywhere: one line, exit 1, nothing sent.
  nokey="$TMP_ROOT/no-key-checkout"
  make_checkout "$nokey"
  reset_log
  out=$(cd "$TMP_ROOT" && env -u FM_HOME -u TYPESAFE_API_KEY -u OPENROUTER_API_KEY PATH="$FAKEBIN:$PATH" \
    "$nokey/bin/fm-jev.sh" yes s q 2> "$TMP_ROOT/nokey.err")
  code=$?
  assert_equals "$code" 1 "a missing key exits 1"
  assert_contains "$(cat "$TMP_ROOT/nokey.err")" "TYPESAFE_API_KEY" "the missing key is named"
  assert_absent "$LOG/body" "nothing is sent without a key"
  pass "fm-jev.sh: key discovery works from any directory without env setup"
}

test_help_is_short_and_complete
test_pick_answers_one_line
test_yes_and_score_lines
test_batch_one_call_many_lines
test_escalation_exits_two
test_json_prints_raw_response
test_errors_exit_one_with_one_line
test_privacy_guard_refuses_before_sending
test_privacy_guard_screens_checkout_env_without_fm_home
test_log_records_metadata_only
test_key_discovery_needs_no_env_setup
