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
 jq -nc --argjson body "$body" --argjson lead "${PICK_LEAD:-0.51}" '
   ($body.questions.pick.criteria | keys) as $keys |
   {model:"jev-1.13.0",answers:{pick:{type:"choice",choice:$keys[0],confidence:$lead,
     probabilities:($keys | to_entries | map({key:.value,value:(if .key == 0 then $lead else (1 - $lead) / (($keys | length) - 1) end)}) | from_entries)}}}' > "$out"
elif [ -n "${RULE_ANSWER:-}" ]; then
 printf '%s\n' "$RULE_ANSWER" > "$out"
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

record_of() { awk '/^  receipt: / {sub(/^  receipt: /, ""); print}' <<<"$1"; }
SELECTED='{"harness":"claude","model":"claude-opus-5-5","effort":"medium"}'
jq -e --argjson s "$SELECTED" '.kind == "dispatch" and .selected == $s and .selected_rule == "rule_1" and .exception == null and .consultation.model == "jev-1.13.0"' \
  "$(record_of "$out")" >/dev/null || fail 'dispatch record did not capture the selected profile and Jev consultation'
cat > "$H/config/model-denylist.json" <<'JSON'
{"never":[{"pattern":"*luna*","reason":"unsupported for this work"}],"rules":["Opus handles judgment."]}
JSON
pass 'a dispatch record captures the selected profile and its Jev consultation'

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
out=$(policy cross-review 'catalog-proven cross-family reviewer chain') || fail 'cross-review did not route its reviewer chain'
assert_contains "$out" 'exception: deterministic_policy' 'cross-review records its exception'
jq -e --argjson s "$SELECTED" '.kind == "cross-review" and .selected == $s' "$(record_of "$out")" >/dev/null || fail 'cross-review record did not capture its profile'
pass 'the public resolver accepts and records the cross-review reviewer chain'

# Explicit captain overrides are recorded by the same resolver, including
# after a captain-approval rule issued no usable receipt.
cp "$H/config/crew-dispatch.json" "$TMP_ROOT/before-override.json"
why='Explicit per-task model choice authorized for this fixture.'
out=$(route "$BRIEF" --policy-profile "$SELECTED" --captain-override "$why") || fail 'explicit override did not route'
jq -e --arg why "$why" --argjson s "$SELECTED" '.captain_override == true and .exception == "deterministic_policy" and .reason == $why and .selected == $s and .selected_rule == null' \
  "$(record_of "$out")" >/dev/null || fail 'override reason was not recorded'
jq '.rules = [.rules[0]] | .rules[0].approval = "captain"' "$TMP_ROOT/before-override.json" > "$H/config/crew-dispatch.json"
out=$(route "$BRIEF") || fail 'approval rule did not escalate'
assert_contains "$out" '  status: escalate' 'rule waits for captain approval'
assert_not_contains "$out" '  receipt: ' 'approval escalation issues no launch receipt'
out=$(route "$BRIEF" --policy-profile "$SELECTED" --captain-override "$why") || fail 'approved escalation could not route'
jq -e --argjson s "$SELECTED" '.captain_override == true and .selected == $s' "$(record_of "$out")" >/dev/null || fail 'approved escalation did not record the profile'
route "$BRIEF" --policy-profile "$SELECTED" --policy-reason 'captain-authorized launch override' >/dev/null 2>&1 && fail 'policy reason forged captain authority without the explicit override path'
route "$BRIEF" --policy-profile '{"harness":"pi","model":"openai-codex/gpt-6-luna","effort":"high"}' --captain-override "$why" >/dev/null 2>&1 && fail 'captain override silently waived a model ban'
cp "$TMP_ROOT/before-override.json" "$H/config/crew-dispatch.json"
pass 'captain overrides and approved escalations record their explicit reason'

# Consultation records are optional evidence, never a model-choice prerequisite.
cp "$H/config/crew-dispatch.json" "$TMP_ROOT/before-fallback-tie.json"
cat > "$H/config/crew-dispatch.json" <<'JSON'
{"rules":[
 {"when":"Contained implementation work.","min_confidence":0.8,"use":{"harness":"claude","model":"claude-opus-5-5","effort":"medium"}},
 {"when":"Complex implementation work.","use":[{"harness":"claude","model":"claude-opus-5-5","effort":"medium"},{"harness":"pi","model":"openai-codex/gpt-6.1-sol","effort":"high","provider":"codex"}]}
],"default":{"harness":"claude","model":"claude-opus-5-5","effort":"medium"}}
JSON
printf '{"schemaVersion":5,"providers":[]}\n' > "$QUOTA"
: > "$CALLS"
out=$(RULE_ANSWER='{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.3,"probabilities":{"rule_1":0.3,"rule_2":0.65,"default":0.05}}}}' \
  PICK_LEAD=0.9 route "$BRIEF") || fail "a floor fallback with a model tie did not resolve: $out"
jq -s -e '.[-1].questions.pick.criteria | length == 2 and all(.[]; . == "Complex implementation work.")' "$CALLS" >/dev/null \
  || fail "model-tie options were worded with the rejected rule: $(jq -sc '.[-1].questions.pick.criteria' "$CALLS")"
assert_contains "$out" '  decided: rule_2 by typed' 'the settled fallback rule decides the model tie'
assert_not_contains "$out" '  matched: ' 'a model tie inside the settled rule claims no other matched rule'
tail -n 1 "$H/state/dispatch-resolve.jsonl" | jq -e '.rule == "rule_2" and .matched_rule == null' >/dev/null \
  || fail 'the dispatch log misattributed the model tie'
cp "$TMP_ROOT/before-fallback-tie.json" "$H/config/crew-dispatch.json"
cp "$TMP_ROOT/measured.json" "$QUOTA"
pass 'model ties after a confidence fallback belong to the settled rule'

printf '%s\n' '{"status":"ok","median":"broken"}' > "$TMP_ROOT/broken-ledger"
cat > "$F/broken-ledger" <<SH
cat "$TMP_ROOT/broken-ledger"
SH
chmod +x "$F/broken-ledger"
out=$(PATH="$F:$PATH" FM_HOME="$H" TYPESAFE_API_KEY=test-route-key FM_SPEND_LEDGER="$F/broken-ledger" "$ROOT/bin/fm-dispatch-resolve.sh" "$BRIEF" 2>/dev/null)
code=$?
assert_equals 3 "$code" 'a full-chain internal failure authorizes no launch'
assert_contains "$out" '  status: error' 'the internal failure is reported'
assert_not_contains "$out" '  profile: ' 'an internal failure prints no profile'
pass 'full-chain internal failures exit 3 without a profile'

cp "$H/config/crew-dispatch.json" "$TMP_ROOT/before-default-only.json"
jq '.rules = []' "$TMP_ROOT/before-default-only.json" > "$H/config/crew-dispatch.json"
out=$(route "$BRIEF" 2>&1) || fail "a default-only rules file did not resolve: $out"
assert_not_contains "$out" 'record unavailable' 'a default-only selection still writes its record'
jq -e '.exception == "deterministic_policy" and .selected.model == "claude-opus-5-5"' "$(record_of "$out")" >/dev/null \
  || fail 'the default-only record did not capture its deterministic policy'
cp "$TMP_ROOT/before-default-only.json" "$H/config/crew-dispatch.json"
pass 'a default-only rules file records its deterministic policy'

mv "$H/state/model-route" "$TMP_ROOT/saved-records"
printf 'records unavailable\n' > "$H/state/model-route"
out=$(route "$BRIEF") || fail 'unwritable records blocked core routing'
assert_contains "$out" '  profile: ' 'a concrete Jev/default choice survives unavailable records'
assert_not_contains "$out" '  receipt: ' 'unavailable records must not claim a saved receipt'
out=$(route "$BRIEF" --policy-profile "$SELECTED" --captain-override "$why") || fail 'unwritable records blocked a captain override'
assert_contains "$out" "--model 'claude-opus-5-5'" 'record failure preserves the explicit override model'
pass 'unavailable records never block the routing result or captain override'

write_receipt() {  # <selected-rule-json>
  jq -nc --argjson rule "$1" --argjson s "$SELECTED" \
    '{selected:$s, selected_rule:$rule, consultation:{model:"jev-1.13.0",answer:{}}, options_hash:("a" * 64), exception:"jev_escalation", reason:"fixture"}' |
    "$ROOT/bin/fm-model-route-receipt.py" write --home "$TMP_ROOT/receipt-home" --brief "$BRIEF" --config "$H/config" 2>/dev/null
}
record=$(write_receipt '"rule_2"') || fail 'a receipt with a named selected rule was refused'
assert_equals rule_2 "$(jq -r .selected_rule "$record")" 'a receipt keeps the selected rule it was given'
for bad in '""' '7'; do
  write_receipt "$bad" >/dev/null && fail "a receipt accepted selected_rule $bad"
done
pass 'a receipt keeps a named selected rule and refuses an empty or non-string one'
