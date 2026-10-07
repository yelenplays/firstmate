#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-selftest.sh, offline.
#
# The tracked synthetic fixture (tests/fixtures/dispatch-selftest/) runs through
# the real resolver with the typed call and the backup judge stubbed: a fake
# curl answers each sample's expected rule (or a wrong one on request, or not at
# all), a fake claude does the same as the backup judge, and a fake quota-axi
# serves fresh rows. Every case drives the public run/check/arm/disarm CLI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-dispatch-selftest.sh"
FIXTURE="$ROOT/tests/fixtures/dispatch-selftest"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-selftest)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HOME_DIR="$TMP_ROOT/home"
BASE_PATH=$PATH
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state"
SAMPLES="$FIXTURE/samples.json"
RULES="$FIXTURE/rules.json"
export FAKE_SAMPLES="$SAMPLES"

# The fake endpoint finds the sample whose brief is in the request state and
# answers its expected rule, or rule_1 for the id in FAKE_TYPED_WRONG; it does
# not answer at all when FAKE_TYPED_DOWN=1.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac
done
body=$(cat)
cat /dev/fd/3 >/dev/null 2>&1 || true
[ "${FAKE_TYPED_DOWN:-0}" = 1 ] && exit 7
brief=$(printf '%s' "$body" | jq -r '.state.task.brief // ""')
expect=$(jq -r --arg b "$brief" --arg wrong "${FAKE_TYPED_WRONG:-}" \
  '[.samples[] | select(.brief as $s | $b | contains($s)) | if .id == $wrong then "rule_1" else .expect end] | first // "default"' "$FAKE_SAMPLES")
printf '%s' "$body" | jq --arg c "$expect" '
  (.questions.rule.criteria | keys) as $opts
  | {model: "jev-1.13.0",
     answers: {
       rule: {type: "choice", choice: $c, confidence: 0.95,
         probabilities: ($opts | map({key: ., value: (if . == $c then 0.95 else (0.05 / (($opts | length) - 1)) end)}) | from_entries)},
       effort: {type: "choice", choice: "high", confidence: 0.9,
         probabilities: {low: 0.025, medium: 0.025, high: 0.9, xhigh: 0.025, max: 0.025}}},
     usage: {input_tokens: 100, output_tokens: 20}}' > "$out"
printf '200'
SH
chmod +x "$FAKEBIN/curl"

cat > "$FAKEBIN/fake-claude" <<'SH'
#!/usr/bin/env bash
set -u
prompt=$(cat)
[ "${FAKE_BACKUP_DOWN:-0}" = 1 ] && exit 1
expect=$(jq -r --arg p "$prompt" '[.samples[] | select(.brief as $s | $p | contains($s)) | .expect] | first // "default"' "$FAKE_SAMPLES")
jq -nc --arg r "$expect" '{type: "result", is_error: false, structured_output: {rule: $r, effort: "high"}, modelUsage: {"claude-haiku-5-5": {}}}'
SH
chmod +x "$FAKEBIN/fake-claude"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{ "generatedAt": "2030-01-01T00:00:00Z", "schemaVersion": 5, "providers": [
  { "provider": "claude", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
    { "scope": "all_models", "status": "known", "effectivePercentRemaining": 80, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.2 } } ] } },
  { "provider": "codex", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
    { "scope": "all_models", "status": "known", "effectivePercentRemaining": 70, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.1 } } ] } } ] }
JSON
SH
chmod +x "$FAKEBIN/quota-axi"

run_selftest() { # <exit-var> <out-var> [args...]
  local __exit=$1 __out=$2 _out _code
  shift 2
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=selftest-key FM_BACKUP_JUDGE_CMD=fake-claude \
    FM_SPEND_LEDGER=/nonexistent "$TOOL" "$@" 2>&1)
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
}
code='' out=''

# --- the fixture itself: about 30 samples, at least three per rule -----------
n=$(jq '.samples | length' "$SAMPLES")
[ "$n" -ge 28 ] || fail "fixture has $n samples, expected about 30"
rules=$(jq '.rules | length' "$RULES")
for ((r = 1; r <= rules; r++)); do
  c=$(jq --arg k "rule_$r" '[.samples[] | select(.expect == $k)] | length' "$SAMPLES")
  [ "$c" -ge 3 ] || fail "fixture rule_$r has $c samples, needs 3"
done
pass "fixture: $n samples with at least three per rule"

# --- typed stage answers every sample -------------------------------------------
run_selftest code out run --rules "$RULES" --samples "$SAMPLES"
expect_code 0 "$code" "typed: every sample routes"
assert_contains "$out" "selftest: $n samples, $n pass, 0 fail" "typed: the summary counts every pass"
assert_contains "$out" 'PASS fast-2 expect=rule_5 decided=rule_5 by=typed status=clear' "typed: a pass line names the stage"
assert_not_contains "$out" 'FAIL ' "typed: no sample fails"
assert_equals 0 "$(find "$HOME_DIR/state" -type f | wc -l | tr -d ' ')" "typed: a run writes nothing into the home"
pass "run: the typed stage routes every sample"

# --- typed call down: the backup judge answers every sample ---------------------
FAKE_TYPED_DOWN=1 run_selftest code out run --rules "$RULES" --samples "$SAMPLES"
expect_code 0 "$code" "backup: every sample routes with the typed call down"
assert_contains "$out" 'PASS think-1 expect=rule_1 decided=rule_1 by=backup status=' "backup: the backup stage decided"
pass "run: the backup judge routes every sample when the typed call is down"

# --- both judges down: the default stage answers, and the run says it failed ----
# The repeat runs below use a few samples; the full fixture ran twice above.
jq '.samples |= map(select(.id | IN("think-1", "front-2", "impl-2", "none-1")))' "$SAMPLES" > "$TMP_ROOT/few.json"
FAKE_TYPED_DOWN=1 FAKE_BACKUP_DOWN=1 run_selftest code out run --rules "$RULES" --samples "$TMP_ROOT/few.json"
expect_code 1 "$code" "default: misroutes fail the run"
assert_contains "$out" 'FAIL think-1 expect=rule_1 decided=default by=default status=fallback' "default: a misroute names the stage"
assert_contains "$out" 'PASS none-1 expect=default decided=default by=default' "default: default samples still pass"
pass "run: losing both judges is reported, never hidden behind the default answer"

# --- a single misroute is named -----------------------------------------------
FAKE_TYPED_WRONG=front-2 run_selftest code out run --rules "$RULES" --samples "$TMP_ROOT/few.json"
expect_code 1 "$code" "misroute: one wrong sample fails the run"
assert_contains "$out" 'FAIL front-2 expect=rule_2 decided=rule_1 by=typed' "misroute: the sample is named"
assert_contains "$out" 'PASS think-1 expect=rule_1 decided=rule_1 by=typed' "misroute: the other samples still pass"
assert_contains "$out" "fail: front-2 coverage" "misroute: the summary names the sample"
pass "run: a misrouted sample is named"

# --- coverage and input errors --------------------------------------------------
jq '.samples |= map(select(.expect != "rule_3"))' "$SAMPLES" > "$TMP_ROOT/thin.json"
run_selftest code out run --rules "$RULES" --samples "$TMP_ROOT/thin.json"
expect_code 1 "$code" "coverage: a rule without samples fails"
assert_contains "$out" 'COVERAGE rule_3 has 0 sample(s), needs 3' "coverage: the thin rule is named"
jq '.samples[0].expect = "rule_99"' "$SAMPLES" > "$TMP_ROOT/bad.json"
run_selftest code out run --rules "$RULES" --samples "$TMP_ROOT/bad.json"
expect_code 2 "$code" "input: an expect beyond the rules is an input error"
assert_contains "$out" 'each sample expect must be "default" or rule_1..rule_7' "input: the bad expect is explained"
jq '.samples[1].id = .samples[0].id' "$SAMPLES" > "$TMP_ROOT/dup.json"
run_selftest code out run --rules "$RULES" --samples "$TMP_ROOT/dup.json"
expect_code 2 "$code" "input: duplicate ids are an input error"
run_selftest code out run --rules "$RULES" --samples "$TMP_ROOT/absent.json"
expect_code 2 "$code" "input: a missing samples file is an input error"
jq '.rules[0].use.effort_max = "low"' "$RULES" > "$TMP_ROOT/bad-rules.json"
run_selftest code out run --rules "$TMP_ROOT/bad-rules.json" --samples "$SAMPLES"
expect_code 2 "$code" "input: rules the resolver refuses are an input error"
assert_contains "$out" 'error: the resolver refused the rules: ' "input: the refusal is named"
assert_not_contains "$out" 'FAIL ' "input: a refused rules file is not reported as misroutes"
pass "run: coverage gaps fail and malformed input is refused"

# --- nightly: arm, a detached run, one report, disarm -------------------------
# A two-rule home keeps the detached runs short.
jq '.rules |= .[4:6] | .rules[0].beats = [{"rule": 2, "when": "the change is one line"}] | del(.rules[1].beats)' "$RULES" > "$TMP_ROOT/home-rules.json"
jq '.samples |= (map(select(.expect | IN("rule_5", "rule_6"))) | map(.expect |= {"rule_5": "rule_1", "rule_6": "rule_2"}[.]))' "$SAMPLES" > "$TMP_ROOT/home-samples.json"
export FAKE_SAMPLES="$TMP_ROOT/home-samples.json"
cp "$TMP_ROOT/home-rules.json" "$HOME_DIR/config/crew-dispatch.json"
rm -f "$HOME_DIR/config/dispatch-samples.json"
run_selftest code out arm
expect_code 1 "$code" "arm: refused without a samples file"
cp "$TMP_ROOT/home-samples.json" "$HOME_DIR/config/dispatch-samples.json"
run_selftest code out arm
expect_code 0 "$code" "arm: succeeds with rules and samples"
[ -x "$HOME_DIR/state/dispatch-selftest.check.sh" ] || fail "arm: no shim"
[ -f "$HOME_DIR/state/dispatch-selftest.check-trust" ] || fail "arm: no trust binding"
assert_equals 3600 "$(cat "$HOME_DIR/state/dispatch-selftest.check-every")" "arm: hourly check cadence"

wait_for_result() {
  local i
  for ((i = 0; i < 300; i++)); do
    if [ ! -d "$HOME_DIR/state/dispatch-selftest/running" ] \
      && jq -e '.state == "done"' "$HOME_DIR/state/dispatch-selftest/result.json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  fail "the detached run never recorded a result"
}

# A failing nightly run: the first check launches it and returns silently, the
# next check reports it once, and the one after stays silent.
FAKE_TYPED_WRONG=impl-2 run_selftest code out check
expect_code 0 "$code" "check: launching a run exits 0"
assert_equals '' "$out" "check: launching a run is silent"
wait_for_result
jq -e '.exit == 1 and .reported == false' "$HOME_DIR/state/dispatch-selftest/result.json" >/dev/null || fail "check: the failing run was not recorded"
run_selftest code out check
assert_contains "$out" 'dispatch selftest failed: selftest: 7 samples, 6 pass, 1 fail: impl-2 - misrouted: impl-2(rule_2->rule_1)' "check: the failure names the sample"
assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "check: the report is one line"
run_selftest code out check
assert_equals '' "$out" "check: a failure is reported once"
assert_contains "$(cat "$HOME_DIR/state/dispatch-selftest/last.out")" 'FAIL impl-2' "check: the full output is kept"
pass "check: a failing nightly run becomes one actionable line"

# A run that died before recording is reported, not silently retried forever.
jq -n --argjson at "$(date +%s)" '{started: $at, state: "running"}' > "$HOME_DIR/state/dispatch-selftest/result.json"
run_selftest code out check
assert_contains "$out" 'dispatch selftest failed: the run stopped before it finished' "check: a dead run is reported"
pass "check: a run that stopped early is reported"

# The next scheduled slot re-runs; a passing run stays silent.
jq '.started = 0' "$HOME_DIR/state/dispatch-selftest/result.json" > "$TMP_ROOT/r.json" && mv "$TMP_ROOT/r.json" "$HOME_DIR/state/dispatch-selftest/result.json"
run_selftest code out check
wait_for_result
jq -e '.exit == 0' "$HOME_DIR/state/dispatch-selftest/result.json" >/dev/null || fail "check: the re-run did not pass"
run_selftest code out check
assert_equals '' "$out" "check: a passing run is silent"
pass "check: a passing scheduled run stays silent"

run_selftest code out disarm
expect_code 0 "$code" "disarm: succeeds"
[ ! -e "$HOME_DIR/state/dispatch-selftest.check.sh" ] && [ ! -e "$HOME_DIR/state/dispatch-selftest.check-trust" ] \
  && [ ! -e "$HOME_DIR/state/dispatch-selftest.check-every" ] || fail "disarm: left the check behind"
pass "disarm: retires the shim, its binding, and its cadence"

printf '# all fm-dispatch-selftest tests passed\n'
