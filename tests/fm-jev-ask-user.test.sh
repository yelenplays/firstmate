#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-ask-user.sh, the Jev-first ask-user gate.
#
# A fake curl on PATH stands in for the Jev endpoint: it records the request
# body and answers with a canned TypeSafe response or HTTP status, and counts
# calls so the always-escalate classes can prove no request left the machine.
# A fake sender replaces bin/fm-send.sh through FM_JEV_ASK_USER_SEND and
# records its arguments. No case touches the network or a terminal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-ask-user)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
RESPONSE="$TMP_ROOT/response.json"
KEY='ts-ask-user-test-key-0123456789'
GATE=nm-01M4TEST0000000000000000AB-review
SUT="$ROOT/bin/fm-jev-ask-user.sh"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf 'x' >> "${FAKE_CURL_LOG:?}/calls"
cat > "$FAKE_CURL_LOG/body"
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
cat > "$FAKEBIN/fake-send" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FAKE_CURL_LOG:?}/send-args"
printf '%s\n' "${FM_HOME:-}" > "$FAKE_CURL_LOG/send-home"
exit "${FAKE_SEND_EXIT:-0}"
SH
chmod +x "$FAKEBIN/curl" "$FAKEBIN/fake-send"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE"

# answer <choice1> <conf1> [<choice2> <conf2>] - a canned response whose
# probabilities put the choice on top by the given margin.
answer() {
  jq -nc --args '
    def probs($c; $conf):
      ["in-scope-fix", "expands-contract", "unsettled-call", "destructive-or-security"]
      | map({(.): (if . == $c then (1 + 3 * ($conf | tonumber)) / 4 else (1 - ($conf | tonumber)) / 4 end)}) | add;
    $ARGS.positional as $a
    | {model: "jev-1.13.0",
       answers: (([range(0; $a | length; 2) as $i
         | {("f\($i / 2 + 1)"): {type: "choice", choice: $a[$i], confidence: ($a[$i + 1] | tonumber),
             probabilities: probs($a[$i]; $a[$i + 1])}}] | add)
         + {s1: {type: "noul", noul: 0.01},
            s2: {type: "noul", noul: 0.01}}),
       usage: {input_tokens: 900, output_tokens: 12}}' "$@" > "$RESPONSE"
}

# world [project-kind] - a fresh home with one task holding an open ask-user
# gate over findings F1 and F2. project-kind "vault" adds a wiki marker.
world() {
  local kind=${1:-code}
  HOME_DIR="$TMP_ROOT/home-$RANDOM$RANDOM"
  PROJECT="$HOME_DIR/projects/sample"
  mkdir -p "$HOME_DIR/state/t1.inbox/handled" "$HOME_DIR/data/t1" "$PROJECT"
  [ "$kind" != vault ] || { mkdir -p "$PROJECT/_meta"; : > "$PROJECT/_meta/pruefe.sh"; }
  fm_write_meta "$HOME_DIR/state/t1.meta" kind=ship mode=no-mistakes "project=$PROJECT"
  FINDINGS="$HOME_DIR/data/t1/$GATE-findings.txt"
  cat > "$FINDINGS" <<'EOF'
id: F1
severity: error
file: src/parse.sh
line: 12
description: The parser drops the last field when the line has no trailing newline, which the intent requires to be kept.
authority: ask-user

id: F2
severity: warning
file: tests/parse.test.sh
line:
description: No test covers a final line without a trailing newline.
authority: ask-user
EOF
  cat > "$HOME_DIR/data/t1/brief.md" <<'EOF'
# Task
## Captain's intent
Make the parser keep every field, including on a final line with no trailing newline.

## Firstmate spec
- Fix bin/parse.sh and add a regression test.

# Setup
Boilerplate that never reaches Jev.
EOF
  printf 'schema=fm-task-inbox.v1\nat=2026-10-04T20:00:00Z\n--\nAlso keep empty trailing fields.\n' \
    > "$HOME_DIR/state/t1.inbox/handled/001.msg"
  printf 'needs-decision [at=1791145829] [key=%s]: ask-user findings=F1,F2 file=%s\n' "$GATE" "$FINDINGS" \
    > "$HOME_DIR/state/t1.status"
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# run <exit-var> <out-var> [args...] - runs with the key and the fake sender.
run() {
  local __code=$1 __out=$2 __o="$TMP_ROOT/run.out" __c
  shift 2
  PATH="$FAKEBIN:$PATH" TYPESAFE_API_KEY="${ASK_TEST_KEY-$KEY}" FM_HOME="$HOME_DIR" \
    FM_WIKIS_ROOT="$TMP_ROOT/no-wikis" FM_JEV_ASK_USER_SEND="$FAKEBIN/fake-send" \
    "$SUT" "$@" > "$__o" 2>&1
  __c=$?
  printf -v "$__code" '%s' "$__c"
  printf -v "$__out" '%s' "$(cat "$__o")"
}

calls() {
  if [ -f "$LOG/calls" ]; then wc -c < "$LOG/calls" | tr -d ' '; else printf 0; fi
}

last_log() {
  tail -n 1 "$HOME_DIR/state/jev-ask-user.jsonl"
}

test_act_sends_jev_decision_with_resolve_key() {
  local code out
  world
  answer in-scope-fix 0.92 in-scope-fix 0.88
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 0 "a confident in-scope verdict on every finding acts"
  assert_contains "$out" "ACT $GATE: Jev decided fix F1,F2" "act prints the decision first"
  assert_equals "$(sed -n 1,3p "$LOG/send-args" | tr '\n' ' ')" "t1 --resolve-key $GATE " \
    "act answers the gate through fm-send --resolve-key"
  assert_equals "$(cat "$LOG/send-home")" "$HOME_DIR" "the send names this home explicitly"
  assert_contains "$(sed -n 4p "$LOG/send-args")" "Jev decided this gate under ask-user-authority: fix findings F1,F2" \
    "the answer leads with Jev's decision"
  assert_contains "$(sed -n 4p "$LOG/send-args")" "(gate $GATE, step review, round 1;" \
    "the answer names the gate, step, and round"
  assert_contains "$(sed -n 4p "$LOG/send-args")" \
    "Respond exactly: no-mistakes axi respond --step review --action fix --findings F1,F2" \
    "the answer carries the exact response command"
  assert_contains "$(sed -n 4p "$LOG/send-args")" "never pass --yes" "the answer forbids --yes"
  assert_equals "$(calls)" 1 "act makes exactly one Jev call"
  assert_contains "$(jq -r .state "$LOG/body")" "Make the parser keep every field" "Jev sees the captain's intent"
  assert_contains "$(jq -r .state "$LOG/body")" "Fix bin/parse.sh and add a regression test." "Jev sees the spec"
  assert_contains "$(jq -r .state "$LOG/body")" "[1] Also keep empty trailing fields." "Jev sees the steers"
  assert_contains "$(jq -r .state "$LOG/body")" "No test covers a final line" "Jev sees the findings verbatim"
  assert_not_contains "$(jq -r .state "$LOG/body")" "Boilerplate that never reaches Jev" "Jev never sees the brief boilerplate"
  assert_equals "$(jq -c '.questions | keys' "$LOG/body")" '["f1","f2","s1","s2"]' "each finding gets a scope and security question"
  assert_equals "$(jq -r '.questions.s1.type' "$LOG/body")" noul "security screen uses a typed yes/no question"
  assert_equals "$(jq -c '.questions.f1.criteria | keys' "$LOG/body")" \
    '["destructive-or-security","expands-contract","in-scope-fix","unsettled-call"]' \
    "each question offers the ask-user-authority classes"
  assert_equals "$(last_log | jq -c '[.purpose, .outcome, .code, .jev_called, .sent, .findings]')" \
    '["ask-user-gate","act","decided",true,true,["F1","F2"]]' "the decision is logged as Jev's"
  assert_not_contains "$(cat "$HOME_DIR/state/jev-ask-user.jsonl")" "trailing newline" "the log carries no finding text"
  pass "fm-jev-ask-user: a confident in-scope verdict answers the gate through fm-send"
}

test_security_screen_escalates_cross_tenant_finding() {
  local code out
  world
  sed -i.bak "s/The parser drops the last field/Tenant A can retrieve tenant B's draft/" "$FINDINGS"
  answer in-scope-fix 0.99 in-scope-fix 0.99
  jq '.answers.s1.noul = 0.91' "$RESPONSE" > "$TMP_ROOT/high-risk.json" && mv "$TMP_ROOT/high-risk.json" "$RESPONSE"
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "a high security-screen probability escalates"
  assert_contains "$out" "ESCALATE $GATE jev-security" "the security screen owns the escalation"
  assert_absent "$LOG/send-args" "the security-sensitive finding never answers the gate"
  assert_equals "$(calls)" 1 "the security screen is asked before any decision is sent"
  pass "fm-jev-ask-user: cross-tenant security findings escalate"
}

test_escalates_contact_data_before_jev() {
  local code out
  for contact in 'reach person@example.com' 'call 555-123-4567'; do
    world
    printf 'schema=fm-task-inbox.v1\nat=2026-10-04T20:02:00Z\n--\n%s\n' "$contact" > "$HOME_DIR/state/t1.inbox/002.msg"
    answer in-scope-fix 0.99 in-scope-fix 0.99
    run code out t1 "$GATE" --round 1
    assert_equals "$code" 2 "personal contact data escalates instead of leaving the machine"
    assert_contains "$out" "ESCALATE $GATE privacy" "the shared Jev privacy boundary refuses contact data"
    assert_equals "$(calls)" 0 "contact data is screened before any Jev call"
    assert_absent "$LOG/send-args" "contact data never answers the gate"
  done
  pass "fm-jev-ask-user: email and phone data are refused before Jev"
}

test_escalates_incomplete_contract_and_steers() {
  local code out section
  for section in intent spec; do
    world
    if [ "$section" = intent ]; then
      cat > "$HOME_DIR/data/t1/brief.md" <<'EOF'
# Task
## Captain's intent

## Firstmate spec
- Fix bin/parse.sh and add a regression test.
EOF
    else
      cat > "$HOME_DIR/data/t1/brief.md" <<'EOF'
# Task
## Captain's intent
Make the parser keep every field.

## Firstmate spec
EOF
    fi
    answer in-scope-fix 0.99 in-scope-fix 0.99
    run code out t1 "$GATE" --round 1
    assert_equals "$code" 2 "a brief missing its $section escalates"
    assert_contains "$out" "ESCALATE $GATE no-contract" "an incomplete contract is named"
    assert_equals "$(calls)" 0 "an incomplete contract never reaches Jev"
    assert_absent "$LOG/send-args" "an incomplete contract never answers the gate"
  done

  world
  printf 'schema=fm-task-inbox.v1\nat=2026-10-04T20:03:00Z\nsteer without separator\n' \
    > "$HOME_DIR/state/t1.inbox/002.msg"
  answer in-scope-fix 0.99 in-scope-fix 0.99
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "a steer record without its separator escalates"
  assert_contains "$out" "ESCALATE $GATE steer-record" "the malformed steer is named"
  assert_equals "$(calls)" 0 "a partial steer history never reaches Jev"
  assert_absent "$LOG/send-args" "a partial steer history never answers the gate"
  pass "fm-jev-ask-user: incomplete contracts and steer records escalate"
}

test_escalates_unorderable_steers() {
  local code out kind
  for kind in nonnumeric broken-link; do
    world
    if [ "$kind" = nonnumeric ]; then
      printf 'schema=fm-task-inbox.v1\nat=2026-10-04T20:04:00Z\n--\nUnorderable steer.\n' > "$HOME_DIR/state/t1.inbox/handled/bad.msg"
    else
      ln -s "$HOME_DIR/state/t1.inbox/missing.msg" "$HOME_DIR/state/t1.inbox/handled/002.msg"
    fi
    answer in-scope-fix 0.99 in-scope-fix 0.99
    run code out t1 "$GATE" --round 1
    assert_equals "$code" 2 "a $kind steer record escalates"
    assert_contains "$out" "ESCALATE $GATE steer-record" "an invalid steer record is named"
    assert_equals "$(calls)" 0 "invalid steer records never reach Jev"
    assert_absent "$LOG/send-args" "invalid steer records never answer the gate"
  done
  pass "fm-jev-ask-user: unorderable and unreadable steer records escalate"
}

test_escalates_symlinked_steer() {
  local code out marker=UNRELATED_LINKED_STEER_CONTENT
  world
  printf '%s\n' "$marker" > "$TMP_ROOT/unrelated-steer.txt"
  ln -s "$TMP_ROOT/unrelated-steer.txt" "$HOME_DIR/state/t1.inbox/handled/002.msg"
  answer in-scope-fix 0.99 in-scope-fix 0.99
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "a symlink to a readable file escalates"
  assert_contains "$out" "ESCALATE $GATE steer-record" "the symlink is refused as a steer record"
  assert_equals "$(calls)" 0 "linked file contents never reach Jev"
  assert_absent "$LOG/body" "no Jev request contains linked file content"
  assert_absent "$LOG/send-args" "a symlinked steer never answers the gate"
  pass "fm-jev-ask-user: symlinked steer records are refused"
}

test_escalates_low_confidence() {
  local code out
  world
  answer in-scope-fix 0.92 in-scope-fix 0.6
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "a verdict under the floor escalates"
  assert_contains "$out" "ESCALATE $GATE jev-low-confidence" "the escalation names the low confidence"
  assert_absent "$LOG/send-args" "a low-confidence verdict never answers the gate"
  assert_equals "$(last_log | jq -c '[.outcome, .code, .jev_called]')" '["escalate","jev-low-confidence",true]' \
    "the escalation is logged"

  world
  answer in-scope-fix 0.92 in-scope-fix 0.746
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "raw confidence just below the floor escalates"
  assert_contains "$out" "ESCALATE $GATE jev-low-confidence" "rounding cannot lift raw confidence over the floor"
  assert_contains "$out" "F2=in-scope-fix@0.75" "the displayed confidence remains rounded"
  assert_absent "$LOG/send-args" "a rounded display never authorizes a below-floor answer"
  pass "fm-jev-ask-user: confidence below the floor escalates to the captain"
}

test_escalates_out_of_scope_class() {
  local code out
  world
  answer in-scope-fix 0.95 expands-contract 0.9
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "a confident expansion escalates"
  assert_contains "$out" "ESCALATE $GATE jev-class" "the escalation names the class verdict"
  assert_contains "$out" "F2=expands-contract@0.9" "the escalation shows each finding's class"
  assert_absent "$LOG/send-args" "an expansion never answers the gate"
  answer destructive-or-security 0.97 in-scope-fix 0.9
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "a destructive or security class escalates regardless of confidence"
  assert_absent "$LOG/send-args" "a destructive class never answers the gate"
  pass "fm-jev-ask-user: any finding outside a plain in-scope fix escalates the whole gate"
}

test_escalates_jev_errors() {
  local code out
  world
  answer in-scope-fix 0.92 in-scope-fix 0.88
  FAKE_CURL_HTTP=500 run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "a failed Jev call escalates"
  assert_contains "$out" "ESCALATE $GATE jev-error" "the escalation names the Jev error"
  assert_absent "$LOG/send-args" "a failed call never answers the gate"
  assert_equals "$(last_log | jq -c '[.code, .http]')" '["jev-error","500"]' "the failed call is logged"

  printf '{"model":"jev-1.13.0","answers":{"f1":{"type":"choice","choice":"in-scope-fix","confidence":0.9},"s1":{"type":"noul","noul":0.01},"s2":{"type":"noul","noul":0.01}}}\n' > "$RESPONSE"
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "a response missing a finding's answer escalates"
  assert_contains "$out" "jev-error" "a malformed answer is a Jev error"

  printf '{"model":"jev-1.13.0","answers":{"f1":{"type":"choice","choice":"in-scope-fix","confidence":0.9,"probabilities":{"in-scope-fix":0.4,"expands-contract":0.4,"unsettled-call":0.1,"destructive-or-security":0.1}},"f2":{"type":"choice","choice":"in-scope-fix","confidence":0.9,"probabilities":{"in-scope-fix":0.97,"expands-contract":0.01,"unsettled-call":0.01,"destructive-or-security":0.01}},"s1":{"type":"noul","noul":0.01},"s2":{"type":"noul","noul":0.01}}}\n' > "$RESPONSE"
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "a split top probability escalates even with a high reported confidence"
  assert_absent "$LOG/send-args" "a split answer never answers the gate"

  ASK_TEST_KEY='' run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "no Jev key escalates"
  assert_contains "$out" "jev-unavailable" "a missing key is named"
  pass "fm-jev-ask-user: Jev errors and missing keys escalate with no fallback"
}

test_escalates_wrong_or_missing_answer_type() {
  local code out mutation
  for mutation in '.answers.f1.type = "score"' 'del(.answers.f1.type)'; do
    world
    answer in-scope-fix 0.95 in-scope-fix 0.95
    jq "$mutation" "$RESPONSE" > "$TMP_ROOT/typed.json" && mv "$TMP_ROOT/typed.json" "$RESPONSE"
    run code out t1 "$GATE" --round 1
    assert_equals "$code" 2 "an answer whose type is not choice escalates ($mutation)"
    assert_contains "$out" "ESCALATE $GATE jev-error" "a mistyped answer is a Jev error ($mutation)"
    assert_absent "$LOG/send-args" "a mistyped answer never answers the gate ($mutation)"
  done
  pass "fm-jev-ask-user: a wrong or missing answer type escalates even with valid probabilities"
}

test_always_escalate_classes_skip_jev() {
  local code out
  world
  answer in-scope-fix 0.99 in-scope-fix 0.99
  run code out t1 "$GATE" --round 4
  assert_equals "$code" 2 "a gate past round 3 escalates"
  assert_contains "$out" "ESCALATE $GATE round-cap" "the round cap is named"
  run code out t1 "$GATE" --round 3
  assert_equals "$code" 0 "round 3 still follows the normal procedure"

  world
  answer in-scope-fix 0.99 in-scope-fix 0.99
  printf '\nid: F3\nseverity: warning\ndescription: The cleanup path runs rm -rf on the cache root.\nauthority: ask-user\n' >> "$FINDINGS"
  printf 'needs-decision [at=1791145830] [key=%s]: ask-user findings=F1,F2,F3 file=%s\n' "$GATE" "$FINDINGS" \
    > "$HOME_DIR/state/t1.status"
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "a destructive finding escalates before Jev"
  assert_contains "$out" "always-escalate" "the always-escalate class is named"
  assert_equals "$(calls)" 0 "no Jev call for a destructive finding"

  world
  answer in-scope-fix 0.99 in-scope-fix 0.99
  sed -i.bak 's/which the intent requires/a security boundary the intent requires/' "$FINDINGS"
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "a security finding escalates before Jev"
  assert_equals "$(calls)" 0 "no Jev call for a security finding"

  world vault
  answer in-scope-fix 0.99 in-scope-fix 0.99
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "a wiki vault project escalates"
  assert_contains "$out" "kept-out" "the vault keep-out is named"
  assert_equals "$(calls)" 0 "no vault content leaves the machine"
  assert_equals "$(last_log | jq -c '[.code, .jev_called]')" '["kept-out",false]' "the keep-out is logged without a call"
  assert_absent "$LOG/send-args" "no always-escalate class answers the gate"
  pass "fm-jev-ask-user: round cap, destructive, security, and vault gates escalate without a Jev call"
}

test_escalates_oversized_or_secret_contract() {
  local code out
  world
  answer in-scope-fix 0.99 in-scope-fix 0.99
  head -c 9000 /dev/zero | tr '\0' 'a' >> "$HOME_DIR/data/t1/brief.md"
  sed -i.bak "s/^Make the parser/$(head -c 9000 /dev/zero | tr '\0' 'b') Make the parser/" "$HOME_DIR/data/t1/brief.md"
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "a contract over the state cap escalates"
  assert_contains "$out" "contract-too-large" "the size cap is named"
  assert_equals "$(calls)" 0 "an oversized contract is never truncated and sent"

  world
  answer in-scope-fix 0.99 in-scope-fix 0.99
  printf 'schema=fm-task-inbox.v1\nat=2026-10-04T20:01:00Z\n--\nuse api_token=abcdef0123456789 for the fixture\n' \
    > "$HOME_DIR/state/t1.inbox/002.msg"
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "a secret-shaped steer escalates"
  assert_contains "$out" "privacy" "the privacy refusal is named"
  assert_equals "$(calls)" 0 "a secret never leaves the machine"
  pass "fm-jev-ask-user: oversized or secret-bearing contracts escalate unsent"
}

test_record_errors_refuse() {
  local code out
  world
  run code out t1 nm-01M4OTHER00000000000000000-review --round 1
  assert_equals "$code" 1 "an unknown key is a record error"
  assert_contains "$out" "no open decision" "the missing key is named"

  printf 'resolved [at=1791145900] [key=%s]: answered: fix\n' "$GATE" >> "$HOME_DIR/state/t1.status"
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 1 "an already-answered gate is refused"

  world
  sed -i.bak 's/^id: F2$/id: F9/' "$FINDINGS"
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 1 "a snapshot whose ids differ from the status line is refused"
  assert_contains "$out" "do not match" "the id mismatch is named"

  world
  cp "$FINDINGS" "$TMP_ROOT/outside-findings.txt"
  printf 'needs-decision [at=1791145829] [key=%s]: ask-user findings=F1,F2 file=%s\n' "$GATE" "$TMP_ROOT/outside-findings.txt" \
    > "$HOME_DIR/state/t1.status"
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 1 "a snapshot outside the task's data directory is refused"

  run code out t1 "$GATE"
  assert_equals "$code" 1 "--round is required"
  assert_equals "$(calls)" 0 "no record error reaches Jev"
  pass "fm-jev-ask-user: record and usage errors refuse without deciding"
}

test_send_failure_reports_error() {
  local code out
  world
  answer in-scope-fix 0.92 in-scope-fix 0.88
  FAKE_SEND_EXIT=1 run code out t1 "$GATE" --round 1
  assert_equals "$code" 1 "a failed send is an error"
  assert_contains "$out" "did not reach the worker" "the failed send says the answer is undelivered"
  assert_contains "$out" "Respond exactly:" "the decision stays printed for a resend"
  assert_equals "$(last_log | jq -c '[.outcome, .code, .sent]')" '["act","send-failed",false]' "the failed send is logged"
  pass "fm-jev-ask-user: a failed send reports the undelivered decision"
}

test_ordinary_task_numbers_reach_jev() {
  local code out
  world
  # The real pickup steer every worker receives carries an execution receipt
  # id; briefs carry viewport lists, ranges, decimals, and prose such as
  # "Keyboard pass:". None of them is a phone number or a secret.
  printf 'schema=fm-task-inbox.v1\nat=2026-10-04T20:02:00Z\n--\n%s\n' \
    'Pickup receipt: from your worktree run: FM_HOME=/home/fm /home/fm/bin/fm-task-execution.sh started t1 e1791449349.20521.20886 - then carry on.' \
    > "$HOME_DIR/state/t1.inbox/handled/002.msg"
  printf '%s\n' '# Task' "## Captain's intent" 'Make the parser keep every field.' '' '## Firstmate spec' \
    '- Check 320/390/768/1440, lines 1028-1045, ISO 1600-3200, oklch(0.575 0.18 24).' \
    '- Keyboard pass: every control reachable; Engpass: none; host 127.0.0.1:8081.' > "$HOME_DIR/data/t1/brief.md"
  answer in-scope-fix 0.99 in-scope-fix 0.99
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 0 "ordinary task numbers and prose do not trip the privacy screen"
  assert_contains "$out" "ACT $GATE" "Jev decides the gate"
  assert_contains "$(jq -r '.state' "$LOG/body")" 'e1791449349.20521.20886' "the receipt id is sent unchanged"
  assert_contains "$(jq -r '.state' "$LOG/body")" '320/390/768/1440' "the viewport list is sent unchanged"
  pass "fm-jev-ask-user: receipt ids, viewport lists, ranges, and prose reach Jev"
}

test_act_sends_jev_decision_with_resolve_key
test_security_screen_escalates_cross_tenant_finding
test_escalates_contact_data_before_jev
test_ordinary_task_numbers_reach_jev
test_escalates_incomplete_contract_and_steers
test_escalates_unorderable_steers
test_escalates_symlinked_steer
test_escalates_low_confidence
test_escalates_out_of_scope_class
test_escalates_jev_errors
test_escalates_wrong_or_missing_answer_type
test_always_escalate_classes_skip_jev
test_escalates_oversized_or_secret_contract
test_record_errors_refuse
test_send_failure_reports_error
