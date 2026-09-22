#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-replay.sh.
#
# `run` drives the real bin/fm-dispatch-resolve.sh with a fake curl on PATH
# that answers each request from a queue of canned typesafe.ai responses and
# records every request body, plus a fake quota-axi. `score` reads fixture
# JSON lines. No case touches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-dispatch-replay.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-replay)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
QUEUE="$TMP_ROOT/queue"
BODIES="$TMP_ROOT/bodies"
BASE_PATH=$PATH
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$QUEUE" "$BODIES"
KEY='test-key-replay-never-on-argv'

cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{ "rules": [
    { "when": "HOME-RULE-ONE investigation work.", "use": { "harness": "claude", "model": "opus" } },
    { "when": "HOME-RULE-TWO build work.", "use": { "harness": "claude", "model": "sonnet" } } ],
  "default": { "harness": "claude", "model": "opus" } }
JSON
touch "$HOME_DIR/config/jev-dispatch-shadow"
CANDIDATE="$TMP_ROOT/candidate.json"
jq '.rules[0].when = "CANDIDATE investigation work." | .rules[0].beats = [{"rule": 2, "when": "the deliverable is findings"}]' \
  "$HOME_DIR/config/crew-dispatch.json" > "$CANDIDATE"
cp "$HOME_DIR/config/crew-dispatch.json" "$TMP_ROOT/home-rules.before"

cat > "$TMP_ROOT/quota.json" <<'JSON'
{ "generatedAt": "2030-01-01T00:00:00Z", "schemaVersion": 5,
  "providers": [
    { "provider": "claude", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 79, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.5 } } ] } } ] }
JSON

answer() {  # <queue-slot> <choice> <confidence> <rule_1> <rule_2> <default>
  cat > "$QUEUE/$1.json" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "$2", "confidence": $3,
    "probabilities": { "rule_1": $4, "rule_2": $5, "default": $6 } } },
  "usage": { "input_tokens": 100, "output_tokens": 10 } }
JSON
}

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: serves the lowest-numbered queued response and records the body.
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
next=$(ls "${FAKE_QUEUE:?}" | sort -n | head -1)
[ -n "$next" ] || exit 7
cat > "${FAKE_BODIES:?}/${next%.json}.body"
cp "$FAKE_QUEUE/$next" "$out"
rm -f "$FAKE_QUEUE/$next"
printf '200'
SH
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/curl" "$FAKEBIN/quota-axi"
LEDGER_STUB="$TMP_ROOT/ledger"
printf '#!/usr/bin/env bash\nprintf %s\\n\n' "'{\"status\":\"unavailable\"}'" > "$LEDGER_STUB"
chmod +x "$LEDGER_STUB"
export FAKE_QUEUE="$QUEUE" FAKE_BODIES="$BODIES" QUOTA_AXI_FIXTURE="$TMP_ROOT/quota.json"

mkdir -p "$TMP_ROOT/briefs"
printf '# Task\nDiagnose why the pager skips a page.\n' > "$TMP_ROOT/briefs/diagnose.md"
printf '# Task\nAdd a --json flag to the pager.\n' > "$TMP_ROOT/briefs/build.md"
printf '# Task\nRename the pager module.\n' > "$TMP_ROOT/briefs/rename.md"
CASES="$TMP_ROOT/cases.tsv"
printf '%s\n' '# id	brief	project	expected' '' \
  $'diagnose\tbriefs/diagnose.md\tpager\trule_1' \
  $'build\tbriefs/build.md\t-\trule_2|default' \
  $'rename\tbriefs/rename.md\tpager\t-' > "$CASES"

run_tool() {  # <out-var> <err-var> [args...]; exit status in $code
  local __out=$1 __err=$2 _out
  shift 2
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_SPEND_LEDGER="$LEDGER_STUB" TYPESAFE_API_KEY="$KEY" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  code=$?
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

code='' out='' err=''

# --- run: one resolver call per case, budget stop, candidate rules, no shadow --
answer 1 rule_1 0.6 0.7 0.2 0.1
answer 2 rule_2 0.3 0.3 0.45 0.25
answer 3 rule_2 0.9 0.0 1.0 0.0
RESULT="$TMP_ROOT/run.jsonl"
run_tool out err run --cases "$CASES" --out "$RESULT" --max-calls 2 --rules "$CANDIDATE"
expect_code 0 "$code" "run exits 0"
assert_equals 'replay-run: calls=2 written=2 stopped=budget' "$out" "run stops before the call that would exceed the budget"
assert_contains "$err" 'case diagnose: clear rule_1' "run reports each case on stderr"
assert_equals 2 "$(wc -l < "$RESULT" | tr -d ' ')" "run writes one line per call"
assert_present "$QUEUE/3.json" "the budget-stopped case never reaches the transport"
assert_equals '{"case":"diagnose","project":"pager","expected":["rule_1"],"status":"clear","rule":"rule_1","confidence":0.6,"probabilities":{"rule_1":0.7,"rule_2":0.2,"default":0.1},"reason":null}' \
  "$(jq -c 'select(.case == "diagnose") | del(.brief)' "$RESULT")" "run records the answer, label, and probabilities"
assert_equals "$TMP_ROOT/briefs/diagnose.md" "$(jq -r 'select(.case == "diagnose") | .brief' "$RESULT")" "relative brief paths resolve against the cases file"
assert_equals '{"case":"build","project":"","expected":["rule_2","default"],"status":"ambiguous","rule":"rule_2","reason":"top-2 margin 0.15 below 0.4 (rule_2 vs rule_1)"}' \
  "$(jq -c 'select(.case == "build") | {case, project, expected, status, rule, reason}' "$RESULT")" "run keeps the resolver's own gate verdict and reason"
assert_contains "$(cat "$BODIES/1.body")" 'CANDIDATE investigation work. Tie-break: when rule_2 also fits and the deliverable is findings, choose this option over rule_2.' "run replays the candidate rules file"
assert_not_contains "$(cat "$BODIES/1.body")" 'HOME-RULE-ONE' "the home's rules are not replayed when a candidate is given"
assert_equals "$(cat "$TMP_ROOT/home-rules.before")" "$(cat "$HOME_DIR/config/crew-dispatch.json")" "run never touches the home rules file"
assert_absent "$HOME_DIR/state/jev-dispatch-shadow.jsonl" "run forces the resolver's shadow log off"
pass "run: one resolver call per case under a hard budget, candidate rules, no shadow log"

# --- score: margin sweep against the fixed confidence gate, with labels -------
cat > "$TMP_ROOT/score.jsonl" <<'JSONL'
{"case":"a","expected":["rule_1"],"confidence":0.55,"probabilities":{"rule_1":0.6,"rule_2":0.3,"default":0.1}}
{"case":"b","expected":["rule_2"],"confidence":0.7,"probabilities":{"rule_1":0.8,"rule_2":0.1,"default":0.1}}
{"case":"c","expected":null,"confidence":0.2,"probabilities":{"rule_1":0.4,"rule_2":0.35,"default":0.25}}
{"purpose":"dispatch-shadow","status":"clear","rule":"rule_2","confidence":0.97,"probabilities":{"rule_1":0.0,"rule_2":0.98,"default":0.02}}
{"case":"err","status":"error","probabilities":null}
JSONL
run_tool out err score --margin 0.3,0.5 --rows "$TMP_ROOT/score.jsonl"
expect_code 0 "$code" "score exits 0"
assert_equals 'replay-score: rows=4 labeled=2 skipped=1
  gate: confidence>=0.6 ambiguous=2 pass=2 wrong=1
  gate: margin>=0.3 ambiguous=1 pass=3 wrong=1
  gate: margin>=0.5 ambiguous=2 pass=2 wrong=1
  row: a pick=rule_1 first=rule_1 second=rule_2 margin=0.3 confidence=0.55 expected=rule_1 margin-gate=pass ok
  row: b pick=rule_1 first=rule_1 second=default margin=0.7 confidence=0.7 expected=rule_2 margin-gate=pass wrong
  row: c pick=rule_1 first=rule_1 second=rule_2 margin=0.05 confidence=0.2 expected=- margin-gate=ambiguous -
  row: #4 pick=rule_2 first=rule_2 second=default margin=0.96 confidence=0.97 expected=- margin-gate=pass -' "$out" "score compares both gates, counts wrong picks, and prints rows"
run_tool out err score "$TMP_ROOT/score.jsonl"
assert_contains "$out" '  gate: margin>=0.4 ambiguous=2 pass=2 wrong=1' "the default threshold is the resolver's default"
PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_JEV_DISPATCH_MARGIN=0.75 "$TOOL" score "$TMP_ROOT/score.jsonl" > "$TMP_ROOT/out" 2>&1
assert_contains "$(cat "$TMP_ROOT/out")" '  gate: margin>=0.75 ambiguous=3 pass=1 wrong=0' "FM_JEV_DISPATCH_MARGIN sets the default threshold"
printf '%s\n' \
  '{"case":"recorded","expected":["rule_2"],"rule":"rule_2","confidence":0.9,"probabilities":{"rule_1":0.9,"rule_2":0.05,"default":0.05}}' \
  '{"case":"argmax","expected":["rule_2"],"confidence":0.9,"probabilities":{"rule_1":0.9,"rule_2":0.05,"default":0.05}}' > "$TMP_ROOT/pick.jsonl"
run_tool out err score --margin 0.5 --rows "$TMP_ROOT/pick.jsonl"
assert_contains "$out" '  row: recorded pick=rule_2 first=rule_1 second=default margin=0.85 confidence=0.9 expected=rule_2 margin-gate=pass ok' "a recorded rule is judged even when it is not the most probable option"
assert_contains "$out" '  row: argmax pick=rule_1 first=rule_1 second=default margin=0.85 confidence=0.9 expected=rule_2 margin-gate=pass wrong' "a row without a recorded rule is judged by the most probable option"
assert_contains "$out" '  gate: margin>=0.5 ambiguous=0 pass=2 wrong=1' "the wrong count follows the judged pick"
cat > "$TMP_ROOT/top2.jsonl" <<'JSONL'
{"case":"tie","probabilities":{"b":0.4,"a":0.4,"c":0.2}}
{"case":"single","probabilities":{"only":1}}
{"case":"rounded","probabilities":{"alpha":0.512345,"beta":0.388889,"gamma":0.098766}}
JSONL
run_tool out err score --margin 0.1 --rows "$TMP_ROOT/top2.jsonl"
assert_contains "$out" '  row: tie pick=a first=a second=b margin=0 confidence=- expected=- margin-gate=ambiguous -' "ties use option names to order equal probabilities"
assert_contains "$out" '  row: single pick=only first=only second=- margin=1 confidence=- expected=- margin-gate=pass -' "a single option has the full margin"
assert_contains "$out" '  row: rounded pick=alpha first=alpha second=beta margin=0.1235 confidence=- expected=- margin-gate=pass -' "the margin is rounded to four decimal places"
cat > "$TMP_ROOT/boundaries.jsonl" <<'JSONL'
{"case":"below","expected":["rule_1"],"confidence":0.9,"probabilities":{"rule_1":0.52996,"rule_2":0.13,"rule_3":0.12,"rule_4":0.11,"default":0.11004}}
{"case":"exact-0.4","expected":["rule_1"],"confidence":0.9,"probabilities":{"rule_1":0.65,"rule_2":0.25,"rule_3":0.05,"rule_4":0.01,"default":0.04}}
{"case":"exact-0.45","expected":["rule_1"],"confidence":0.9,"probabilities":{"rule_1":0.63,"rule_2":0.18,"rule_3":0.11,"rule_4":0.03,"default":0.05}}
JSONL
run_tool out err score --margin 0.4,0.45 --rows "$TMP_ROOT/boundaries.jsonl"
assert_contains "$out" '  gate: margin>=0.4 ambiguous=1 pass=2 wrong=0' "the replay gate keeps a true 0.39996 margin ambiguous"
assert_contains "$out" '  gate: margin>=0.45 ambiguous=2 pass=1 wrong=0' "the replay gate passes an exact 0.45 margin"
assert_contains "$out" '  row: below pick=rule_1 first=rule_1 second=rule_2 margin=0.4 confidence=0.9 expected=rule_1 margin-gate=ambiguous -' "the displayed 0.4 does not pass on a raw 0.39996 margin"
assert_contains "$out" '  row: exact-0.4 pick=rule_1 first=rule_1 second=rule_2 margin=0.4 confidence=0.9 expected=rule_1 margin-gate=pass ok' "an exact 0.4 margin passes with tolerance"
run_tool out err score --margin 0.45 --rows "$TMP_ROOT/boundaries.jsonl"
assert_contains "$out" '  row: exact-0.45 pick=rule_1 first=rule_1 second=rule_2 margin=0.45 confidence=0.9 expected=rule_1 margin-gate=pass ok' "an exact 0.45 margin passes with tolerance"
pass "score: margin sweep, recorded picks, tie ordering, single option, and rounding"

# --- usage errors exit 2 -------------------------------------------------------
run_tool out err score --margin 0 "$TMP_ROOT/score.jsonl"
expect_code 2 "$code" "a zero margin is refused"
run_tool out err score --margin 0.3,abc "$TMP_ROOT/score.jsonl"
expect_code 2 "$code" "a non-numeric margin is refused"
run_tool out err score
expect_code 2 "$code" "score without input is refused"
run_tool out err run --cases "$CASES" --out "$RESULT"
expect_code 2 "$code" "run without a budget is refused"
assert_contains "$err" 'run needs --max-calls' "the missing budget is named"
printf '%s\n' $'ghost\tbriefs/missing.md\t-\t-' > "$TMP_ROOT/bad-cases.tsv"
run_tool out err run --cases "$TMP_ROOT/bad-cases.tsv" --out "$RESULT" --max-calls 5
expect_code 2 "$code" "an unreadable case brief is refused"
assert_contains "$err" 'case ghost brief not readable' "the unreadable brief is named"
run_tool out err bogus
expect_code 2 "$code" "an unknown command is refused"
pass "usage errors exit 2"

echo "# all fm-dispatch-replay tests passed"
