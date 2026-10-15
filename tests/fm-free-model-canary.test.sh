#!/usr/bin/env bash
# Behavior tests for bin/fm-free-model-canary.sh, offline.
#
# A fake opencode answers `opencode models <provider>` from a listing file (or
# fails on request), and a fake config push records that it ran. Every case
# drives the public run/check/arm/disarm CLI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-free-model-canary.sh"
TMP_ROOT=$(fm_test_tmproot fm-free-model-canary)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
BASE_PATH=$PATH
FREE=opencode/deepseek-v4.1-flash-free
PAID=opencode-go/deepseek-v4.1-flash
export FAKE_OC_LOG="$TMP_ROOT/opencode.log"
export FAKE_OC_LISTING="$TMP_ROOT/listing.txt"
export FAKE_PUSH_LOG="$TMP_ROOT/push.log"

# The fake opencode logs its arguments and the config it was handed, then
# prints the listing file and exits FAKE_OC_EXIT. FAKE_OC_TOUCH names a file
# it appends to while "listing", to model an edit during the run.
cat > "$FAKEBIN/opencode" <<'SH'
#!/usr/bin/env bash
printf '%s | %s\n' "$*" "${OPENCODE_CONFIG_CONTENT:-}" >> "$FAKE_OC_LOG"
[ -z "${FAKE_OC_TOUCH:-}" ] || printf '\n' >> "$FAKE_OC_TOUCH"
cat "$FAKE_OC_LISTING" 2>/dev/null
exit "${FAKE_OC_EXIT:-0}"
SH
chmod +x "$FAKEBIN/opencode"
cat > "$FAKEBIN/config-push" <<'SH'
#!/usr/bin/env bash
printf 'push %s\n' "$FM_HOME" >> "$FAKE_PUSH_LOG"
SH
chmod +x "$FAKEBIN/config-push"

WATCHED_RULES='{"rules":[{"when":"read-only research","use":{"harness":"opencode","model":"'"$FREE"'","provider":"opencode","private_ok":false,"replace_when_unlisted":{"harness":"pi","model":"'"$PAID"'","provider":"opencode-go"}}},{"when":"implementation","use":{"harness":"codex","model":"gpt-5"}}],"default":{"harness":"claude","model":"sonnet"}}'
PLAIN_RULES='{"rules":[{"when":"implementation","use":{"harness":"opencode","model":"opencode/big-pickle"}}],"default":{"harness":"claude","model":"sonnet"}}'

HOME_DIR=''
new_home() {  # <name> <rules-json>
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state"
  printf '%s\n' "$2" | jq . > "$HOME_DIR/config/crew-dispatch.json"
  : > "$FAKE_OC_LOG"
  : > "$FAKE_PUSH_LOG"
}

run_canary() {  # <exit-var> <out-var> [args...]
  local __exit=$1 __out=$2 _out _code
  shift 2
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_CONFIG_PUSH_BIN="$FAKEBIN/config-push" \
    FM_OPENCODE_BIN="$FAKEBIN/opencode" "$TOOL" "$@" 2>&1)
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
}
code='' out=''

backups() { find "$HOME_DIR/config" -name 'crew-dispatch.json.bak-*-canary' | wc -l | tr -d ' '; }

# --- run -----------------------------------------------------------------------

new_home listed "$WATCHED_RULES"
printf '%s\n' opencode/big-pickle "$FREE" opencode/gpt-5-nano > "$FAKE_OC_LISTING"
before=$(cat "$HOME_DIR/config/crew-dispatch.json")
run_canary code out run
expect_code 0 "$code" "run: a listed free model"
assert_equals "OK $FREE: listed" "$out" "run: a listed free model is one OK line"
assert_equals "$before" "$(cat "$HOME_DIR/config/crew-dispatch.json")" "run: a listed model leaves the rules untouched"
assert_contains "$(cat "$FAKE_OC_LOG")" 'models opencode --refresh --pure' "run: the provider is listed fresh, without project plugins"
assert_contains "$(cat "$FAKE_OC_LOG")" '"autoupdate":false,"share":"disabled"' "run: the listing never autoupdates or shares"
assert_equals 0 "$(backups)" "run: no backup without a swap"
[ ! -s "$FAKE_PUSH_LOG" ] || fail "run: no config push without a swap"
pass "run: a listed free model is ok and changes nothing"

new_home unlisted "$WATCHED_RULES"
printf '%s\n' opencode/big-pickle opencode/gpt-5-nano > "$FAKE_OC_LISTING"
run_canary code out run
expect_code 0 "$code" "run: an unlisted free model is swapped: $out"
assert_contains "$out" "SWAPPED $FREE: no longer listed by opencode; its dispatch profile now runs pi $PAID" "run: the swap names the replacement"
rules="$HOME_DIR/config/crew-dispatch.json"
assert_equals "{\"harness\":\"pi\",\"model\":\"$PAID\",\"provider\":\"opencode-go\",\"private_ok\":false}" \
  "$(jq -c '.rules[0].use' "$rules")" "run: the profile becomes its replacement and keeps private_ok"
assert_equals '{"harness":"codex","model":"gpt-5"}' "$(jq -c '.rules[1].use' "$rules")" "run: other rules are untouched"
assert_equals '{"harness":"claude","model":"sonnet"}' "$(jq -c '.default' "$rules")" "run: the default is untouched"
assert_equals 'read-only research' "$(jq -r '.rules[0].when' "$rules")" "run: the rule's routing text is untouched"
assert_equals 1 "$(backups)" "run: the previous rules are kept as one dated backup"
jq -e '.rules[0].use.replace_when_unlisted' "$HOME_DIR"/config/crew-dispatch.json.bak-*-canary >/dev/null \
  || fail "run: the backup holds the rules from before the swap"
assert_equals "push $HOME_DIR" "$(cat "$FAKE_PUSH_LOG")" "run: a swap converges the secondmate homes"
run_canary code out run
expect_code 0 "$code" "run: after the swap nothing is watched"
assert_equals 'canary: no watched profile' "$out" "run: a swapped profile is no longer watched"
pass "run: an unlisted free model swaps to its replacement, keeps a backup, and pushes"

new_home failed "$WATCHED_RULES"
before=$(cat "$HOME_DIR/config/crew-dispatch.json")
printf '%s\n' opencode/big-pickle > "$FAKE_OC_LISTING"
FAKE_OC_EXIT=1 run_canary code out run
expect_code 1 "$code" "run: a failed listing proves nothing"
assert_contains "$out" "UNVERIFIABLE $FREE: opencode models opencode listed nothing (exit 1)" "run: a failed listing is unverifiable"
: > "$FAKE_OC_LISTING"
run_canary code out run
expect_code 1 "$code" "run: an empty listing proves nothing"
assert_contains "$out" "UNVERIFIABLE $FREE" "run: an empty listing is unverifiable"
printf '%s\n' opencode-go/glm-5 > "$FAKE_OC_LISTING"
run_canary code out run
expect_code 1 "$code" "run: a listing naming none of the provider's models proves nothing"
assert_equals "$before" "$(cat "$HOME_DIR/config/crew-dispatch.json")" "run: an unverifiable listing never swaps"
assert_equals 0 "$(backups)" "run: an unverifiable listing keeps no backup"
[ ! -s "$FAKE_PUSH_LOG" ] || fail "run: an unverifiable listing pushes nothing"
pass "run: a failed or empty listing is unverifiable and never swaps"

new_home raced "$WATCHED_RULES"
printf '%s\n' opencode/big-pickle > "$FAKE_OC_LISTING"
FAKE_OC_TOUCH="$HOME_DIR/config/crew-dispatch.json" run_canary code out run
expect_code 1 "$code" "run: a rules edit during the listing"
assert_contains "$out" "FAILED $FREE: no longer listed by opencode, but the swap failed: the rules file changed while the canary ran" "run: an edit during the run refuses the swap"
jq -e '.rules[0].use.replace_when_unlisted' "$HOME_DIR/config/crew-dispatch.json" >/dev/null \
  || fail "run: a refused swap leaves the operator's rules in place"
pass "run: a rules edit during the listing refuses the swap"

new_home plain "$PLAIN_RULES"
run_canary code out run
expect_code 0 "$code" "run: no watched profile"
assert_equals 'canary: no watched profile' "$out" "run: no watched profile says so"
[ ! -s "$FAKE_OC_LOG" ] || fail "run: no watched profile never calls opencode"
pass "run: a rules file without replace_when_unlisted calls nothing"

new_home secondmate "$WATCHED_RULES"
printf 'research-mate\n' > "$HOME_DIR/.fm-secondmate-home"
printf '%s\n' opencode/big-pickle > "$FAKE_OC_LISTING"
run_canary code out run
expect_code 2 "$code" "run: a secondmate home"
assert_contains "$out" 'this is a secondmate home' "run: a secondmate home is refused"
jq -e '.rules[0].use.replace_when_unlisted' "$HOME_DIR/config/crew-dispatch.json" >/dev/null \
  || fail "run: a secondmate home never rewrites its inherited rules"
[ ! -s "$FAKE_OC_LOG" ] || fail "run: a secondmate home never calls opencode"
pass "run: a secondmate home is refused before any listing"

# --- check: one notification per outcome ----------------------------------------

new_home notify "$WATCHED_RULES"
printf '%s\n' opencode/big-pickle > "$FAKE_OC_LISTING"
run_canary code out run --record
expect_code 0 "$code" "check: a recorded swap"
jq -e '.outcome == "swapped" and .reported == false' "$HOME_DIR/state/free-model-canary/result.json" >/dev/null \
  || fail "check: the swap was not recorded"
run_canary code out check
assert_contains "$out" "captain notice - free-model canary swapped a dispatch profile: SWAPPED $FREE" "check: a swap raises one captain notice"
assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "check: the notice is one line"
run_canary code out check
assert_equals '' "$out" "check: the notice is raised once"
pass "check: a recorded swap raises exactly one captain notice"

new_home unverified "$WATCHED_RULES"
printf '%s\n' "$FREE" > "$FAKE_OC_LISTING"
FAKE_OC_EXIT=1 run_canary code out run --record
expect_code 1 "$code" "check: a recorded unverifiable run"
run_canary code out check
assert_contains "$out" 'free-model canary could not verify the free opencode models: UNVERIFIABLE' "check: the first unverifiable run alerts"
FAKE_OC_EXIT=1 run_canary code out run --record
run_canary code out check
assert_equals '' "$out" "check: a repeated unverifiable outcome stays silent"
run_canary code out run --record
expect_code 0 "$code" "check: a recovered listing"
run_canary code out check
assert_equals '' "$out" "check: a recovered listing is silent"
FAKE_OC_EXIT=1 run_canary code out run --record
run_canary code out check
assert_contains "$out" 'could not verify' "check: a new unverifiable outcome after a recovery alerts again"
pass "check: an unverifiable canary alerts once per outcome change"

# A stale record starts a detached run; its result reports on a later check.
new_home detached "$WATCHED_RULES"
printf '%s\n' opencode/big-pickle > "$FAKE_OC_LISTING"
run_canary code out check
assert_equals '' "$out" "check: a due run starts silently"
for ((i = 0; i < 150; i++)); do
  jq -e '.state == "done"' "$HOME_DIR/state/free-model-canary/result.json" >/dev/null 2>&1 \
    && [ ! -d "$HOME_DIR/state/free-model-canary/running" ] && break
  sleep 0.2
done
jq -e '.outcome == "swapped"' "$HOME_DIR/state/free-model-canary/result.json" >/dev/null 2>&1 \
  || fail "check: the detached run never recorded its swap"
run_canary code out check
assert_contains "$out" 'captain notice - free-model canary swapped a dispatch profile' "check: the detached swap is reported"
run_canary code out check
assert_equals '' "$out" "check: a fresh record does not start another run"
pass "check: a due canary runs detached and reports on the next poll"

new_home stopped "$WATCHED_RULES"
mkdir -p "$HOME_DIR/state/free-model-canary"
printf '%s\n' '{"started":1,"state":"running"}' > "$HOME_DIR/state/free-model-canary/result.json"
run_canary code out check
assert_contains "$out" 'free-model canary could not verify the free opencode models: the canary run stopped before it finished' "check: a run that died is reported"
pass "check: a run that stopped before it finished is reported"

new_home sm-check "$WATCHED_RULES"
printf 'research-mate\n' > "$HOME_DIR/.fm-secondmate-home"
run_canary code out check
expect_code 0 "$code" "check: a secondmate home"
assert_equals '' "$out" "check: a secondmate home stays silent"
[ ! -e "$HOME_DIR/state/free-model-canary" ] || fail "check: a secondmate home keeps no canary state"
pass "check: a secondmate home never runs the canary"

# --- arm -------------------------------------------------------------------------

new_home arm-plain "$PLAIN_RULES"
run_canary code out arm --if-watched
expect_code 0 "$code" "arm --if-watched: nothing watched"
assert_equals '' "$out" "arm --if-watched: nothing watched stays silent"
[ ! -e "$HOME_DIR/state/free-model-canary.check.sh" ] || fail "arm --if-watched: nothing watched arms nothing"
run_canary code out arm
expect_code 1 "$code" "arm: nothing watched is refused"
assert_contains "$out" 'declares replace_when_unlisted' "arm: the refusal names the missing field"
pass "arm: nothing is armed without a watched profile"

new_home arm-sm "$WATCHED_RULES"
printf 'research-mate\n' > "$HOME_DIR/.fm-secondmate-home"
run_canary code out arm --if-watched
expect_code 0 "$code" "arm --if-watched: a secondmate home"
[ ! -e "$HOME_DIR/state/free-model-canary.check.sh" ] || fail "arm --if-watched: a secondmate home arms nothing"
run_canary code out arm
expect_code 1 "$code" "arm: a secondmate home is refused"
pass "arm: a secondmate home is never armed"

new_home arm-watched "$WATCHED_RULES"
run_canary code out arm --if-watched
expect_code 0 "$code" "arm --if-watched: a watched profile: $out"
assert_equals 'armed: state/free-model-canary.check.sh' "$out" "arm --if-watched: a watched profile arms the check"
[ -x "$HOME_DIR/state/free-model-canary.check.sh" ] || fail "arm: no shim"
[ -f "$HOME_DIR/state/free-model-canary.check-trust" ] || fail "arm: no trust binding"
assert_equals 3600 "$(cat "$HOME_DIR/state/free-model-canary.check-every")" "arm: hourly check cadence"
run_canary code out arm
expect_code 0 "$code" "arm: repeated arming succeeds"
run_canary code out disarm
expect_code 0 "$code" "disarm: succeeds"
[ ! -e "$HOME_DIR/state/free-model-canary.check.sh" ] || fail "disarm: the shim is gone"
[ ! -e "$HOME_DIR/state/free-model-canary.check-every" ] || fail "disarm: the cadence is gone"
[ ! -s "$FAKE_OC_LOG" ] || fail "arm: arming never calls opencode"
pass "arm: a watched profile arms an hourly check, and disarm removes it"

echo "# all fm-free-model-canary tests passed"
