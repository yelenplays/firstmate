#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-resolve.sh.
#
# Drives the public argv and environment interface with a fake curl on PATH
# that records argv, the request body it read from stdin, and the header it
# read from file descriptor 3, and answers with a canned typesafe.ai response.
# A fake quota-axi serves the selected schema-5 fixture. No case touches the
# network, and the absent-key case proves the tool makes no call
# at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-dispatch-resolve.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-resolve)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
# A passing eval scorecard lets the resolver's pick bind the spawn; the
# advise-only case below points this at a missing file.
FM_JEV_EVAL_SCORES=$(fm_jev_act_scores "$TMP_ROOT")
export FM_JEV_EVAL_SCORES
NO_CURL_BIN="$TMP_ROOT/no-curl-bin"
LOG="$TMP_ROOT/log"
BRIEF="$TMP_ROOT/brief.md"
BASE_RULES="$TMP_ROOT/rules.json"
RULES="$HOME_DIR/config/crew-dispatch.json"
QUOTA="$TMP_ROOT/quota.json"
BASE_PATH=$PATH
mkdir -p "$HOME_DIR/config" "$LOG" "$NO_CURL_BIN"
for command_name in bash chmod cp dirname jq mktemp rm; do
  ln -s "$(command -v "$command_name")" "$NO_CURL_BIN/$command_name"
done

cat > "$BRIEF" <<'MD'
# Task
Fix the off-by-one in the pager: root cause is the `<=` on line 40 of pager.sh, expected behavior is one page per call.
MD

cat > "$BASE_RULES" <<'JSON'
{
  "rules": [
    {
      "when": "New feature work on the app.",
      "floor": { "scope": "model:fable", "min_percent": 20, "provider": "claude" },
      "use": { "harness": "claude", "model": "fable", "effort": "xhigh" },
      "why": "SECRET-WHY-TEXT feature work wants the strongest model"
    },
    {
      "when": "The task generates images.",
      "use": [
        { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "provider": "codex" },
        { "harness": "codex", "model": "gpt-5.6-sol", "floor": { "scope": "all_models", "min_percent": 50 } }
      ]
    },
    {
      "when": "Genuinely very difficult design or planning work.",
      "approval": "captain",
      "use": { "harness": "claude", "model": "fable", "effort": "xhigh" }
    },
    {
      "when": "A simple bug fix with a stated root cause.",
      "use": [
        { "harness": "claude", "model": "sonnet", "effort": "high" },
        { "harness": "cursor", "model": "cursor-grok-4.6-medium" },
        { "harness": "kimi", "model": "kimi-code/k3" }
      ]
    }
  ],
  "default": [
    { "harness": "claude", "model": "opus" },
    { "harness": "cursor", "model": "cursor-grok-4.6-high" }
  ]
}
JSON
cp "$BASE_RULES" "$RULES"

write_quota() {  # <path> <cursor spendPriority> [<claude all_models spendPriority>]
  local path=$1 cursor=$2 claude=${3:--0.4627}
  cat > "$path" <<JSON
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    { "provider": "claude", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 79, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": $claude } },
      { "scope": "model:fable", "status": "known", "effectivePercentRemaining": 15, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -0.79 } } ] } },
    { "provider": "codex", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 31, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -0.1649 } } ] } },
    { "provider": "cursor", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 91, "runway": { "status": "through_reset" }, "selection": { "spendPriority": $cursor } } ] } },
    { "provider": "agy", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 64, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.4 } } ] } },
    { "provider": "google", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 72, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.3 } } ] } },
    { "provider": "kimi", "state": { "status": "unknown" }, "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } }
  ]
}
JSON
}
write_quota "$QUOTA" 0.7597

write_response() {  # <path> <choice> <confidence> [<probabilities-json>]
  local probabilities=${4:-'{ "rule_1": 0.01, "rule_2": 0.01, "rule_3": 0.01, "rule_4": 0.96, "default": 0.01 }'}
  cat > "$1" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "$2", "confidence": $3,
    "probabilities": $probabilities } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
}

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: records argv (minus the -o target), the stdin body, and the header
# read from fd 3, then answers with FAKE_CURL_RESPONSE and FAKE_CURL_HTTP.
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ] \
  || [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ]; then
  printf 'curl:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'curl:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
body=$(cat)
printf 'call\n' >> "$FAKE_CURL_LOG/calls"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
# A runoff request (it asks the `pick` Choice) is recorded and answered on its
# own, so the rule request's body stays inspectable after a runoff follows it.
if printf '%s' "$body" | jq -e '.questions.pick' >/dev/null 2>&1; then
  printf '%s' "$body" > "$FAKE_CURL_LOG/pick-body"
  if [ "${FAKE_CURL_PICK_FAIL:-0}" = 1 ]; then
    exit 7
  fi
  cp "${FAKE_CURL_PICK_RESPONSE:-${FAKE_CURL_RESPONSE:?}}" "$out"
  printf '%s' "${FAKE_CURL_PICK_HTTP:-200}"
  exit 0
fi
printf '%s' "$body" > "$FAKE_CURL_LOG/body"
if [ -n "${FAKE_CURL_MUTATE_SOURCE:-}" ]; then
  cp "$FAKE_CURL_MUTATE_SOURCE" "${FAKE_CURL_MUTATE_TARGET:?}"
fi
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ] \
  || [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ]; then
  printf 'quota-axi:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'quota-axi:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
printf '%s\n' "$*" >> "${QUOTA_AXI_CALLS:?}"
[ "${FAKE_QUOTA_FAIL:-0}" = 1 ] && exit 1
[ "${1:-}" = --json ] || exit 2
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"

# The spend ledger is a public-dependency boundary: the stub answers
# "unavailable" so these cases assert quota/gate behavior unchanged, and the
# effort/cost-aware cases override FM_SPEND_LEDGER with a fixture answer.
LEDGER_STUB="$TMP_ROOT/fm-spend-ledger.py"
cat > "$LEDGER_STUB" <<'SH'
#!/usr/bin/env bash
printf '{"status":"unavailable"}\n'
SH
chmod +x "$LEDGER_STUB"

RESPONSE="$TMP_ROOT/response.json"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" QUOTA_AXI_CALLS="$LOG/quota-axi.calls" QUOTA_AXI_FIXTURE="$QUOTA" CHILD_ENV_LOG="$LOG/child-env"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# run <exit-var> <out-var> <err-var> [args...]: the tool's typed stage alone
# (--typed-only) with fakebin first on PATH and an isolated FM_HOME;
# TYPESAFE_API_KEY comes from the caller's env. The typed gates are pinned
# here; the backup and default stages after them are pinned by run_chain below.
run() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_SPEND_LEDGER="${FM_SPEND_LEDGER:-$LEDGER_STUB}" "$TOOL" --typed-only "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

run_without_curl() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$NO_CURL_BIN" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="$KEY" FM_SPEND_LEDGER="$LEDGER_STUB" "$TOOL" --typed-only "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

KEY='test-key-9f1c2d3e-never-on-argv'
code='' out='' err=''

# --- absent key: off, silent on stdout, no network, no quota read -----------
reset_log
write_response "$RESPONSE" rule_4 0.9
run code out err "$BRIEF" --project pager
expect_code 0 "$code" "absent key exits 0"
assert_equals '' "$out" "absent key prints nothing on stdout"
assert_contains "$err" 'dispatch-resolve: off (TYPESAFE_API_KEY and OPENROUTER_API_KEY absent from the environment and' "absent key explains itself on stderr"
assert_absent "$LOG/argv" "absent key never calls curl"
assert_absent "$LOG/quota-axi.calls" "absent key never reads quota-axi"
pass "absent key is off: one stderr line, exit 0, no network call"

# --- .env key, and the environment wins over it ------------------------------
printf '%s\n' '# local secrets' 'FMX_PAIRING_TOKEN=abc' "export TYPESAFE_API_KEY=\"$KEY\"" > "$HOME_DIR/.env"
reset_log
run code out err "$BRIEF" --project pager
expect_code 0 "$code" ".env key resolves"
assert_contains "$out" '  status: clear' ".env key produces a clear result"
assert_contains "$(cat "$LOG/header")" "Authorization: Bearer $KEY" ".env key reaches curl on the fd header"
reset_log
TYPESAFE_API_KEY=env-wins run code out err "$BRIEF" --project pager
assert_equals 'Authorization: Bearer env-wins' "$(cat "$LOG/header")" "environment key wins over .env"
rm -f "$HOME_DIR/.env"
OVERRIDE_CONFIG="$TMP_ROOT/override-config"
mkdir -p "$OVERRIDE_CONFIG"
cp "$BASE_RULES" "$OVERRIDE_CONFIG/crew-dispatch.json"
reset_log
TYPESAFE_API_KEY=$KEY FM_CONFIG_OVERRIDE="$OVERRIDE_CONFIG" run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: clear' "FM_CONFIG_OVERRIDE selects the canonical rules directory"
pass "TYPESAFE_API_KEY= in .env activates the tool; environment and config overrides work"

# --- advise-only: the pick is advice until the eval score clears the bar ----
reset_log
write_response "$RESPONSE" rule_4 0.9
FM_JEV_EVAL_SCORES="$TMP_ROOT/no-scorecard.json" TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "advise-only exits 0"
assert_contains "$out" '  status: clear' "the match itself is still reported"
assert_not_contains "$out" '  profile: ' "an advise-only site prints no profile line for fm-spawn"
assert_contains "$out" "  mode: advise (this call site's eval score has not cleared the bar; decide as today)" "the mode says why"
assert_contains "$out" "  advice: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the pick is printed as advice"
pass "an advise-only dispatch site shows its pick as advice and binds nothing"

# --- clear: request shape, secret handling, argmax --------------------------
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "clear exits 0"
assert_contains "$out" 'dispatch-resolve:' "TOON block header"
assert_contains "$out" '  status: clear' "clear status"
assert_contains "$out" '  rule: rule_4 (A simple bug fix with a stated root cause.)   confidence: 0.9' "rule and confidence line"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "argmax picks the highest spendPriority"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  effort=high(range high)  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  pred=unknown  -> eligible' "every candidate is accounted for"
assert_contains "$out" 'candidate: kimi:kimi-code/k3  provider=kimi  pred=unknown  -> eligible, unranked: provider kimi unmeasured (unknown): disclosed uncertainty' "unmeasured provider stays listed as eligible and unranked"
assert_contains "$out" '  note: 1 eligible candidate(s) unranked (kimi)' "clear results flag eligible unranked candidates once"
assert_not_contains "$out" '--effort' "cursor profile without effort emits no --effort"
assert_not_contains "$out" '  mode: advise' "a passing eval score prints no advise mode"
argv=$(cat "$LOG/argv")
assert_not_contains "$argv" "$KEY" "the key never appears on curl argv"
assert_contains "$argv" 'https://api.typesafe.ai/v1/systemone' "the request uses the default typesafe.ai endpoint"
assert_contains "$argv" $'--max-time\n25' "the request uses the default 25-second timeout"
assert_contains "$argv" '@/dev/fd/3' "the header is read from a file descriptor"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "curl receives the bearer header on fd 3"
assert_equals $'curl:clean\nquota-axi:clean' "$(cat "$LOG/child-env")" "the API key is absent from every child environment"
body=$(cat "$LOG/body")
assert_equals 'jev-1.13.0' "$(jq -r .model <<<"$body")" "default model is the pinned jev-1.13.0"
assert_equals 'pager' "$(jq -r .state.task.project <<<"$body")" "project rides in the state"
assert_contains "$(jq -r .state.task.brief <<<"$body")" 'off-by-one in the pager' "a brief without task headings rides whole in the state"
assert_equals '["effort","rule"]' "$(jq -c '.questions | keys' <<<"$body")" "the rule and effort Choices are asked"
assert_equals '["default","rule_1","rule_2","rule_3","rule_4"]' "$(jq -c '.questions.rule.criteria | keys' <<<"$body")" "one option per rule plus default"
assert_equals 'No listed rule applies to this task.' "$(jq -r '.questions.rule.criteria.default' <<<"$body")" "the fixed generic none criterion is the default option"
assert_equals 'A simple bug fix with a stated root cause.' "$(jq -r '.questions.rule.criteria.rule_4' <<<"$body")" "rule when text is the option verbatim"
assert_not_contains "$body" 'SECRET-WHY-TEXT' "why text never leaves the machine"
assert_not_contains "$body" 'spendPriority' "quota never leaves the machine"
assert_not_contains "$body" 'cursor-grok' "use profiles never leave the machine"
pass "clear: one rule Choice request, key on the fd header only, spendPriority argmax over every candidate"

# --- never-send list: a match or a bad list withholds the request -------------
NEVER_SEND="$HOME_DIR/config/dispatch-never-send"
PRIVATE_BRIEF="$TMP_ROOT/private-brief.md"
cat > "$PRIVATE_BRIEF" <<'MD'
# Task
## Captain's intent
Fix the pager for the Acme-Ledger account 4417-2290.

## Firstmate spec
- Keep the change small.
MD
expect_withheld() {  # <label> <stderr fragment> [<value that must not print>...]
  local label=$1 fragment=$2
  shift 2
  expect_code 0 "$code" "$label exits 0"
  assert_equals '' "$out" "$label prints nothing on stdout, so firstmate uses its existing intake"
  assert_contains "$err" "dispatch-resolve: off ($fragment" "$label names why on stderr"
  assert_contains "$err" 'nothing sent)' "$label says nothing was sent"
  assert_equals '1' "$(grep -c . <<<"$err")" "$label prints one diagnostic line"
  assert_absent "$LOG/argv" "$label never calls curl"
  assert_absent "$LOG/quota-axi.calls" "$label never reads quota"
  local value
  for value in "$@"; do
    assert_not_contains "$err" "$value" "$label never prints the listed value"
  done
}

printf '%s\n' '# private values' '' '   ' 'Unlisted-Value' > "$NEVER_SEND"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
assert_contains "$out" '  status: clear' "a list with no match leaves resolution unchanged"
assert_contains "$(jq -r .state.task.brief "$LOG/body")" 'Acme-Ledger' "a list with no match sends the task text"

printf '%s\n' '# private values' '' '  acme-ledger  ' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a case-insensitive literal match" "brief text matches $NEVER_SEND line 3" 'acme-ledger' 'Acme-Ledger'

WRAPPED_BRIEF="$TMP_ROOT/wrapped-brief.md"
printf '# Task\n## Captain'"'"'s intent\nFix the pager for Example Client\nLtd before\tthe\xc2\xa0release.\n' > "$WRAPPED_BRIEF"
printf '%s\n' 'example  client ltd' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$WRAPPED_BRIEF" --project pager
expect_withheld "a literal the brief wraps across lines" "brief text matches $NEVER_SEND line 1" 'example' 'Example'

printf '%s\n' 'before the release' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$WRAPPED_BRIEF" --project pager
expect_withheld "a literal the brief spaces with a tab and a no-break space" "brief text matches $NEVER_SEND line 1" 'release'

printf '%s\n' 'orion-private' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project orion-private
expect_withheld "a project-name match" "brief text matches $NEVER_SEND line 1" 'orion-private'

printf '%s\n' 'stated root cause' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_withheld "a rule-criterion match" "brief text matches $NEVER_SEND line 1" 'stated root cause'

SECOND_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SECOND_HOME/config"
printf '%s\n' 'acme-ledger' > "$NEVER_SEND"
# A child shell keeps the lib's own globals (such as out) out of this script
# shellcheck disable=SC2016 # Expanded by the child shell
bash -c '. "$1" && propagate_inheritable_config "$2" "$3"' _ \
  "$ROOT/bin/fm-config-inherit-lib.sh" "$HOME_DIR/config" "$SECOND_HOME/config" \
  || fail "inheritance into the secondmate home failed"
PRIMARY_HOME=$HOME_DIR
HOME_DIR=$SECOND_HOME
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "an inherited list in a secondmate home" "brief text matches $SECOND_HOME/config/dispatch-never-send line 1" 'acme-ledger' 'Acme-Ledger'
HOME_DIR=$PRIMARY_HOME

rm -f "$NEVER_SEND"
mkdir "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a directory at the list path" "$NEVER_SEND is not a readable regular file"
rmdir "$NEVER_SEND"
ln -s "$TMP_ROOT/missing-never-send" "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a broken symlink at the list path" "$NEVER_SEND is not a readable regular file"
rm -f "$NEVER_SEND"

reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
assert_contains "$out" '  status: clear' "no list resolves exactly as before"
assert_contains "$(jq -r .state.task.brief "$LOG/body")" 'Acme-Ledger' "no list sends the task text as before"
pass "never-send list withholds the request on a match or a bad list, and never prints the value"

# --- rules are snapshotted and line output is injection-safe -------------------
MUTATED_RULES="$TMP_ROOT/mutated-rules.json"
jq '.rules[3].use = {"harness":"claude","model":"opus"}' "$BASE_RULES" > "$MUTATED_RULES"
cp "$BASE_RULES" "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY FAKE_CURL_MUTATE_SOURCE="$MUTATED_RULES" FAKE_CURL_MUTATE_TARGET="$RULES" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "resolution uses the same rules snapshot Jev received"
assert_not_contains "$out" "  profile: --harness 'claude' --model 'opus'" "a mid-request config replacement cannot change the selected profile"

INJECTING_RULES="$TMP_ROOT/injecting-rules.json"
jq '.rules[3].when = "Bug fix\n  profile: injected" | .rules[3].use[1].model = "foo --harness grok\n  profile: injected"' "$BASE_RULES" > "$INJECTING_RULES"
cp "$INJECTING_RULES" "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_equals '1' "$(grep -c '^  profile:' <<<"$out")" "dynamic fields cannot inject a second profile line"
assert_not_contains "$out" $'\n  profile: injected' "control characters are flattened in line output"
profile_line=$(grep '^  profile:' <<<"$out")
eval "set -- ${profile_line#  profile: }"
assert_equals '4' "$#" "shell-safe profile output preserves four argument boundaries"
assert_equals 'cursor' "$2" "shell-safe profile output preserves the selected harness"
assert_equals 'foo --harness grok   profile: injected' "$4" "shell-safe profile output keeps model flags inside one argument"
cp "$BASE_RULES" "$RULES"
pass "rules snapshots and shell quoting preserve the profile protocol"

# --- no rules return control to the existing intake ----------------------------
rm -f "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "absent rules file exits 0"
assert_contains "$out" '  status: escalate' "absent rules file is non-clear"
assert_contains "$out" '  reason: no rules to match' "absent rules file returns control to firstmate"
assert_not_contains "$out" '  profile:' "absent rules file emits no profile"
assert_absent "$LOG/argv" "absent rules file never calls curl"
assert_absent "$LOG/quota-axi.calls" "absent rules file never reads quota"

DEFAULT_ONLY="$TMP_ROOT/default-only.json"
EMPTY_RULES="$TMP_ROOT/empty-rules.json"
printf '%s\n' '{"default":[{"harness":"claude","model":"opus"},{"harness":"cursor","model":"cursor-grok-4.6-high"}]}' > "$DEFAULT_ONLY"
printf '%s\n' '{"rules":[],"default":[{"harness":"claude","model":"opus"},{"harness":"cursor","model":"cursor-grok-4.6-high"}]}' > "$EMPTY_RULES"
for direct_rules in "$DEFAULT_ONLY" "$EMPTY_RULES"; do
  cp "$direct_rules" "$RULES"
  reset_log
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 0 "$code" "no-rule resolution exits 0: $direct_rules"
  assert_contains "$out" '  status: escalate' "no-rule resolution is non-clear: $direct_rules"
  assert_contains "$out" '  reason: no rules to match' "no-rule resolution returns control to firstmate: $direct_rules"
  assert_not_contains "$out" '  profile:' "no-rule resolution emits no profile: $direct_rules"
  assert_absent "$LOG/argv" "no-rule resolution never calls curl: $direct_rules"
  assert_absent "$LOG/quota-axi.calls" "no-rule resolution never reads quota: $direct_rules"
done

AGY_RULE="$TMP_ROOT/agy-rule.json"
printf '%s\n' '{"rules":[{"when":"Agy work.","use":{"harness":"agy"}}]}' > "$AGY_RULE"
cp "$AGY_RULE" "$RULES"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.99,"probabilities":{"rule_1":0.99,"default":0.01}}},"usage":{"input_tokens":100,"output_tokens":60}}
JSON
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: agy:-  provider=agy  scope=all_models  remaining=64%  spendPriority=0.4  runway=through_reset  pred=unknown  -> eligible' "agy uses its resolver-only authoritative quota provider"
assert_contains "$out" "  profile: --harness 'agy'" "provider-less agy rule resolves"

GEMINI_RULE="$TMP_ROOT/gemini-rule.json"
printf '%s\n' '{"rules":[{"when":"Gemini work.","use":{"harness":"gemini","model":"gemini-3.8-flash-high","provider":"google"}}]}' > "$GEMINI_RULE"
cp "$GEMINI_RULE" "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: gemini:gemini-3.8-flash-high  provider=google  scope=all_models  remaining=72%  spendPriority=0.3  runway=through_reset  pred=unknown  -> eligible' "Gemini resolves through its explicit provider"
assert_contains "$out" "  profile: --harness 'gemini' --model 'gemini-3.8-flash-high'" "Gemini is a typed verified dispatch harness"

cp "$ROOT/docs/examples/crew-dispatch.json" "$RULES"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"default","confidence":0.9,"probabilities":{"rule_1":0.02,"rule_2":0.02,"rule_3":0.02,"default":0.94}}},"usage":{"input_tokens":812,"output_tokens":60}}
JSON
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "the documented example passes opted-in resolution"
assert_contains "$out" 'candidate: pi:anthropic/claude-sonnet-5  provider=claude' "the documented Pi default uses its declared Claude provider"
assert_not_contains "$err" 'malformed rules file' "the documented example reaches resolution"
cp "$BASE_RULES" "$RULES"
pass "no-rule fallback, Agy, Gemini, and documented configurations resolve"

# --- ambiguous: top-2 probability margin gate -----------------------------------
reset_log
write_response "$RESPONSE" rule_4 0.26 '{ "rule_1": 0.02, "rule_2": 0.30, "rule_3": 0.02, "rule_4": 0.41, "default": 0.25 }'
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "ambiguous exits 0"
assert_contains "$out" '  status: ambiguous' "a narrow top-2 margin is ambiguous"
assert_contains "$out" '  reason: top-2 margin 0.11 below 0.4 (rule_4 vs rule_2)' "ambiguous names the margin, the threshold, and both contenders"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  effort=high(range high)  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  pred=unknown  -> eligible' "ambiguous preserves matched candidate evidence"
assert_contains "$out" 'candidate: kimi:kimi-code/k3  provider=kimi  pred=unknown  -> eligible, unranked: provider kimi unmeasured (unknown): disclosed uncertainty' "ambiguous preserves eligible unranked candidate evidence"
assert_not_contains "$out" '  profile:' "ambiguous emits no profile line"
pass "ambiguous: a narrow top-2 margin hands the decision back"

reset_log
write_response "$RESPONSE" rule_2 0.4125 '{ "rule_1": 0.53, "rule_2": 0.13, "rule_3": 0.12, "rule_4": 0.11, "default": 0.11 }'
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "a non-winning choice cannot clear on a wide top-2 margin"
assert_contains "$out" '  reason: choice rule_2 is not the most probable option rule_1' "the ambiguity names the selected choice and probability leader"
assert_contains "$out" 'candidate: pi:openai-codex/gpt-5.6-sol' "a non-winning choice preserves candidate evidence"
assert_not_contains "$out" '  profile:' "a non-winning choice emits no profile line"
pass "ambiguous: a choice below the probability leader hands the decision back"

# --- runoff: a typed Jev pick settles an ambiguous answer among its contenders ---
PICK_RESPONSE="$TMP_ROOT/pick-response.json"
write_pick_response() {  # <path> <choice> <probabilities-json> [type]
  cat > "$1" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "pick": { "type": "${4:-choice}", "choice": "$2", "confidence": 0.8, "probabilities": $3 } },
  "usage": { "input_tokens": 400, "output_tokens": 20 } }
JSON
}
NARROW='{ "rule_1": 0.02, "rule_2": 0.30, "rule_3": 0.02, "rule_4": 0.41, "default": 0.25 }'
reset_log
write_response "$RESPONSE" rule_4 0.26 "$NARROW"
write_pick_response "$PICK_RESPONSE" rule_4 '{ "rule_4": 0.86, "rule_2": 0.14 }'
TYPESAFE_API_KEY=$KEY FAKE_CURL_PICK_RESPONSE=$PICK_RESPONSE run code out err "$BRIEF" --project pager
expect_code 0 "$code" "a settled runoff exits 0"
assert_contains "$out" '  status: picked' "a settled runoff reports picked"
assert_contains "$out" '  reason: top-2 margin 0.11 below 0.4 (rule_4 vs rule_2)' "picked keeps the reason the rule answer was ambiguous"
assert_contains "$out" '  pick: rule_4 (rule_4) over rule_2 by jev runoff   p=0.86 margin=0.72' "the pick line names the winner, the loser, and the evidence"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the winner's quota-ranked profile is emitted"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  effort=high(range high)' "the winner's candidates stay accounted for"
assert_equals '2' "$(grep -c . "$LOG/calls")" "a runoff spends exactly one more call"
assert_equals $'curl:clean\nquota-axi:clean\ncurl:clean' "$(cat "$LOG/child-env")" "the key stays out of every child environment across both calls"
pick_body=$(cat "$LOG/pick-body")
assert_equals '["pick"]' "$(jq -c '.questions | keys' <<<"$pick_body")" "the runoff asks one pick Choice"
assert_equals '["rule_2","rule_4"]' "$(jq -c '.questions.pick.criteria | keys' <<<"$pick_body")" "only the contenders are offered, keyed by rule"
assert_equals 'A simple bug fix with a stated root cause.' "$(jq -r '.questions.pick.criteria.rule_4' <<<"$pick_body")" "a contender is worded with its own rule criterion"
assert_equals "$(jq -c .state "$LOG/body")" "$(jq -c .state <<<"$pick_body")" "the runoff reuses the rule request's state"
assert_not_contains "$pick_body" 'cursor-grok' "use profiles never leave the machine in a runoff"
assert_not_contains "$pick_body" 'SECRET-WHY-TEXT' "why text never leaves the machine in a runoff"
assert_not_contains "$pick_body" 'spendPriority' "quota never leaves the machine in a runoff"
assert_not_contains "$(cat "$LOG/argv")" "$KEY" "the key never appears on curl argv in a runoff"
pass "runoff: a decisive pick among clearing contenders emits the winner's profile"

reset_log
write_pick_response "$PICK_RESPONSE" rule_2 '{ "rule_4": 0.2, "rule_2": 0.8 }'
TYPESAFE_API_KEY=$KEY FAKE_CURL_PICK_RESPONSE=$PICK_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  status: picked' "the runoff may pick the rule answer's runner-up"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "the runner-up's own quota-ranked profile is emitted"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol' "the runner-up's candidates replace the rule answer's"
assert_not_contains "$out" 'candidate: claude:sonnet' "the losing contender's candidates are not presented as the answer"
pass "runoff: the pick can overturn the rule answer's own choice"

for undecided in 'rule_4|{ "rule_4": 0.6, "rule_2": 0.4 }|runoff margin 0.2 below 0.4 (rule_4 vs rule_2)' \
                 'rule_2|{ "rule_4": 0.9, "rule_2": 0.1 }|runoff choice rule_2 is not the most probable option rule_4'; do
  IFS='|' read -r pick_choice pick_probs pick_reason <<<"$undecided"
  reset_log
  write_pick_response "$PICK_RESPONSE" "$pick_choice" "$pick_probs"
  TYPESAFE_API_KEY=$KEY FAKE_CURL_PICK_RESPONSE=$PICK_RESPONSE run code out err "$BRIEF"
  assert_contains "$out" '  status: ambiguous' "an undecided runoff stays ambiguous: $pick_reason"
  assert_contains "$out" "  pick: undecided ($pick_reason)" "the pick line names why the runoff did not settle"
  assert_not_contains "$out" '  profile:' "an undecided runoff emits no profile line: $pick_reason"
done
reset_log
write_pick_response "$PICK_RESPONSE" rule_4 '{ "rule_4": 0.9, "default": 0.1 }'
TYPESAFE_API_KEY=$KEY FAKE_CURL_PICK_RESPONSE=$PICK_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  pick: error (response is not a runoff Choice answer)' "a runoff answer over the wrong options is refused"
assert_not_contains "$out" '  profile:' "a malformed runoff answer emits no profile line"
reset_log
write_pick_response "$PICK_RESPONSE" rule_4 '{ "rule_4": 0.86, "rule_2": 0.14 }' text
TYPESAFE_API_KEY=$KEY FAKE_CURL_PICK_RESPONSE=$PICK_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "a text-typed pick cannot settle the runoff"
assert_contains "$out" '  pick: error (response is not a runoff Choice answer)' "a text-typed pick is reported as malformed"
assert_not_contains "$out" '  profile:' "a text-typed pick emits no profile line"
reset_log
jq 'del(.answers.pick.confidence)' "$PICK_RESPONSE" > "$TMP_ROOT/pick-missing-confidence.json"
TYPESAFE_API_KEY=$KEY FAKE_CURL_PICK_RESPONSE="$TMP_ROOT/pick-missing-confidence.json" run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "a pick without confidence cannot settle the runoff"
assert_contains "$out" '  pick: error (response is not a runoff Choice answer)' "a pick without confidence is reported as malformed"
assert_not_contains "$out" '  profile:' "a pick without confidence emits no profile line"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_PICK_RESPONSE=$PICK_RESPONSE FAKE_CURL_PICK_HTTP=500 run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "a failed runoff call stays ambiguous"
assert_contains "$out" '  pick: error (http 500 after' "a failed runoff call names the HTTP status"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_PICK_FAIL=1 run code out err "$BRIEF"
assert_contains "$out" '  pick: error (' "a runoff transport failure stays ambiguous"
assert_not_contains "$out" '  profile:' "a runoff transport failure emits no profile line"
pass "runoff: a narrow, non-winning, malformed, or failed pick hands the decision back"

reset_log
write_response "$RESPONSE" rule_4 0.26 '{ "rule_1": 0.02, "rule_2": 0.02, "rule_3": 0.30, "rule_4": 0.41, "default": 0.25 }'
TYPESAFE_API_KEY=$KEY FAKE_CURL_PICK_RESPONSE=$PICK_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "a captain-approval contender keeps the answer ambiguous"
assert_contains "$out" "  pick: skipped (rule_3 would not clear: rule requires the captain's explicit approval before dispatch)" "the approval rule is named as the reason no runoff ran"
assert_equals '1' "$(grep -c . "$LOG/calls")" "no runoff call is made past a captain-approval contender"
assert_not_contains "$out" '  profile:' "a captain-approval contender emits no profile line"
pass "runoff: a contender that would not clear, such as a captain-approval rule, skips the runoff"

reset_log
jq '.default = { "harness": "cursor", "model": "cursor-grok-4.6-medium" }' "$BASE_RULES" > "$RULES"
write_response "$RESPONSE" rule_4 0.46 '{ "rule_1": 0.09, "rule_2": 0.08, "rule_3": 0.08, "rule_4": 0.57, "default": 0.18 }'
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: picked' "contenders that land on one profile settle without a runoff call"
assert_contains "$out" '  pick: rule_4, default settle on the same profile (no runoff call)' "the agreeing contenders are named"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the shared profile is emitted"
assert_equals '1' "$(grep -c . "$LOG/calls")" "agreeing contenders need no second call"
cp "$BASE_RULES" "$RULES"
pass "runoff: contenders that settle on the same profile need no call"

reset_log
write_response "$RESPONSE" rule_4 0.26 "$NARROW"
write_pick_response "$PICK_RESPONSE" rule_4 '{ "rule_4": 0.86, "rule_2": 0.14 }'
printf '%s\n' 'plausibly fits' > "$HOME_DIR/config/dispatch-never-send"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_PICK_RESPONSE=$PICK_RESPONSE run code out err "$BRIEF"
assert_contains "$out" "  pick: skipped (brief text matches $HOME_DIR/config/dispatch-never-send line 1; nothing sent)" "the never-send list also guards the runoff request"
assert_absent "$LOG/pick-body" "a withheld runoff request never reaches curl"
assert_not_contains "$out" '  profile:' "a withheld runoff emits no profile line"
rm -f "$HOME_DIR/config/dispatch-never-send"
reset_log
rm -f "$HOME_DIR/state/jev-dispatch-shadow.jsonl"
TYPESAFE_API_KEY=$KEY FAKE_CURL_PICK_RESPONSE=$PICK_RESPONSE FM_JEV_DISPATCH_SHADOW=1 run code out err "$BRIEF" --project pager
line=$(cat "$HOME_DIR/state/jev-dispatch-shadow.jsonl")
assert_equals 'picked' "$(jq -r .status <<<"$line")" "the shadow log records a picked status"
assert_equals '{"state":"settled","rules":["rule_4"],"choice":"rule_4","probabilities":{"rule_4":0.86,"rule_2":0.14},"margin":0.72}' "$(jq -c .pick <<<"$line")" "the shadow log records the runoff evidence"
assert_equals 'cursor' "$(jq -r .profile.harness <<<"$line")" "the shadow log records the picked profile"
rm -f "$HOME_DIR/state/jev-dispatch-shadow.jsonl"
write_response "$RESPONSE" rule_4 0.9
pass "runoff: the never-send list and shadow log cover the runoff"

# --- the margin gate is invariant to option count and configurable ---------------
reset_log
write_response "$RESPONSE" rule_4 0.46 '{ "rule_1": 0.09, "rule_2": 0.08, "rule_3": 0.08, "rule_4": 0.57, "default": 0.18 }'
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "a margin just below the default threshold is ambiguous"
assert_contains "$out" '  reason: top-2 margin 0.39 below 0.4 (rule_4 vs default)' "the runner-up may be the none option"
reset_log
unset FM_JEV_DISPATCH_MARGIN
write_response "$RESPONSE" rule_1 0.99 '{ "rule_1": 0.52996, "rule_2": 0.13, "rule_3": 0.12, "rule_4": 0.11, "default": 0.11004 }'
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "a true margin below the threshold stays ambiguous despite display rounding"
assert_contains "$out" '  reason: top-2 margin 0.4 below 0.4 (rule_1 vs rule_2)' "the ambiguous reason keeps the rounded display margin"
reset_log
write_response "$RESPONSE" rule_4 0.45 '{ "rule_1": 0.10, "rule_2": 0.10, "rule_3": 0.09, "rule_4": 0.56, "default": 0.15 }'
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a derived confidence far below 0.6 still clears on a wide enough margin"
assert_contains "$out" '  rule: rule_4 (A simple bug fix with a stated root cause.)   confidence: 0.45' "the derived confidence is still reported unchanged"
reset_log
write_response "$RESPONSE" rule_4 0.56 '{ "rule_1": 0.0, "rule_2": 0.25, "rule_3": 0.0, "rule_4": 0.65, "default": 0.10 }'
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a margin exactly at the threshold clears"
reset_log
TYPESAFE_API_KEY=$KEY FM_JEV_DISPATCH_MARGIN=.5 run code out err "$BRIEF"
assert_contains "$out" '  reason: top-2 margin 0.4 below 0.5 (rule_4 vs rule_2)' "a leading-dot environment margin is normalized before the gate"
printf '%s\n' 'FM_JEV_DISPATCH_MARGIN=0.2' > "$HOME_DIR/.env"
reset_log
write_response "$RESPONSE" rule_4 0.26 '{ "rule_1": 0.02, "rule_2": 0.30, "rule_3": 0.02, "rule_4": 0.41, "default": 0.25 }'
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  reason: top-2 margin 0.11 below 0.2 (rule_4 vs rule_2)' "FM_JEV_DISPATCH_MARGIN in .env sets the threshold"
reset_log
TYPESAFE_API_KEY=$KEY FM_JEV_DISPATCH_MARGIN=0.1 run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "the environment wins over .env"
rm -f "$HOME_DIR/.env"
for bad_margin in 0 1.5 -0.2 abc . 0.3x; do
  reset_log
  TYPESAFE_API_KEY=$KEY FM_JEV_DISPATCH_MARGIN=$bad_margin run code out err "$BRIEF"
  expect_code 2 "$code" "invalid margin exits 2: $bad_margin"
  assert_contains "$err" 'FM_JEV_DISPATCH_MARGIN must be a number in (0, 1]' "invalid margin is named: $bad_margin"
  assert_absent "$LOG/argv" "invalid margin never reaches the network: $bad_margin"
done
write_response "$RESPONSE" rule_4 0.9
pass "margin gate: option-count invariant, inclusive threshold, environment then .env, invalid values refused"

# --- beats: precedence renders as tie-break sentences on both options -------------
reset_log
jq '.rules[1].beats = [{"rule": 4, "when": "the deliverable is an image"}] | .rules[3].beats = [{"rule": 1}]' "$BASE_RULES" > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "rules with beats resolve"
body=$(cat "$LOG/body")
assert_equals 'The task generates images. Tie-break: when rule_4 also fits and the deliverable is an image, choose this option over rule_4.' "$(jq -r '.questions.rule.criteria.rule_2' <<<"$body")" "the winner carries a conditional tie-break"
assert_equals 'A simple bug fix with a stated root cause. Tie-break: when rule_1 also fits, choose this option over rule_1. Tie-break: when rule_2 also fits and the deliverable is an image, choose rule_2 over this option.' "$(jq -r '.questions.rule.criteria.rule_4' <<<"$body")" "an option can both win and lose, winner sentences first"
assert_equals 'New feature work on the app. Tie-break: when rule_4 also fits, choose rule_4 over this option.' "$(jq -r '.questions.rule.criteria.rule_1' <<<"$body")" "the loser carries an unconditional tie-break"
# shellcheck disable=SC2016  # literal backticks in the expected question text
assert_contains "$(jq -r '.questions.rule.instructions' <<<"$body")" 'follow the Tie-break sentences at the end of the options; any rule whose condition fits wins over `default`.' "the instructions point at the tie-break sentences and rank every fitting rule over default"
assert_not_contains "$body" '"beats"' "the beats field itself never leaves the machine"
cp "$BASE_RULES" "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
body=$(cat "$LOG/body")
assert_not_contains "$body" 'Tie-break' "rules without beats send the question unchanged"
reset_log
jq '.rules[0].beats = [{"rule": 2, "when": "both fit"}] | .rules[1].beats = [{"rule": 1, "when": "both fit"}, {"rule": 3}]' "$BASE_RULES" > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a conditional pair and non-cyclic chain remain valid"
cp "$BASE_RULES" "$RULES"
pass "beats: tie-break sentences, conditional pairs, non-cyclic chains, and no-beats behavior"

# --- per-rule confidence floor ------------------------------------------------
write_floor_response() {  # <path> <choice> <confidence> <rule_1> <rule_2> <rule_3> <rule_4> <default>
  cat > "$1" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "$2", "confidence": $3,
    "probabilities": { "rule_1": $4, "rule_2": $5, "rule_3": $6, "rule_4": $7, "default": $8 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
}
FLOOR_RULES="$TMP_ROOT/floor-rules.json"
jq '.rules[1].min_confidence = 0.9 | .rules[3].min_confidence = 0.1' "$BASE_RULES" > "$FLOOR_RULES"
cp "$FLOOR_RULES" "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.02 0.76 0.02 0.18 0.02
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a top rule below its own floor falls to a runner-up that clears its floor"
assert_contains "$out" '  rule: rule_2 (The task generates images.)   confidence: 0.76' "the model's own pick stays visible"
assert_contains "$out" '  fallback: rule_4 (A simple bug fix with a stated root cause.) probability 0.18 clears its floor 0.1; rule_2 probability 0.76 is below its floor 0.9' "the fallback names both floors"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the runner-up rule's profiles are resolved"
assert_not_contains "$(cat "$LOG/body")" 'min_confidence' "the model never sees confidence floors"

reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.02 0.76 0.02 0.08 0.12
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "no runner-up clearing its own floor is ambiguous"
assert_contains "$out" '  reason: rule_2 probability 0.76 below its floor 0.9; no other option clears its own floor' "the undeclared default keeps the global floor as a runner-up"
assert_not_contains "$out" '  fallback:' "no fallback is reported when none is taken"
assert_not_contains "$out" '  profile:' "ambiguous per-rule floor emits no profile"
write_pick_response "$PICK_RESPONSE" rule_2 '{ "rule_2": 0.85, "default": 0.15 }'
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_PICK_RESPONSE=$PICK_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  pick: undecided (runoff choice rule_2 probability 0.85 below its floor 0.9)' "a runoff pick must clear the rule's own declared floor"
assert_not_contains "$out" '  profile:' "a runoff pick below its rule's floor emits no profile"
write_pick_response "$PICK_RESPONSE" rule_2 '{ "rule_2": 0.95, "default": 0.05 }'
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_PICK_RESPONSE=$PICK_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  status: picked' "a runoff pick at or above its rule's declared floor settles"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "the floored rule's profile is emitted once its floor is met"
write_pick_response "$PICK_RESPONSE" rule_9 '{ "rule_2": 0.95, "default": 0.05 }'
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_PICK_RESPONSE=$PICK_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  pick: error (response is not a runoff Choice answer)' "a runoff choice outside the offered options is refused"

jq '.rules[0].min_confidence = 0.1' "$FLOOR_RULES" > "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.12 0.76 0.0 0.12 0.0
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "equally probable runner-ups never break by option order"
assert_contains "$out" '  reason: rule_2 probability 0.76 below its floor 0.9; runner-up tie' "a runner-up tie is named"

cp "$FLOOR_RULES" "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_4 0.45 0.01 0.01 0.01 0.45 0.52
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "a declared floor below the global floor lets the picked rule resolve"

# A declared floor needs the same support from a rule as the pick or as a runner-up
jq '.rules[3].min_confidence = 0.3' "$FLOOR_RULES" > "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_4 0.25 0.25 0.05 0.05 0.35 0.30
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a picked rule clears its declared floor on its own probability, not the answer confidence"
assert_not_contains "$out" '  fallback:' "a picked rule that clears its own floor takes no fallback"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the picked rule resolves at probability 0.35 over floor 0.3"

reset_log
write_floor_response "$RESPONSE" rule_2 0.95 0.05 0.55 0.05 0.30 0.05
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a high answer confidence does not lift a picked rule over its own floor"
assert_contains "$out" '  fallback: rule_4 (A simple bug fix with a stated root cause.) probability 0.30 clears its floor 0.3; rule_2 probability 0.55 is below its floor 0.9' "the runner-up clears the same floor it would need as the pick"

reset_log
write_floor_response "$RESPONSE" rule_2 0.55 0.05 0.55 0.05 0.25 0.10
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "a runner-up below its own floor is not taken"
assert_contains "$out" '  reason: rule_2 probability 0.55 below its floor 0.9; no other option clears its own floor' "the missed runner-up floor is named"
cp "$BASE_RULES" "$RULES"

reset_log
write_floor_response "$RESPONSE" rule_2 0.55 0.01 0.55 0.01 0.42 0.01
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "without declared floors a low pick stays ambiguous"
assert_contains "$out" '  reason: top-2 margin 0.13 below 0.4 (rule_2 vs rule_4)' "without declared floors the top-2 margin gate governs unchanged"
assert_not_contains "$out" '  fallback:' "without declared floors no runner-up is taken"
pass "per-rule confidence floors fall to the most probable runner-up that clears its own floor"

# --- the model sees only the task-specific brief sections ----------------------
SCAFFOLD_BRIEF="$TMP_ROOT/scaffold-brief.md"
cat > "$SCAFFOLD_BRIEF" <<'MD'
# Task
## Captain's intent
Add a flag to the pager.

## Firstmate spec
Touch pager.sh only.
```sh
# Not a heading inside a fence
## Setup
```
### Out of scope
Anything else.

# Setup
BOILERPLATE-SETUP never push to the default branch.

## Captain intent authorized for --intent
BOILERPLATE-DUPLICATE
MD
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$SCAFFOLD_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'## Captain\'s intent\nAdd a flag to the pager.' "the captain's intent section is sent"
assert_contains "$sent" $'## Firstmate spec\nTouch pager.sh only.' "the Firstmate spec section is sent"
assert_contains "$sent" $'# Not a heading inside a fence\n## Setup\n```\n### Out of scope\nAnything else.' "fenced lines and subheadings stay inside the section"
assert_not_contains "$sent" 'BOILERPLATE' "scaffold boilerplate after the task sections is not sent"
assert_not_contains "$sent" '# Task' "the enclosing Task heading is not sent"
assert_not_contains "$sent" 'Brief kind:' "a brief without a scout contract line gets no kind line"

SPEC_ONLY_BRIEF="$TMP_ROOT/spec-only-brief.md"
printf '%s\n' '# Task' '## Firstmate spec' 'Spec text.' '## Rules' 'RULES-TEXT' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals $'## Firstmate spec\nSpec text.' "$(jq -r .state.task.brief "$LOG/body")" "one recognized section is enough"

printf '%s\n' '# Task' '## Firstmate spec   ' 'Spec text.' '## Rules' 'RULES-TEXT' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals "$(cat "$SPEC_ONLY_BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a heading with trailing blanks is not a section, matching spawn validation"

printf '%s\n' 'Preamble.' '## Firstmate spec' 'Spec text.' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals "$(cat "$SPEC_ONLY_BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a section outside the Task heading is not a task section"

KIND_BRIEF="$TMP_ROOT/kind-brief.md"
{ cat "$SCAFFOLD_BRIEF"; printf '%s\n' '# Definition of done' 'Delivery contract: mode=no-mistakes' 'Delivery contract: mode=direct-PR'; } > "$KIND_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$KIND_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'## Captain\'s intent\nAdd a flag to the pager.' "a ship brief still sends its task sections"
assert_not_contains "$sent" 'Brief kind:' "a ship brief gets no kind line"
assert_not_contains "$sent" 'mode=' "a ship brief's delivery mode is not sent"

{ cat "$SCAFFOLD_BRIEF"; printf '%s\n' 'This is a SCOUT task: the deliverable is a written report, not a PR.'; } > "$KIND_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$KIND_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'Brief kind: scout (report only)\n\n## Captain\'s intent' "a scout brief's contract line names its kind"
assert_not_contains "$sent" 'This is a SCOUT task' "the scout contract line itself is not sent"

reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_equals "$(cat "$BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a brief with neither heading is sent whole"
pass "only the brief's task sections and scout tag reach the model, with a whole-brief fallback"

# --- escalate: captain approval ------------------------------------------------
reset_log
write_response "$RESPONSE" rule_3 0.95 '{ "rule_1": 0.01, "rule_2": 0.01, "rule_3": 0.96, "rule_4": 0.01, "default": 0.01 }'
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "escalate exits 0"
assert_contains "$out" '  status: escalate' "approval-gated rule escalates"
assert_contains "$out" "  reason: rule requires the captain's explicit approval before dispatch" "escalate names the approval gate"
assert_contains "$out" 'candidate: claude:fable  provider=claude  effort=xhigh(range xhigh)  scope=model:fable  remaining=15%  spendPriority=-0.79  runway=projected_exhaustion  pred=unknown  bounds=all_models:79%/projected_exhaustion,model:fable:15%/projected_exhaustion  -> eligible' "approval escalation preserves matched candidate evidence"
assert_not_contains "$out" '  profile:' "escalate emits no profile line"
pass "escalate: a rule declared approval: captain never yields a profile"

# --- rule floor fails: fall through to default -------------------------------
reset_log
write_response "$RESPONSE" rule_1 0.97 '{ "rule_1": 0.96, "rule_2": 0.01, "rule_3": 0.01, "rule_4": 0.01, "default": 0.01 }'
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "rule floor fall-through still resolves"
assert_contains "$out" '  note: rule rule_1 floor model:fable below 20%: fall through to default' "rule floor fall-through is explained"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "fall-through resolves among the default profiles"
assert_not_contains "$out" 'candidate: claude:fable' "the floored rule's own profile is not a candidate"

MISSING_RULE_FLOOR="$TMP_ROOT/missing-rule-floor.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) |= map(select(.scope != "model:fable"))' "$QUOTA" > "$MISSING_RULE_FLOOR"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$MISSING_RULE_FLOOR" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "an unverifiable rule floor escalates"
assert_contains "$out" '  reason: rule rule_1 floor claude/model:fable is unverifiable' "the unverifiable rule floor names its provider and scope"
assert_not_contains "$out" '  profile:' "an unverifiable rule floor never authorizes default routing"
pass "rule floor: known shortfall falls through while unavailable evidence escalates"

# --- declared provider and profile floor --------------------------------------
reset_log
write_response "$RESPONSE" rule_2 0.99 '{ "rule_1": 0.01, "rule_2": 0.96, "rule_3": 0.01, "rule_4": 0.01, "default": 0.01 }'
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: pi:openai-codex/gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%' "declared provider routes a Pi profile to the codex row"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  -> not eligible: profile floor all_models below 50%' "profile floor makes a candidate ineligible with its reason"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "the remaining eligible candidate wins"

FLOOR_BOUNDS="$TMP_ROOT/floor-bounds.json"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability) += [
  {"scope":"model:gpt-5.6-sol","status":"known","effectivePercentRemaining":10,"runway":{"status":"projected_exhaustion"},"selection":{"spendPriority":-0.9}}
]' "$QUOTA" > "$FLOOR_BOUNDS"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$FLOOR_BOUNDS" run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  bounds=all_models:31%/projected_exhaustion,model:gpt-5.6-sol:10%/projected_exhaustion  -> not eligible: profile floor all_models below 50%' "a failed profile floor reports its named row while retaining all bounds"

FLOOR_WITH_UNKNOWN="$TMP_ROOT/floor-with-unknown.json"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:gpt-5.6-sol","status":"unknown","runway":{"status":"unknown"}}
])' "$QUOTA" > "$FLOOR_WITH_UNKNOWN"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$FLOOR_WITH_UNKNOWN" run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  bounds=all_models:31%/projected_exhaustion,model:gpt-5.6-sol:-%/unknown  -> not eligible: profile floor all_models below 50%' "a known profile-floor shortfall wins over unrelated unknown model evidence"

MISSING_PROFILE_FLOOR_RULES="$TMP_ROOT/missing-profile-floor-rules.json"
jq '.rules[1].use[1].floor.scope = "model:missing"' "$BASE_RULES" > "$MISSING_PROFILE_FLOOR_RULES"
cp "$MISSING_PROFILE_FLOOR_RULES" "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=model:missing  remaining=-%  spendPriority=-  runway=-  pred=unknown  -> eligible, unranked: profile floor model:missing is unverifiable: not rankable: disclosed uncertainty' "a missing profile floor remains eligible but unranked"
assert_not_contains "$out" 'profile floor model:missing below' "missing profile evidence is not described as a shortfall"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "another candidate may clear without misrepresenting missing floor evidence"
cp "$BASE_RULES" "$RULES"
pass "declared provider and profile floor evidence are applied in code"

# --- malformed ranking evidence is never ordered -------------------------------
reset_log
NONNUMERIC="$TMP_ROOT/nonnumeric-spend-priority.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models") | .selection.spendPriority) = "high"' "$QUOTA" > "$NONNUMERIC"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NONNUMERIC" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=-  runway=through_reset  pred=unknown  -> eligible, unranked: spendPriority missing or non-numeric at all_models: not rankable: disclosed uncertainty' "a nonnumeric spendPriority remains eligible but unranked"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "numeric evidence wins without mixed-type ordering"
pass "nonnumeric spendPriority evidence is never ranked"

# --- partial providers retain their known row evidence --------------------------
reset_log
PARTIAL="$TMP_ROOT/partial.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.status) = "partial"' "$QUOTA" > "$PARTIAL"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=0.7597  runway=through_reset  pred=unknown  -> eligible' "a known row from a partial provider remains rankable"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "partial provider evidence can win the argmax"

PARTIAL_UNKNOWN="$TMP_ROOT/partial-unknown.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:cursor-grok-4.6-medium","status":"unknown","runway":{"status":"unknown"}}
])' "$QUOTA" > "$PARTIAL_UNKNOWN"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL_UNKNOWN" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=model:cursor-grok-4.6-medium  remaining=-%  spendPriority=-  runway=-  pred=unknown  bounds=all_models:91%/through_reset,model:cursor-grok-4.6-medium:-%/unknown  -> eligible, unranked: quota row model:cursor-grok-4.6-medium unknown: not rankable: disclosed uncertainty' "an unknown exact-model row preserves partial known evidence without ranking"
assert_contains "$out" '  note: 2 eligible candidate(s) unranked (cursor, kimi)' "clear result lists every provider with unranked uncertainty"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "another measured candidate can clear"

PARTIAL_EXHAUSTED="$TMP_ROOT/partial-exhausted.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:cursor-grok-4.6-medium","status":"unknown","runway":{"status":"unknown"}}
] | .effectiveAvailability[] |= if .scope == "all_models" then .effectivePercentRemaining = 0 | .runway.status = "exhausted_now" else . end)' "$QUOTA" > "$PARTIAL_EXHAUSTED"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL_EXHAUSTED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=0%  spendPriority=-  runway=exhausted_now  bounds=all_models:0%/exhausted_now,model:cursor-grok-4.6-medium:-%/unknown  -> not eligible: runway exhausted_now at all_models' "known exhaustion vetoes a candidate despite unknown exact-model evidence"
assert_contains "$out" '  note: 1 eligible candidate(s) unranked (kimi)' "an exhausted candidate is excluded from the unranked uncertainty note"

UNKNOWN_EXHAUSTED="$TMP_ROOT/unknown-exhausted.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) = {
  "status":"unknown","effectiveAvailability":[
    {"scope":"all_models","status":"unknown","runway":{"status":"exhausted_now"}}
  ]
}' "$QUOTA" > "$UNKNOWN_EXHAUSTED"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$UNKNOWN_EXHAUSTED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=-%  spendPriority=-  runway=exhausted_now  -> not eligible: runway exhausted_now at all_models' "unknown provider semantics cannot mask concrete exhaustion"

NO_APPLICABLE="$TMP_ROOT/no-applicable.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability) = [
  {"scope":"model:other","status":"known","effectivePercentRemaining":91,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}}
]' "$QUOTA" > "$NO_APPLICABLE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NO_APPLICABLE" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  pred=unknown  -> eligible, unranked: no applicable quota row for provider cursor: disclosed uncertainty' "a candidate without an applicable row remains eligible but unranked"
assert_contains "$out" '  note: 2 eligible candidate(s) unranked (cursor, kimi)' "no-applicable-row uncertainty appears in the clear-result note"
pass "partial and missing quota evidence remain eligible but unranked"

# --- provider-wide rows remain bounds beside exact model rows ------------------
reset_log
BOUNDED="$TMP_ROOT/bounded.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) += [
  {"scope":"model:sonnet","status":"known","effectivePercentRemaining":99,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.9}}
]' "$QUOTA" > "$BOUNDED"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$BOUNDED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  effort=high(range high)  scope=all_models  remaining=79%  spendPriority=-0.4627' "the limiting provider-wide row drives ranking"
assert_contains "$out" 'bounds=all_models:79%/projected_exhaustion,model:sonnet:99%/through_reset' "all applicable quota bounds are disclosed"

EXHAUSTED_WIDE="$TMP_ROOT/exhausted-wide.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models")) |= (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")' "$BOUNDED" > "$EXHAUSTED_WIDE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$EXHAUSTED_WIDE" run code out err "$BRIEF"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  effort=high(range high)  scope=all_models  remaining=0%' "the exhausted account-wide bound is the candidate evidence"
assert_contains "$out" '-> not eligible: runway exhausted_now at all_models' "a healthy exact row cannot bypass an exhausted account-wide bound"
pass "provider-wide and exact quota rows combine into one limiting candidate"

# --- default choice ------------------------------------------------------------
reset_log
write_response "$RESPONSE" default 0.88 '{ "rule_1": 0.01, "rule_2": 0.01, "rule_3": 0.01, "rule_4": 0.01, "default": 0.96 }'
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  rule: default (No listed rule applies to this task.)' "default names the fixed neutral none option"
assert_contains "$out" '  note: no rule matched' "default is explained"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "default resolves by argmax"
pass "default: no rule matched resolves among the default profiles"

# --- genuine tie escalates ---------------------------------------------------------
reset_log
TIE="$TMP_ROOT/tie.json"
write_quota "$TIE" 0.5 0.5
write_response "$RESPONSE" default 0.88 '{ "rule_1": 0.01, "rule_2": 0.01, "rule_3": 0.01, "rule_4": 0.01, "default": 0.96 }'
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TIE" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "tie escalates"
assert_contains "$out" '  reason: genuine spendPriority tie' "tie is named"
pass "tie: equal spendPriority never breaks by array order"

# --- nothing rankable escalates -------------------------------------------------
reset_log
NONE="$TMP_ROOT/none.json"
jq '.providers |= map(if .provider == "cursor" or .provider == "claude" then .quotaSemantics.effectiveAvailability |= map(.runway.status = "exhausted_now") else . end)' "$QUOTA" > "$NONE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NONE" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "no rankable candidate escalates"
assert_contains "$out" '  reason: no rankable eligible candidate' "no-candidate reason"
assert_contains "$out" '-> not eligible: runway exhausted_now' "exhausted candidates keep their reason"
pass "no rankable candidate: the tool escalates instead of guessing"

# --- schema 6: rows keyed by provider + accountKey bind per account ----------------
# quota-axi emits schema 6 once a provider expands to several accounts; every
# row then carries accountKey and one provider id may appear on several rows.
# Native Codex and Pi lanes bind to their own account rows, with no row
# chosen by position or summed across accounts.
LANE_RULES="$TMP_ROOT/lane-rules.json"
SCHEMA6="$TMP_ROOT/schema6.json"
SCHEMA5_PAIR="$TMP_ROOT/schema5-pair.json"
cat > "$LANE_RULES" <<'JSON'
{
  "rules": [
    {
      "when": "Codex work.",
      "use": [
        { "harness": "pi", "model": "openai-codex-work/gpt-5.6-terra", "provider": "codex" },
        { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "provider": "codex" },
        { "harness": "codex", "model": "gpt-5.6-sol" }
      ]
    }
  ]
}
JSON
cat > "$SCHEMA6" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 6,
  "providers": [
    { "provider": "claude", "accountKey": "default", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } },
    { "provider": "codex", "accountKey": "openai-codex", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 0, "runway": { "status": "exhausted_now" }, "selection": { "spendPriority": -1.4788 } } ] } },
    { "provider": "codex", "accountKey": "openai-codex-work", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 11, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -5.6819 } } ] } },
    { "provider": "cursor", "accountKey": "default", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 24, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": 0.3917 } } ] } }
  ]
}
JSON
cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "rule_1", "confidence": 0.9,
    "probabilities": { "rule_1": 0.97, "default": 0.03 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
cp "$LANE_RULES" "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6" run code out err "$BRIEF"
expect_code 0 "$code" "schema 6 snapshot exits 0"
assert_contains "$out" '  status: clear' "schema 6 snapshot resolves"
assert_contains "$out" 'candidate: pi:openai-codex-work/gpt-5.6-terra  provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  pred=unknown  -> eligible' "a Pi lane binds to its own account row"
assert_contains "$out" 'candidate: pi:openai-codex/gpt-5.6-sol  provider=codex  scope=all_models  remaining=0%  spendPriority=-  runway=exhausted_now  -> not eligible: runway exhausted_now at all_models' "the sibling lane reads its own exhausted row"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  pred=unknown  -> eligible, unranked: provider codex has no quota row for account codex-home: disclosed uncertainty' "native Codex never infers an account from a Pi lane"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex-work/gpt-5.6-terra'" "the lane with headroom is chosen"
assert_equals '--json' "$(cat "$LOG/quota-axi.calls")" "schema 6 needs one quota-axi --json read"

SCHEMA6_NATIVE="$TMP_ROOT/schema6-native.json"
jq '
  .providers |= map(if .provider == "codex" then
    .quotaSemantics.effectiveAvailability |= map(.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")
    else . end) |
  (.providers[] | select(.accountKey == "openai-codex-work")) as $account |
  .providers += [($account | .accountKey = "default"),
    ($account | .accountKey = "codex-home" |
      .quotaSemantics.effectiveAvailability |= map(
        .effectivePercentRemaining = 80 | .runway.status = "through_reset" | .selection.spendPriority = 0.8))]
' "$SCHEMA6" > "$SCHEMA6_NATIVE"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6_NATIVE" run code out err "$BRIEF"
expect_code 0 "$code" "native Codex schema 6 snapshot exits 0"
assert_contains "$out" '  status: clear' "native Codex headroom resolves despite exhausted Pi and default rows"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=80%  spendPriority=0.8  runway=through_reset  pred=unknown  -> eligible' "native Codex reads codex-home"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex headroom is chosen"

jq '.providers |= reverse' "$SCHEMA6_NATIVE" > "$TMP_ROOT/schema6-reversed.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-reversed.json" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex selection ignores row order"

jq '.providers |= map(select(.provider != "codex" or .accountKey != "default") |
  if .accountKey == "codex-home" then .accountKey = "default" else . end)' "$SCHEMA6_NATIVE" > "$TMP_ROOT/schema6-default.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-default.json" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex falls back to the default row when codex-home is absent"
pass "native Codex binds to codex-home before default, independently of Pi accounts and row order"

jq '.schemaVersion = 5 | .providers |= map(select(.accountKey != "openai-codex")) | del(.providers[].accountKey)' "$SCHEMA6" > "$SCHEMA5_PAIR"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA5_PAIR" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "schema 5 keeps joining by provider alone"
assert_contains "$out" '  reason: genuine spendPriority tie' "every codex profile reads the one schema 5 codex row"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  pred=unknown  -> eligible' "a schema 5 row never needs accountKey"

SCHEMA6_PI_NATIVE="$TMP_ROOT/schema6-pi-native.json"
jq '.providers |= map(select(.provider != "codex" or .accountKey != "default"))' "$SCHEMA6_NATIVE" > "$SCHEMA6_PI_NATIVE"
for harness in pi pi-signed; do
  jq --arg harness "$harness" '.rules[0].use |= map(if .harness == "codex" then
    {harness: $harness, model: "codex-native/gpt-6-astra", provider: "codex", effort: "ultra"}
    else . end)' "$LANE_RULES" > "$RULES"
  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6_PI_NATIVE" run code out err "$BRIEF"
  expect_code 0 "$code" "$harness native adapter schema 6 exits 0"
  assert_contains "$out" '  status: clear' "$harness native adapter resolves with codex-home and no default row"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  effort=ultra(range ultra)  scope=all_models  remaining=80%  spendPriority=0.8  runway=through_reset  pred=unknown  -> eligible" "$harness native adapter reads codex-home"
  assert_contains "$out" "  profile: --harness '$harness' --model 'codex-native/gpt-6-astra' --effort 'ultra'" "$harness native adapter is chosen over exhausted Pi accounts"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-default.json" run code out err "$BRIEF"
  assert_contains "$out" "  profile: --harness '$harness' --model 'codex-native/gpt-6-astra' --effort 'ultra'" "$harness native adapter falls back to default"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6" run code out err "$BRIEF"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  effort=ultra(range ultra)  pred=unknown  -> eligible, unranked: provider codex has no quota row for account codex-home: disclosed uncertainty" "$harness native adapter never borrows a Pi account"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA5_PAIR" run code out err "$BRIEF"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  effort=ultra(range ultra)  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  pred=unknown  -> eligible" "$harness native adapter still joins schema 5 by provider alone"
done
cp "$LANE_RULES" "$RULES"
pass "Pi native adapters bind to codex-home with existing fallbacks and schema 5 compatibility"

jq 'del(.providers[1].accountKey)' "$SCHEMA6" > "$TMP_ROOT/schema6-keyless.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-keyless.json" run code out err "$BRIEF"
assert_contains "$out" '  status: error' "a schema 6 row without accountKey is an error outcome"
assert_contains "$out" '  reason: quota-axi --json returned an invalid snapshot' "keyless schema 6 row is named as an invalid snapshot"
cp "$BASE_RULES" "$RULES"
pass "schema 6: each candidate binds to its account row; schema 5 is unchanged"

# --- quota-axi is read exactly once --------------------------------------------
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "quota-axi path exits 0"
assert_equals '--json' "$(cat "$LOG/quota-axi.calls")" "quota-axi --json is called exactly once"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "quota-axi snapshot drives the argmax"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_QUOTA_FAIL=1 run code out err "$BRIEF"
expect_code 0 "$code" "quota-axi failure exits 0"
assert_contains "$out" '  status: error' "quota-axi failure is an error outcome"
assert_contains "$out" '  reason: quota-axi --json failed' "quota-axi failure is named"
pass "quota evidence comes from one quota-axi --json read, and its failure is an error outcome"

# --- API and response failures are error outcomes, exit 0 ----------------------
reset_log
run_without_curl code out err "$BRIEF"
expect_code 0 "$code" "missing curl exits 0"
assert_contains "$out" '  status: error' "missing curl is a structured error outcome"
assert_contains "$out" '  reason: curl not installed' "missing curl is named in the TOON block"
assert_contains "$err" 'dispatch-resolve: error (curl not installed)' "missing curl is also reported on stderr"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=429 run code out err "$BRIEF"
expect_code 0 "$code" "http 429 exits 0"
assert_contains "$out" '  status: error' "http 429 is an error outcome"
assert_contains "$out" '  reason: http 429 after' "http status is reported"
assert_contains "$err" 'dispatch-resolve: error (http 429' "error also goes to stderr"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_FAIL=1 run code out err "$BRIEF"
expect_code 0 "$code" "curl failure exits 0"
assert_contains "$out" '  reason: http 000 after' "transport failure reads as http 000"
reset_log
printf '%s\n' '{"model":"jev","answers":{}}' > "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  reason: response is not a rule Choice answer' "a malformed answer is an error outcome"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.usage = "bad"' "$RESPONSE" > "$TMP_ROOT/malformed-usage.json"
mv "$TMP_ROOT/malformed-usage.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "malformed usage is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "malformed usage cannot break text rendering silently"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq 'del(.answers.rule.probabilities.default)' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "missing probability choice is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must name every offered choice"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.answers.rule.probabilities.rule_4 = "high"' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "nonnumeric probability is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must be numeric and bounded"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.answers.rule.probabilities[] = 0' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "a zero-mass probability distribution is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must sum to approximately one"
reset_log
write_response "$RESPONSE" rule_4 2
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "out-of-range confidence is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "out-of-range confidence is a malformed answer"
reset_log
write_response "$RESPONSE" rule_9 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "an unknown rule id is an error outcome"
assert_contains "$out" '  reason: rule rule_9 is not in the rules file' "unknown rule id is named"
write_response "$RESPONSE" rule_0 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "rule zero is an error outcome"
assert_contains "$out" '  reason: rule rule_0 is not in the rules file' "rule zero cannot alias the final rule"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=500 run code out err "$BRIEF"
assert_contains "$out" '  status: error' "http 500 is a TOON error outcome"
pass "API, transport, and response failures are error outcomes with exit 0"

# --- configuration errors exit 2 and select nothing ----------------------------------
reset_log
TYPESAFE_API_KEY=$KEY run code out err
expect_code 2 "$code" "missing brief exits 2"
assert_contains "$err" 'brief file required' "missing brief is named"
rm -f "$RULES"
ln -s "$TMP_ROOT/missing-rules-target.json" "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "broken canonical rules symlink exits 2"
assert_contains "$err" "rules file not readable: $RULES" "broken rules symlink is actionable"
rm -f "$RULES"
printf '%s\n' '{"rules":[' > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "non-JSON rules exits 2"
assert_contains "$err" 'not JSON' "non-JSON rules is named"
for bad in \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"approval":"firstmate"}]}|approval must be "captain" when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"select":"mystery"}]}|unknown select: mystery' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"min_confidence":"high"}]}|min_confidence must be a number from 0 through 1 when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"min_confidence":1.5}]}|min_confidence must be a number from 0 through 1 when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"floor":{"scope":"model:fable","min_percent":20}}]}|rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\z' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"floor":{"scope":"model:fable","min_percent":20,"provider":"CLAUDE"}}]}|rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\z' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":""}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":" claude"}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":"claude\n"}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"codex","floor":{"scope":"all_models","min_percent":20,"provider":"claude"}}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":[{"harness":"codex","model":"gpt-5.5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]}]}|each rule use must not contain duplicate harness, model, and effort profiles' \
  '{"rules":[{"when":"x","use":{"harness":"codex"}}],"default":[{"harness":"claude","model":"opus"},{"harness":"claude","model":"opus"}]}|default must not contain duplicate harness, model, and effort profiles' \
  '{"rules":[{"when":"x","use":{"harness":"spaceship"}}]}|each use profile must name a verified harness' \
  '{"rules":[{"when":"x","use":{"harness":"grok","effort":"max"}}]}|each use profile effort must be supported by its harness and model' \
  '{"rules":[{"when":"x","use":{"harness":"opencode","model":"anthropic/claude-sonnet-4-5"}}]}|use profiles whose harness lacks one authoritative provider family require provider: opencode' \
  '{"rules":[{"when":"x","use":{"harness":"rovo"}}]}|use profiles whose harness lacks one authoritative provider family require provider: rovo' \
  '{"rules":[{"when":"x","use":{"harness":"codex"}}],"default":{"harness":"pi","model":"anthropic/claude-sonnet-5"}}|default profiles whose harness lacks one authoritative provider family require provider: pi' \
  '{"rules":[{"when":"x","use":{"harness":"codex"},"beats":[]},{"when":"y","use":{"harness":"codex"}}]}|beats must be a non-empty array of {rule, when?} naming other rules by 1-based number, each at most once, with when a non-empty string when present' \
  '{"rules":[{"when":"x","use":{"harness":"codex"},"beats":[{"rule":3}]},{"when":"y","use":{"harness":"codex"}}]}|beats must be a non-empty array of {rule, when?} naming other rules by 1-based number, each at most once, with when a non-empty string when present' \
  '{"rules":[{"when":"x","use":{"harness":"codex"},"beats":[{"rule":1}]},{"when":"y","use":{"harness":"codex"}}]}|beats must be a non-empty array of {rule, when?} naming other rules by 1-based number, each at most once, with when a non-empty string when present' \
  '{"rules":[{"when":"x","use":{"harness":"codex"},"beats":[{"rule":1.5}]},{"when":"y","use":{"harness":"codex"}}]}|beats must be a non-empty array of {rule, when?} naming other rules by 1-based number, each at most once, with when a non-empty string when present' \
  '{"rules":[{"when":"x","use":{"harness":"codex"},"beats":[{"rule":2},{"rule":2,"when":"z"}]},{"when":"y","use":{"harness":"codex"}}]}|beats must be a non-empty array of {rule, when?} naming other rules by 1-based number, each at most once, with when a non-empty string when present' \
  '{"rules":[{"when":"x","use":{"harness":"codex"},"beats":[{"rule":2,"when":""}]},{"when":"y","use":{"harness":"codex"}}]}|beats must be a non-empty array of {rule, when?} naming other rules by 1-based number, each at most once, with when a non-empty string when present' \
  '{"rules":[{"when":"x","use":{"harness":"codex"},"beats":[{"rule":2}]},{"when":"y","use":{"harness":"codex"},"beats":[{"rule":1}]}]}|two rules must not beat each other unconditionally; give at least one of the pair a when condition' \
  '{"rules":[{"when":"x","use":{"harness":"codex"},"beats":[{"rule":2,"when":"fits"}]},{"when":"y","use":{"harness":"codex"},"beats":[{"rule":3,"when":"fits"}]},{"when":"z","use":{"harness":"codex"},"beats":[{"rule":1,"when":"fits"}]}]}|beats must not form a cycle of three or more rules: rule_1 -> rule_2 -> rule_3 -> rule_1'; do
  printf '%s\n' "${bad%%|*}" > "$RULES"
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 2 "$code" "malformed rules exit 2: ${bad#*|}"
  assert_contains "$err" "malformed rules file: $RULES - ${bad#*|}" "malformed rules are named: ${bad#*|}"
done
printf '%s\n' '{"rules":[{"when":"x","use":[{"harness":"opencode"},{"harness":"rovo"},{"harness":"codex"}]}],"default":[{"harness":"pi"},{"harness":"claude"}]}' > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "multiple provider-less profiles exit 2"
assert_contains "$err" "malformed rules file: $RULES - use profiles whose harness lacks one authoritative provider family require provider: opencode; use profiles whose harness lacks one authoritative provider family require provider: rovo; default profiles whose harness lacks one authoritative provider family require provider: pi" "all provider-less profiles are reported together across use and default"
[ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" -eq 1 ] || fail "provider errors must use one diagnostic"
assert_absent "$LOG/argv" "configuration errors never reach the network"
cp "$BASE_RULES" "$RULES"
for removed in --json --rules --quota; do
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" "$removed"
  expect_code 2 "$code" "removed option is rejected: $removed"
  assert_contains "$err" "unknown flag $removed" "removed option has no public path: $removed"
done
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --bogus
expect_code 2 "$code" "unknown flag exits 2"
run code out err --help
expect_code 0 "$code" "--help exits 0"
assert_contains "$out" 'Usage:' "--help prints usage"
pass "configuration errors exit 2 before any network call"

OR_KEY='sk-or-v1-test-key-never-on-argv'
cp "$BASE_RULES" "$RULES"
write_response "$RESPONSE" rule_4 0.9

# --- OpenRouter route via fake curl --------------------------------------------
reset_log
OPENROUTER_API_KEY=$OR_KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "OpenRouter-only exits 0"
assert_contains "$out" '  status: clear' "OpenRouter-only still resolves a profile"
assert_contains "$(cat "$LOG/argv")" 'https://openrouter.ai/api/alpha/decisions' "OpenRouter-only uses the OpenRouter URL"
assert_equals "Authorization: Bearer $OR_KEY" "$(cat "$LOG/header")" "OpenRouter-only uses the OpenRouter bearer"
assert_equals 'typesafe/jev-1.13-20260917' "$(jq -r .model <"$LOG/body")" "OpenRouter default model is the pinned typesafe/jev-1.13-20260917"
assert_equals $'curl:clean\nquota-axi:clean' "$(cat "$LOG/child-env")" "the OpenRouter key is absent from every child environment"
assert_not_contains "$(cat "$LOG/argv")" "$OR_KEY" "the OpenRouter key never appears on curl argv"
reset_log
TYPESAFE_API_KEY=$KEY OPENROUTER_API_KEY=$OR_KEY JEV_ROUTE=openrouter run code out err "$BRIEF" --project pager
assert_contains "$(cat "$LOG/argv")" 'https://openrouter.ai/api/alpha/decisions' "JEV_ROUTE=openrouter wins over a TypeSafe key"
assert_equals "Authorization: Bearer $OR_KEY" "$(cat "$LOG/header")" "JEV_ROUTE=openrouter uses the OpenRouter bearer"
reset_log
TYPESAFE_API_KEY=$KEY JEV_URL='https://openrouter.ai/api/alpha/decisions' JEV_TIMEOUT=9 \
  run code out err "$BRIEF" --project pager
assert_contains "$(cat "$LOG/argv")" 'https://openrouter.ai/api/alpha/decisions' "JEV_URL is used verbatim on the resolver"
assert_not_contains "$(cat "$LOG/argv")" 'https://openrouter.ai/api/alpha/decisions/v1/systemone' "JEV_URL does not get /v1/systemone appended"
assert_contains "$(cat "$LOG/argv")" $'--max-time\n9' "JEV_TIMEOUT reaches curl"
reset_log
printf '%s\n' "TYPESAFE_API_KEY=$KEY" 'JEV_URL=https://file.example/jev' 'JEV_MODEL=from-file' 'JEV_TIMEOUT=11' > "$HOME_DIR/.env"
run code out err "$BRIEF" --project pager
rm -f "$HOME_DIR/.env"
assert_contains "$(cat "$LOG/argv")" 'https://file.example/jev' "resolver reads JEV_URL from .env"
assert_equals 'from-file' "$(jq -r .model <"$LOG/body")" "resolver reads JEV_MODEL from .env"
assert_contains "$(cat "$LOG/argv")" $'--max-time\n11' "resolver reads JEV_TIMEOUT from .env"
unset JEV_URL JEV_TIMEOUT JEV_MODEL JEV_BASE JEV_ROUTE
pass "OpenRouter path and URL/model/timeout overrides are covered by fake curl"

# --- compact state default for OpenRouter; explicit compact drops later sections ---
LONG_BRIEF="$TMP_ROOT/long-brief.md"
cat > "$LONG_BRIEF" <<'MD'
# Task
## Captain's intent
Fix the pager off-by-one so each call advances one page.
## Firstmate spec
TYPESAFE_API_KEY=should-never-leave-the-machine
Do not send this section or the assigned key.
MD
reset_log
OPENROUTER_API_KEY=$OR_KEY run code out err "$LONG_BRIEF" --project pager
body=$(cat "$LOG/body")
assert_contains "$(jq -r .state.task.brief <<<"$body")" 'Fix the pager off-by-one' "OpenRouter compact keeps the intent"
assert_not_contains "$body" 'should-never-leave-the-machine' "compact state redacts assigned keys"
assert_not_contains "$body" 'Do not send this section' "OpenRouter compact omits Firstmate spec"
reset_log
TYPESAFE_API_KEY=$KEY FM_JEV_DISPATCH_COMPACT=1 run code out err "$LONG_BRIEF" --project pager
body=$(cat "$LOG/body")
assert_not_contains "$body" 'should-never-leave-the-machine' "explicit compact redacts assigned keys"
assert_not_contains "$body" 'Do not send this section' "explicit compact omits Firstmate spec"
reset_log
printf 'FM_JEV_DISPATCH_COMPACT=1\n' > "$HOME_DIR/.env"
TYPESAFE_API_KEY=$KEY run code out err "$LONG_BRIEF" --project pager
body=$(cat "$LOG/body")
assert_contains "$(jq -r .state.task.brief <<<"$body")" 'Fix the pager off-by-one' ".env compact keeps the intent with process env unset"
assert_not_contains "$body" 'Do not send this section' ".env compact omits Firstmate spec with process env unset"
reset_log
TYPESAFE_API_KEY=$KEY FM_JEV_DISPATCH_COMPACT=0 run code out err "$LONG_BRIEF" --project pager
body=$(cat "$LOG/body")
assert_contains "$body" 'Do not send this section' "process env compact=0 wins over .env=1"
rm -f "$HOME_DIR/.env"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$LONG_BRIEF" --project pager
body=$(cat "$LOG/body")
assert_contains "$body" 'Do not send this section' "TypeSafe with compact unset sends the whole brief"
pass "compact state sends project plus intent, never credentials"

NESTED_BRIEF="$TMP_ROOT/nested-secret-brief.md"
cat > "$NESTED_BRIEF" <<'MD'
{
  "clientSecret": {
    "value": "opaque-vendor-secret"
  }
}
MD
reset_log
TYPESAFE_API_KEY=$KEY FM_JEV_DISPATCH_COMPACT=0 run code out err "$NESTED_BRIEF" --project pager
expect_code 0 "$code" "dispatch with a nested sensitive value still resolves"
body=$(cat "$LOG/body")
assert_equals 'pager' "$(jq -r '.state.task.project' <<<"$body")" \
  "dispatch reaches the mock transport after sanitizing the brief"
assert_not_contains "$(jq -r '.state.task.brief' <<<"$body")" 'opaque-vendor-secret' \
  "dispatch sanitization removes a nested value under a sensitive key"

YAML_BRIEF="$TMP_ROOT/nested-secret-yaml-brief.md"
cat > "$YAML_BRIEF" <<'MD'
clientSecret:
 value:
 text: opaque-vendor-secret
safe: retained
MD
reset_log
TYPESAFE_API_KEY=$KEY FM_JEV_DISPATCH_COMPACT=0 run code out err "$YAML_BRIEF" --project pager
expect_code 0 "$code" "dispatch with an indented YAML secret still resolves"
body=$(cat "$LOG/body")
assert_equals 'pager' "$(jq -r '.state.task.project' <<<"$body")" \
  "dispatch reaches the mock transport after sanitizing YAML"
assert_not_contains "$(jq -r '.state.task.brief' <<<"$body")" 'opaque-vendor-secret' \
  "dispatch sanitization removes nested YAML values under a sensitive key"
assert_contains "$(jq -r '.state.task.brief' <<<"$body")" 'safe: retained' \
  "dispatch preserves a sibling following the sensitive YAML block"

FLOW_BRIEF="$TMP_ROOT/next-line-flow-secret-brief.md"
cat > "$FLOW_BRIEF" <<'MD'
{
  "clientSecret":
  {"value":"opaque-vendor-secret"},
  "safe":"retained"
}
MD
reset_log
TYPESAFE_API_KEY=$KEY FM_JEV_DISPATCH_COMPACT=0 run code out err "$FLOW_BRIEF" --project pager
expect_code 0 "$code" "dispatch with a same-indent flow secret still resolves"
body=$(cat "$LOG/body")
assert_not_contains "$(jq -r '.state.task.brief' <<<"$body")" 'opaque-vendor-secret' \
  "dispatch removes a next-line flow value under a sensitive key"
assert_contains "$(jq -r '.state.task.brief' <<<"$body")" 'safe' \
  "dispatch preserves content after the matched next-line flow value"

# --- shadow logs the Jev pick and does not change the profile line --------------
reset_log
rm -f "$HOME_DIR/state/jev-dispatch-shadow.jsonl"
TYPESAFE_API_KEY=$KEY FM_JEV_DISPATCH_SHADOW=1 run code out err "$BRIEF" --project pager
expect_code 0 "$code" "shadow run exits 0"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "shadow still emits today's profile line"
line=$(cat "$HOME_DIR/state/jev-dispatch-shadow.jsonl")
assert_contains "$line" '"purpose":"dispatch-shadow"' "shadow writes a dispatch-shadow log line"
assert_contains "$line" '"status":"clear"' "shadow records the Jev status"
assert_contains "$line" '"harness":"cursor"' "shadow records the spawn axes"
assert_equals 'jev-1.13.0' "$(jq -r .model <<<"$line")" "shadow records the pinned request model"
assert_equals 'jev-1.13.0' "$(jq -r .response_model <<<"$line")" "shadow records the build that answered"
assert_not_contains "$line" "$KEY" "shadow log does not leak the TypeSafe key"
assert_not_contains "$out" "$KEY" "stdout does not leak the TypeSafe key"
reset_log
rm -f "$HOME_DIR/state/jev-dispatch-shadow.jsonl"
touch "$HOME_DIR/config/jev-dispatch-shadow"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
assert_contains "$(cat "$HOME_DIR/state/jev-dispatch-shadow.jsonl")" '"purpose":"dispatch-shadow"' "config/jev-dispatch-shadow enables shadow logging"
rm -f "$HOME_DIR/config/jev-dispatch-shadow" "$HOME_DIR/state/jev-dispatch-shadow.jsonl"
reset_log
TYPESAFE_API_KEY=$KEY FM_JEV_DISPATCH_SHADOW=0 run code out err "$BRIEF" --project pager
assert_absent "$HOME_DIR/state/jev-dispatch-shadow.jsonl" "FM_JEV_DISPATCH_SHADOW=0 does not log"
pass "shadow flag logs without changing spawn output"

# --- extra home/deliverable questions are log-only ------------------------------
mkdir -p "$HOME_DIR/data"
cat > "$HOME_DIR/data/secondmates.md" <<'MD'
- agency - Agency home (home: /tmp/agency; scope: Brand and agency work; projects: none; added 2026-01-01)
MD
jq '.answers.home = {"type":"choice","choice":"agency","confidence":0.8,"probabilities":{"main":0.1,"agency":0.8,"lay":0.04,"frontend":0.03,"zimmer":0.03}} | .answers.deliverable = {"type":"choice","choice":"scout","confidence":0.7,"probabilities":{"ship":0.2,"scout":0.7,"neither":0.1}}' "$RESPONSE" > "$TMP_ROOT/extra-response.json"
mv "$TMP_ROOT/extra-response.json" "$RESPONSE"
reset_log
rm -f "$HOME_DIR/state/jev-dispatch-shadow.jsonl"
TYPESAFE_API_KEY=$KEY FM_JEV_DISPATCH_EXTRA=1 FM_JEV_DISPATCH_SHADOW=1 run code out err "$BRIEF" --project pager
body=$(cat "$LOG/body")
assert_equals '["deliverable","effort","home","rule"]' "$(jq -c '.questions | keys' <<<"$body")" "extra asks home and deliverable beside rule and effort"
assert_equals 'Brand and agency work' "$(jq -r '.questions.home.criteria.agency' <<<"$body")" "home criteria use secondmates.md scope when readable"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "extra questions do not change the profile line"
assert_not_contains "$out" 'agency' "extra home pick is not auto-routed on stdout"
line=$(cat "$HOME_DIR/state/jev-dispatch-shadow.jsonl")
assert_contains "$line" '"home":"agency"' "shadow logs the extra home pick"
assert_contains "$line" '"deliverable":"scout"' "shadow logs the extra deliverable pick"
rm -f "$HOME_DIR/data/secondmates.md" "$HOME_DIR/state/jev-dispatch-shadow.jsonl"
write_response "$RESPONSE" rule_4 0.9
pass "extra questions are log-only"

# --- effort classifier: dynamic class, range clamp, max guard, fallback -------

# write_response_effort <path> <choice> <confidence> <effort-choice>: a canned
# response carrying the second typed effort answer.
write_response_effort() {
  cat > "$1" <<JSON
{ "model": "jev-1.13.0",
  "answers": {
    "rule": { "type": "choice", "choice": "$2", "confidence": $3,
      "probabilities": { "rule_1": 0.01, "rule_2": 0.01, "rule_3": 0.01, "rule_4": 0.96, "default": 0.01 } },
    "effort": { "type": "choice", "choice": "$4", "confidence": 0.9,
      "probabilities": { "low": 0.05, "medium": 0.05, "high": 0.05, "xhigh": 0.05, "max": 0.8 } }
  },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
}

# A declared range lets the assessed class through: rule_4's claude profile
# declares high with effort_min low, Jev assesses low, and the emitted effort
# is the assessed class. Cursor gets a lower spendPriority so the
# effort-capable lane wins the argmax.
reset_log
LOW_CURSOR="$TMP_ROOT/low-cursor-quota.json"
write_quota "$LOW_CURSOR" -0.9
RANGE_RULES="$TMP_ROOT/range-rules.json"
jq '.rules[3].use[0].effort_min = "low"' "$BASE_RULES" > "$RANGE_RULES"
cp "$RANGE_RULES" "$RULES"
write_response_effort "$RESPONSE" rule_4 0.9 low
jq '.answers.effort.probabilities = {"low":0.8,"medium":0.05,"high":0.05,"xhigh":0.05,"max":0.05}' "$RESPONSE" > "$TMP_ROOT/r.json" && mv "$TMP_ROOT/r.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$LOW_CURSOR" run code out err "$BRIEF"
assert_contains "$out" '  effort: low (jev confidence=0.9)' "effort line names the assessed class"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  effort=low(range low..high)' "the assessed class inside the range is the emitted class"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'low'" "the assessed class is emitted on the profile line"
pass "effort range: an assessed class inside the declared range is emitted"

# A bare effort is a one-level range: the same low assessment is clamped up to
# the declared high, and the clamp is shown on the candidate line.
cp "$BASE_RULES" "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$LOW_CURSOR" run code out err "$BRIEF"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  effort=high(range high) [clamped from low]' "a bare effort clamps the assessment to itself"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "the declared effort is emitted"
pass "effort range: a bare effort is a one-level range"

# An assessed class above the range is clamped to its top and logged, never a
# refusal: the 2026-10-07 escalate ("assessed effort high exceeds declared
# ceiling medium") cannot recur.
reset_log
write_response_effort "$RESPONSE" rule_4 0.9 max
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$LOW_CURSOR" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "an assessment above the range still clears"
assert_contains "$out" 'effort=high(range high) [clamped from max]' "the clamp is disclosed"
assert_not_contains "$out" 'exceeds declared ceiling' "an assessment never refuses a candidate"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "the range top is emitted"
pass "effort range: an assessment above the range is clamped, never refused"

# max is reachable only through an explicit declaration: a rule declaring max
# lets an assessed max through; nothing else emits max.
MAX_RULE="$TMP_ROOT/max-rule.json"
printf '%s\n' '{"rules":[{"when":"The hardest work.","use":{"harness":"claude","model":"opus","effort":"max"}}]}' > "$MAX_RULE"
cp "$MAX_RULE" "$RULES"
cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": {
    "rule": { "type": "choice", "choice": "rule_1", "confidence": 0.95,
      "probabilities": { "rule_1": 0.95, "default": 0.05 } },
    "effort": { "type": "choice", "choice": "max", "confidence": 0.9,
      "probabilities": { "low": 0.05, "medium": 0.05, "high": 0.05, "xhigh": 0.05, "max": 0.8 } }
  },
  "usage": { "input_tokens": 100, "output_tokens": 60 } }
JSON
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "declared max admits an assessed max"
assert_contains "$out" "  profile: --harness 'claude' --model 'opus' --effort 'max'" "declared max emits max"
cp "$BASE_RULES" "$RULES"

# The clamped class moves to the nearest level the harness supports inside the
# range: an undeclared effort allows low..xhigh, agy tops out at high, so an
# assessed xhigh becomes high instead of refusing the candidate.
AGY_FIT_RULE="$TMP_ROOT/agy-fit-rule.json"
printf '%s\n' '{"rules":[{"when":"Deep work.","use":{"harness":"agy"}},{"when":"Other.","use":{"harness":"cursor","model":"cursor-grok-4.6-medium"}}]}' > "$AGY_FIT_RULE"
cp "$AGY_FIT_RULE" "$RULES"
cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": {
    "rule": { "type": "choice", "choice": "rule_1", "confidence": 0.95,
      "probabilities": { "rule_1": 0.95, "rule_2": 0.04, "default": 0.01 } },
    "effort": { "type": "choice", "choice": "xhigh", "confidence": 0.9,
      "probabilities": { "low": 0.05, "medium": 0.05, "high": 0.05, "xhigh": 0.8, "max": 0.05 } }
  },
  "usage": { "input_tokens": 100, "output_tokens": 60 } }
JSON
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'effort=high(range low..xhigh) [clamped from xhigh]' "the nearest supported level inside the range is used"
assert_contains "$out" "  profile: --harness 'agy' --effort 'high'" "agy is dispatched at its highest supported level"
cp "$BASE_RULES" "$RULES"

# A malformed effort answer falls back to the declared effort and says so;
# the rule question alone still drives a normal clear result.
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.answers.effort = {"type":"choice","choice":"ludicrous","confidence":0.9,"probabilities":{"ludicrous":1.0}}' "$RESPONSE" > "$TMP_ROOT/r.json" && mv "$TMP_ROOT/r.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "malformed effort answer does not break resolution"
assert_contains "$out" 'declared fallback (classifier malformed)' "the fallback is disclosed"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  effort=high(range high)' "declared effort stands when the classifier is malformed"

# A low-confidence effort answer is not trusted: the declared default applies.
cp "$RANGE_RULES" "$RULES"
reset_log
write_response_effort "$RESPONSE" rule_4 0.9 low
jq '.answers.effort.confidence = 0.3 | .answers.effort.probabilities = {"low":0.4,"medium":0.3,"high":0.1,"xhigh":0.1,"max":0.1}' "$RESPONSE" > "$TMP_ROOT/r.json" && mv "$TMP_ROOT/r.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$LOW_CURSOR" run code out err "$BRIEF"
assert_contains "$out" 'declared fallback (classifier low-confidence)' "a low-confidence effort answer is disclosed as such"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "the range default applies"
cp "$BASE_RULES" "$RULES"

# Malformed ranges are configuration errors, never selected around.
for bad in '.rules[3].use[0].effort_min = "xhigh"' '.rules[3].use[0].effort_max = "medium"' '.default[0].effort_max = "high"' '.rules[3].use[0].effort_min = "turbo"'; do
  jq "$bad" "$BASE_RULES" > "$RULES"
  reset_log
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 2 "$code" "malformed range exits 2: $bad"
  assert_contains "$err" 'effort_min and effort_max' "malformed range is named: $bad"
done
cp "$BASE_RULES" "$RULES"
pass "effort range: harness fit, the declared fallback, and range validation are enforced"

# --- cost-aware ranking: predicted burn against headroom and runway -----------

# A ledger stub answering a real prediction document: cursor burns 200k tokens
# on a 91%-remaining window calibrated at 1000 tokens per point (~200% needed -
# refused), claude burns 30k (~30% of 79% - fits), kimi unmeasured.
LEDGER_DATA="$TMP_ROOT/fm-spend-ledger-data.py"
cat > "$LEDGER_DATA" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"status":"ok","providers":{"cursor":{"tokensPerPoint":1000,"percentConsumed":9,"windowKind":"weekly"},"claude":{"tokensPerPoint":1000,"percentConsumed":21,"windowKind":"weekly"}},"median":{"claude":{"high":{"tokens":30000,"seconds":300,"tasks":4},"all":{"tokens":30000,"seconds":300,"tasks":4}},"cursor":{"all":{"tokens":200000,"seconds":500,"tasks":2}}},"anyProvider":{"all":{"tokens":60000,"seconds":300,"tasks":9}}}'
SH
chmod +x "$LEDGER_DATA"

reset_log
write_response_effort "$RESPONSE" rule_4 0.9 high
jq '.answers.effort.probabilities = {"low":0.05,"medium":0.05,"high":0.8,"xhigh":0.05,"max":0.05}' "$RESPONSE" > "$TMP_ROOT/r.json" && mv "$TMP_ROOT/r.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY FM_SPEND_LEDGER="$LEDGER_DATA" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "cost gates leave a fitting candidate clear"
assert_contains "$out" 'not eligible: predicted burn ~200k tokens (~200%) exceeds remaining 91%' "cursor is refused with its predicted burn named"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "the fitting candidate wins over the higher spendPriority"
pass "cost-aware ranking: predicted burn refuses a candidate that cannot fit"

# When every measured candidate's predicted burn exceeds its headroom the
# escalate reason names the predicted burn.
BURN_ALL="$TMP_ROOT/burn-all.json"
cat > "$BURN_ALL" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"status":"ok","providers":{"cursor":{"tokensPerPoint":1000},"claude":{"tokensPerPoint":1000}},"median":{"claude":{"all":{"tokens":300000,"seconds":300,"tasks":4}},"cursor":{"all":{"tokens":200000,"seconds":500,"tasks":2}}},"anyProvider":{"all":{"tokens":250000,"seconds":300,"tasks":9}}}'
SH
chmod +x "$BURN_ALL"
reset_log
write_response_effort "$RESPONSE" rule_4 0.9 high
jq '.answers.effort.probabilities = {"low":0.05,"medium":0.05,"high":0.8,"xhigh":0.05,"max":0.05}' "$RESPONSE" > "$TMP_ROOT/r.json" && mv "$TMP_ROOT/r.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY FM_SPEND_LEDGER="$BURN_ALL" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "all refused escalates"
assert_contains "$out" 'predicted burn ~' "the escalate reason names the predicted burn"
pass "cost-aware ranking: an all-refused escalate names the predicted burn"

# Runway: a candidate whose usable runway is shorter than the predicted
# duration is refused with the prediction named. Cursor's token burn fits
# (30k at 1000/point = 30% of 91%) so the runway gate is what fires.
LEDGER_RUNWAY="$TMP_ROOT/fm-spend-ledger-runway.py"
cat > "$LEDGER_RUNWAY" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"status":"ok","providers":{"cursor":{"tokensPerPoint":1000},"claude":{"tokensPerPoint":1000}},"median":{"claude":{"high":{"tokens":30000,"seconds":300,"tasks":4},"all":{"tokens":30000,"seconds":300,"tasks":4}},"cursor":{"all":{"tokens":30000,"seconds":500,"tasks":2}}},"anyProvider":{"all":{"tokens":30000,"seconds":300,"tasks":9}}}'
SH
chmod +x "$LEDGER_RUNWAY"
RUNWAY_QUOTA="$TMP_ROOT/runway-quota.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models") | .runway) = {"status":"projected_exhaustion","usableRunwaySeconds":60}' "$QUOTA" > "$RUNWAY_QUOTA"
reset_log
TYPESAFE_API_KEY=$KEY FM_SPEND_LEDGER="$LEDGER_RUNWAY" QUOTA_AXI_FIXTURE="$RUNWAY_QUOTA" run code out err "$BRIEF"
assert_contains "$out" 'not eligible: predicted duration ~500s exceeds usable runway 60s' "short runway refuses with the predicted duration named"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "the runway-fitting candidate still resolves"
pass "cost-aware ranking: a runway shorter than predicted duration refuses the candidate"

# A failing or absent ledger never fabricates a limit: candidates keep their
# quota-driven ranking with pred=unknown disclosed.
BROKEN_LEDGER="$TMP_ROOT/fm-spend-ledger-broken.py"
cat > "$BROKEN_LEDGER" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$BROKEN_LEDGER"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY FM_SPEND_LEDGER="$BROKEN_LEDGER" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a failing ledger does not block resolution"
assert_contains "$out" 'pred=unknown' "missing prediction evidence is disclosed, not fabricated"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "quota ranking stands when prediction is unavailable"
pass "cost-aware ranking: absent ledger evidence stays disclosed and never blocks"

# Overflow: a profile marked overflow is held out of the ranking while a
# primary candidate's quota lasts through its reset, and takes the work once
# every primary is projected to run out first. A scout brief never overflows.
OVERFLOW_RULES="$TMP_ROOT/overflow-rules.json"
cat > "$OVERFLOW_RULES" <<'JSON'
{
  "rules": [
    {
      "when": "Building and thinking work.",
      "use": [
        { "harness": "claude", "model": "claude-opus-5-5", "effort": "medium" },
        { "harness": "pi", "model": "openai-codex/gpt-6.1-sol", "effort": "high", "provider": "codex", "overflow": true }
      ]
    }
  ],
  "default": { "harness": "claude", "model": "claude-opus-5-5", "effort": "medium" }
}
JSON
cp "$OVERFLOW_RULES" "$RULES"
overflow_quota() {  # <path> <claude runway> <codex runway>
  jq --arg c "$2" --arg x "$3" '
    (.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) |= map(select(.scope == "all_models") | .runway.status = $c)
    | (.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability[0]) |= (.runway.status = $x | .selection.spendPriority = 0.6)
  ' "$QUOTA" > "$1"
}
OVERFLOW_QUOTA="$TMP_ROOT/overflow-quota.json"
OVERFLOW_RESPONSE='{ "rule_1": 0.97, "default": 0.03 }'
SOL_PROFILE="  profile: --harness 'pi' --model 'openai-codex/gpt-6.1-sol' --effort 'high'"
OPUS_PROFILE="  profile: --harness 'claude' --model 'claude-opus-5-5' --effort 'medium'"

overflow_quota "$OVERFLOW_QUOTA" through_reset through_reset
reset_log
write_response "$RESPONSE" rule_1 0.97 "$OVERFLOW_RESPONSE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$OVERFLOW_QUOTA" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a primary that lasts through reset clears"
assert_contains "$out" "$OPUS_PROFILE" "the primary wins even when the overflow candidate has the higher spendPriority"
assert_contains "$out" 'not eligible: overflow only: not every primary has concrete Claude quota-shortfall evidence' "the held overflow candidate is accounted for"
pass "overflow: a candidate marked overflow stays out while the primary's quota lasts"

overflow_quota "$OVERFLOW_QUOTA" projected_exhaustion through_reset
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$OVERFLOW_QUOTA" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "an overflowing rule clears"
assert_contains "$out" "$SOL_PROFILE" "the overflow candidate takes the work when the primary runs out before reset"
assert_contains "$out" 'not eligible: overflowed: quota projected to run out before reset at all_models' "the primary's line names why it was passed over"
pass "overflow: the overflow candidate takes the work once every primary is projected to run out before reset"

SCOUT_OVERFLOW_BRIEF="$TMP_ROOT/scout-overflow-brief.md"
{ cat "$BRIEF"; printf '%s\n' 'This is a SCOUT task: the deliverable is a written report, not a PR.'; } > "$SCOUT_OVERFLOW_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$OVERFLOW_QUOTA" run code out err "$SCOUT_OVERFLOW_BRIEF"
assert_contains "$out" "$OPUS_PROFILE" "a scout brief stays on the primary even when it runs short"
assert_contains "$out" 'not eligible: overflow only: a scout brief never overflows' "the scout hold is accounted for"
pass "overflow: a scout brief never overflows"

overflow_quota "$OVERFLOW_QUOTA" projected_exhaustion exhausted_now
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$OVERFLOW_QUOTA" run code out err "$BRIEF"
assert_contains "$out" "$OPUS_PROFILE" "a short primary keeps the work when no overflow candidate is rankable"
assert_not_contains "$out" 'overflowed:' "the primary is not passed over for an ineligible overflow candidate"
pass "overflow: a short primary keeps the work when the overflow candidate cannot take it"

overflow_quota "$OVERFLOW_QUOTA" exhausted_now through_reset
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$OVERFLOW_QUOTA" run code out err "$BRIEF"
assert_contains "$out" "$SOL_PROFILE" "an exhausted primary overflows"
assert_contains "$out" 'not eligible: runway exhausted_now at all_models' "the exhausted primary keeps its own reason"
pass "overflow: an exhausted primary overflows"

overflow_quota "$OVERFLOW_QUOTA" through_reset through_reset
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[0].effectivePercentRemaining) = 0' "$OVERFLOW_QUOTA" > "$TMP_ROOT/q.json" && mv "$TMP_ROOT/q.json" "$OVERFLOW_QUOTA"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$OVERFLOW_QUOTA" run code out err "$BRIEF"
assert_contains "$out" "$SOL_PROFILE" "known zero remaining is quota-shortfall evidence even with stale runway"
pass "overflow: a zero-percent primary overflows"

for rejection in ceiling harness floor burn; do
  overflow_quota "$OVERFLOW_QUOTA" through_reset through_reset
  cp "$OVERFLOW_RULES" "$RULES"
  write_response_effort "$RESPONSE" rule_1 0.97 high
  jq --argjson p "$OVERFLOW_RESPONSE" '.answers.rule.probabilities = $p | .answers.effort.probabilities = {"low":0.05,"medium":0.05,"high":0.8,"xhigh":0.05,"max":0.05}' "$RESPONSE" > "$TMP_ROOT/r.json" && mv "$TMP_ROOT/r.json" "$RESPONSE"
  ledger=$LEDGER_STUB
  case "$rejection" in
    ceiling) ;;
    harness)
      jq '.rules[0].use[0] = {"harness":"agy","provider":"claude"} | .rules[0].use[1].effort = "xhigh"' "$OVERFLOW_RULES" > "$RULES"
      jq '.answers.effort.choice = "xhigh" | .answers.effort.probabilities = {"low":0.05,"medium":0.05,"high":0.05,"xhigh":0.8,"max":0.05}' "$RESPONSE" > "$TMP_ROOT/r.json" && mv "$TMP_ROOT/r.json" "$RESPONSE" ;;
    floor)
      jq '.rules[0].use[0].effort = "high" | .rules[0].use[0].floor = {"scope":"all_models","min_percent":90}' "$OVERFLOW_RULES" > "$RULES" ;;
    burn)
      jq '.rules[0].use[0].effort = "high"' "$OVERFLOW_RULES" > "$RULES"
      ledger=$BURN_ALL ;;
  esac
  reset_log
  TYPESAFE_API_KEY=$KEY FM_SPEND_LEDGER="$ledger" QUOTA_AXI_FIXTURE="$OVERFLOW_QUOTA" run code out err "$BRIEF"
  case "$rejection" in
    ceiling|harness)
      assert_contains "$out" '  status: clear' "$rejection assessment clamps to the primary's supported range"
      assert_contains "$out" "  profile: --harness '$(if [ "$rejection" = harness ]; then printf agy; else printf claude; fi)'" "$rejection assessment keeps the primary"
      ;;
    floor|burn)
      assert_contains "$out" '  status: escalate' "non-quota $rejection rejection does not activate overflow"
      assert_not_contains "$out" '  profile:' "non-quota $rejection rejection emits no overflow launch"
      ;;
  esac
  assert_not_contains "$out" "$SOL_PROFILE" "non-quota $rejection evidence never authorizes overflow"
done
pass "overflow: clamped effort, harness support, floor, and burn never authorize overflow"

cp "$OVERFLOW_RULES" "$RULES"
write_response "$RESPONSE" rule_1 0.97 "$OVERFLOW_RESPONSE"
for runway in unknown through_reset; do
  overflow_quota "$OVERFLOW_QUOTA" "$runway" through_reset
  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$OVERFLOW_QUOTA" run code out err "$BRIEF"
  assert_contains "$out" "$OPUS_PROFILE" "a $runway primary does not overflow"
done
jq '.rules[0].use += [{"harness":"claude","model":"claude-haiku-4-5","effort":"medium","floor":{"scope":"all_models","min_percent":90}}]' "$OVERFLOW_RULES" > "$RULES"
overflow_quota "$OVERFLOW_QUOTA" projected_exhaustion through_reset
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$OVERFLOW_QUOTA" run code out err "$BRIEF"
assert_contains "$out" "$OPUS_PROFILE" "a sibling primary rejected for a floor prevents overflow despite projected exhaustion"
jq '.rules[0].use |= map(select(.overflow == true))' "$OVERFLOW_RULES" > "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$OVERFLOW_QUOTA" run code out err "$BRIEF"
assert_not_contains "$out" '  profile:' "an overflow-only array cannot activate without primaries"
pass "overflow: every primary must have quota evidence without a non-quota rejection"

for location in use default; do
  for scope in model:other product:other; do
    for floor_runway in projected_exhaustion exhausted_now; do
      jq --arg location "$location" --arg scope "$scope" '
        .rules[0].use[0].floor = {scope:$scope,min_percent:20} |
        if $location == "default" then .default = .rules[0].use else . end
      ' "$OVERFLOW_RULES" > "$RULES"
      overflow_quota "$OVERFLOW_QUOTA" projected_exhaustion through_reset
      jq --arg scope "$scope" --arg runway "$floor_runway" '
        (.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) +=
          [{scope:$scope,status:"known",effectivePercentRemaining:0,
            runway:{status:$runway},selection:{spendPriority:0.1}}]
      ' "$OVERFLOW_QUOTA" > "$TMP_ROOT/q.json" && mv "$TMP_ROOT/q.json" "$OVERFLOW_QUOTA"
      choice=rule_1
      probabilities=$OVERFLOW_RESPONSE
      if [ "$location" = default ]; then choice=default; probabilities='{"rule_1":0.03,"default":0.97}'; fi
      write_response "$RESPONSE" "$choice" 0.97 "$probabilities"
      reset_log
      TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$OVERFLOW_QUOTA" run code out err "$BRIEF"
      assert_contains "$out" '  status: escalate' "$location floor rejection never activates overflow"
      assert_contains "$out" "not eligible: profile floor $scope below 20%" "the actual non-quota rejection is preserved"
      assert_not_contains "$out" '  profile:' "$location zero-percent $floor_runway display fields do not authorize Sol"
    done
  done
done
pass "overflow: depleted non-applicable floor scopes never authorize a fallback"

cp "$OVERFLOW_RULES" "$RULES"
overflow_quota "$OVERFLOW_QUOTA" exhausted_now through_reset
jq '.rules[0].use[1].effort_floor = "high"' "$OVERFLOW_RULES" > "$RULES"
reset_log
write_response_effort "$RESPONSE" rule_1 0.97 medium
jq --argjson p "$OVERFLOW_RESPONSE" '.answers.rule.probabilities = $p | .answers.effort.probabilities = {"low":0.05,"medium":0.8,"high":0.05,"xhigh":0.05,"max":0.05}' "$RESPONSE" > "$TMP_ROOT/r.json" && mv "$TMP_ROOT/r.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$OVERFLOW_QUOTA" run code out err "$BRIEF"
assert_contains "$out" "$SOL_PROFILE" "an effort floor lifts a lower assessed class to the floor"
assert_contains "$out" 'candidate: claude:claude-opus-5-5  provider=claude  effort=medium(range medium)' "a profile without a floor keeps the assessed class"
jq '.rules[0].use[1].effort_floor = "max"' "$OVERFLOW_RULES" > "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$OVERFLOW_QUOTA" run code out err "$BRIEF"
expect_code 2 "$code" "an effort floor above the profile effort is a configuration error"
assert_contains "$err" 'profile effort_floor must be low, medium, high, xhigh, or max and not above the profile effort' "the malformed effort floor is named"
write_response "$RESPONSE" rule_1 0.97 "$OVERFLOW_RESPONSE"
pass "effort floor: an overflowed Sol runs at its floor, never the lower assessed class"

jq '.rules[0].use[1].overflow = "yes"' "$OVERFLOW_RULES" > "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$OVERFLOW_QUOTA" run code out err "$BRIEF"
expect_code 2 "$code" "a non-boolean overflow is a configuration error"
assert_contains "$err" 'profile overflow must be true or false when present' "the malformed overflow is named"
pass "overflow: a non-boolean overflow declaration is refused"

for location in use default; do
  for shape in object array; do
    for invalid in overflow-string floor-array floor-null floor-ceiling cursor kimi opencode devin gemini agy; do
      jq --arg location "$location" --arg shape "$shape" --arg invalid "$invalid" '
        {harness:"claude", effort:"high", effort_floor:"high"} |
        (if $invalid == "overflow-string" then .overflow = "yes"
         elif $invalid == "floor-array" then .effort_floor = ["high"]
         elif $invalid == "floor-null" then .effort_floor = null
         elif $invalid == "floor-ceiling" then .effort = "medium"
         else .harness = $invalid | .provider = "claude" | del(.effort) |
           if $invalid == "agy" then .effort_floor = "xhigh" else . end end) as $profile |
        {rules:[{when:"Building.",use:{harness:"claude"}}]} |
        if $location == "use" then .rules[0].use = (if $shape == "array" then [$profile] else $profile end)
        else .default = (if $shape == "array" then [$profile] else $profile end) end
      ' <<< '{}' > "$RULES"
      reset_log
      TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
      expect_code 2 "$code" "$location $shape rejects $invalid"
      assert_absent "$LOG/calls" "invalid profile is rejected before a model call"
    done
  done
done
pass "profile validation: all use and default forms reject malformed or unenforceable floors and overflow"

for location in use default; do
  for answer in absent malformed medium; do
    jq --arg location "$location" '
      .rules[0].use = {harness:"claude",model:"claude-opus-5-5",effort_floor:"high"} |
      if $location == "default" then .default = .rules[0].use else . end
    ' "$OVERFLOW_RULES" > "$RULES"
    choice=rule_1
    probabilities=$OVERFLOW_RESPONSE
    if [ "$location" = default ]; then choice=default; probabilities='{"rule_1":0.03,"default":0.97}'; fi
    write_response "$RESPONSE" "$choice" 0.97 "$probabilities"
    case "$answer" in
      malformed) effort_answer='{"type":"choice","choice":"invalid","confidence":0.9,"probabilities":{"invalid":1}}' ;;
      medium) effort_answer='{"type":"choice","choice":"medium","confidence":0.9,"probabilities":{"low":0.05,"medium":0.8,"high":0.05,"xhigh":0.05,"max":0.05}}' ;;
      absent) effort_answer=null ;;
    esac
    jq --argjson answer "$effort_answer" '.answers.effort = $answer' "$RESPONSE" > "$TMP_ROOT/r.json" && mv "$TMP_ROOT/r.json" "$RESPONSE"
    reset_log
    TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$QUOTA" run code out err "$BRIEF"
    assert_contains "$out" "  profile: --harness 'claude' --model 'claude-opus-5-5' --effort 'high'" "$location enforces the floor with $answer effort and no declared ceiling"
  done
done
pass "effort floor: fallback and assessed values are floored for rules and defaults"

# Floors compose with widened effort ranges, including a floor above the
# declared default but inside the range. Both assessed and fallback effort
# must stay inside the range and never below the floor.
for location in use default; do
  for answer in absent low high max; do
    jq --arg location "$location" '
      .rules[0].use = {harness:"claude",model:"claude-opus-5-5",effort:"medium",effort_min:"low",effort_max:"xhigh",effort_floor:"high"} |
      if $location == "default" then .default = .rules[0].use else . end
    ' "$OVERFLOW_RULES" > "$RULES"
    choice=rule_1
    probabilities=$OVERFLOW_RESPONSE
    if [ "$location" = default ]; then choice=default; probabilities='{"rule_1":0.03,"default":0.97}'; fi
    write_response "$RESPONSE" "$choice" 0.97 "$probabilities"
    if [ "$answer" != absent ]; then
      jq --arg answer "$answer" '
        .answers.effort = {type:"choice",choice:$answer,confidence:1,
          probabilities:(["low","medium","high","xhigh","max"] | map({key:.,value:(if . == $answer then 1 else 0 end)}) | from_entries)}
      ' "$RESPONSE" > "$TMP_ROOT/r.json" && mv "$TMP_ROOT/r.json" "$RESPONSE"
    fi
    reset_log
    TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$QUOTA" run code out err "$BRIEF"
    expect_code 0 "$code" "$location range accepts an effort floor above its default"
    resolved=high
    [ "$answer" != max ] || resolved=xhigh
    assert_contains "$out" "  profile: --harness 'claude' --model 'claude-opus-5-5' --effort '$resolved'" "$location $answer effort respects both floor and range"
  done
done
pass "effort floor: assessed and fallback effort compose with widened rule and default ranges"
cp "$BASE_RULES" "$RULES"

# --- the always-answer chain: typed, then backup judge, then default ----------
# run_chain drops --typed-only and points the backup judge at a stub claude
# that records its argv and the prompt it read on stdin, and answers with
# FAKE_BACKUP_ANSWER as structured output or exits 1 when FAKE_BACKUP_FAIL=1.
cat > "$FAKEBIN/fake-claude" <<'SH'
#!/usr/bin/env bash
set -u
printf 'call\n' >> "${FAKE_CURL_LOG:?}/backup-calls"
printf '%s\n' "$@" > "$FAKE_CURL_LOG/backup-argv"
cat > "$FAKE_CURL_LOG/backup-prompt"
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY+x}" ]; then
  printf 'backup:secret-present\n' >> "${CHILD_ENV_LOG:?}"
fi
[ "${FAKE_BACKUP_FAIL:-0}" = 1 ] && exit 1
jq -nc --argjson a "${FAKE_BACKUP_ANSWER:?}" '[{type:"system"},{type:"result",is_error:false,structured_output:$a,modelUsage:{"claude-haiku-5-5":{}}}]'
SH
chmod +x "$FAKEBIN/fake-claude"

run_chain() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_BACKUP_JUDGE_CMD=fake-claude FM_SPEND_LEDGER="${FM_SPEND_LEDGER:-$LEDGER_STUB}" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}
backup_calls() { [ -f "$LOG/backup-calls" ] && wc -l < "$LOG/backup-calls" | tr -d ' ' || printf '0'; }
curl_calls() { [ -f "$LOG/calls" ] && wc -l < "$LOG/calls" | tr -d ' ' || printf '0'; }
DISPATCH_LOG="$HOME_DIR/state/dispatch-resolve.jsonl"
cp "$BASE_RULES" "$RULES"

# A clear typed answer decides alone; the backup is never asked.
reset_log; rm -f "$DISPATCH_LOG"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY FAKE_BACKUP_ANSWER='{"rule":"rule_1","effort":"low"}' run_chain code out err "$BRIEF"
expect_code 0 "$code" "chain: a clear typed answer exits 0"
assert_contains "$out" '  status: clear' "chain: the typed stage clears"
assert_contains "$out" '  decided: rule_4 by typed' "chain: the deciding stage is named"
assert_equals "0" "$(backup_calls)" "chain: no backup call after a clear typed answer"
assert_contains "$(tail -n 1 "$DISPATCH_LOG")" '"decided_by":"typed"' "chain: the dispatch log records the deciding stage"
pass "chain: a clear typed answer decides without the backup"

# An ambiguous typed answer goes to the backup, which sees exactly the typed
# state and the same rule options, and its answer decides.
reset_log
write_response "$RESPONSE" rule_4 0.26 '{ "rule_1": 0.02, "rule_2": 0.30, "rule_3": 0.02, "rule_4": 0.41, "default": 0.25 }'
FAKE_CURL_PICK_FAIL=1 TYPESAFE_API_KEY=$KEY FAKE_BACKUP_ANSWER='{"rule":"rule_1","effort":"high"}' run_chain code out err "$BRIEF"
expect_code 0 "$code" "chain: ambiguous typed answer still exits 0"
assert_contains "$out" '  status: backup' "chain: the backup decided"
assert_contains "$out" '  decided: default by backup' "chain: a floor shortfall names the default lane actually used"
assert_contains "$out" '  matched: rule_1 (its profiles were not used)' "chain: the matched rule stays visible"
assert_not_contains "$out" '  decided: rule_1 by backup' "chain: the matched rule is never reported as the lane"
assert_contains "$(tail -n 1 "$DISPATCH_LOG")" '"rule":"default","matched_rule":"rule_1"' "chain: the dispatch log records the lane and the matched rule"
assert_contains "$out" '  backup: rule_1 effort=high' "chain: the backup answer is summarized"
assert_contains "$out" "note: rule rule_1 floor model:fable below 20%: fall through to default" "chain: the backup's rule keeps its quota floor"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "chain: the backup's rule yields a profile through the ordinary gates"
assert_equals "1" "$(backup_calls)" "chain: exactly one backup call"
STATE_SENT=$(jq -c '.state' "$LOG/body")
assert_contains "$(cat "$LOG/backup-prompt")" "$STATE_SENT" "chain: the backup sees the same state as the typed call"
for opt in rule_1 rule_2 rule_3 rule_4 default; do
  assert_contains "$(cat "$LOG/backup-argv")" "\"$opt\"" "chain: the backup schema offers $opt"
done
assert_contains "$(cat "$LOG/backup-argv")" 'claude-haiku-5-5' "chain: the backup defaults to Haiku 5.5"
assert_not_contains "$(cat "$LOG/backup-argv")" "$KEY" "chain: no key reaches the backup argv"
assert_not_contains "$(cat "$CHILD_ENV_LOG" 2>/dev/null)" 'backup:secret-present' "chain: no key reaches the backup environment"
assert_contains "$(tail -n 1 "$DISPATCH_LOG")" '"decided_by":"backup"' "chain: the log records the backup"
pass "chain: an ambiguous typed answer is decided by the backup on the same state"

# An unreachable typed call and an absent key both go to the backup.
reset_log
write_response "$RESPONSE" rule_4 0.9
FAKE_CURL_HTTP=503 TYPESAFE_API_KEY=$KEY FAKE_BACKUP_ANSWER='{"rule":"rule_4","effort":"high"}' run_chain code out err "$BRIEF"
assert_contains "$out" '  status: backup' "chain: an http error goes to the backup"
assert_contains "$out" '  typed: http 503' "chain: the typed failure is named"
assert_contains "$out" '  profile: ' "chain: an http error still yields a profile"
reset_log
FAKE_BACKUP_ANSWER='{"rule":"rule_4","effort":"high"}' run_chain code out err "$BRIEF"
expect_code 0 "$code" "chain: no key exits 0"
assert_contains "$out" '  status: backup' "chain: no key goes to the backup"
assert_equals "0" "$(curl_calls)" "chain: no key makes no typed call"
assert_contains "$out" '  profile: ' "chain: no key still yields a profile"
pass "chain: an unreachable typed call or absent key falls to the backup"

# A failed backup falls to the default rule's profile.
reset_log
FAKE_CURL_HTTP=500 TYPESAFE_API_KEY=$KEY FAKE_BACKUP_FAIL=1 run_chain code out err "$BRIEF"
expect_code 0 "$code" "chain: a failed backup still exits 0"
assert_contains "$out" '  status: fallback' "chain: the default stage decided"
assert_contains "$out" '  decided: default by default' "chain: the default rule is named"
assert_contains "$out" '  backup: failed' "chain: the backup failure is named"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "chain: the best-ranked default profile is emitted"
assert_contains "$(tail -n 1 "$DISPATCH_LOG")" '"decided_by":"default"' "chain: the log records the default stage"
reset_log
FAKE_CURL_HTTP=500 TYPESAFE_API_KEY=$KEY FAKE_BACKUP_ANSWER='{"rule":"rule_99","effort":"high"}' run_chain code out err "$BRIEF"
assert_contains "$out" '  backup: failed (answer is not a valid structured answer)' "chain: an off-menu backup answer is rejected"
assert_contains "$out" '  status: fallback' "chain: an off-menu backup answer falls to the default"
reset_log
FAKE_CURL_HTTP=500 TYPESAFE_API_KEY=$KEY FAKE_BACKUP_FAIL=1 run_chain code out err "$BRIEF"
assert_contains "$out" '  backup: failed (fake-claude exited 1)' "chain: a failing backup stub is named"
assert_contains "$out" '  status: fallback' "chain: a failing backup stub falls to the default"
pass "chain: a failed or invalid backup falls to the default rule"

# Advise-only gates Jev's own pick: a backup or default-stage profile still binds.
reset_log
FM_JEV_EVAL_SCORES="$TMP_ROOT/no-scorecard.json" FAKE_BACKUP_ANSWER='{"rule":"rule_4","effort":"high"}' run_chain code out err "$BRIEF"
assert_contains "$out" '  status: backup' "chain: advise-only no-key still goes to the backup"
assert_contains "$out" '  profile: ' "chain: an advise-only site keeps the backup profile"
assert_not_contains "$out" '  mode: advise' "chain: a backup pick is not printed as Jev advice"
reset_log
FM_JEV_EVAL_SCORES="$TMP_ROOT/no-scorecard.json" FAKE_CURL_HTTP=500 TYPESAFE_API_KEY=$KEY FAKE_BACKUP_FAIL=1 run_chain code out err "$BRIEF"
assert_contains "$out" '  status: fallback' "chain: advise-only failed backup falls to the default"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "chain: an advise-only site keeps the default profile"
assert_not_contains "$out" '  mode: advise' "chain: a default-stage pick is not printed as Jev advice"
pass "chain: advise-only mode leaves backup and default-stage profiles binding"

# The never-send list blocks both judges: no typed call, no backup call, and
# the default answers.
reset_log
printf 'pager.sh\n' > "$HOME_DIR/config/dispatch-never-send"
TYPESAFE_API_KEY=$KEY FAKE_BACKUP_ANSWER='{"rule":"rule_4","effort":"high"}' run_chain code out err "$BRIEF"
rm -f "$HOME_DIR/config/dispatch-never-send"
expect_code 0 "$code" "chain: a never-send match exits 0"
assert_equals "0" "$(curl_calls)" "chain: a never-send match makes no typed call"
assert_equals "0" "$(backup_calls)" "chain: a never-send match makes no backup call"
assert_contains "$out" '  status: fallback' "chain: a never-send match uses the default"
assert_contains "$out" '  profile: ' "chain: a never-send match still yields a profile"
pass "chain: the never-send list keeps the brief from both judges"

# A captain-approval rule stays an escalation with no profile: it is an
# authority gate, not a routing failure.
reset_log
write_response "$RESPONSE" rule_3 0.95 '{ "rule_1": 0.01, "rule_2": 0.01, "rule_3": 0.96, "rule_4": 0.01, "default": 0.01 }'
TYPESAFE_API_KEY=$KEY FAKE_BACKUP_ANSWER='{"rule":"rule_4","effort":"high"}' run_chain code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "chain: a captain-approval rule escalates"
assert_not_contains "$out" '  profile:' "chain: a captain-approval rule emits no profile"
assert_equals "0" "$(backup_calls)" "chain: the backup never overrides an approval gate"
pass "chain: captain approval remains the one no-profile outcome"

# Quota evidence that would make the typed stage escalate (the 2026-10-07
# shape) still yields a profile: a quota-axi failure leaves every candidate
# unranked and the last resort picks inside the decided rule.
reset_log
write_response "$RESPONSE" rule_4 0.9
FAKE_QUOTA_FAIL=1 TYPESAFE_API_KEY=$KEY FAKE_BACKUP_ANSWER='{"rule":"rule_4","effort":"high"}' run_chain code out err "$BRIEF"
expect_code 0 "$code" "chain: a quota-axi failure exits 0"
assert_contains "$out" '  profile: ' "chain: a quota-axi failure still yields a profile"
assert_contains "$out" '  last_resort: ' "chain: the last resort is disclosed"
pass "chain: missing quota evidence never stops routing"

ATTRIBUTION_RULES="$TMP_ROOT/attribution-rules.json"
ATTRIBUTION_QUOTA="$TMP_ROOT/attribution-quota.json"
for refusal_case in rescued all-refused floor-fallthrough; do
  jq -n --arg scenario "$refusal_case" '{rules: [
    {when: "A broad implementation task.", min_confidence: 0.9, use: {harness: "codex", model: "gpt-5.6-sol"}},
    {when: "A focused implementation task.", min_confidence: 0.6, use: {harness: "claude", model: "sonnet", effort: "high"}}
  ], default: {harness: "cursor", model: "cursor-grok-4.6-high"}}
  | if $scenario == "floor-fallthrough" then
      .rules[1].floor = {provider: "claude", scope: "all_models", min_percent: 20}
    else . end' > "$ATTRIBUTION_RULES"
  jq --arg scenario "$refusal_case" '
    (.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models") | .effectivePercentRemaining) = 0
    | (.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models") | .effectivePercentRemaining) = (if $scenario == "rescued" then 91 else 0 end)
  ' "$QUOTA" > "$ATTRIBUTION_QUOTA"
  cp "$ATTRIBUTION_RULES" "$RULES"
  reset_log
  write_response "$RESPONSE" rule_1 0.3 '{"rule_1":0.30,"rule_2":0.65,"default":0.05}'
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$ATTRIBUTION_QUOTA" run_chain code out err "$BRIEF"
  expect_code 0 "$code" "$refusal_case: a settled runner-up still answers"
  case "$refusal_case" in
    rescued)
      lane=default; matched=rule_2
      refusal='rule rule_2 candidates refused:'
      incorrect_refusal='rule rule_1 candidates refused:'
      assert_contains "$out" '  decided: default by default' 'rescued: the healthy default supplies the profile'
      assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" 'rescued: the default profile is preserved' ;;
    all-refused)
      lane=rule_2; matched=''
      refusal='rule rule_2 candidates refused:'
      incorrect_refusal='rule rule_1 candidates refused:'
      assert_contains "$out" '  decided: rule_2 by typed' 'all-refused: the settled runner-up supplies the last resort'
      assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" 'all-refused: the settled profile is preserved' ;;
    floor-fallthrough)
      lane=default; matched=rule_2
      refusal='default lane candidates refused for rule_2:'
      incorrect_refusal='default lane candidates refused for rule_1:'
      assert_contains "$out" '  decided: default by typed' 'floor-fallthrough: the settled rule falls through to the default lane'
      assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" 'floor-fallthrough: the default profile is preserved' ;;
  esac
  assert_contains "$out" "$refusal" "$refusal_case: refusal diagnostics name the settled rule"
  assert_not_contains "$out" "$incorrect_refusal" "$refusal_case: refusal diagnostics never blame the initial pick"
  tail -n 1 "$DISPATCH_LOG" | jq -e --arg lane "$lane" --arg matched "$matched" --arg refusal "$refusal" --arg incorrect "$incorrect_refusal" '
    .rule == $lane and (.matched_rule // "") == $matched
    and (.reason | contains($refusal)) and (.reason | contains($incorrect) | not)
  ' >/dev/null || fail "$refusal_case: the persisted lane, matched rule, and refusal attribution disagree"
done
cp "$BASE_RULES" "$RULES"
pass 'last-resort refusal diagnostics and logs name the settled rule after confidence fallback'

ALL_REFUSED_RULES="$TMP_ROOT/all-refused-rule.json"
jq '.rules[3].use = [
  {"harness":"claude","model":"fable","floor":{"scope":"model:fable","min_percent":20}},
  {"harness":"cursor","model":"cursor-grok-4.6-medium","floor":{"scope":"all_models","min_percent":99}}
]' "$BASE_RULES" > "$ALL_REFUSED_RULES"
cp "$ALL_REFUSED_RULES" "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$QUOTA" run_chain code out err "$BRIEF"
assert_contains "$out" '  decided: default by default' "all-refused rule: eligible default lane is named"
assert_contains "$out" '  matched: rule_4 (its profiles were not used)' "all-refused rule: the refused matched rule is named"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "all-refused rule: eligible default profile is emitted"
assert_contains "$out" 'last_resort: ' "all-refused rule: the default-lane rescue is disclosed"
assert_contains "$out" 'eligible default lane used' "all-refused rule: the refusal and default transition are named"
pass "chain: eligible default candidates follow an all-refused decided rule"

UNRANKED_DEFAULT_RULES="$TMP_ROOT/unranked-default-rules.json"
UNRANKED_DEFAULT_QUOTA="$TMP_ROOT/unranked-default-quota.json"
jq '.default = {harness: "codex", model: "gpt-5.6-sol"}' "$ALL_REFUSED_RULES" > "$UNRANKED_DEFAULT_RULES"
jq '.providers |= map(select(.provider != "codex"))' "$QUOTA" > "$UNRANKED_DEFAULT_QUOTA"
cp "$UNRANKED_DEFAULT_RULES" "$RULES"
for stage in typed backup; do
  reset_log
  http=200
  [ "$stage" != backup ] || http=503
  TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=$http FAKE_BACKUP_ANSWER='{"rule":"rule_4","effort":"high"}' \
    FM_SPEND_LEDGER="$LEDGER_RUNWAY" QUOTA_AXI_FIXTURE="$UNRANKED_DEFAULT_QUOTA" run_chain code out err "$BRIEF"
  expect_code 0 "$code" "$stage unranked default: routing answers"
  assert_contains "$out" '  decided: default by default' "$stage unranked default: eligible lane rescues the rule"
  assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "$stage unranked default: profile is not the refused original"
  assert_contains "$out" 'predicted burn ~' "$stage unranked default: the diagnostic includes burn evidence"
  tail -n 1 "$DISPATCH_LOG" | jq -e '.rule == "default" and .matched_rule == "rule_4" and .profile.harness == "codex"' >/dev/null \
    || fail "$stage unranked default: actual lane not logged"
done
pass "chain: diagnostic burn text cannot disqualify an eligible default"

RESTRICTED_DEFAULT_RULES="$TMP_ROOT/restricted-default-rules.json"
jq 'del(.default) | .rules[3].use[0].floor = {scope: "all_models", min_percent: 99}' "$ALL_REFUSED_RULES" > "$RESTRICTED_DEFAULT_RULES"
cp "$RESTRICTED_DEFAULT_RULES" "$RULES"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$MISSING_RULE_FLOOR" run_chain code out err "$BRIEF"
assert_contains "$out" '  decided: rule_4 by typed' "restricted default: an unverifiable rule floor cannot rescue the rule"
assert_contains "$out" "  profile: --harness 'claude' --model 'fable'" "restricted default: the original lane answers"
cp "$ALL_REFUSED_RULES" "$RULES"

ALL_REFUSED_DEFAULT_QUOTA="$TMP_ROOT/all-refused-default-quota.json"
jq '(.providers[] | select(.provider == "claude" or .provider == "cursor") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models") | .effectivePercentRemaining) = 0' "$QUOTA" > "$ALL_REFUSED_DEFAULT_QUOTA"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$ALL_REFUSED_DEFAULT_QUOTA" run_chain code out err "$BRIEF"
assert_contains "$out" '  decided: rule_4 by typed' "all-refused defaults: original decision remains named"
assert_not_contains "$out" '  matched: ' "all-refused defaults: the lane used is the matched rule"
assert_contains "$out" "  profile: --harness 'claude' --model 'fable'" "all-refused defaults: first declared original profile answers"
assert_contains "$out" 'default candidates refused:' "all-refused defaults: default refusal is disclosed"
assert_contains "$out" 'every candidate refused' "all-refused defaults: the final choice is identified as last resort"
pass "chain: the original first profile answers only after default candidates refuse"

reset_log
FAKE_CURL_HTTP=500 FAKE_BACKUP_FAIL=1 TYPESAFE_API_KEY=$KEY \
  QUOTA_AXI_FIXTURE="$ALL_REFUSED_DEFAULT_QUOTA" run_chain code out err "$BRIEF"
assert_contains "$out" '  decided: default by default' "default all-refused: the default stage remains named"
assert_contains "$out" "  profile: --harness 'claude' --model 'opus'" "default all-refused: the first declared default profile answers"
assert_contains "$out" 'default candidates refused:' "default all-refused: refusal details are disclosed"
tail -n 1 "$DISPATCH_LOG" | jq -e '.rule == "default" and (.reason | contains("default candidates refused:"))' >/dev/null \
  || fail 'default all-refused: the persisted refusal names the default stage'
pass "chain: a refused default stage names its final declared-order choice"

APPROVAL_DEFAULT_RULES="$TMP_ROOT/approval-default-rule.json"
jq '.rules[0].approval = "captain" | del(.default)' "$ALL_REFUSED_RULES" > "$APPROVAL_DEFAULT_RULES"
cp "$APPROVAL_DEFAULT_RULES" "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$QUOTA" run_chain code out err "$BRIEF"
assert_contains "$out" '  decided: rule_4 by typed' "approval default: the captain gate is not bypassed"
assert_not_contains "$out" '  decided: rule_1 by default' "approval default: no profile is routed through the approval rule"
pass "chain: the no-default fallback preserves captain approval"
cp "$BASE_RULES" "$RULES"

# An unverifiable rule floor never authorizes the default: the last resort
# picks inside the decided rule instead.
NOFLOOR_QUOTA="$TMP_ROOT/nofloor-quota.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) |= map(select(.scope != "model:fable"))' "$QUOTA" > "$NOFLOOR_QUOTA"
reset_log
write_response "$RESPONSE" rule_1 0.97 '{ "rule_1": 0.96, "rule_2": 0.01, "rule_3": 0.01, "rule_4": 0.01, "default": 0.01 }'
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NOFLOOR_QUOTA" FAKE_BACKUP_ANSWER='{"rule":"rule_1","effort":"high"}' run_chain code out err "$BRIEF"
assert_contains "$out" '  decided: rule_1 by typed' "chain: an unverifiable floor keeps the decided rule"
assert_contains "$out" "  profile: --harness 'claude' --model 'fable'" "chain: the last resort picks inside the rule, not the default"
assert_contains "$out" '  last_resort: ' "chain: the last resort is disclosed for an unverifiable floor"
pass "chain: an unverifiable rule floor takes the last resort inside its rule"

# An assessed effort above a rule's range is clamped, not refused.
reset_log
write_response_effort "$RESPONSE" rule_4 0.9 max
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$LOW_CURSOR" FAKE_BACKUP_ANSWER='{"rule":"rule_4","effort":"high"}' run_chain code out err "$BRIEF"
assert_contains "$out" '  decided: rule_4 by typed' "chain: a clamped effort keeps the typed decision"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "chain: the clamped effort is emitted"
assert_contains "$(tail -n 1 "$DISPATCH_LOG")" '"clamped_from":"max"' "chain: the clamp is logged"
pass "chain: an effort above the range is clamped and logged"

# A rules file with only a default still routes, and a malformed rules file is
# the one hard error.
reset_log
printf '%s\n' '{"rules":[],"default":{"harness":"claude","model":"opus","effort":"medium"}}' > "$RULES"
FAKE_BACKUP_ANSWER='{"rule":"default","effort":"high"}' run_chain code out err "$BRIEF"
expect_code 0 "$code" "chain: a default-only rules file exits 0"
assert_contains "$out" "  profile: --harness 'claude' --model 'opus' --effort 'medium'" "chain: a default-only rules file yields the default"
printf '{ not json\n' > "$RULES"
run_chain code out err "$BRIEF"
expect_code 2 "$code" "chain: a malformed rules file is still an error"
assert_not_contains "$out" '  profile:' "chain: a malformed rules file emits no profile"
cp "$BASE_RULES" "$RULES"
pass "chain: only a malformed rules file stops routing"

# --- never-use model list: banned profiles are never eligible, and the runoff carries the rules ---
DENYLIST="$HOME_DIR/config/model-denylist.json"
cat > "$DENYLIST" <<'JSON'
{"never": [{"pattern": "*kimi*", "reason": "Kimi is ruled out"}], "rules": ["Opus does judgment work."]}
JSON
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "a never-use list keeps the resolver exiting 0"
assert_contains "$out" '  status: clear' "a banned profile does not block the other candidates"
assert_contains "$out" 'candidate: kimi:kimi-code/k3' "the banned profile stays accounted for"
assert_contains "$out" '-> not eligible: never-use model list: rule *kimi* - Kimi is ruled out' "the banned profile is not eligible and names the rule and reason"
assert_not_contains "$out" 'unranked (kimi)' "a banned profile is not counted as eligible unranked"
assert_not_contains "$(jq -c .state "$LOG/body")" 'captain_model_rules' "the rule Choice state is unchanged"
pass "never-use list: a banned profile is listed as not eligible with its rule"

jq '.never += [{"pattern": "cursor-*", "reason": "no Cursor subscription"}]' "$DENYLIST" > "$TMP_ROOT/d.json" && mv "$TMP_ROOT/d.json" "$DENYLIST"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet'" "the argmax skips a banned profile even when it ranks highest"
assert_not_contains "$out" "--model 'cursor-grok-4.6-medium'" "a banned profile is never emitted"
pass "never-use list: the highest-ranked profile is skipped when it is banned"

jq '.never |= map(select(.pattern != "cursor-*"))' "$DENYLIST" > "$TMP_ROOT/d.json" && mv "$TMP_ROOT/d.json" "$DENYLIST"
reset_log
write_response "$RESPONSE" rule_4 0.26 "$NARROW"
write_pick_response "$PICK_RESPONSE" rule_4 '{ "rule_4": 0.86, "rule_2": 0.14 }'
TYPESAFE_API_KEY=$KEY FAKE_CURL_PICK_RESPONSE=$PICK_RESPONSE run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: picked' "the runoff still settles with a never-use list"
pick_body=$(cat "$LOG/pick-body")
assert_contains "$(jq -r '.state.captain_model_rules' <<<"$pick_body")" 'Never use *kimi* (Kimi is ruled out). Opus does judgment work.' "the runoff state carries the captain model rules"
assert_equals "$(jq -c .state "$LOG/body")" "$(jq -c 'del(.captain_model_rules)' <<<"$(jq -c .state <<<"$pick_body")")" "the runoff state is the rule state plus the rules"
pass "never-use list: the runoff state carries the captain model rules"

printf '{"never": [{"pattern": "*", "reason": "everything"}]}' > "$DENYLIST"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 2 "$code" "a malformed never-use list is a configuration error"
assert_contains "$err" 'malformed never-use model list' "the error names the list"
assert_equals '' "$out" "a malformed list prints no result"
rm -f "$DENYLIST"
pass "never-use list: a malformed list exits 2 instead of resolving unchecked"

printf '# all fm-dispatch-resolve tests passed\n'
