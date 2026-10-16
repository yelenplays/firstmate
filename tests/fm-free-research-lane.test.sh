#!/usr/bin/env bash
# Behavior tests for bin/fm-free-research-lane.sh, offline.
#
# Every case drives the public status/enable/disable CLI against a temporary
# home. A fake config push records that it ran; the real free-model canary is
# armed and disarmed, which never calls opencode.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-free-research-lane.sh"
TMP_ROOT=$(fm_test_tmproot fm-free-research-lane)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
BASE_PATH=$PATH
FREE=opencode/deepseek-v4.1-flash-free
PAID=opencode-go/deepseek-v4.1-flash
export FAKE_PUSH_LOG="$TMP_ROOT/push.log"

cat > "$FAKEBIN/config-push" <<'SH'
#!/usr/bin/env bash
printf 'push %s\n' "$FM_HOME" >> "$FAKE_PUSH_LOG"
SH
chmod +x "$FAKEBIN/config-push"

# Two existing rules with a precedence edge, so renumbering would show.
BASE_RULES='{"rules":[{"when":"implementation","use":{"harness":"codex","model":"gpt-5"},"beats":[{"rule":2}]},{"when":"quick fixes","use":{"harness":"claude","model":"haiku"}}],"default":{"harness":"claude","model":"sonnet"}}'

HOME_DIR=''
new_home() {  # <name> <rules-json> [markers...]
  local name=$1 rules=$2
  shift 2
  HOME_DIR="$TMP_ROOT/$name"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state"
  printf '%s\n' "$rules" | jq . > "$HOME_DIR/config/crew-dispatch.json"
  [ "$#" -eq 0 ] || printf '%s\n' "$@" > "$HOME_DIR/config/private-markers"
  : > "$FAKE_PUSH_LOG"
}

run_lane() {  # <exit-var> <out-var> [args...]
  local __exit=$1 __out=$2 _out _code
  shift 2
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_CONFIG_PUSH_BIN="$FAKEBIN/config-push" \
    "$TOOL" "$@" 2>&1)
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
}
code='' out=''
rules_file() { printf '%s\n' "$HOME_DIR/config/crew-dispatch.json"; }
backups() { find "$HOME_DIR/config" -name 'crew-dispatch.json.bak-*-research-lane' | wc -l | tr -d ' '; }

# --- enable refuses without a usable marker list -------------------------------

new_home no-markers "$BASE_RULES"
before=$(cat "$(rules_file)")
run_lane code out enable
expect_code 1 "$code" "enable: no marker list"
assert_contains "$out" 'config/private-markers is missing' "enable: the refusal names the missing list"
printf '%s\n' '# private clients' '' > "$HOME_DIR/config/private-markers"
run_lane code out enable
expect_code 1 "$code" "enable: a list with no marker"
assert_contains "$out" 'names no marker' "enable: the refusal names the empty list"
assert_equals "$before" "$(cat "$(rules_file)")" "enable: a refusal leaves the rules untouched"
assert_equals 0 "$(backups)" "enable: a refusal keeps no backup"
[ ! -s "$FAKE_PUSH_LOG" ] || fail "enable: a refusal pushes nothing"
pass "enable: refused without a marker list that names a marker"

new_home secondmate "$BASE_RULES" 'Acme Private'
printf 'research-mate\n' > "$HOME_DIR/.fm-secondmate-home"
before=$(cat "$(rules_file)")
run_lane code out enable
expect_code 1 "$code" "enable: a secondmate home"
assert_contains "$out" 'secondmate home' "enable: a secondmate home is refused"
assert_equals "$before" "$(cat "$(rules_file)")" "enable: a secondmate home keeps its inherited rules"
pass "enable: a secondmate home is refused"

# --- enable, status, idempotence ----------------------------------------------

new_home enable "$BASE_RULES" '# private clients' 'Acme Private' 'Zebracorp'
run_lane code out enable
expect_code 0 "$code" "enable: with markers: $out"
assert_contains "$out" "lane: enabled as rule 3 on $FREE" "enable: the lane is appended as the last rule"
assert_not_contains "$out" 'Acme Private' "enable: output never names a marker"
assert_equals "$(printf '%s\n' "$BASE_RULES" | jq -c '.rules')" "$(jq -c '.rules[:2]' "$(rules_file)")" \
  "enable: existing rules and their beats keep their numbers"
assert_equals "{\"harness\":\"opencode\",\"model\":\"$FREE\",\"provider\":\"opencode\",\"private_ok\":false}" \
  "$(jq -c '.rules[2].use[0]' "$(rules_file)")" "enable: the lane's sole profile is the free model, not for private work"
assert_contains "$(jq -r '.rules[2].when' "$(rules_file)")" 'never for private projects' "enable: the rule keeps private work out"
assert_contains "$(jq -r '.rules[2].when' "$(rules_file)")" 'Never for code changes, tests, reviews' "enable: the rule keeps out work beyond reading"
assert_not_contains "$(jq -r '.rules[2].when' "$(rules_file)")" 'Acme Private' "enable: the rule text never carries a marker"
assert_equals '{"harness":"claude","model":"sonnet"}' "$(jq -c '.default' "$(rules_file)")" "enable: the default is untouched"
assert_equals 1 "$(backups)" "enable: the previous rules are kept as one dated backup"
assert_equals "push $HOME_DIR" "$(cat "$FAKE_PUSH_LOG")" "enable: the rules reach the secondmate homes"
[ -x "$HOME_DIR/state/free-model-canary.check.sh" ] || fail "enable: the free-model canary is armed"
pass "enable: appends the lane rule, keeps a backup, pushes, and arms the canary"

after=$(cat "$(rules_file)")
: > "$FAKE_PUSH_LOG"
run_lane code out enable
expect_code 0 "$code" "enable: a second time"
assert_equals 'lane: already enabled as rule 3' "$out" "enable: a second enable reports the existing rule"
assert_equals "$after" "$(cat "$(rules_file)")" "enable: a second enable changes nothing"
[ ! -s "$FAKE_PUSH_LOG" ] || fail "enable: a second enable pushes nothing"
pass "enable: is idempotent"

run_lane code out status
expect_code 0 "$code" "status: enabled"
assert_equals "lane: enabled as rule 3 on $FREE"$'\n''private markers: 2' "$out" "status: names the rule and counts markers"
pass "status: names the lane rule and counts markers without naming one"

jq --arg paid "$PAID" '.rules[2].use = [{harness: "pi", model: $paid, provider: "opencode-go", private_ok: false}]' "$(rules_file)" > "$TMP_ROOT/swapped.json"
cp "$TMP_ROOT/swapped.json" "$(rules_file)"
run_lane code out status
assert_contains "$out" "lane: enabled as rule 3 on the paid replacement pi $PAID" "status: a swapped lane names the paid replacement"
run_lane code out enable
assert_equals 'lane: already enabled as rule 3' "$out" "enable: a swapped lane is not added again"
pass "status and enable: recognize a lane the canary swapped to the paid replacement"

# --- disable ---------------------------------------------------------------------

new_home disable "$BASE_RULES" 'Acme Private'
run_lane code out enable
expect_code 0 "$code" "disable: setup enable"
jq '.rules[0].beats += [{"rule": 3}] | .rules[1].beats = [{"rule": 3, "when": "public research"}]' "$(rules_file)" > "$TMP_ROOT/beats.json"
cp "$TMP_ROOT/beats.json" "$(rules_file)"
run_lane code out disable
expect_code 0 "$code" "disable: the last rule: $out"
assert_contains "$out" 'lane: disabled (removed rule 3)' "disable: names the removed rule"
assert_equals "$(printf '%s\n' "$BASE_RULES" | jq -c '.rules')" "$(jq -c '.rules' "$(rules_file)")" \
  "disable: the lane rule and every beats entry naming it are gone, other edges stay"
[ ! -e "$HOME_DIR/state/free-model-canary.check.sh" ] || fail "disable: the canary is disarmed"
run_lane code out disable
assert_equals 'lane: already disabled' "$out" "disable: a second disable does nothing"
pass "disable: removes the last-rule lane and its beats entries, and disarms the canary"

new_home not-last "$BASE_RULES" 'Acme Private'
run_lane code out enable
jq '.rules += [{"when": "later rule", "use": {"harness": "codex", "model": "gpt-5"}}]' "$(rules_file)" > "$TMP_ROOT/later.json"
cp "$TMP_ROOT/later.json" "$(rules_file)"
before=$(cat "$(rules_file)")
run_lane code out disable
expect_code 1 "$code" "disable: a lane that is not the last rule"
assert_contains "$out" 'would renumber later rules' "disable: the refusal explains the renumbering"
assert_equals "$before" "$(cat "$(rules_file)")" "disable: a refusal leaves the rules untouched"
pass "disable: refuses when removing the lane would renumber later rules"

new_home custom-paid "$BASE_RULES" 'Acme Private'
jq --arg paid "$PAID" '.rules += [{"when": "operator rule", "use": {"harness": "pi", "model": $paid, "provider": "opencode-go"}}] | .rules[0].beats += [{"rule": 3}]' "$(rules_file)" > "$TMP_ROOT/custom.json"
cp "$TMP_ROOT/custom.json" "$(rules_file)"
before=$(cat "$(rules_file)")
run_lane code out status
assert_contains "$out" 'lane: disabled' "custom paid rule: status does not claim it as the lane"
run_lane code out enable
expect_code 0 "$code" "custom paid rule: enable: $out"
assert_contains "$out" 'lane: enabled as rule 4' "custom paid rule: the lane is appended after it"
assert_equals "$FREE" "$(jq -r '.rules[3].use[0].model' "$(rules_file)")" "custom paid rule: the new lane rule is the free one"
assert_equals false "$(jq -r '.rules[3].use[0].private_ok' "$(rules_file)")" "custom paid rule: the new lane rule is private_ok false"
run_lane code out disable
expect_code 0 "$code" "custom paid rule: disable: $out"
assert_contains "$out" 'removed rule 4' "custom paid rule: disable removes only the lane rule"
assert_equals "$before" "$(cat "$(rules_file)")" "custom paid rule: the custom rule and its beats edge are intact"
pass "a custom paid-profile rule is never mistaken for the lane"

echo "# all fm-free-research-lane tests passed"
