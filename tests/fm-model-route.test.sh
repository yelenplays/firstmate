#!/usr/bin/env bash
# Model routing integration: same-model effort ties, quota feasibility,
# state-bound consultation receipts, and fixed-policy seats/reviewer pins.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-model-route)
H="$TMP_ROOT/home"
F=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$H/config" "$H/state" "$H/data/demo"
BRIEF="$H/data/demo/brief.md"
printf '## Captain\x27s intent\nImplement the agreed pager fix.\n## Firstmate spec\nUse the existing pager contract.\n' > "$BRIEF"
cat > "$H/config/crew-dispatch.json" <<'JSON'
{"rules":[
 {"when":"Contained implementation work.","use":{"harness":"claude","model":"claude-opus-5-5","effort":"medium"}},
 {"when":"Complex implementation work.","use":{"harness":"claude","model":"claude-opus-5-5","effort":"high"}}
],"default":{"harness":"claude","model":"claude-opus-5-5","effort":"medium"}}
JSON
cat > "$F/curl" <<'SH'
#!/usr/bin/env bash
out=''
while [ $# -gt 0 ]; do
 case "$1" in -o) out=$2; shift 2;; *) shift;; esac
done
body=$(cat)
printf '%s\n' "$body" >> "$CALLS"
if jq -e '.questions.pick' <<<"$body" >/dev/null; then
 jq -nc --argjson body "$body" '
   ($body.questions.pick.criteria | keys) as $keys |
   {model:"jev-1.13.0",answers:{pick:{type:"choice",choice:$keys[0],confidence:0.01,
     probabilities:($keys | to_entries | map({key:.value,value:(if .key == 0 then 0.51 else 0.49 end)}) | from_entries)}}}' > "$out"
elif jq -e '.questions.rule.criteria.rule_2' <<<"$body" >/dev/null; then
 printf '%s\n' '{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.01,"probabilities":{"rule_1":0.51,"rule_2":0.49,"default":0}}}}' > "$out"
else
 printf '%s\n' '{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.95,"probabilities":{"rule_1":0.95,"default":0.05}}}}' > "$out"
fi
printf 200
SH
cat > "$F/quota-axi" <<'SH'
#!/usr/bin/env bash
cat "$ROUTE_QUOTA"
SH
cat > "$F/ledger" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"status":"ok","median":{"claude":{"all":{"tokens":1100000,"seconds":108000,"tasks":1}}},"anyProvider":{"all":{"tokens":1100000,"seconds":108000,"tasks":1}},"providers":{"claude":{"tokensPerPoint":10000}}}'
SH
chmod +x "$F/curl" "$F/quota-axi" "$F/ledger"
export CALLS="$TMP_ROOT/calls" ROUTE_QUOTA="$TMP_ROOT/quota.json"
QUOTA=$ROUTE_QUOTA
cat > "$QUOTA" <<'JSON'
{"schemaVersion":5,"generatedAt":"2030-01-01T00:00:00Z","providers":[{"provider":"claude","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":70,"runway":{"status":"through_reset","usableRunwaySeconds":3600},"selection":{"spendPriority":0.5}}]}}]}
JSON
route() { PATH="$F:$PATH" FM_HOME="$H" TYPESAFE_API_KEY=test-route-key FM_BACKUP_JUDGE_CMD=false FM_SPEND_LEDGER="$F/ledger" "$ROOT/bin/fm-dispatch-resolve.sh" "$@"; }
out=$(route "$BRIEF" --project pager)
assert_contains "$out" '  status: picked' 'same-model effort tie uses the top rule, not another judge'
assert_contains "$out" "--model 'claude-opus-5-5' --effort 'medium'" 'top option effort is preserved'
assert_equals 1 "$(jq -s length "$CALLS")" 'same-model tie makes one Jev call'
assert_not_contains "$out" 'not eligible: predicted' 'through_reset cannot be vetoed by a cross-provider or long-duration task median'
pass 'same model, top effort, and through-reset quota'

RECEIPT=$(awk '/^  receipt: / {sub(/^  receipt: /, ""); print}' <<<"$out")
SELECTED='{"harness":"claude","model":"claude-opus-5-5","effort":"medium"}'
check() { "$ROOT/bin/fm-model-route-receipt.py" check --home "$H" --brief "$BRIEF" --selected "$SELECTED" "$@"; }
check >/dev/null || fail 'fresh dispatch receipt did not bind the selected profile'
check --selected '{"harness":"claude","model":"claude-opus-5-5","effort":"high"}' >/dev/null 2>&1 && fail 'a hand-picked effort bypassed the receipt'
printf '\nChanged requirement.\n' >> "$BRIEF"
check >/dev/null 2>&1 && fail 'changed instructions reused an old receipt'
out=$(route "$BRIEF") || fail 'instructions could not be resolved again'
check >/dev/null || fail 'a new consultation did not replace the stale receipt'
jq '.created -= 301' "$RECEIPT" > "$TMP_ROOT/old.json"
mv "$TMP_ROOT/old.json" "$RECEIPT"
check >/dev/null 2>&1 && fail 'expired receipt was accepted'
out=$(route "$BRIEF") || fail 'expired receipt could not be refreshed'
cat > "$H/config/model-denylist.json" <<'JSON'
{"never":[{"pattern":"*luna*","reason":"unsupported for this work"}],"rules":["Opus handles judgment."]}
JSON
check >/dev/null 2>&1 && fail 'a changed model policy reused an old receipt'
pass 'receipts reject changed instructions, policy, profile and age'

# An ambiguous rule answer must not skip the second pass when a contender has
# equally ranked models or no rankable provider evidence.
cp "$H/config/crew-dispatch.json" "$TMP_ROOT/before-model-ties.json"
cp "$QUOTA" "$TMP_ROOT/before-model-ties-quota.json"
jq '.rules[0].use = [{harness:"claude",model:"claude-opus-5-5",effort:"medium"},
  {harness:"claude",model:"claude-sonnet-5",effort:"high"}]' "$TMP_ROOT/before-model-ties.json" > "$H/config/crew-dispatch.json"
for evidence in tied unranked; do
  if [ "$evidence" = unranked ]; then printf '{"schemaVersion":5,"providers":[]}\n' > "$QUOTA"; fi
  : > "$CALLS"
  out=$(route "$BRIEF") || fail "$evidence ambiguous contender did not resolve"
  assert_equals 2 "$(jq -s length "$CALLS")" "$evidence contender must make the bounded second Jev call"
  jq -s -e '.[1].state.model_options | length == 2 and any(.[]; .model == "claude-opus-5-5") and any(.[]; .model == "claude-sonnet-5")' "$CALLS" >/dev/null || fail "$evidence second pass did not offer concrete eligible models"
  assert_contains "$out" '  receipt: ' "$evidence undecided second pass still binds the safe default"
done
cp "$TMP_ROOT/before-model-ties.json" "$H/config/crew-dispatch.json"
cp "$TMP_ROOT/before-model-ties-quota.json" "$QUOTA"
pass 'ambiguous rule arrays run the bounded model pass before the default'

# An array with unmeasured candidates asks Jev about the concrete models rather
# than passing an arbitrary eligible option to the launch consumer.
jq '.rules[0].use = [{harness:"claude",model:"claude-opus-5-5",effort:"medium"},{harness:"pi",model:"openai-codex/gpt-6.1-sol",effort:"high",provider:"codex"}] |
  .rules = [.rules[0]]' "$H/config/crew-dispatch.json" > "$TMP_ROOT/rules.json"
mv "$TMP_ROOT/rules.json" "$H/config/crew-dispatch.json"
cp "$QUOTA" "$TMP_ROOT/measured.json"
printf '{"schemaVersion":5,"providers":[]}\n' > "$QUOTA"
out=$(route "$BRIEF") || fail 'unmeasured model array did not resolve safely'
assert_contains "$(jq -sc '.[-1].state.model_options' "$CALLS")" 'gpt-6.1-sol' 'model tie request includes concrete alternatives'
assert_contains "$out" '  receipt: ' 'Jev escalation still binds the configured default exception'
cp "$H/config/crew-dispatch.json" "$TMP_ROOT/two-model-rules.json"
jq '.rules[0].use |= [.[0], (.[0] | .effort = "high"), .[1]]' "$TMP_ROOT/two-model-rules.json" > "$H/config/crew-dispatch.json"
: > "$CALLS"
out=$(route "$BRIEF") || fail 'same-model efforts in an unmeasured array did not resolve safely'
jq -s -e '.[-1].state.model_options | length == 2 and ([.[].model] | sort) == ["claude-opus-5-5","openai-codex/gpt-6.1-sol"] and
  ([.[] | select(.model == "claude-opus-5-5") | .harness] == ["claude"])' "$CALLS" >/dev/null \
  || fail "same-model efforts split the model tie: $(jq -sc '.[-1].state.model_options' "$CALLS")"
cp "$TMP_ROOT/two-model-rules.json" "$H/config/crew-dispatch.json"
pass 'rule-local model ties offer one option per concrete model'
cp "$TMP_ROOT/measured.json" "$QUOTA"

# Fixed-policy consumers use the public resolver, not another picker.
policy() { route "$BRIEF" --decision-kind "$1" --policy-profile "$SELECTED" --policy-reason "$2"; }
policy dispatch arbitrary >/dev/null 2>&1 && fail 'hand-picked dispatch flags became a fixed-policy exception'
for kind in secondmate cross-review no-mistakes; do
  case "$kind" in
    secondmate) reason='configured secondmate seat pin';;
    cross-review) reason='catalog-proven cross-family reviewer chain';;
    no-mistakes) reason='configured no-mistakes native agent/reviewer chain';;
  esac
  out=$(policy "$kind" "$reason") || fail "$kind did not route its existing policy"
  assert_contains "$out" 'exception: deterministic_policy' "$kind records its exception"
  check --kind "$kind" >/dev/null || fail "$kind receipt was not consumable"
done
pass 'seats, cross-family reviewers and native pipeline pins share the resolver'

# Explicit captain overrides are recorded by the same resolver, including
# after a captain-approval rule issued no usable receipt.
cp "$H/config/crew-dispatch.json" "$TMP_ROOT/before-override.json"
why='Explicit per-task model choice authorized for this fixture.'
out=$(route "$BRIEF" --policy-profile "$SELECTED" --captain-override "$why") || fail 'explicit override did not route'
check >/dev/null || fail 'override receipt was not consumable'
RECEIPT=$(awk '/^  receipt: / {sub(/^  receipt: /, ""); print}' <<<"$out")
jq -e --arg why "$why" '.captain_override == true and .exception == "deterministic_policy" and .reason == $why' "$RECEIPT" >/dev/null || fail 'override reason was not recorded'
jq '.rules = [.rules[0]] | .rules[0].approval = "captain"' "$TMP_ROOT/before-override.json" > "$H/config/crew-dispatch.json"
out=$(route "$BRIEF") || fail 'approval rule did not escalate'
assert_contains "$out" '  status: escalate' 'rule waits for captain approval'
assert_not_contains "$out" '  receipt: ' 'approval escalation issues no launch receipt'
check >/dev/null 2>&1 && fail 'old override was reusable after the rule changed'
out=$(route "$BRIEF" --policy-profile "$SELECTED" --captain-override "$why") || fail 'approved escalation could not route'
check >/dev/null || fail 'approved escalation receipt did not bind the profile'
route "$BRIEF" --policy-profile "$SELECTED" --policy-reason 'captain-authorized launch override' >/dev/null 2>&1 && fail 'policy reason forged captain authority without the explicit override path'
route "$BRIEF" --policy-profile '{"harness":"pi","model":"openai-codex/gpt-6-luna","effort":"high"}' --captain-override "$why" >/dev/null 2>&1 && fail 'captain override silently waived a model ban'
cp "$TMP_ROOT/before-override.json" "$H/config/crew-dispatch.json"
pass 'captain overrides and approved escalations carry explicit reason receipts'

# Exercise the executable no-mistakes boundary with an opaque native tool.
# The wrapper never administers a daemon and never changes native argv.
cat > "$F/native-no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = 'axi status' ]; then
  if [ -n "${NATIVE_STATUS:-}" ]; then cat "$NATIVE_STATUS"; else printf 'runs_on_current_branch: 0\n'; fi
  exit 0
fi
printf '%s\n' "$*" >> "$NATIVE_CALLS"
SH
chmod +x "$F/native-no-mistakes"
mkdir -p "$TMP_ROOT/nm" "$TMP_ROOT/repo"
cat > "$TMP_ROOT/nm/config.yaml" <<'YAML'
agent: [claude, pi]
agent_args_override:
  claude: [--model, claude-opus-5-5, --effort, high]
agent_config:
  pi:
    provider: openai-codex
    model: gpt-6.1-sol
    thinking: high
YAML
export NATIVE_CALLS="$TMP_ROOT/native-calls"
native() {
  (cd "$TMP_ROOT/repo" && FM_MODEL_ROUTER_HOME="$H" NM_HOME="$TMP_ROOT/nm" FM_MODEL_ROUTER_BRIEF="$BRIEF" \
    FM_NO_MISTAKES_REAL="$F/native-no-mistakes" "$ROOT/bin/fm-no-mistakes.sh" "$@")
}
native axi status >/dev/null || fail 'status pass-through unexpectedly requires a receipt'
native axi run --intent 'Implement the agreed fix.' >/dev/null || fail 'configured native chain did not route'
assert_equals 1 "$(wc -l < "$NATIVE_CALLS" | tr -d ' ')" 'the real tool sees only the allowed model-changing calls'
native axi run --model openai-codex/gpt-6-luna --intent 'Implement the agreed fix.' >/dev/null 2>&1 && fail 'runtime Pi pin bypassed the ban'
assert_equals 1 "$(wc -l < "$NATIVE_CALLS" | tr -d ' ')" 'banned native pin never reached the tool'
jq -s -e 'any(.[]; .kind == "no-mistakes" and .selected.model == "openai-codex/gpt-6.1-sol" and .selected.effort == "high")' "$H/state/model-route/decisions.jsonl" >/dev/null || fail 'native Pi policy selection lacks a durable receipt'
pass 'runtime native model pins and configured agent chains are routed and ban-checked'

# Repeated executable-boundary trials test fresh receipt consumption, including
# a ban changed after the worker started. These are fixture integration trials,
# not launches of hosted workers or evidence of live model accuracy.
for ((trial=1; trial<=30; trial++)); do
  native axi run --model openai-codex/gpt-6.1-sol --effort high --intent 'Apply the agreed patch.' >/dev/null || fail "native boundary trial $trial"
done
assert_equals 31 "$(wc -l < "$NATIVE_CALLS" | tr -d ' ')" '30 native boundary trials complete without hand-picking'

# A real native immutable pin survives disk edits. A reattach must read that
# exact current-branch profile, not claim the replacement YAML was selected.
git init -q -b profile-trial "$TMP_ROOT/repo"
export NATIVE_STATUS="$TMP_ROOT/native-status"
printf 'run:\n  id: RUNPI\n  branch: profile-trial\n  status: running\n' > "$NATIVE_STATUS"
python3 - "$TMP_ROOT/nm/state.sqlite" <<'PY'
import json, sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('CREATE TABLE runs (id TEXT PRIMARY KEY, branch TEXT, pi_profile TEXT)')
    db.execute('INSERT INTO runs VALUES (?,?,?)', ('RUNPI', 'profile-trial', json.dumps({'model':'openai-codex/gpt-6-luna','effort':'high'})))
PY
native axi run --intent 'Apply the agreed patch.' >/dev/null 2>&1 && fail 'saved immutable banned pin bypassed edited disk config'
assert_equals 31 "$(wc -l < "$NATIVE_CALLS" | tr -d ' ')" 'banned saved pin never reached a model-changing native call'
python3 - "$TMP_ROOT/nm/state.sqlite" <<'PY'
import json, sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('UPDATE runs SET pi_profile = ? WHERE id = ?', (json.dumps({'model':'openai-codex/gpt-6.1-sol','effort':'high'}), 'RUNPI'))
PY
printf 'agent: pi\nagent_config:\n  pi:\n    model: openai-codex/gpt-6-luna\n    effort: high\n' > "$TMP_ROOT/nm/config.yaml"
native axi run --intent 'Apply the agreed patch.' >/dev/null || fail 'edited unused disk config displaced the allowed immutable pin'
assert_equals 32 "$(wc -l < "$NATIVE_CALLS" | tr -d ' ')" 'allowed immutable pin reattaches despite an unused disk-model change'
pass 'reattach checks the saved current-branch model, not replacement config'
jq '.never += [{pattern:"*sol*",reason:"new runtime policy"}]' "$H/config/model-denylist.json" > "$TMP_ROOT/bans.json"
mv "$TMP_ROOT/bans.json" "$H/config/model-denylist.json"
native axi run --model openai-codex/gpt-6.1-sol --intent 'Apply the agreed patch.' >/dev/null 2>&1 && fail 'a mid-run ban change was not enforced'
assert_equals 32 "$(wc -l < "$NATIVE_CALLS" | tr -d ' ')" 'changed ban refuses before native tool invocation'
native axi respond --action fix >/dev/null 2>&1 && fail 'a fix response launched the newly banned saved model'
assert_equals 32 "$(wc -l < "$NATIVE_CALLS" | tr -d ' ')" 'fix responses recheck model bans before launching another agent'
native rerun --skip ci >/dev/null 2>&1 && fail 'legacy rerun arguments bypassed the model ban'
native --skip=ci >/dev/null 2>&1 && fail 'legacy default-run arguments bypassed the model ban'
native >/dev/null 2>&1 && fail 'bare default-run invocation bypassed the model ban'
assert_equals 32 "$(wc -l < "$NATIVE_CALLS" | tr -d ' ')" 'legacy default runs and reruns recheck saved pins'
pass '30 automatic executable-boundary trials; mid-run policy changes stop new model pins and fix responses'
