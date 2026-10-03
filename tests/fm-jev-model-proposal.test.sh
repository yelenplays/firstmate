#!/usr/bin/env bash
# Behavioral regression for the per-role Jev model proposal generator.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TOOL="$ROOT/bin/fm-jev-model-proposal.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-model-proposal)
HOME_DIR="$TMP_ROOT/home"
BIN="$TMP_ROOT/bin"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config/override-state" "$HOME_DIR/data" "$BIN" "$TMP_ROOT/requests"
ln -s "$HOME_DIR/config" "$TMP_ROOT/config-alias"

cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{"rules": [
  {"when": "planning, architecture and design decisions", "use": [{"harness": "claude", "model": "claude-opus-5-5", "effort": "medium", "provider": "claude"}], "why": "PRIVATE-WHY-NOTE"},
  {"when": "well-scoped implementation with a clear target", "use": [{"harness": "claude", "model": "claude-sonnet-5-5", "effort": "medium", "provider": "claude"}]}
]}
JSON
cat > "$TMP_ROOT/evidence.json" <<'JSON'
{"as_of": "2026-10-03", "sources": ["agent-stack REFERENCE.md"],
 "candidates": [
  {"id": "opus", "harness": "claude", "model": "claude-opus-5-5", "provider": "claude", "billing": "subscription", "evidence": "strong long-horizon orchestration and review"},
  {"id": "sonnet", "harness": "claude", "model": "claude-sonnet-5-5", "provider": "claude", "billing": "subscription", "evidence": "fast well-scoped implementation and UI work"},
  {"id": "fable", "harness": "claude", "model": "claude-fable-5-1", "provider": "claude", "billing": "usage-credits", "evidence": "planning and architecture"}
 ],
 "roles": [{"id": "secondmate", "job": "persistent domain supervisor", "current": ["pi/openai-codex/gpt-6-luna/max"]}]}
JSON

# The stub answers by role: planning picks Fable in the act band, the
# implementation rule keeps Sonnet, and the secondmate role leans below it.
cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
out=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac
done
n=$(find "$TEST_REQUESTS" -type f | wc -l | tr -d ' ')
req="$TEST_REQUESTS/$n.json"
cat > "$req"
job=$(jq -r '.state.role.job' "$req")
case "$job" in
  planning*) body='{"id":"gen-dec-1","model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"fable","confidence":0.8,"probabilities":{"opus":0.1,"sonnet":0.05,"fable":0.85,"none_fit":0}}}}' ;;
  well-scoped*) body='{"model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"sonnet","confidence":0.9,"probabilities":{"opus":0.05,"sonnet":0.95,"fable":0,"none_fit":0}}}}' ;;
  *) body=${TEST_THIRD:-'{"model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"opus","confidence":0.4,"probabilities":{"opus":0.6,"sonnet":0.3,"fable":0.1,"none_fit":0}}}}'} ;;
esac
printf '%s' "$body" > "$out"
printf 200
SH
chmod +x "$BIN/curl"
export FM_HOME="$HOME_DIR" TEST_REQUESTS="$TMP_ROOT/requests"
unset TYPESAFE_API_KEY OPENROUTER_API_KEY JEV_ROUTE JEV_MODEL JEV_URL JEV_BASE FM_STATE_OVERRIDE TEST_THIRD
run_tool() { PATH="$BIN:$PATH" bash "$TOOL" "$@"; }
config_sum() { find "$HOME_DIR/config" -type f -exec cat {} + | cksum; }
config_tree_sum() { find "$HOME_DIR/config" -print | sort | cksum; }
CONFIG_BEFORE=$(config_sum)
CONFIG_TREE_BEFORE=$(config_tree_sum)

run_tool --help | grep -q 'never changes a model' || fail '--help does not print the interface'
pass '--help prints the interface'

out=$(run_tool --evidence "$TMP_ROOT/evidence.json" 2>&1); rc=$?
[ "$rc" -eq 2 ] || fail "no key must exit 2, got $rc"
case "$out" in *'nothing sent, no proposal written'*) ;; *) fail "no-key message missing: $out" ;; esac
[ -z "$(find "$TEST_REQUESTS" -type f)" ] && [ ! -d "$HOME_DIR/data/model-proposals" ] || fail 'no key must send and write nothing'
pass 'no key sends and writes nothing'

export TYPESAFE_API_KEY=testing-only
jq '.candidates[2].billing = "subscription"' "$TMP_ROOT/evidence.json" > "$TMP_ROOT/bad-fable.json"
out=$(run_tool --evidence "$TMP_ROOT/bad-fable.json" 2>&1); rc=$?
case "$rc:$out" in
  2:*'Fable model must be marked billing usage-credits'*) ;;
  *) fail "Fable without usage-credits billing must refuse: $rc $out" ;;
esac
jq '.candidates[1].id = "opus"' "$TMP_ROOT/evidence.json" > "$TMP_ROOT/dup.json"
run_tool --evidence "$TMP_ROOT/dup.json" >/dev/null 2>&1 && fail 'duplicate candidate ids must refuse'
jq '.candidates[1].id = "none_fit"' "$TMP_ROOT/evidence.json" > "$TMP_ROOT/reserved.json"
run_tool --evidence "$TMP_ROOT/reserved.json" >/dev/null 2>&1 && fail 'the reserved none_fit id must refuse'
printf '{"rules": "nope"}' > "$TMP_ROOT/bad-dispatch.json"
run_tool --evidence "$TMP_ROOT/evidence.json" --dispatch "$TMP_ROOT/bad-dispatch.json" >/dev/null 2>&1 && fail 'a malformed dispatch file must refuse'
[ -z "$(find "$TEST_REQUESTS" -type f)" ] || fail 'invalid input must send nothing'
pass 'invalid evidence or dispatch input refuses before any call'

run_tool --evidence "$TMP_ROOT/evidence.json" --out "$HOME_DIR/config/proposal.md" >/dev/null 2>&1 && fail 'an output under config/ must refuse'
run_tool --evidence "$TMP_ROOT/evidence.json" --out "$HOME_DIR/config/new/nested/proposal.md" >/dev/null 2>&1 && fail 'a nested output under config/ must refuse'
[ ! -e "$HOME_DIR/config/new" ] || fail 'refusing a nested config output must not create directories'
run_tool --evidence "$TMP_ROOT/evidence.json" --out "$TMP_ROOT/evidence.json" >/dev/null 2>&1 && fail 'overwriting the evidence file must refuse'
[ -z "$(find "$TEST_REQUESTS" -type f)" ] && [ "$(config_sum)" = "$CONFIG_BEFORE" ] \
  && [ "$(config_tree_sum)" = "$CONFIG_TREE_BEFORE" ] || fail 'refused outputs must send and change nothing'
pass 'an output under config/ or on an input file refuses'

FM_STATE_OVERRIDE="$TMP_ROOT/config-alias/override-state" run_tool --evidence "$TMP_ROOT/evidence.json" --out "$TMP_ROOT/should-not-write.md" >/dev/null 2>&1 && fail 'a state override under config/ must refuse'
[ -z "$(find "$TEST_REQUESTS" -type f)" ] && [ "$(config_sum)" = "$CONFIG_BEFORE" ] && [ ! -e "$TMP_ROOT/should-not-write.md" ] \
  || fail 'a config-backed state override must refuse before calls or writes'
pass 'a config-backed state override refuses through a symlinked path'

path=$(run_tool --evidence "$TMP_ROOT/evidence.json") || fail 'happy-path proposal failed'
case "$path" in "$HOME_DIR/data/model-proposals/"*.md) ;; *) fail "default proposal path is wrong: $path" ;; esac
[ -s "$path" ] || fail 'proposal file is empty'
P=$(cat "$path")
# shellcheck disable=SC2016 # Backticks are literal Markdown in the proposal.
for want in \
  'Proposal only: nothing in config/ or any dispatch profile was changed.' \
  '**Billing:** `claude-fable-5-1` bills the account'"'"'s usage credits, outside the subscription.' \
  '## rule-1' '## rule-2' '## secondmate' \
  "switch to \`claude/claude-fable-5-1\` (bills usage credits); needs the captain's yes." \
  'Jev: route typesafe, model jev-1.13.0.' \
  'keep `claude-sonnet-5-5`, Jev agrees with the current pick.' \
  'none; Jev leans to `claude-opus-5-5` below the act band.' \
  '- Current: claude/claude-opus-5-5/medium' \
  '(provider gen-dec-1)' \
  '| fable | claude | claude-fable-5-1 | usage-credits | 85% |'; do
  case "$P" in *"$want"*) ;; *) fail "proposal is missing: $want" ;; esac
done
pass 'proposal names current models, picks, bands, billing, and the Fable credit notice'

ids=$(grep -o 'Request id: [0-9a-f-]*' "$path" | awk '{print $3}')
[ "$(printf '%s\n' "$ids" | grep -c .)" -eq 3 ] && [ "$(printf '%s\n' "$ids" | sort -u | grep -c .)" -eq 3 ] \
  || fail "each role needs its own request id: $ids"
log="$HOME_DIR/state/jev-model-proposal.jsonl"
[ "$(wc -l < "$log" | tr -d ' ')" -eq 3 ] || fail 'one log record per role expected'
for id in $ids; do
  jq -e --arg id "$id" 'select(.request_id == $id) | .purpose == "model-proposal" and (.state_sha256 | length) == 64' "$log" | grep -q true \
    || fail "request id $id is not in the call log"
done
if grep -q 'well-scoped\|planning' "$log"; then fail 'the call log must not hold the state text'; fi
pass 'every role has its own request id, matched in the call log without the state text'

[ "$(find "$TEST_REQUESTS" -type f | wc -l | tr -d ' ')" -eq 3 ] || fail 'one Jev request per role expected'
for req in "$TEST_REQUESTS"/*.json; do
  jq -e '.model == "jev-1.13.0" and (.questions.model.criteria | keys) == ["fable", "none_fit", "opus", "sonnet"]
         and (.state | keys) == ["candidates", "role"] and (.state.candidates.fable | keys) == ["evidence", "model"]' "$req" >/dev/null \
    || fail "request shape is wrong: $(cat "$req")"
  if grep -Eq 'usage-credits|subscription|PRIVATE-WHY-NOTE|gpt-6-luna|"harness"' "$req"; then fail "billing, harness, why, or current pick leaked to Jev: $(cat "$req")"; fi
done
[ "$(config_sum)" = "$CONFIG_BEFORE" ] || fail 'config/ changed'
pass 'Jev sees only the job and candidate evidence, on the pinned model, and config/ is unchanged'

rm -f "$TEST_REQUESTS"/*.json
out_file="$TMP_ROOT/out/partial.md"
TEST_THIRD='{"model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"opus","probabilities":{"opus":1}}}}' \
  run_tool --evidence "$TMP_ROOT/evidence.json" --out "$out_file" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] || fail "a malformed answer must exit 1, got $rc"
grep -q 'Jev: no answer (Jev answer was malformed).' "$out_file" || fail 'a malformed answer must be named in the proposal'
grep -qF "switch to \`claude/claude-fable-5-1\`" "$out_file" || fail 'a malformed answer must still write the other roles'
pass 'a malformed answer for one role still writes the proposal and exits 1'
