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
answer() { # <choice> <confidence> ...; ANSWER_APPROVE=1 answers a question that offers approve-followup
  jq -nc --arg approve "${ANSWER_APPROVE:-0}" --args '
    def probs($c; $conf):
      (["in-scope-fix", "expands-contract", "unsettled-call", "destructive-or-security"]
        + (if $approve == "1" then ["approve-followup"] else [] end)) as $keys
      | ($keys | length) as $n
      | $keys | map({(.): (if . == $c then (1 + ($n - 1) * ($conf | tonumber)) / $n else (1 - ($conf | tonumber)) / $n end)}) | add;
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

test_privacy_corpus_before_transport() {
  local row id label text marker code out failures=''
  while IFS= read -r row; do
    id=$(jq -r .id <<<"$row")
    label=$(jq -r .label <<<"$row")
    text=$(jq -r .text <<<"$row")
    marker=$(jq -r '.project_marker // ""' <<<"$row")
    world
    if [ -n "$marker" ]; then
      mkdir -p "$PROJECT/$(dirname "$marker")"
      : > "$PROJECT/$marker"
    fi
    printf 'schema=fm-task-inbox.v1\nat=2026-10-09T18:00:00Z\n--\n%s\n' "$text" \
      > "$HOME_DIR/state/t1.inbox/002.msg"
    answer in-scope-fix 0.99 in-scope-fix 0.99
    run code out t1 "$GATE" --round 1
    if [ "$label" = pass ]; then
      if [ "$code" != 0 ] || [ "$(calls)" != 1 ]; then
        failures="$failures $id"
        printf 'corpus false alarm: %s (%s)\n' "$id" "$out" >&2
      else
        assert_contains "$(jq -r .state "$LOG/body")" "$text" "$id reaches transport unchanged"
      fi
    else
      assert_equals 2 "$code" "$id is refused"
      assert_equals 0 "$(calls)" "$id makes no outbound request"
      assert_absent "$LOG/body" "$id never reaches the transport"
      assert_absent "$LOG/send-args" "$id never answers the gate"
      assert_equals false "$(last_log | jq -r .jev_called)" "$id is logged as unsent"
    fi
  done < <(jq -c '.[]' "$ROOT/tests/fixtures/jev-privacy/corpus.json")
  [ -z "$failures" ] || fail "privacy corpus false alarms:$failures"
  pass "fm-jev-ask-user: labeled privacy corpus reaches transport unchanged or stays entirely local"
}

test_real_dispatch_finding_before_transport() {
  local code out fixture
  fixture="$ROOT/tests/fixtures/jev-privacy/dispatch-findings.txt"
  world
  cp "$fixture" "$FINDINGS"
  printf 'needs-decision [at=1791571614] [key=%s]: ask-user findings=dispatch-advise-skips-chain file=%s\n' \
    "$GATE" "$FINDINGS" > "$HOME_DIR/state/t1.status"
  answer in-scope-fix 0.99
  jq '.answers.f1 as $answer | .answers = {f1: $answer, s1: {type: "noul", noul: 0.01}}' \
    "$RESPONSE" > "$TMP_ROOT/dispatch-response.json"
  mv "$TMP_ROOT/dispatch-response.json" "$RESPONSE"
  run code out t1 "$GATE" --round 1
  assert_equals 0 "$code" "the real dispatch finding passes privacy screening"
  assert_equals 1 "$(calls)" "the real dispatch finding reaches the fake endpoint"
  assert_contains "$(jq -r .state "$LOG/body")" "$(cat "$fixture")" "the real finding is sent verbatim"
  pass "fm-jev-ask-user: real dispatch review finding no longer trips the phone screen"
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
  assert_equals "$(last_log | jq -r '.caller')" ask-user-gate "the record names the ask-user-gate call site"
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
  assert_equals "$code" 2 "a contract over the state cap escalates without losing scope"
  assert_contains "$out" "contract-too-large" "the contract size refusal is named"
  assert_equals "$(calls)" 0 "an oversized contract never reaches Jev"
  assert_absent "$LOG/send-args" "an oversized contract never answers the gate"

  world
  answer in-scope-fix 0.99 in-scope-fix 0.99
  sed -i.bak "s/^description: No test covers/description: $(head -c 9000 /dev/zero | tr '\0' 'c') No test covers/" "$FINDINGS"
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "findings over the state cap escalate"
  assert_contains "$out" "contract-too-large" "the size cap is named"
  assert_equals "$(calls)" 0 "oversized findings are never truncated and sent"

  world
  answer in-scope-fix 0.99 in-scope-fix 0.99
  printf 'schema=fm-task-inbox.v1\nat=2026-10-04T20:01:00Z\n--\nuse api_token=abcdef0123456789 for the fixture\n' \
    > "$HOME_DIR/state/t1.inbox/002.msg"
  run code out t1 "$GATE" --round 1
  assert_equals "$code" 2 "a secret-shaped steer escalates"
  assert_contains "$out" "privacy" "the privacy refusal is named"
  assert_equals "$(calls)" 0 "a secret never leaves the machine"
  pass "fm-jev-ask-user: oversized contracts, findings, or secrets escalate unsent"
}

test_compaction_keeps_scope_or_escalates() {
  local section code out contract state
  for section in intent spec steer; do
    world
    contract="$(printf 'The parser must preserve every field.\n%.0s' {1..300})
MANDATORY SCOPE LIMIT: documentation-only; do not edit production code."
    case "$section" in
      intent)
        printf "# Task\n## Captain's intent\n%s\n\n## Firstmate spec\nDocument the parser bug.\n" "$contract" > "$HOME_DIR/data/t1/brief.md"
        ;;
      spec)
        printf "# Task\n## Captain's intent\nDocument the parser bug.\n\n## Firstmate spec\n%s\n" "$contract" > "$HOME_DIR/data/t1/brief.md"
        ;;
      steer)
        printf 'schema=fm-task-inbox.v1\nat=2026-10-04T20:02:00Z\n--\n%s\n' "$contract" > "$HOME_DIR/state/t1.inbox/002.msg"
        ;;
    esac
    answer in-scope-fix 0.99 in-scope-fix 0.99
    run code out t1 "$GATE" --round 1
    if [ "$code" = 0 ]; then
      state=$(jq -r .state "$LOG/body")
      [[ "$state" == *"$contract"* ]] || fail "an autonomous decision lost the complete $section contract"
    else
      assert_equals 2 "$code" "an oversized $section contract escalates"
      assert_contains "$out" "contract-too-large" "the incomplete $section contract is refused for size"
      assert_equals 0 "$(calls)" "an incomplete $section contract never reaches Jev"
      assert_absent "$LOG/send-args" "an incomplete $section contract never answers the gate"
    fi
  done
  pass "fm-jev-ask-user: late scope limits survive or escalate without transport"
}

test_json_ci_gate_with_long_setup_is_decided() {
  local code out state line
  world
  FINDINGS="$HOME_DIR/data/t1/nm-01M4TEST0000000000000000AB-ci-findings.txt"
  printf '%s\n' '{"findings":[{"id":"ci-1","severity":"error","file":"","line":null,"action":"ask-user","description":"The first CI run failed on a flaky network fetch; the replacement run is green."}]}' > "$FINDINGS"
  printf 'needs-decision [at=1791145829] [key=nm-01M4TEST0000000000000000AB-ci]: ask-user findings=ci-1 file=%s\n' "$FINDINGS" \
    > "$HOME_DIR/state/t1.status"
  {
    printf '# Task\n## Captain'"'"'s intent\nMake the parser keep every field.\n'
    printf '\n## Firstmate spec\nFix bin/parse.sh and keep the regression test.\n'
    printf '\n# Setup\n'
    for line in $(seq 1 240); do printf 'Setup detail %03d: boilerplate that never reaches Jev.\n' "$line"; done
  } > "$HOME_DIR/data/t1/brief.md"
  answer in-scope-fix 0.95
  run code out t1 nm-01M4TEST0000000000000000AB-ci --round 1
  assert_equals "$code" 0 "a one-finding JSON CI gate under a long brief is decided"
  assert_contains "$out" "ACT nm-01M4TEST0000000000000000AB-ci: Jev decided fix ci-1" "the JSON id is judged"
  state=$(jq -r .state "$LOG/body")
  assert_contains "$state" "id: ci-1" "the JSON finding reaches Jev as an id line"
  assert_contains "$state" "authority/action: ask-user" "the JSON action is read as the finding's authority"
  assert_contains "$state" "the replacement run is green" "the JSON description reaches Jev verbatim"
  assert_contains "$state" "Make the parser keep every field." "the complete intent reaches Jev"
  assert_contains "$state" "Fix bin/parse.sh and keep the regression test." "the complete spec reaches Jev"
  assert_not_contains "$state" "Setup detail" "non-contract setup is excluded"
  assert_equals "$([ "$(printf '%s' "$state" | wc -c)" -le 8192 ] && echo under)" under "the complete contract fits the cap"
  assert_equals "$(jq -c '.questions | keys' "$LOG/body")" '["f1","s1"]' "only the asked JSON id is a question"
  pass "fm-jev-ask-user: a JSON CI gate under an over-cap brief retains the entire accepted contract"
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

TGATE=nm-01M4TEST0000000000000000AB-test
INCONCLUSIVE='live validation verdict: inconclusive (2 of 5 scenarios were driven live against the product); untested: Parse a live upstream feed that ends without a newline, Resume parsing after an interrupted download'
NOOP_CONTEXT='The regression tests passed, but this step cannot reach the live upstream feed by design. Validate those outcomes outside the gate.'

# test_world [lines|toon|json] [context-action] [asked-ids] [gate-key]: a test-step
# gate whose snapshot holds a context finding T1 next to the asked inconclusive verdict T2.
test_world() {
  local shape=${1:-lines} context=${2-no-op} asked=${3:-T2} gate=${4:-$TGATE}
  world
  FINDINGS="$HOME_DIR/data/t1/$gate-findings.txt"
  if [ "$shape" = toon ]; then
    cat > "$FINDINGS" <<TOON
gate:
  step: test
  findings[2]{id,severity,file,action,description}:
    T1,warning,"",$context,"$NOOP_CONTEXT"
    T2,warning,"",ask-user,"$INCONCLUSIVE"
TOON
  elif [ "$shape" = json ]; then
    jq -n --arg context "$context" --arg noop "$NOOP_CONTEXT" --arg inconclusive "$INCONCLUSIVE" '
      {step: "test", findings: [
        {id: "T1", severity: "warning", file: "", line: null, action: $context, description: $noop},
        {id: "T2", severity: "warning", file: "", line: null, action: "ask-user", description: $inconclusive}]}' > "$FINDINGS"
  else
    {
      printf 'id: T1\nseverity: warning\nfile: ""\nline: ""\n'
      [ -z "$context" ] || printf 'authority/action: %s\n' "$context"
      printf 'description: %s\n\n' "$NOOP_CONTEXT"
      printf 'id: T2\nseverity: warning\nfile: ""\nline: ""\nauthority/action: ask-user\ndescription: %s\n\n' "$INCONCLUSIVE"
      printf 'Crew context (not a decision): the gate cannot reach the upstream feed by design; acceptance outside the gate is recorded in the report.\n'
    } > "$FINDINGS"
  fi
  printf 'needs-decision [at=1791145829] [key=%s]: ask-user findings=%s file=%s\n' "$gate" "$asked" "$FINDINGS" \
    > "$HOME_DIR/state/t1.status"
}

approve_offered() {
  jq -e '.questions.f1.criteria | has("approve-followup")' "$LOG/body" >/dev/null
}

test_subset_snapshot_with_noop_context_approves() {
  local code out shape msg
  for shape in lines toon json; do
    test_world "$shape"
    ANSWER_APPROVE=1 answer approve-followup 0.9
    run code out t1 "$TGATE" --round 1
    assert_equals "$code" 0 "a $shape snapshot with no-op context passes intake and acts on approval"
    assert_contains "$out" "ACT $TGATE: Jev decided approve T2" "the $shape approval is printed first"
    assert_equals "$(jq -c '.questions | keys' "$LOG/body")" '["f1","s1"]' "only the asked id is a $shape question"
    assert_equals "$(jq -c '.questions.f1.criteria | keys' "$LOG/body")" \
      '["approve-followup","destructive-or-security","expands-contract","in-scope-fix","unsettled-call"]' \
      "the $shape test gate offers approve-followup"
    assert_contains "$(jq -r .state "$LOG/body")" "$NOOP_CONTEXT" "the $shape no-op finding stays as context"
    assert_equals "$(sed -n 1,3p "$LOG/send-args" | tr '\n' ' ')" "t1 --resolve-key $TGATE " \
      "the $shape approval answers through fm-send --resolve-key"
    msg=$(sed -n 4p "$LOG/send-args")
    assert_contains "$msg" "Jev decided this gate under ask-user-authority: approve findings T2" \
      "the $shape answer records that Jev decided the approval"
    assert_contains "$msg" "Respond exactly: no-mistakes axi respond --step test --action approve --reason" \
      "the $shape answer carries the exact approve command"
    assert_contains "$msg" "'Follow-up check' heading" "the $shape answer records the follow-up check"
    assert_contains "$msg" "never pass --yes" "the $shape approval forbids --yes"
    assert_equals "$(last_log | jq -c '[.outcome, .code, .sent, .findings, .answers[0].choice]')" \
      '["act","decided",true,["T2"],"approve-followup"]' "the $shape approval is logged as Jev's"
  done
  pass "fm-jev-ask-user: id-line, TOON, and JSON subset snapshots with no-op context approve an inconclusive test gate"
}

test_snapshot_ids_must_cover_the_asked_ids() {
  local code out
  test_world lines no-op T2,T9
  run code out t1 "$TGATE" --round 1
  assert_equals "$code" 1 "an asked id missing from the snapshot is refused"
  assert_contains "$out" "does not list: T9" "the missing id is named"

  test_world toon no-op T2,T9
  run code out t1 "$TGATE" --round 1
  assert_equals "$code" 1 "an asked id missing from a TOON snapshot is refused"
  assert_contains "$out" "does not list: T9" "the TOON missing id is named"

  test_world json no-op T2,T9
  run code out t1 "$TGATE" --round 1
  assert_equals "$code" 1 "an asked id missing from a JSON snapshot is refused"
  assert_contains "$out" "does not list: T9" "the JSON missing id is named"

  test_world lines no-op T2,T2
  run code out t1 "$TGATE" --round 1
  assert_equals "$code" 1 "a repeated asked id is refused"
  assert_contains "$out" "finding ids repeat" "the repeated asked id is named"

  test_world
  printf 'id: T2\nauthority/action: ask-user\ndescription: duplicate\n' >> "$FINDINGS"
  run code out t1 "$TGATE" --round 1
  assert_equals "$code" 1 "a snapshot that repeats an id is refused"
  assert_contains "$out" "the snapshot repeats a finding id" "the repeated snapshot id is named"
  assert_equals "$(calls)" 0 "no id mismatch reaches Jev"
  pass "fm-jev-ask-user: the asked ids must be a unique subset of the snapshot ids"
}

test_approve_needs_unanimous_confident_answers() {
  local code out
  test_world lines no-op T1,T2
  sed -i.bak 's/^authority\/action: no-op$/authority\/action: ask-user/' "$FINDINGS"
  ANSWER_APPROVE=1 answer in-scope-fix 0.95 approve-followup 0.95
  run code out t1 "$TGATE" --round 1
  assert_equals "$code" 2 "a gate split between fix and approve escalates"
  assert_contains "$out" "ESCALATE $TGATE jev-class" "the split gate is a class escalation"
  assert_contains "$out" "T2=approve-followup@0.95" "the escalation shows the approve answer"
  assert_absent "$LOG/send-args" "a split gate never answers"

  test_world
  ANSWER_APPROVE=1 answer approve-followup 0.746
  run code out t1 "$TGATE" --round 1
  assert_equals "$code" 2 "an approval with raw confidence just below the floor escalates"
  assert_contains "$out" "ESCALATE $TGATE jev-low-confidence" "the floor applies to approve"
  assert_contains "$out" "T2=approve-followup@0.75" "the displayed approval confidence remains rounded"
  assert_absent "$LOG/send-args" "a below-floor approval never answers"
  pass "fm-jev-ask-user: approval needs every finding approved at or above the floor"
}

test_approve_is_offered_only_for_inconclusive_test_gates() {
  local code out context rgate=${TGATE%-test}-review
  test_world lines no-op T2 "$rgate"
  answer in-scope-fix 0.9
  run code out t1 "$rgate" --round 1
  assert_equals "$code" 0 "a review gate still decides an in-scope fix"
  ! approve_offered || fail "a review gate must not offer approve-followup"
  ANSWER_APPROVE=1 answer approve-followup 0.99
  run code out t1 "$rgate" --round 1
  assert_equals "$code" 2 "an approval outside a test gate is refused"
  assert_contains "$out" "jev-error" "an unoffered approval is a malformed answer"
  rm -f "$LOG/send-args"

  test_world
  sed -i.bak 's/live validation verdict: inconclusive/live validation verdict: failed/' "$FINDINGS"
  answer in-scope-fix 0.9
  run code out t1 "$TGATE" --round 1
  assert_equals "$code" 0 "a test gate without an inconclusive verdict still decides a fix"
  ! approve_offered || fail "a test gate without an inconclusive asked finding must not offer approve-followup"

  for context in auto-fix ask-me ''; do
    test_world lines "$context"
    answer in-scope-fix 0.9
    run code out t1 "$TGATE" --round 1
    ! approve_offered || fail "unjudged context '${context:-no authority}' must not offer approve-followup"
  done
  test_world toon auto-fix
  answer in-scope-fix 0.9
  run code out t1 "$TGATE" --round 1
  ! approve_offered || fail "unjudged TOON auto-fix context must not offer approve-followup"
  pass "fm-jev-ask-user: approve is offered only for an inconclusive asked test finding with no unjudged context"
}

test_toon_quoted_commas_preserve_context_action() {
  local code out context file_field
  for file_field in '"src/a,no-op,b.sh"' '"src/a\",no-op,b.sh"' '"src/a\\,no-op,b.sh"'; do
    for context in auto-fix ask-me no-op; do
      test_world toon "$context"
      # The quoted filename is one TOON field, not extra action columns.
      printf 'gate:\n  step: test\n  findings[2]{id,severity,file,action,description}:\n    T1,warning,%s,%s,"%s"\n    T2,warning,"",ask-user,"%s"\n' \
        "$file_field" "$context" "$NOOP_CONTEXT" "$INCONCLUSIVE" > "$FINDINGS"
      ANSWER_APPROVE=1 answer approve-followup 0.99
      run code out t1 "$TGATE" --round 1
      if [ "$context" = no-op ]; then
        assert_equals 0 "$code" "a quoted-comma filename does not disable harmless no-op approval ($file_field)"
        approve_offered || fail "quoted-comma no-op context must offer approval ($file_field)"
        assert_contains "$out" "ACT $TGATE: Jev decided approve T2" "harmless quoted-comma context permits approval"
      else
        assert_equals 2 "$code" "quoted commas cannot disguise unjudged $context context as no-op ($file_field)"
        ! approve_offered || fail "quoted-comma $context context must not offer approval ($file_field)"
        assert_absent "$LOG/send-args" "unjudged $context context never sends approval"
      fi
    done
  done
  pass "fm-jev-ask-user: quoted TOON commas cannot disguise unjudged context authority"
}

test_screens_win_over_approve() {
  local code out
  test_world
  ANSWER_APPROVE=1 answer approve-followup 0.99
  jq '.answers.s1.noul = 0.91' "$RESPONSE" > "$TMP_ROOT/high-risk.json" && mv "$TMP_ROOT/high-risk.json" "$RESPONSE"
  run code out t1 "$TGATE" --round 1
  assert_equals "$code" 2 "a high security screen escalates a confident approval"
  assert_contains "$out" "ESCALATE $TGATE jev-security" "the security screen owns the escalation"
  assert_absent "$LOG/send-args" "a security-flagged approval never answers"

  test_world
  ANSWER_APPROVE=1 answer approve-followup 0.99
  run code out t1 "$TGATE" --round 4
  assert_equals "$code" 2 "an approval past round 3 escalates"
  assert_contains "$out" "ESCALATE $TGATE round-cap" "the round cap wins over approve"
  assert_equals "$(calls)" 0 "the round cap never calls Jev"

  test_world
  sed -i.bak 's/the gate cannot reach the upstream feed/the gate cannot reach the credential store/' "$FINDINGS"
  ANSWER_APPROVE=1 answer approve-followup 0.99
  run code out t1 "$TGATE" --round 1
  assert_equals "$code" 2 "a credential-naming snapshot escalates before approval"
  assert_contains "$out" "ESCALATE $TGATE always-escalate" "the always-escalate screen wins over approve"
  assert_equals "$(calls)" 0 "no always-escalate snapshot reaches Jev"

  test_world
  printf 'schema=fm-task-inbox.v1\nat=2026-10-04T20:02:00Z\n--\nreach person@example.com\n' > "$HOME_DIR/state/t1.inbox/002.msg"
  ANSWER_APPROVE=1 answer approve-followup 0.99
  run code out t1 "$TGATE" --round 1
  assert_equals "$code" 2 "contact data escalates before approval"
  assert_contains "$out" "ESCALATE $TGATE privacy" "the privacy screen wins over approve"
  assert_equals "$(calls)" 0 "contact data never reaches Jev"
  assert_absent "$LOG/send-args" "no screened approval answers the gate"
  pass "fm-jev-ask-user: security, round-cap, always-escalate, and privacy screens win over approve"
}

# Optional function names keep failure reproduction focused on one behavior.
if [ "$#" -gt 0 ]; then
  for test_case in "$@"; do "$test_case" || exit "$?"; done
  exit
fi

test_compaction_keeps_scope_or_escalates
test_toon_quoted_commas_preserve_context_action
test_privacy_corpus_before_transport
test_real_dispatch_finding_before_transport
test_act_sends_jev_decision_with_resolve_key
test_security_screen_escalates_cross_tenant_finding
test_escalates_contact_data_before_jev
test_escalates_incomplete_contract_and_steers
test_escalates_unorderable_steers
test_escalates_symlinked_steer
test_escalates_low_confidence
test_escalates_out_of_scope_class
test_escalates_jev_errors
test_escalates_wrong_or_missing_answer_type
test_always_escalate_classes_skip_jev
test_escalates_oversized_or_secret_contract
test_json_ci_gate_with_long_setup_is_decided
test_record_errors_refuse
test_send_failure_reports_error
test_subset_snapshot_with_noop_context_approves
test_snapshot_ids_must_cover_the_asked_ids
test_approve_needs_unanimous_confident_answers
test_approve_is_offered_only_for_inconclusive_test_gates
test_screens_win_over_approve
