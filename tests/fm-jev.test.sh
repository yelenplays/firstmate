#!/usr/bin/env bash
# Behavior tests for bin/fm-jev.sh, the lean worker-facing Jev command.
#
# A fake curl on PATH records the request body and the Authorization header
# read from file descriptor 3, then answers with a canned TypeSafe response.
# No case touches the network. Key discovery runs against disposable copies of
# the command and temporary homes.
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
# Fake curl: records the request URL, stdin body, and fd 3 header, then answers
# with FAKE_CURL_RESPONSE and FAKE_CURL_HTTP.
set -u
out=''
url=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -X) shift 2; url=$1; shift ;;
    *) shift ;;
  esac
done
printf '%s' "$url" > "$FAKE_CURL_LOG/url"
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
  local invoke_key=${JEV_TEST_API_KEY-$KEY} invoke_home=${JEV_TEST_HOME:-$HOME_DIR}
  shift 3
  __o="$TMP_ROOT/run.out"
  __e="$TMP_ROOT/run.err"
  PATH="$FAKEBIN:$PATH" TYPESAFE_API_KEY="$invoke_key" FM_HOME="$invoke_home" \
    "$JEV" "$@" > "$__o" 2> "$__e"
  __c=$?
  printf -v "$__code" '%s' "$__c"
  printf -v "$__out" '%s' "$(cat "$__o")"
  printf -v "$__err" '%s' "$(cat "$__e")"
}

test_help_is_short_and_complete() {
  local out lines
  out=$("$JEV" yes --help)
  lines=$(printf '%s\n' "$out" | wc -l)
  lines=${lines// /}
  [ "$lines" -lt 15 ] || fail "--help is $lines lines, want under 15"
  for word in pick yes score batch --json ESCALATE TYPESAFE_API_KEY; do
    assert_contains "$out" "$word" "--help names $word"
  done
  assert_contains "$out" 'First "=" splits label from meaning' "--help documents option parsing"
  assert_contains "$out" "4096 bytes total" "--help documents the combined input cap"
  assert_not_contains "$out" "--id" "--help omits the removed id option"
  assert_not_contains "$out" "--min" "--help omits the removed threshold option"
  assert_not_contains "$out" "OPENROUTER_API_KEY" "--help does not advertise an OpenRouter route"
  assert_contains "$out" "config/typesafe-key" "--help documents the key-only file"
  assert_contains "$out" "same OS user with full file access" "--help explains worker filesystem access"
  assert_contains "$out" "mode 0600" "--help documents the key file mode"
  pass "fm-jev.sh: --help is the whole interface in under 15 lines"
}

test_pick_answers_one_line() {
  local code out err
  reset_log
  respond '{"model":"jev-1.13.0","answers":{"pick":{"type":"choice","choice":"PlacementWiki","confidence":0.94,"probabilities":{"PlacementWiki":0.96,"FinanzWiki":0.04}}},"usage":{"input_tokens":120,"output_tokens":9}}'
  run_jev code out err pick "topic: trainee hiring" "Which vault?" PlacementWiki "FinanzWiki=money and budgets"
  assert_equals "$code" 0 "a confident pick exits 0"
  assert_equals "$out" "pick: PlacementWiki p=0.96 conf=0.94" "a pick prints one TOON line"
  assert_equals "$err" "" "a confident pick prints nothing on stderr"
  assert_equals "$(jq -c '.questions.pick' "$LOG/body")" \
    '{"type":"choice","instructions":"Which vault?","criteria":{"PlacementWiki":"PlacementWiki","FinanzWiki":"money and budgets"}}' \
    "a pick becomes one choice question with label=meaning criteria"
  assert_equals "$(jq -r '.state' "$LOG/body")" "topic: trainee hiring" "the state is sent as a string"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY" "the key travels only as the fd 3 header"
  pass "fm-jev.sh: pick sends one choice question and prints one line"
}

test_option_meaning_splits_on_first_equals() {
  local code out err
  respond '{"answers":{"pick":{"choice":"A","confidence":0.9,"probabilities":{"A":0.95,"B":0.05}}}}'
  reset_log
  run_jev code out err pick "state" "Choose?" "A=first=second=third" B
  assert_equals "$code" 0 "equals in an option meaning does not change its label"
  assert_equals "$(jq -c '.questions.pick.criteria' "$LOG/body")" \
    '{"A":"first=second=third","B":"B"}' "only the first equals separates label and meaning"
  pass "fm-jev.sh: option text uses the first equals as delimiter"
}

test_cli_forces_typesafe_route() {
  local code out err
  respond '{"answers":{"yes":{"noul":0.97}}}'
  reset_log
  JEV_ROUTE=openrouter OPENROUTER_API_KEY='or-cli-test-key-0123456789' \
    run_jev code out err yes "route check" "Did the CLI stay on TypeSafe?"
  assert_equals "$code" 0 "a TypeSafe key answers despite an OpenRouter override"
  assert_equals "$(jq -r '.route' <(tail -n 1 "$HOME_DIR/state/jev-calls.jsonl"))" \
    "typesafe" "the worker command pins the TypeSafe route"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY" "the TypeSafe key reaches the request"
  pass "fm-jev.sh: OpenRouter settings cannot redirect the worker command"
}

test_cli_pins_typesafe_endpoint() {
  local code out err expected_url
  expected_url='https://api.typesafe.ai/v1/systemone'
  respond '{"answers":{"yes":{"noul":0.97}}}'

  reset_log
  JEV_URL='https://example.invalid/collect' JEV_BASE='https://example.invalid/base' \
    run_jev code out err yes "endpoint check" "Did the CLI keep its endpoint?"
  assert_equals "$code" 0 "a caller URL override does not block the request"
  assert_equals "$(cat "$LOG/url")" "$expected_url" "the CLI pins JEV_URL to the TypeSafe production endpoint"

  reset_log
  JEV_BASE='https://example.invalid/base' \
    run_jev code out err yes "endpoint check" "Did the CLI ignore JEV_BASE?"
  assert_equals "$code" 0 "a caller base override does not block the request"
  assert_equals "$(cat "$LOG/url")" "$expected_url" "the CLI ignores an environment JEV_BASE"

  printf 'JEV_URL=https://example.invalid/env-file\nJEV_BASE=https://example.invalid/env-file-base\n' > "$HOME_DIR/.env"
  reset_log
  run_jev code out err yes "endpoint check" "Did the CLI ignore .env endpoints?"
  assert_equals "$code" 0 "home .env endpoint overrides do not block the request"
  assert_equals "$(cat "$LOG/url")" "$expected_url" "the CLI ignores JEV_URL and JEV_BASE in the home .env"
  rm -f "$HOME_DIR/.env"
  pass "fm-jev.sh: destination settings cannot redirect the TypeSafe credential"
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
  respond '{"answers":{"vault":{"choice":"A","confidence":0.9,"probabilities":{"A":0.95,"B":0.04}},"private":{"noul":0.9},"q3":{"score":0.1,"confidence":0.7,"probabilities":{"0":0.85,"1":0.15}}}}'
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

test_batch_score_accepts_more_than_ten_levels() {
  local code out err
  respond '{"answers":{"levels":{"score":10,"confidence":0.9}}}'
  run_jev code out err batch <<'JSON'
{"state":"s","questions":[{"id":"levels","type":"score","q":"How large?","opts":["L0","L1","L2","L3","L4","L5","L6","L7","L8","L9","L10"]}]}
JSON
  assert_equals "$code" 0 "a batch score with eleven levels is accepted"
  assert_equals "$out" "levels: L10 s=10 conf=0.9" "the final offered score level remains selectable"
  assert_equals "$(jq '.questions.levels.criteria | length' "$LOG/body")" 11 \
    "all eleven score levels reach TypeSafe"
  pass "fm-jev.sh: batch score accepts more than ten levels"
}

test_escalation_exits_two() {
  local code out err
  respond '{"answers":{"pick":{"choice":"merge","confidence":0.31,"probabilities":{"merge":0.55,"hold":0.45}}}}'
  run_jev code out err pick "state" "Next?" merge hold
  assert_equals "$code" 2 "a low-confidence verdict exits 2"
  assert_equals "$out" "pick: ESCALATE conf=0.31 prior=merge -> decide yourself" "an escalation names its prior"

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
  run_jev code out err yes --json "state" "Done?"
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

  respond '{"answers":{"pick":{"choice":"C","confidence":0.9}}}'
  run_jev code out err pick "state" "Choose?" A B
  assert_equals "$code" 1 "a pick outside the offered options is rejected"
  assert_contains "$err" "unoffered option" "the malformed pick is explained"
  assert_equals "$out" "" "a malformed pick prints no answer"

  respond '{"answers":{"score":{"score":1,"confidence":0.9,"probabilities":{"0":0.05,"9":0.95}}}}'
  run_jev code out err score "state" "How severe?" low medium high
  assert_equals "$code" 1 "a score distribution with an out-of-range index is rejected"
  assert_contains "$err" "probability keys do not match offered levels" "the malformed score map is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 "an invalid score map prints one stderr line"
  assert_equals "$out" "" "a malformed score prints no answer"

  respond '{"answers":{"pick":{"choice":"A","confidence":0.9,"probabilities":{"A":0.1,"B":0.1,"unexpected":0.8}}}}'
  run_jev code out err pick "state" "Choose?" A B C
  assert_equals "$code" 1 "a pick map with an unoffered label is rejected"
  assert_contains "$err" "probability keys do not match offered options" "the malformed pick map is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 "an invalid pick map prints one stderr line"
  assert_equals "$out" "" "an invalid pick map prints no answer"

  respond '{"answers":{"pick":{"choice":"A","confidence":0.9,"probabilities":{"A":0.1,"B":0.1}}}}'
  run_jev code out err pick "state" "Choose?" A B
  assert_equals "$code" 1 "a pick map that does not sum to one is rejected"
  assert_contains "$err" "must sum to approximately 1" "the malformed pick sum is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 "an invalid pick sum prints one stderr line"
  assert_equals "$out" "" "an invalid pick sum prints no answer"

  respond '{"answers":{"score":{"score":1,"confidence":0.9,"probabilities":{"0":0.8,"1":0.1,"2":0.0}}}}'
  run_jev code out err score "state" "How severe?" low medium high
  assert_equals "$code" 1 "a score map that does not sum to one is rejected"
  assert_contains "$err" "must sum to approximately 1" "the malformed score sum is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 "an invalid score sum prints one stderr line"
  assert_equals "$out" "" "an invalid score sum prints no answer"

  respond '{"answers":{"score":{"score":9,"confidence":0.9}}}'
  run_jev code out err score "state" "How severe?" low medium high
  assert_equals "$code" 1 "a probability-free score outside the offered range is rejected"
  assert_contains "$err" "out-of-range score index" "the malformed score is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "an out-of-range score prints one stderr line"
  assert_equals "$out" "" "an out-of-range score prints no answer"

  respond '{"answers":{"yes":{"noul":1.5}}}'
  run_jev code out err yes "state" "Is the value in range?"
  assert_equals "$code" 1 "a yes probability above one is rejected"
  assert_contains "$err" "probability must be within 0..1" "the malformed probability is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "an invalid yes probability prints one stderr line"
  assert_equals "$out" "" "an invalid yes probability prints no answer"

  respond '{"answers":{"pick":{"choice":"A","confidence":1.2}}}'
  run_jev code out err pick "state" "Choose?" A B
  assert_equals "$code" 1 "a confidence above one is rejected"
  assert_contains "$err" "confidence must be within 0..1" "the malformed confidence is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "an invalid confidence prints one stderr line"
  assert_equals "$out" "" "an invalid confidence prints no answer"

  respond '{"answers":{"score":{"score":1,"confidence":0.9,"probabilities":{"0":0.05,"1":1.2,"2":0.0}}}}'
  run_jev code out err score "state" "How severe?" low medium high
  assert_equals "$code" 1 "a probability above one is rejected"
  assert_contains "$err" "probability outside 0..1" "the malformed probability is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "an invalid score probability prints one stderr line"
  assert_equals "$out" "" "an invalid score probability prints no answer"

  for args in "frob" "pick s q only" "yes s" "--min 2 yes s q" "--id x pick s q A B" \
    "--json yes s q" "yes --min 0.7 s q" "yes s --json q"; do
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
{"state":"s","questions":[{"id":false,"type":"yes","q":"x"}]}
JSON
  assert_equals "$code" 1 "a non-string batch id exits 1"
  assert_contains "$err" "question id must match" "the invalid batch id is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "a non-string batch id prints one stderr line"
  assert_absent "$LOG/body" "a non-string batch id is never sent"

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
  local code out err big openrouter_key large_state large_question large_meaning private_key boundary_state batch_json
  respond '{"answers":{"yes":{"noul":0.9}}}'
  reset_log
  big=$(head -c 4097 /dev/zero | tr '\0' a)
  run_jev code out err yes "$big" "Done?"
  assert_equals "$code" 1 "state over 4096 bytes is refused"
  assert_contains "$err" "4096-byte cap" "the cap is named"
  assert_absent "$LOG/body" "an oversized state is never sent"

  large_state=$(head -c 1000 /dev/zero | tr '\0' s)
  large_question=$(head -c 1000 /dev/zero | tr '\0' q)
  large_meaning=$(head -c 1100 /dev/zero | tr '\0' m)
  reset_log
  run_jev code out err pick "$large_state" "$large_question" "A=$large_meaning" "B=$large_meaning"
  assert_equals "$code" 1 "combined state, question, and option text over 4096 bytes is refused"
  assert_contains "$err" "4096-byte cap" "the aggregate cap is named"
  assert_absent "$LOG/body" "oversized combined input is never sent"

  boundary_state=$(head -c 4095 /dev/zero | tr '\0' s)
  batch_json=$(jq -cn --arg state "$boundary_state" '{state:$state,questions:[{id:"i",type:"yes",q:"q"}]}')
  reset_log
  run_jev code out err batch <<<"$batch_json"
  assert_equals "$code" 1 "batch ids count toward the aggregate input cap"
  assert_contains "$err" "4096-byte cap" "the batch id cap is named"
  assert_absent "$LOG/body" "an oversized batch including its id is never sent"

  private_key=$(printf '%s\n' \
    '-----BEGIN RSA PRIVATE KEY-----' \
    'MIIEpAIBAAKCAQEA7VhY5V2Qe9yJx7u4UmP9zT0qkQmN5Z8bV2hV8xH6TgH8' \
    'dQ7aY6Jm4Vxg9pWq3Nf2cK8rL1sT5uB0eH6iO9mZ2aC4dF7gJ1kL5pR8vX3w' \
    'q2M5nB8cD1fG4hJ7kL0pS3uV6xY9aC2dE5gH8jK1mN4pQ7sT0vW3yZ6bC9d' \
    '-----END RSA PRIVATE KEY-----')
  reset_log
  run_jev code out err yes "$private_key" "Done?"
  assert_equals "$code" 1 "a multiline PEM key in state is refused"
  assert_contains "$err" "secret" "the PEM state refusal names the privacy issue"
  assert_absent "$LOG/body" "a multiline PEM key in state is never sent"

  reset_log
  run_jev code out err pick "state" "Choose?" "A=$private_key" B
  assert_equals "$code" 1 "a multiline PEM key in option text is refused"
  assert_contains "$err" "secret" "the PEM option refusal names the privacy issue"
  assert_absent "$LOG/body" "a multiline PEM key in option text is never sent"

  respond '{"answers":{"yes":{"noul":0.97}}}'
  reset_log
  run_jev code out err yes "worktree for task-execution-receipt-retry is clean" "Done?"
  assert_equals "$code" 0 "a hyphenated task slug is accepted"
  assert_equals "$(jq -r '.state' "$LOG/body")" "worktree for task-execution-receipt-retry is clean" \
    "the complete task slug is sent unchanged"

  for token in sk-abcdefghijklmnop sk-or-abcdefghijklmnop ghp_abcdefghijklmnop github_pat_abcdefghijklmnop; do
    reset_log
    run_jev code out err yes "credential ($token)" "Done?"
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

  reset_log
  run_jev code out err yes "state" "Question includes $KEY"
  assert_equals "$code" 1 "the live key value in a question is refused"
  assert_absent "$LOG/body" "the question key is never sent"

  reset_log
  run_jev code out err pick "state" "Which?" "A=meaning includes $KEY" B
  assert_equals "$code" 1 "the live key value in an option meaning is refused"
  assert_absent "$LOG/body" "the option key is never sent"

  reset_log
  run_jev code out err pick "state" "Which?" "$KEY=meaning" B
  assert_equals "$code" 1 "the live key value in an option label is refused"
  assert_absent "$LOG/body" "the option label key is never sent"

  reset_log
  run_jev code out err pick "state" "Which?" "sk-or-v1-abcdefghijklmnop=meaning" B
  assert_equals "$code" 1 "a secret-shaped option label is refused"
  assert_absent "$LOG/body" "the secret-shaped option label is never sent"

  local pgp_key
  pgp_key=$'-----BEGIN PGP PRIVATE KEY BLOCK-----\nComment: test fixture\n\nmQINBGV8Y2QBEAC7Y3NhbXBsZUJhc2U2NEJsb2Nr\n-----END PGP PRIVATE KEY BLOCK-----'
  reset_log
  run_jev code out err yes "encrypted payload: $pgp_key" "Is the state safe?"
  assert_equals "$code" 1 "a multiline PGP private-key block in state is refused"
  assert_absent "$LOG/body" "a PGP private-key state never reaches TypeSafe"

  reset_log
  run_jev code out err pick "state" "Which?" "A=$pgp_key" B
  assert_equals "$code" 1 "a multiline PGP private-key block in option text is refused"
  assert_absent "$LOG/body" "a PGP private-key option never reaches TypeSafe"

  reset_log
  run_jev code out err pick "state" "Which?" $'A\nB' C
  assert_equals "$code" 1 "an option label containing a newline is refused"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "the multiline label refusal prints one stderr line"
  assert_contains "$err" "option labels must not contain line breaks" "the invalid label is explained"
  assert_absent "$LOG/body" "a multiline option label is never sent"

  run_jev code out err yes "the key is $KEY" "Done?"
  assert_equals "$code" 1 "the live key value is refused"
  assert_not_contains "$err" "$KEY" "the refusal never echoes the key"
  assert_absent "$LOG/body" "the live key is never sent"

  openrouter_key='or-cli-test-key-9876543210'
  reset_log
  OPENROUTER_API_KEY="$openrouter_key" run_jev code out err yes \
    "provider credential $openrouter_key" "Done?"
  assert_equals "$code" 1 "an OpenRouter key value is refused even on the TypeSafe route"
  assert_not_contains "$err" "$openrouter_key" "the OpenRouter key is never echoed"
  assert_absent "$LOG/body" "the OpenRouter key is never sent to TypeSafe"

  printf 'OPENROUTER_API_KEY=%s\n' "$openrouter_key" > "$HOME_DIR/.env"
  reset_log
  OPENROUTER_API_KEY= run_jev code out err yes \
    "provider credential $openrouter_key" "Done?"
  assert_equals "$code" 1 "an OpenRouter key from the resolved .env is refused"
  assert_not_contains "$err" "$openrouter_key" "the .env OpenRouter key is never echoed"
  assert_absent "$LOG/body" "the .env OpenRouter key is never sent to TypeSafe"

  batch_json=$(jq -cn --arg id "$openrouter_key" '{state:"safe",questions:[{id:$id,type:"yes",q:"Done?"}]}')
  reset_log
  OPENROUTER_API_KEY= run_jev code out err batch <<<"$batch_json"
  assert_equals "$code" 1 "an OpenRouter key used as a batch id is refused"
  assert_contains "$err" "Jev API key itself" "a secret batch id is refused by the privacy guard"
  assert_not_contains "$err" "$openrouter_key" "the secret batch id is never echoed"
  assert_absent "$LOG/body" "a secret batch id is never sent to TypeSafe"
  rm -f "$HOME_DIR/.env"
  pass "fm-jev.sh: privacy guard refuses before anything is sent"
}

# The guard must screen the selected key-only file, even when the environment
# carries only the other route's key and FM_HOME is unset.
test_privacy_guard_screens_checkout_key_file_without_fm_home() {
  local code main
  respond '{"answers":{"yes":{"noul":0.97}}}'
  main="$TMP_ROOT/guard-checkout"
  make_checkout "$main"
  mkdir -p "$main/config"
  printf '%s\n' "$KEY-checkout" > "$main/config/typesafe-key"
  chmod 600 "$main/config/typesafe-key"
  reset_log
  env -u FM_HOME -u TYPESAFE_API_KEY OPENROUTER_API_KEY="$KEY-or" PATH="$FAKEBIN:$PATH" \
    "$main/bin/fm-jev.sh" yes "the key is $KEY-checkout" "Done?" \
    > "$TMP_ROOT/guard.out" 2> "$TMP_ROOT/guard.err"
  code=$?
  assert_equals "$code" 1 "the checkout config key is refused with FM_HOME unset"
  assert_contains "$(cat "$TMP_ROOT/guard.err")" "Jev API key itself" "the refusal names the live key"
  assert_not_contains "$(cat "$TMP_ROOT/guard.err")" "$KEY-checkout" "the refusal never echoes the key"
  assert_absent "$LOG/body" "the checkout config key is never sent"
  pass "fm-jev.sh: the guard screens the selected key file"
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
  assert_equals "$(printf '%s' "$line" | jq -r 'has("cwd")')" false \
    "the metadata record does not store the working directory"
  pass "fm-jev.sh: every call is logged as metadata only"
}

# make_checkout <dir> - a disposable copy of the command and its libraries.
make_checkout() {
  mkdir -p "$1/bin"
  cp "$ROOT/bin/fm-jev.sh" "$ROOT/bin/fm-jev-lib.sh" "$ROOT/bin/fm-env-lib.sh" "$1/bin/"
}

test_key_discovery_needs_no_env_setup() {
  local main wt nokey code out err
  respond '{"answers":{"yes":{"noul":0.97}}}'

  # A checkout-local key-only file works from an unrelated directory, while a
  # TypeSafe key in .env is not a CLI credential source.
  main="$TMP_ROOT/own-checkout"
  make_checkout "$main"
  mkdir -p "$main/config"
  printf '%s\n' "$KEY-own" > "$main/config/typesafe-key"
  chmod 600 "$main/config/typesafe-key"
  printf 'TYPESAFE_API_KEY=%s\n' "$KEY-env-file-must-not-be-used" > "$main/.env"
  reset_log
  out=$(cd "$TMP_ROOT" && env -u FM_HOME -u TYPESAFE_API_KEY -u OPENROUTER_API_KEY PATH="$FAKEBIN:$PATH" \
    "$main/bin/fm-jev.sh" yes s q)
  assert_equals "$out" "yes: yes p=0.97 conf=0.94" "the checkout key file answers with no env setup"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY-own" "the key-only file supplies the request key"

  # A linked worktree copy falls back to its main worktree's config file.
  git -C "$main" init -q
  git -C "$main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  wt="$TMP_ROOT/pooled-worktree"
  git -C "$main" worktree add -q --detach "$wt"
  make_checkout "$wt"
  reset_log
  out=$(cd "$TMP_ROOT" && env -u FM_HOME -u TYPESAFE_API_KEY -u OPENROUTER_API_KEY PATH="$FAKEBIN:$PATH" \
    "$wt/bin/fm-jev.sh" yes s q)
  assert_equals "$out" "yes: yes p=0.97 conf=0.94" "a pooled worktree copy finds the main worktree config key"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY-own" "the main worktree config key is used"

  # FM_HOME config wins over checkout config. The process environment still
  # takes precedence over any key file.
  mkdir -p "$HOME_DIR/config"
  printf '%s\n' "$KEY-home" > "$HOME_DIR/config/typesafe-key"
  chmod 600 "$HOME_DIR/config/typesafe-key"
  reset_log
  JEV_TEST_API_KEY= JEV_TEST_HOME="$HOME_DIR" run_jev code out err yes s q
  assert_equals "$code" 0 "an FM_HOME key file is accepted"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY-home" "FM_HOME config wins over checkout config"
  reset_log
  JEV_TEST_API_KEY="$KEY-env-wins" JEV_TEST_HOME="$HOME_DIR" run_jev code out err yes s q
  assert_equals "$code" 0 "the environment key remains supported"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY-env-wins" "the environment key wins over files"

  chmod 644 "$HOME_DIR/config/typesafe-key"
  reset_log
  JEV_TEST_API_KEY= JEV_TEST_HOME="$HOME_DIR" run_jev code out err yes s q
  assert_equals "$code" 1 "a group-readable key file is refused"
  assert_contains "$err" "must not be group- or world-readable" "the unsafe key-file refusal is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 "an unsafe key file prints one stderr line"
  assert_absent "$LOG/body" "an unsafe key file is never sent to TypeSafe"
  chmod 600 "$HOME_DIR/config/typesafe-key"

  # A TypeSafe key only in .env is not accepted, even if .env is in FM_HOME.
  nokey="$TMP_ROOT/no-key-checkout"
  make_checkout "$nokey"
  printf 'TYPESAFE_API_KEY=%s\n' "$KEY-dotenv" > "$nokey/.env"
  reset_log
  env -u TYPESAFE_API_KEY -u OPENROUTER_API_KEY FM_HOME="$nokey" PATH="$FAKEBIN:$PATH" \
    "$nokey/bin/fm-jev.sh" yes s q > "$TMP_ROOT/nokey.out" 2> "$TMP_ROOT/nokey.err"
  code=$?
  assert_equals "$code" 1 "a .env-only key is refused"
  assert_contains "$(cat "$TMP_ROOT/nokey.err")" "TYPESAFE_API_KEY missing" "the missing key is named"
  assert_equals "$(wc -l < "$TMP_ROOT/nokey.err" | tr -d ' ')" 1 "a missing key prints one stderr line"
  assert_absent "$LOG/body" "a .env-only key never reaches TypeSafe"

  printf 'OPENROUTER_API_KEY=%s\nJEV_ROUTE=openrouter\n' "$KEY-or" > "$nokey/.env"
  reset_log
  env -u TYPESAFE_API_KEY FM_HOME="$nokey" OPENROUTER_API_KEY="$KEY-or" JEV_ROUTE=openrouter PATH="$FAKEBIN:$PATH" \
    "$nokey/bin/fm-jev.sh" yes s q > "$TMP_ROOT/openrouter-only.out" 2> "$TMP_ROOT/openrouter-only.err"
  code=$?
  assert_equals "$code" 1 "an OpenRouter key alone cannot authorize the worker command"
  assert_contains "$(cat "$TMP_ROOT/openrouter-only.err")" "TYPESAFE_API_KEY missing" \
    "the missing TypeSafe key is named"
  assert_equals "$(wc -l < "$TMP_ROOT/openrouter-only.err" | tr -d ' ')" 1 \
    "a missing TypeSafe key prints one stderr line"
  assert_not_contains "$(cat "$TMP_ROOT/openrouter-only.err")" "$KEY-or" "the OpenRouter key is never echoed"
  assert_absent "$LOG/body" "OpenRouter credentials never trigger a request"
  pass "fm-jev.sh: key discovery works from any directory without env setup"
}

test_help_is_short_and_complete
test_pick_answers_one_line
test_option_meaning_splits_on_first_equals
test_cli_forces_typesafe_route
test_cli_pins_typesafe_endpoint
test_yes_and_score_lines
test_batch_one_call_many_lines
test_batch_score_accepts_more_than_ten_levels
test_escalation_exits_two
test_json_prints_raw_response
test_errors_exit_one_with_one_line
test_privacy_guard_refuses_before_sending
test_privacy_guard_screens_checkout_key_file_without_fm_home
test_log_records_metadata_only
test_key_discovery_needs_no_env_setup
