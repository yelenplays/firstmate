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
FM_JEV_EVAL_SCORES=$(fm_jev_act_scores "$TMP_ROOT")
export FM_JEV_EVAL_SCORES
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
[ -z "${FAKE_REQUEST_LOG:-}" ] || printf '%s\n' "$body" >> "$FAKE_REQUEST_LOG"
[ -z "${FAKE_CALL_LOG:-}" ] || printf 'typed\n' >> "$FAKE_CALL_LOG"
[ -z "${FAKE_TYPED_DELAY:-}" ] || sleep "$FAKE_TYPED_DELAY"
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
[ -z "${FAKE_REQUEST_LOG:-}" ] || printf '%s\n' "$prompt" >> "$FAKE_REQUEST_LOG"
[ -z "${FAKE_CALL_LOG:-}" ] || printf 'backup\n' >> "$FAKE_CALL_LOG"
[ "${FAKE_BACKUP_DOWN:-0}" = 1 ] && exit 1
expect=$(jq -r --arg p "$prompt" '[.samples[] | select(.brief as $s | $p | contains($s)) | .expect] | first // "default"' "$FAKE_SAMPLES")
jq -nc --arg r "$expect" '{type: "result", is_error: false, structured_output: {rule: $r, effort: "high"}, modelUsage: {"claude-haiku-5-5": {}}}'
SH
chmod +x "$FAKEBIN/fake-claude"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ -n "${FAKE_QUOTA_FIXTURE:-}" ]; then cat "$FAKE_QUOTA_FIXTURE"; exit; fi
cat <<'JSON'
{ "generatedAt": "2030-01-01T00:00:00Z", "schemaVersion": 5, "providers": [
  { "provider": "claude", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
    { "scope": "all_models", "status": "known", "effectivePercentRemaining": 80, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.2 } } ] } },
  { "provider": "codex", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
    { "scope": "all_models", "status": "known", "effectivePercentRemaining": 70, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.1 } } ] } } ] }
JSON
SH
chmod +x "$FAKEBIN/quota-axi"

output_identity() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %i "$1" 2>/dev/null
  else
    stat -c %i "$1" 2>/dev/null
  fi
}

run_selftest() { # <exit-var> <out-var> [args...]
  local __exit=$1 __out=$2 _out _code
  shift 2
  if [ "${1:-}" = check ]; then
    before_check_output=$(output_identity "$HOME_DIR/state/dispatch-selftest/last.out")
  fi
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=selftest-key FM_BACKUP_JUDGE_CMD=fake-claude \
    FM_SPEND_LEDGER="${FM_SPEND_LEDGER:-/nonexistent}" "$TOOL" "$@" 2>&1)
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

# --- a never-send list that is not a readable regular file sends nothing --------
# A dangling symlink is a present privacy list the resolver withholds on; the
# selftest must refuse rather than drop it and send every sample.
CALLS="$TMP_ROOT/calls.log"
ln -s "$TMP_ROOT/missing-never-send" "$HOME_DIR/config/dispatch-never-send"
: > "$CALLS"
FAKE_CALL_LOG="$CALLS" run_selftest code out run --rules "$RULES" --samples "$SAMPLES"
expect_code 2 "$code" "never-send: a dangling list refuses the run"
assert_contains "$out" 'dispatch-never-send list is not a readable regular file; nothing sent' "never-send: names the refusal"
assert_equals 0 "$(wc -l < "$CALLS" | tr -d ' ')" "never-send: no judge received a sample"
rm "$HOME_DIR/config/dispatch-never-send"
mkdir "$HOME_DIR/config/dispatch-never-send"
FAKE_CALL_LOG="$CALLS" run_selftest code out run --rules "$RULES" --samples "$SAMPLES"
expect_code 2 "$code" "never-send: a directory list refuses the run"
assert_equals 0 "$(wc -l < "$CALLS" | tr -d ' ')" "never-send: a directory list sends nothing"
rmdir "$HOME_DIR/config/dispatch-never-send"
pass "run: an unreadable never-send list refuses before any sample is sent"

# --- a matched rule whose floor falls through to the default lane fails --------
# The resolver routes those samples on the default profile, so the matched rule
# is not the lane they would dispatch on and the sample must not pass.
FLOOR_RULES="$TMP_ROOT/floor-rules.json"
jq '.rules[0].floor = {provider: "claude", scope: "all_models", min_percent: 90}' "$RULES" > "$FLOOR_RULES"
run_selftest code out run --rules "$FLOOR_RULES" --samples "$SAMPLES"
expect_code 1 "$code" "floor: a fall-through to the default lane fails the run"
assert_contains "$out" 'FAIL think-1 expect=rule_1 decided=default by=typed status=clear' "floor: the sample names the lane actually used"
assert_not_contains "$out" 'PASS think-' "floor: no fall-through sample passes"
assert_contains "$out" 'PASS fast-2 expect=rule_5 decided=rule_5 by=typed' "floor: rules without a shortfall still pass"
pass "run: a floor fall-through to the default lane is a failure, not a pass"

LEDGER="$ROOT/bin/fm-spend-ledger.py"
LEDGER_SAMPLES="$TMP_ROOT/ledger-samples.json"
LEDGER_RULES="$TMP_ROOT/ledger-rules.json"
LEDGER_QUOTA="$TMP_ROOT/ledger-quota.json"
LEDGER_SESSIONS="$TMP_ROOT/ledger-sessions"
REQUESTS="$TMP_ROOT/prediction-requests"
mkdir -p "$LEDGER_SESSIONS/--ledger-private--"
python3 - "$HOME_DIR/state" "$LEDGER_SESSIONS/--ledger-private--/session.jsonl" "$LEDGER_QUOTA" <<'PY'
import datetime
import json
import pathlib
import sys
import time
now = int(time.time())
start = now - 300
iso = lambda epoch: datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).isoformat()
pathlib.Path(sys.argv[1], "history.meta").write_text(f"worktree=/LEDGER_PRIVATE_MARKER\nspawn_gen=s{start-1}.1.test\nprivate=LEDGER_PRIVATE_MARKER\n")
records = [
    {"type": "session", "cwd": "/LEDGER_PRIVATE_MARKER", "id": "history", "timestamp": iso(start)},
    {"type": "thinking_level_change", "thinkingLevel": "high", "timestamp": iso(start)},
    {"type": "message", "timestamp": iso(start + 120), "message": {"role": "assistant", "provider": "openai-codex", "model": "gpt-5.6-sol", "content": "LEDGER_PRIVATE_MARKER", "usage": {"totalTokens": 100}}},
]
pathlib.Path(sys.argv[2]).write_text("".join(json.dumps(r) + "\n" for r in records))
providers = []
for provider, runway in [("claude", 60), ("codex", 600)]:
    providers.append({"provider": provider, "state": {"status": "fresh"}, "windows": [{"kind": "weekly", "resetsAt": iso(now + 86400), "percentRemaining": 80}], "quotaSemantics": {"status": "known", "effectiveAvailability": [{"scope": "all_models", "status": "known", "effectivePercentRemaining": 80, "runway": {"status": "projected_exhaustion", "usableRunwaySeconds": runway}, "selection": {"spendPriority": 0.2}}]}})
pathlib.Path(sys.argv[3]).write_text(json.dumps({"generatedAt": iso(now), "schemaVersion": 5, "providers": providers}))
PY
printf '%s\n' '{"rules":[{"when":"Implementation work.","use":{"harness":"claude","model":"opus","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}}' > "$LEDGER_RULES"
jq -n '{samples: [range(1;4) | {id: ("burn-" + tostring), brief: "Update the public app navigation.", expect: "rule_1"}]}' > "$LEDGER_SAMPLES"
"$LEDGER" --state "$HOME_DIR/state" --sessions-root "$LEDGER_SESSIONS" model >/dev/null
cp -R "$HOME_DIR/state" "$TMP_ROOT/prediction-state-before"
export FAKE_SAMPLES="$LEDGER_SAMPLES"
: > "$REQUESTS"
FM_SPEND_LEDGER="$LEDGER" FM_SPEND_SESSIONS="$LEDGER_SESSIONS" FAKE_QUOTA_FIXTURE="$LEDGER_QUOTA" FAKE_REQUEST_LOG="$REQUESTS" \
  run_selftest code out run --rules "$LEDGER_RULES" --samples "$LEDGER_SAMPLES"
expect_code 1 "$code" 'prediction: a live runway shortfall fails the direct selftest'
assert_contains "$out" 'FAIL burn-1 expect=rule_1 decided=default by=default' 'prediction: fresh model refuses the expected lane'
diff -r "$TMP_ROOT/prediction-state-before" "$HOME_DIR/state" >/dev/null || fail 'prediction: direct run changed live evidence'

jq '.generatedAt = "2000-01-01T00:00:00Z" | .median = {} | .anyProvider = {}' "$HOME_DIR/state/spend-model.json" > "$TMP_ROOT/stale-model.json"
cp "$TMP_ROOT/stale-model.json" "$HOME_DIR/state/spend-model.json"
cp "$HOME_DIR/state/.spend-cache.json" "$TMP_ROOT/cache-before"
FM_SPEND_LEDGER="$LEDGER" FM_SPEND_SESSIONS="$LEDGER_SESSIONS" FAKE_QUOTA_FIXTURE="$LEDGER_QUOTA" FAKE_REQUEST_LOG="$REQUESTS" FAKE_TYPED_DOWN=1 \
  run_selftest code out run --rules "$LEDGER_RULES" --samples "$LEDGER_SAMPLES" --record
expect_code 1 "$code" 'prediction: rebuilt evidence also fails the recorded backup run'
assert_contains "$out" 'FAIL burn-1 expect=rule_1 decided=default by=default' 'prediction: stale model rebuild preserves the runway gate'
jq -e '.exit == 1 and (.failing | contains("burn-1"))' "$HOME_DIR/state/dispatch-selftest/result.json" >/dev/null || fail 'prediction: recorded failure lost the sample'
cmp -s "$TMP_ROOT/stale-model.json" "$HOME_DIR/state/spend-model.json" || fail 'prediction: recorded run rewrote the live model'
cmp -s "$TMP_ROOT/cache-before" "$HOME_DIR/state/.spend-cache.json" || fail 'prediction: recorded run rewrote the live cache'
jq '(.providers[] | .quotaSemantics.effectiveAvailability[0].runway.usableRunwaySeconds) = 600 | (.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability[0].effectivePercentRemaining) = 2' "$LEDGER_QUOTA" > "$TMP_ROOT/token-quota.json"
jq '.rules[0].use = {harness: "codex", model: "gpt-5.6-sol", effort: "high"} | .default = {harness: "claude", model: "opus", effort: "high"}' "$LEDGER_RULES" > "$TMP_ROOT/token-rules.json"
rm "$HOME_DIR/state/spend-model.json"
FM_SPEND_LEDGER="$LEDGER" FM_SPEND_SESSIONS="$LEDGER_SESSIONS" FAKE_QUOTA_FIXTURE="$TMP_ROOT/token-quota.json" FAKE_REQUEST_LOG="$REQUESTS" \
  run_selftest code out run --rules "$TMP_ROOT/token-rules.json" --samples "$LEDGER_SAMPLES"
expect_code 1 "$code" 'prediction: calibrated token shortfalls also fail the selftest'
assert_contains "$out" 'FAIL burn-1 expect=rule_1 decided=default by=default' 'prediction: token evidence refuses the expected lane'
assert_absent "$HOME_DIR/state/spend-model.json" 'prediction: missing models are rebuilt without persistence'
cmp -s "$TMP_ROOT/cache-before" "$HOME_DIR/state/.spend-cache.json" || fail 'prediction: token run rewrote the live cache'
assert_not_contains "$(cat "$REQUESTS")" 'LEDGER_PRIVATE_MARKER' 'prediction: neither judge sees private prediction inputs'
assert_not_contains "$(cat "$REQUESTS")" 'tokensPerPoint' 'prediction: neither judge sees prediction aggregates'
assert_not_contains "$(cat "$REQUESTS")" 'usableRunwaySeconds' 'prediction: neither judge sees quota evidence'
rm -rf "$HOME_DIR/state/dispatch-selftest"
rm "$HOME_DIR/state/history.meta" "$HOME_DIR/state/.spend-cache.json"
export FAKE_SAMPLES="$SAMPLES"
pass 'selftests enforce live prediction gates without modifying or disclosing evidence'

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
# Pin the most recent slot before every recorded run, so an hour rollover
# cannot launch an unrelated nightly run during the changed-input cases.
# Other Perl calls (including backup-judge timing) still use the real tool.
real_perl=$(command -v perl) || fail 'perl is required for check scheduling tests'
export FAKE_REAL_PERL="$real_perl"
cat > "$FAKEBIN/perl" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -MPOSIX ] || exec "$FAKE_REAL_PERL" "$@"
if [ -n "${FAKE_SLOT_BARRIER:-}" ]; then
  exec 3<> "$FAKE_SLOT_BARRIER"
  : > "$FAKE_SLOT_BARRIER.ready"
  read -r -t 30 _ <&3 || exit 1
fi
printf '1\n'
SH
chmod +x "$FAKEBIN/perl"
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
# shellcheck disable=SC2012 # The path is a fixed, private state filename.
first_registration=$(ls -i "$HOME_DIR/state/dispatch-selftest.check-trust" | awk '{print $1}')
run_selftest code out arm
expect_code 0 "$code" "arm: repeated registration succeeds"
# shellcheck disable=SC2012 # The path is a fixed, private state filename.
second_registration=$(ls -i "$HOME_DIR/state/dispatch-selftest.check-trust" | awk '{print $1}')
assert_equals "$first_registration" "$second_registration" "arm: repeated registration preserves the existing binding"
[ -x "$HOME_DIR/state/dispatch-selftest.check.sh" ] || fail "arm: no shim"
[ -f "$HOME_DIR/state/dispatch-selftest.check-trust" ] || fail "arm: no trust binding"
assert_equals 3600 "$(cat "$HOME_DIR/state/dispatch-selftest.check-every")" "arm: hourly check cadence"

wait_for_result() {
  local i
  for ((i = 0; i < 300; i++)); do
    if [ "$(output_identity "$HOME_DIR/state/dispatch-selftest/last.out")" != "${before_check_output:-}" ] \
      && [ ! -d "$HOME_DIR/state/dispatch-selftest/running" ] \
      && jq -e '.state == "done"' "$HOME_DIR/state/dispatch-selftest/result.json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  fail "the detached run never recorded a result"
}

# A clean recorded pass binds the current rules and samples together.
run_selftest code out run --record
expect_code 0 "$code" "proof: the live sample set passes"
attempted_hash=$(cat "$HOME_DIR/state/dispatch-selftest/attempted.sha256")
[[ "$attempted_hash" =~ ^[[:xdigit:]]{64}$ ]] || fail "proof: a recorded run did not save an attempted SHA-256 digest"
started_before=$(jq -r '.started' "$HOME_DIR/state/dispatch-selftest/result.json")
run_selftest code out check
assert_equals '' "$out" "check: unchanged attempted inputs do not run before the nightly slot"
assert_equals "$started_before" "$(jq -r '.started' "$HOME_DIR/state/dispatch-selftest/result.json")" "check: unchanged inputs preserve the prior result"

printf '\n' >> "$HOME_DIR/config/crew-dispatch.json"
run_selftest code out check
assert_equals '' "$out" "check: a changed rules file starts an immediate run silently"
wait_for_result
jq -e '.exit == 0' "$HOME_DIR/state/dispatch-selftest/result.json" >/dev/null || fail "check: the changed rules run did not pass"
changed_hash=$(cat "$HOME_DIR/state/dispatch-selftest/attempted.sha256")
[ "$attempted_hash" != "$changed_hash" ] || fail "check: the changed rules hash was not recorded"
started_after_change=$(jq -r '.started' "$HOME_DIR/state/dispatch-selftest/result.json")
run_selftest code out check
assert_equals '' "$out" "check: the unchanged attempted hash does not run again"
assert_equals "$started_after_change" "$(jq -r '.started' "$HOME_DIR/state/dispatch-selftest/result.json")" "check: unchanged attempted hash preserves the result"
pass "check: changed rules trigger an immediate proof and passing inputs stay quiet"

# A failing changed input runs immediately and reports through the wake line.
cp "$HOME_DIR/config/dispatch-samples.json" "$TMP_ROOT/passing-samples.json"
printf '\n' >> "$HOME_DIR/config/dispatch-samples.json"
FAKE_TYPED_WRONG=impl-2 run_selftest code out check
assert_equals '' "$out" "check: changed samples launch a run silently"
wait_for_result
jq -e '.exit == 1 and .reported == false' "$HOME_DIR/state/dispatch-selftest/result.json" >/dev/null || fail "check: the changed-input failure was not recorded"
run_selftest code out check
assert_contains "$out" 'dispatch selftest failed: selftest: 7 samples, 6 pass, 1 fail: impl-2 - misrouted: impl-2(rule_2->rule_1)' "check: the failure names the sample"
assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "check: the failure is one wake line"
failed_started=$(jq -r '.started' "$HOME_DIR/state/dispatch-selftest/result.json")
run_selftest code out check
assert_equals '' "$out" "check: the next unchanged poll neither reruns nor re-alerts"
assert_equals "$failed_started" "$(jq -r '.started' "$HOME_DIR/state/dispatch-selftest/result.json")" "check: the failed attempt timestamp is retained"
cp "$TMP_ROOT/passing-samples.json" "$HOME_DIR/config/dispatch-samples.json"
run_selftest code out check
assert_equals '' "$out" "check: changed inputs launch an immediate retry silently"
wait_for_result
jq -e '.exit == 0' "$HOME_DIR/state/dispatch-selftest/result.json" >/dev/null || fail "check: the changed-input retry did not pass"
assert_contains "$(cat "$HOME_DIR/state/dispatch-selftest/last.out")" 'PASS impl-2' "check: the successful retry output is retained"
pass "check: failed attempts alert once until inputs change"

FAKE_TYPED_DELAY=0.15 PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=selftest-key \
  FM_BACKUP_JUDGE_CMD=fake-claude FM_SPEND_LEDGER=/nonexistent "$TOOL" run --record > "$TMP_ROOT/direct-run.out" 2>&1 &
direct_pid=$!
for ((i = 0; i < 100; i++)); do
  if [ -d "$HOME_DIR/state/dispatch-selftest/running" ] \
    && jq -e '.state == "running"' "$HOME_DIR/state/dispatch-selftest/result.json" >/dev/null 2>&1; then
    break
  fi
  sleep 0.02
done
[ -d "$HOME_DIR/state/dispatch-selftest/running" ] || fail "run --record: no running marker was created"
run_selftest code out run --record
expect_code 1 "$code" "run --record: an overlapping recorded run is refused"
assert_contains "$out" 'a recorded run is already active' "run --record: the active marker is respected"
run_selftest code out check
assert_equals '' "$out" "check: an active recorded run does not report a stopped run"
jq -e '.state == "running"' "$HOME_DIR/state/dispatch-selftest/result.json" >/dev/null || fail "check: an active recorded run was overwritten"
wait "$direct_pid" || fail "run --record: direct recorded run failed"
[ ! -d "$HOME_DIR/state/dispatch-selftest/running" ] || fail "run --record: its marker was not retired"
jq -e '.state == "done" and .exit == 0' "$HOME_DIR/state/dispatch-selftest/result.json" >/dev/null || fail "run --record: recorded pass was not preserved"
pass "run --record shares the check lock and cannot be mistaken for a stopped run"

for snapshot_case in completed stopped missing; do
  barrier="$TMP_ROOT/snapshot-$snapshot_case"
  mkfifo "$barrier"
  if [ "$snapshot_case" = stopped ]; then
    jq -n --argjson at "$(date +%s)" '{started: $at, state: "running"}' > "$HOME_DIR/state/dispatch-selftest/result.json"
    mkdir "$HOME_DIR/state/dispatch-selftest/running"
    printf '999999999\n' > "$HOME_DIR/state/dispatch-selftest/running/pid"
  elif [ "$snapshot_case" = missing ]; then
    mv "$HOME_DIR/config/dispatch-samples.json" "$TMP_ROOT/held-samples.json"
  fi
  FAKE_REAL_PERL="$real_perl" FAKE_SLOT_BARRIER="$barrier" PATH="$FAKEBIN:$BASE_PATH" \
    FM_HOME="$HOME_DIR" FM_SPEND_LEDGER=/nonexistent "$TOOL" check > "$barrier.out" 2>&1 &
  checker_pid=$!
  for ((i = 0; i < 200; i++)); do
    [ -f "$barrier.ready" ] && break
    sleep 0.02
  done
  [ -f "$barrier.ready" ] || fail "$snapshot_case: check never reached the scheduling barrier"
  cp "$HOME_DIR/state/dispatch-selftest/result.json" "$barrier.record"
  run_selftest code out run --record
  expect_code 1 "$code" "$snapshot_case: recorded run cannot enter a check's snapshot"
  assert_contains "$out" 'a recorded run is already active' "$snapshot_case: check owns the recorded-run guard"
  run_selftest code out check
  assert_equals '' "$out" "$snapshot_case: another check cannot enter the guarded snapshot"
  cmp -s "$barrier.record" "$HOME_DIR/state/dispatch-selftest/result.json" || fail "$snapshot_case: overlapping calls changed the result"
  printf 'continue\n' > "$barrier"
  wait "$checker_pid" || fail "$snapshot_case: guarded check failed"
  case "$snapshot_case" in
    completed) assert_equals '' "$(cat "$barrier.out")" 'completed: the pass is not reported as stopped' ;;
    stopped) assert_contains "$(cat "$barrier.out")" 'dispatch selftest failed: the run stopped before it finished' 'stopped: abandoned state is recovered once' ;;
    missing)
      assert_contains "$(cat "$barrier.out")" 'dispatch selftest failed: error: samples file is missing' 'missing: missing inputs are published under ownership'
      mv "$TMP_ROOT/held-samples.json" "$HOME_DIR/config/dispatch-samples.json" ;;
  esac
  [ ! -d "$HOME_DIR/state/dispatch-selftest/running" ] || fail "$snapshot_case: check did not release the guard"
  run_selftest code out run --record
  expect_code 0 "$code" "$snapshot_case: a recorded run succeeds after the check releases ownership"
  jq -e '.state == "done" and .exit == 0' "$HOME_DIR/state/dispatch-selftest/result.json" >/dev/null || fail "$snapshot_case: the subsequent recorded pass was lost"
done
pass 'check snapshots, stopped-run recovery, and missing-input publication exclude overlapping recorded runs'

# A run that died before recording is reported, not silently retried forever.
jq -n --argjson at "$(date +%s)" '{started: $at, state: "running"}' > "$HOME_DIR/state/dispatch-selftest/result.json"
run_selftest code out check
assert_contains "$out" 'dispatch selftest failed: the run stopped before it finished' "check: a dead run is reported"
pass "check: a run that stopped early is reported"

# The nightly slot re-runs the unchanged attempted digest.
nightly_hash=$(cat "$HOME_DIR/state/dispatch-selftest/attempted.sha256")
jq '.started = 0' "$HOME_DIR/state/dispatch-selftest/result.json" > "$TMP_ROOT/r.json" && mv "$TMP_ROOT/r.json" "$HOME_DIR/state/dispatch-selftest/result.json"
run_selftest code out check
wait_for_result
jq -e '.exit == 0' "$HOME_DIR/state/dispatch-selftest/result.json" >/dev/null || fail "check: the nightly re-run did not pass"
assert_equals "$nightly_hash" "$(cat "$HOME_DIR/state/dispatch-selftest/attempted.sha256")" "check: nightly retry keeps the unchanged digest"
run_selftest code out check
assert_equals '' "$out" "check: a passing run is silent"
pass "check: a passing scheduled run stays silent"

missing_hash_before=$(cat "$HOME_DIR/state/dispatch-selftest/attempted.sha256")
rm -f "$HOME_DIR/config/dispatch-samples.json"
run_selftest code out check
assert_contains "$out" 'dispatch selftest failed: error: samples file is missing' "check: an armed check alerts when samples disappear"
assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "check: missing samples produce one wake line"
missing_started=$(jq -r '.started' "$HOME_DIR/state/dispatch-selftest/result.json")
missing_hash_after=$(cat "$HOME_DIR/state/dispatch-selftest/attempted.sha256")
[ "$missing_hash_before" != "$missing_hash_after" ] || fail "check: the missing-samples marker was not recorded"
assert_contains "$(cat "$HOME_DIR/state/dispatch-selftest/last.out")" 'error: samples file is missing' "check: missing input replaces stale output"
run_selftest code out check
assert_equals '' "$out" "check: an unchanged missing-samples poll neither reruns nor re-alerts"
assert_equals "$missing_started" "$(jq -r '.started' "$HOME_DIR/state/dispatch-selftest/result.json")" "check: missing-input attempt timestamp is retained"
pass "check: a missing samples file alerts once until change or nightly slot"

DIGEST_BIN="$TMP_ROOT/digest-bin"
DIGEST_HOME="$TMP_ROOT/digest-home"
DIGEST_RESOLVER="$TMP_ROOT/digest-resolver"
cp -R "$ROOT/bin" "$DIGEST_BIN"
mkdir -p "$DIGEST_HOME/config" "$DIGEST_HOME/state"
printf '%s\n' '{"rules":[{"when":"Any task.","use":{"harness":"claude","model":"opus"}}]}' > "$DIGEST_HOME/config/crew-dispatch.json"
printf '%s\n' '{"samples":[{"id":"one","brief":"task one","expect":"rule_1"},{"id":"two","brief":"task two","expect":"rule_1"},{"id":"three","brief":"task three","expect":"rule_1"}]}' > "$DIGEST_HOME/config/dispatch-samples.json"
cat > "$DIGEST_RESOLVER" <<'SH'
#!/usr/bin/env bash
sleep 0.1
printf '%s\n' '  status: clear' '  decided: rule_1 by typed' '  profile: --harness claude'
SH
chmod +x "$DIGEST_RESOLVER"
digest_run() {
  if [ "${1:-}" = check ]; then
    before_digest_output=$(output_identity "$DIGEST_HOME/state/dispatch-selftest/last.out")
  fi
  PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$DIGEST_HOME" FM_DISPATCH_RESOLVE_BIN="$DIGEST_RESOLVER" \
    "$DIGEST_BIN/fm-dispatch-selftest.sh" "$@"
}
digest_run run --record >/dev/null || fail "digest proof: initial recorded run failed"
digest_hash=$(cat "$DIGEST_HOME/state/dispatch-selftest/attempted.sha256")
printf '\n' >> "$DIGEST_BIN/fm-dispatch-resolve.sh"
digest_run check >/dev/null || fail "digest proof: resolver change check failed"
for ((i = 0; i < 100; i++)); do
  [ "$(output_identity "$DIGEST_HOME/state/dispatch-selftest/last.out")" != "$before_digest_output" ] \
    && [ ! -d "$DIGEST_HOME/state/dispatch-selftest/running" ] \
    && jq -e '.state == "done"' "$DIGEST_HOME/state/dispatch-selftest/result.json" >/dev/null 2>&1 && break
  sleep 0.05
done
resolver_hash=$(cat "$DIGEST_HOME/state/dispatch-selftest/attempted.sha256")
[ "$digest_hash" != "$resolver_hash" ] || fail "digest proof: resolver content change did not trigger a new attempt"
printf '\n' >> "$DIGEST_BIN/fm-backup-judge-lib.sh"
digest_run check >/dev/null || fail "digest proof: backup change check failed"
for ((i = 0; i < 100; i++)); do
  [ "$(output_identity "$DIGEST_HOME/state/dispatch-selftest/last.out")" != "$before_digest_output" ] \
    && [ ! -d "$DIGEST_HOME/state/dispatch-selftest/running" ] \
    && jq -e '.state == "done"' "$DIGEST_HOME/state/dispatch-selftest/result.json" >/dev/null 2>&1 && break
  sleep 0.05
done
backup_hash=$(cat "$DIGEST_HOME/state/dispatch-selftest/attempted.sha256")
[ "$resolver_hash" != "$backup_hash" ] || fail "digest proof: backup judge content change did not trigger a new attempt"
pass "check: resolver and backup implementation changes trigger proof"

run_selftest code out disarm
expect_code 0 "$code" "disarm: succeeds"
[ ! -e "$HOME_DIR/state/dispatch-selftest.check.sh" ] && [ ! -e "$HOME_DIR/state/dispatch-selftest.check-trust" ] \
  && [ ! -e "$HOME_DIR/state/dispatch-selftest.check-every" ] || fail "disarm: left the check behind"
pass "disarm: retires the shim, its binding, and its cadence"

printf '# all fm-dispatch-selftest tests passed\n'
