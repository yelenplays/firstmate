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
  {"id": "opus", "harness": "claude", "model": "claude-opus-5-5", "billing": "subscription", "evidence": "strong long-horizon orchestration and review"},
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
  planning*) body='{"id":"gen-dec-1","model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"fable","confidence":0.85,"probabilities":{"opus":0.1,"sonnet":0.05,"fable":0.85,"none_fit":0}}}}' ;;
  well-scoped*) body='{"model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"sonnet","confidence":0.95,"probabilities":{"opus":0.05,"sonnet":0.95,"fable":0,"none_fit":0}}}}' ;;
  *) body=${TEST_THIRD:-'{"model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"opus","confidence":0.4,"probabilities":{"opus":0.4,"sonnet":0.3,"fable":0.3,"none_fit":0}}}}'} ;;
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
long_job=$(printf '%601s' '' | tr ' ' x)
jq --arg job "$long_job" '.rules[0].when = $job' "$HOME_DIR/config/crew-dispatch.json" > "$TMP_ROOT/long-dispatch.json"
out=$(run_tool --evidence "$TMP_ROOT/evidence.json" --dispatch "$TMP_ROOT/long-dispatch.json" 2>&1); rc=$?
case "$rc:$out" in 2:*'role rule-1 job exceeds 600 characters'*) ;; *) fail "an oversized dispatch role must be named and refused: $rc $out" ;; esac
jq --arg job "$long_job" '.roles[0].job = $job' "$TMP_ROOT/evidence.json" > "$TMP_ROOT/long-evidence-role.json"
out=$(run_tool --evidence "$TMP_ROOT/long-evidence-role.json" 2>&1); rc=$?
case "$rc:$out" in 2:*'role secondmate job exceeds 600 characters'*) ;; *) fail "an oversized evidence role must be named and refused: $rc $out" ;; esac
[ -z "$(find "$TEST_REQUESTS" -type f)" ] || fail 'invalid or oversized jobs must send nothing'
pass 'invalid input and oversized roles from both sources refuse before any call'

NEVER_SEND="$HOME_DIR/config/dispatch-never-send"
for forbidden in \
  'planning, architecture and design decisions' \
  'persistent domain supervisor' \
  'claude-fable-5-1' \
  'strong long-horizon orchestration and review' \
  'jev-1.13.0'; do
  printf '# ignored\n  %s  \n' "$forbidden" > "$NEVER_SEND"
  out=$(run_tool --evidence "$TMP_ROOT/evidence.json" --out "$TMP_ROOT/never-send.md" 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "never-send match must refuse before calls: $rc $out"
  case "$out" in *'request text matches '*"$NEVER_SEND"*'line 2'*) ;; *) fail "never-send refusal did not identify only the list line: $out" ;; esac
  case "$out" in *"$forbidden"*) fail 'never-send refusal exposed the matched value' ;; esac
  [ -z "$(find "$TEST_REQUESTS" -type f)" ] && [ ! -e "$TMP_ROOT/never-send.md" ] \
    || fail 'a blocked request must send nothing and write no proposal'
done
chmod 000 "$NEVER_SEND"
out=$(run_tool --evidence "$TMP_ROOT/evidence.json" --out "$TMP_ROOT/unreadable-list.md" 2>&1); rc=$?
chmod 600 "$NEVER_SEND"
[ "$rc" -eq 2 ] || fail "an unreadable never-send list must refuse: $rc $out"
case "$out" in *'dispatch-never-send is not a readable regular file'*) ;; *) fail "unreadable list refusal missing: $out" ;; esac
[ -z "$(find "$TEST_REQUESTS" -type f)" ] && [ ! -e "$TMP_ROOT/unreadable-list.md" ] \
  || fail 'an unreadable never-send list must send nothing and write no proposal'
rm -f "$NEVER_SEND"
pass 'never-send blocks every request field and unreadable lists before any call'

run_tool --evidence "$TMP_ROOT/evidence.json" --out "$HOME_DIR/config/proposal.md" >/dev/null 2>&1 && fail 'an output under config/ must refuse'
run_tool --evidence "$TMP_ROOT/evidence.json" --out "$HOME_DIR/config/new/nested/proposal.md" >/dev/null 2>&1 && fail 'a nested output under config/ must refuse'
[ ! -e "$HOME_DIR/config/new" ] || fail 'refusing a nested config output must not create directories'
ln -s "$HOME_DIR/config/newdir" "$TMP_ROOT/config-link"
config_tree_before_link=$(config_tree_sum)
run_tool --evidence "$TMP_ROOT/evidence.json" --out "$TMP_ROOT/config-link/proposal.md" >/dev/null 2>&1 \
  && fail 'an output through a symlink into a missing config directory must refuse'
[ ! -e "$HOME_DIR/config/newdir" ] && [ "$(config_tree_sum)" = "$config_tree_before_link" ] \
  || fail 'refusing a symlinked config output must not create config directories'
run_tool --evidence "$TMP_ROOT/evidence.json" --out "$TMP_ROOT/evidence.json" >/dev/null 2>&1 && fail 'overwriting the evidence file must refuse'
cp "$TMP_ROOT/evidence.json" "$TMP_ROOT/evidence-target.json"
ln -s "$TMP_ROOT/evidence-target.json" "$TMP_ROOT/evidence-link.json"
evidence_before=$(cksum < "$TMP_ROOT/evidence-target.json")
run_tool --evidence "$TMP_ROOT/evidence-link.json" --out "$TMP_ROOT/evidence-target.json" >/dev/null 2>&1 \
  && fail 'overwriting the evidence symlink target must refuse'
[ "$(cksum < "$TMP_ROOT/evidence-target.json")" = "$evidence_before" ] || fail 'evidence symlink target changed'
run_tool --evidence "$TMP_ROOT/evidence-link.json" --out "$TMP_ROOT/evidence-link.json" >/dev/null 2>&1 \
  && fail 'overwriting the evidence symlink path must refuse'
[ -L "$TMP_ROOT/evidence-link.json" ] && [ "$(cksum < "$TMP_ROOT/evidence-target.json")" = "$evidence_before" ] \
  || fail 'evidence symlink path or target changed'
cp "$HOME_DIR/config/crew-dispatch.json" "$TMP_ROOT/dispatch-target.json"
ln -s "$TMP_ROOT/dispatch-target.json" "$TMP_ROOT/dispatch-link.json"
dispatch_before=$(cksum < "$TMP_ROOT/dispatch-target.json")
run_tool --evidence "$TMP_ROOT/evidence.json" --dispatch "$TMP_ROOT/dispatch-link.json" \
  --out "$TMP_ROOT/dispatch-target.json" >/dev/null 2>&1 && fail 'overwriting the dispatch symlink target must refuse'
[ "$(cksum < "$TMP_ROOT/dispatch-target.json")" = "$dispatch_before" ] || fail 'dispatch symlink target changed'
run_tool --evidence "$TMP_ROOT/evidence.json" --dispatch "$TMP_ROOT/dispatch-link.json" \
  --out "$TMP_ROOT/dispatch-link.json" >/dev/null 2>&1 && fail 'overwriting the dispatch symlink path must refuse'
[ -L "$TMP_ROOT/dispatch-link.json" ] && [ "$(cksum < "$TMP_ROOT/dispatch-target.json")" = "$dispatch_before" ] \
  || fail 'dispatch symlink path or target changed'
[ -z "$(find "$TEST_REQUESTS" -type f)" ] && [ "$(config_sum)" = "$CONFIG_BEFORE" ] \
  && [ "$(config_tree_sum)" = "$CONFIG_TREE_BEFORE" ] || fail 'refused outputs must send and change nothing'
pass 'outputs under config/ or on either input, including symlink targets, refuse'

FM_STATE_OVERRIDE="$TMP_ROOT/config-alias/override-state" run_tool --evidence "$TMP_ROOT/evidence.json" --out "$TMP_ROOT/should-not-write.md" >/dev/null 2>&1 && fail 'a state override under config/ must refuse'
[ -z "$(find "$TEST_REQUESTS" -type f)" ] && [ "$(config_sum)" = "$CONFIG_BEFORE" ] && [ ! -e "$TMP_ROOT/should-not-write.md" ] \
  || fail 'a config-backed state override must refuse before calls or writes'
pass 'a config-backed state override refuses through a symlinked path'

printf 'dispatch stays intact\n' > "$HOME_DIR/config/log-target"
ln -s ../config/log-target "$HOME_DIR/state/jev-model-proposal.jsonl"
config_before_log=$(config_sum)
out=$(run_tool --evidence "$TMP_ROOT/evidence.json" --out "$TMP_ROOT/config-log.md" 2>&1); rc=$?
[ "$rc" -eq 2 ] || fail "a call log symlink into config/ must refuse: $rc $out"
[ -z "$(find "$TEST_REQUESTS" -type f)" ] && [ ! -e "$TMP_ROOT/config-log.md" ] \
  && [ "$(config_sum)" = "$config_before_log" ] || fail 'a config-backed log must refuse before requests or writes'
rm "$HOME_DIR/state/jev-model-proposal.jsonl" "$HOME_DIR/config/log-target"
pass 'a call log symlink into config/ refuses before any Jev call'

NO_CONFIG_HOME="$TMP_ROOT/no-config-home"
mkdir -p "$NO_CONFIG_HOME"
for target in "$NO_CONFIG_HOME/config/proposal.md" "$NO_CONFIG_HOME/config/new/nested/proposal.md"; do
  FM_HOME="$NO_CONFIG_HOME" run_tool --evidence "$TMP_ROOT/evidence.json" --out "$target" >/dev/null 2>&1 \
    && fail "an output into an absent config tree must refuse: $target"
  [ ! -e "$NO_CONFIG_HOME/config" ] || fail 'refusing an absent config target must not create config/'
done
FM_HOME="$NO_CONFIG_HOME" FM_STATE_OVERRIDE="$NO_CONFIG_HOME/config" run_tool \
  --evidence "$TMP_ROOT/evidence.json" --out "$TMP_ROOT/no-config-out/proposal.md" >/dev/null 2>&1 \
  && fail 'a state override into an absent config tree must refuse'
[ ! -e "$NO_CONFIG_HOME/config" ] && [ ! -e "$TMP_ROOT/no-config-out" ] \
  || fail 'absent config paths must be refused before any directories are created'
[ -z "$(find "$TEST_REQUESTS" -type f)" ] || fail 'protected absent paths must refuse before any Jev call'
pass 'absent config and state paths are guarded before creating directories'

EMPTY_CONFIG_HOME="$TMP_ROOT/empty-config-home"
mkdir -p "$EMPTY_CONFIG_HOME/config"
ln -s "$TMP_ROOT" "$TMP_ROOT/root-alias"
ln -s "$EMPTY_CONFIG_HOME/config/newdir" "$TMP_ROOT/empty-config-link"
for target in "$TMP_ROOT/empty-config-link/proposal.md" "$TMP_ROOT/empty-config-link/a/proposal.md" "$TMP_ROOT/root-alias/empty-config-link/a/b/proposal.md"; do
  FM_HOME="$EMPTY_CONFIG_HOME" run_tool --evidence "$TMP_ROOT/evidence.json" --out "$target" >/dev/null 2>&1 \
    && fail "an output through a link into an empty config/ must refuse: $target"
  [ -d "$EMPTY_CONFIG_HOME/config" ] || fail 'refusing an output must never remove an existing empty config/'
  [ -z "$(ls -A "$EMPTY_CONFIG_HOME/config")" ] || fail 'refusing an output must leave config/ empty'
done
[ -z "$(find "$TEST_REQUESTS" -type f)" ] || fail 'a refused output must refuse before any Jev call'
pass 'a refused output never removes an existing empty config/'

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

rm -f "$TEST_REQUESTS"/*.json
out_file="$TMP_ROOT/out/out-of-range-confidence.md"
TEST_THIRD='{"model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"opus","confidence":1.2,"probabilities":{"opus":0.6,"sonnet":0.3,"fable":0.1,"none_fit":0}}}}' \
  run_tool --evidence "$TMP_ROOT/evidence.json" --out "$out_file" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] || fail "out-of-range confidence must make that role malformed, got $rc"
grep -q '## secondmate' "$out_file" || fail 'the other roles should still appear in the proposal'
grep -A8 '^## secondmate$' "$out_file" | grep -q 'Jev: no answer (Jev answer was malformed).' \
  || fail 'out-of-range confidence must not be used for a role answer'
grep -A8 '^## secondmate$' "$out_file" | grep -q 'Proposal: none.' \
  || fail 'out-of-range confidence must not create a switch proposal'
pass 'out-of-range confidence is rejected for that role'

for response in \
  '{"model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"opus","probabilities":{"opus":0.4,"sonnet":0.3,"fable":0.3,"none_fit":0}}}}' \
  '{"model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"opus","confidence":null,"probabilities":{"opus":0.4,"sonnet":0.3,"fable":0.3,"none_fit":0}}}}'; do
  rm -f "$TEST_REQUESTS"/*.json
  out_file="$TMP_ROOT/out/missing-confidence.md"
  TEST_THIRD="$response" run_tool --evidence "$TMP_ROOT/evidence.json" --out "$out_file" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] || fail "missing or null confidence must make that role unusable, got $rc"
  grep -A8 '^## secondmate$' "$out_file" | grep -q 'Jev: no answer (Jev answer was malformed).' \
    || fail 'missing or null confidence must not be used for a role answer'
  grep -A8 '^## secondmate$' "$out_file" | grep -q 'Proposal: none.' \
    || fail 'missing or null confidence must not create a switch proposal'
  if grep -A8 '^## secondmate$' "$out_file" | grep -q 'confidence=n/a'; then fail 'an unusable answer must not render confidence=n/a'; fi
done
pass 'missing and null confidence are rejected for that role'

for response in \
  '{"model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"opus","confidence":0.2,"probabilities":{"opus":0.2,"sonnet":0.6,"fable":0.2,"none_fit":0}}}}' \
  '{"model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"opus","confidence":0.8,"probabilities":{"opus":0.3,"sonnet":0.6,"fable":0.1,"none_fit":0}}}}'; do
  rm -f "$TEST_REQUESTS"/*.json
  out_file="$TMP_ROOT/out/inconsistent-answer.md"
  TEST_THIRD="$response" run_tool --evidence "$TMP_ROOT/evidence.json" --out "$out_file" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] || fail "an inconsistent Jev answer must be malformed, got $rc"
  grep -A8 '^## secondmate$' "$out_file" | grep -q 'Jev: no answer (Jev answer was malformed).' \
    || fail 'a non-maximal choice must be rejected'
  grep -A8 '^## secondmate$' "$out_file" | grep -q 'Proposal: none.' \
    || fail 'an inconsistent answer must not create a proposal'
done
pass 'non-maximal choices and mismatched confidence are rejected'

# Live Jev answers carry a separately calibrated confidence a few points off
# the chosen probability; the band follows the probability.
rm -f "$TEST_REQUESTS"/*.json
out_file="$TMP_ROOT/out/calibrated-confidence.md"
TEST_THIRD='{"model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"opus","confidence":0.93,"probabilities":{"opus":0.95,"sonnet":0.05,"fable":0,"none_fit":0}}}}' \
  run_tool --evidence "$TMP_ROOT/evidence.json" --out "$out_file" >/dev/null 2>&1 || fail 'a calibrated confidence must not make the answer malformed'
grep -A8 '^## secondmate$' "$out_file" | grep -q 'p=0.95, confidence=0.93, band act.' \
  || fail 'a calibrated confidence must be reported with the probability-derived band'
pass 'a confidence that differs from the probability is accepted'

cat > "$TMP_ROOT/current-model-evidence.json" <<'JSON'
{"as_of":"2026-10-03","candidates":[
  {"id":"luna","harness":"openai-codex","model":"gpt-6-luna","billing":"subscription","evidence":"strong coding model"},
  {"id":"opus","harness":"claude","model":"claude-opus-5-5","billing":"subscription","evidence":"general reasoning model"}
],"roles":[{"id":"codex-role","job":"coding tasks","current":["pi/openai-codex/gpt-6-luna"]}]}
JSON
printf '{"rules":[]}' > "$TMP_ROOT/empty-dispatch.json"
out_file="$TMP_ROOT/out/current-model.md"
TEST_THIRD='{"model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"luna","confidence":0.9,"probabilities":{"luna":0.9,"opus":0.1,"none_fit":0}}}}' \
  run_tool --evidence "$TMP_ROOT/current-model-evidence.json" --dispatch "$TMP_ROOT/empty-dispatch.json" \
    --out "$out_file" >/dev/null 2>&1 || fail 'the documented current model proposal failed'
# shellcheck disable=SC2016 # Literal backticks from the Markdown proposal.
grep -q 'keep `gpt-6-luna`, Jev agrees with the current pick.' "$out_file" \
  || fail 'the documented family/provider/model current entry must not recommend a switch'
pass 'documented family/provider/model entries are recognized as current'

cat > "$TMP_ROOT/dispatch-current-evidence.json" <<'JSON'
{"as_of":"2026-10-03","candidates":[
  {"id":"luna","harness":"pi","model":"openai-codex/gpt-6-luna","billing":"subscription","evidence":"strong coding model"},
  {"id":"opus","harness":"claude","model":"claude-opus-5-5","billing":"subscription","evidence":"general reasoning model"}
],"roles":[{"id":"pi-role","job":"coding tasks","current":["pi/openai-codex/gpt-6-luna/high"]}]}
JSON
out_file="$TMP_ROOT/out/dispatch-current.md"
TEST_THIRD='{"model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"luna","confidence":0.9,"probabilities":{"luna":0.9,"opus":0.1,"none_fit":0}}}}' \
  run_tool --evidence "$TMP_ROOT/dispatch-current-evidence.json" --dispatch "$TMP_ROOT/empty-dispatch.json" \
    --out "$out_file" >/dev/null 2>&1 || fail 'the dispatch-style current model proposal failed'
# shellcheck disable=SC2016 # Literal backticks from the Markdown proposal.
grep -q 'keep `openai-codex/gpt-6-luna`, Jev agrees with the current pick.' "$out_file" \
  || fail 'a harness/model/effort current entry whose model holds a slash must not recommend a switch'
pass 'dispatch-style harness/model/effort entries are recognized as current'

cat > "$TMP_ROOT/object-use-dispatch.json" <<'JSON'
{"rules":[{"when":"coding tasks","use":{"harness":"openai-codex","model":"gpt-6-luna","effort":"high"}}]}
JSON
out_file="$TMP_ROOT/out/object-use-current.md"
TEST_THIRD='{"model":"jev-1.13.0","answers":{"model":{"type":"choice","choice":"luna","confidence":0.9,"probabilities":{"luna":0.9,"opus":0.1,"none_fit":0}}}}' \
  run_tool --evidence "$TMP_ROOT/current-model-evidence.json" --dispatch "$TMP_ROOT/object-use-dispatch.json" \
    --out "$out_file" >/dev/null 2>&1 || fail 'a single-object dispatch use proposal failed'
# shellcheck disable=SC2016 # Literal backticks from the Markdown proposal.
grep -qF 'keep `gpt-6-luna`, Jev agrees with the current pick.' "$out_file" \
  || fail 'a single-object dispatch use must not recommend switching to its current model'
grep -qF -- '- Current: openai-codex/gpt-6-luna/high' "$out_file" \
  || fail 'a single-object dispatch use must be listed as current'
pass 'single-object dispatch use is normalized as current'
