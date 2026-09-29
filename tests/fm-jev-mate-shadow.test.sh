#!/usr/bin/env bash
# Public CLI tests for privacy-gated, log-only mate routing and comparison.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TOOL="$ROOT/bin/fm-jev-mate-shadow.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-mate-shadow)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
BASE_PATH=$PATH
mkdir -p "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/state"
REG="$HOME_DIR/data/secondmates.md"
APPROVAL="$HOME_DIR/config/jev-mate-public-scopes.json"
LOG="$HOME_DIR/state/jev-mate-shadow.jsonl"
PAYLOAD="$TMP_ROOT/payload"
RESPONSE="$TMP_ROOT/response"
export FM_MATE_PAYLOAD="$PAYLOAD" FM_MATE_RESPONSE="$RESPONSE"
unset TYPESAFE_API_KEY OPENROUTER_API_KEY JEV_ROUTE JEV_URL JEV_MODEL
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s' "$(</dev/stdin)" >> "$FM_MATE_PAYLOAD"
printf '200'
printf '%s' "$(<"$FM_MATE_RESPONSE")" > "$FM_MATE_PAYLOAD.response"
# fm-jev-lib uses -o to save response, so locate that path from argv.
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    shift
    cp "$FM_MATE_PAYLOAD.response" "$1"
    break
  fi
  shift
done
SH
chmod +x "$FAKEBIN/curl"
printf '%s\n' '- docs - Public guides (home: /safe/docs; scope: Public documentation and reference guides.; projects: ; added 2026-09-01)' '- site - Public website work (home: /safe/site; scope: Public website pages and accessibility.; projects: ; added 2026-09-01)' '- private - Private work (home: /safe/private; scope: The captain'"'"'s private room planning and IchWiki.; projects: ; added 2026-09-01)' > "$REG"
jq -n '{docs:"Public documentation and reference guides.", site:"Public website pages and accessibility.", private:"The captain\u0027s private room planning and IchWiki."}' > "$APPROVAL"
write_answer() { # <choice> <probability> <other probability>
  jq -n --arg choice "$1" --argjson p "$2" --argjson other "$3" \
    '{model:"typesafe/jev-1.13-20260917",answers:{mate:{type:"choice",choice:$choice,probabilities:{docs:$p,site:$other,none:0}}}}' > "$RESPONSE"
}
run_tool() {
  FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$BASE_PATH" TYPESAFE_API_KEY=fixture-key JEV_URL=https://example.invalid/decision \
    /bin/bash "$TOOL" "$@"
}
expect_skipped() { # <task-id> <summary> <reason>
  local task=$1 summary=$2 reason=$3 out
  : > "$PAYLOAD"
  out=$(run_tool suggest "$task" --public-summary "$summary") || fail "skip failed for $task"
  assert_equals skipped "$out" "unsafe input skips"
  [ ! -s "$PAYLOAD" ] || fail "private input reached curl"
  jq -e --arg reason "$reason" '.event=="suggest" and .suggested=="skipped" and .reason==$reason and .probability==null' "$LOG" >/dev/null || fail "skip not logged"
}

# Scopes must match the exact reviewed text; a private scope is never offered.
write_answer docs 0.91 0.09
out=$(run_tool suggest docs-task --public-summary 'Update the public installation guide') || fail 'suggest failed'
assert_equals docs "$out" 'strong choice accepted'
jq -e '.state.task_summary=="Update the public installation guide" and (.state.mate_scopes | has("docs") and has("site") and (has("private") | not)) and (.questions.mate.criteria | has("private") | not) and (has("task_id") | not)' "$PAYLOAD" >/dev/null || fail 'outbound privacy or scope shape violated'
jq -e '.event=="suggest" and .task_id=="docs-task" and .suggested=="docs" and .probability==0.91 and .response_model=="typesafe/jev-1.13-20260917"' "$LOG" >/dev/null || fail 'suggestion not recorded'
pass 'approved scopes only; returned build and probability recorded'

expect_skipped private-task 'Update IchWiki' unsafe_summary
expect_skipped room-task 'The captain'"'"'s private room plan' unsafe_summary
expect_skipped karriere-task 'Edit karriere-wissen' unsafe_summary
expect_skipped firma-task 'Check FirmaPrivat' unsafe_summary
expect_skipped cloud-task 'Vault cloud: nein' unsafe_summary
expect_skipped secret-task 'Publish token=fixture' unsafe_summary
pass 'known private inputs stop before request'

: > "$PAYLOAD"
out=$(FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$BASE_PATH" TYPESAFE_API_KEY='' OPENROUTER_API_KEY='' JEV_URL=https://example.invalid/decision /bin/bash "$TOOL" suggest no-key --public-summary 'Update public guide') || fail 'no key failed'
assert_equals skipped "$out" 'missing key skips quietly'
[ ! -s "$PAYLOAD" ] || fail 'no key reached curl'
pass 'missing key skips'

jq -n '{docs:"Old documentation scope"}' > "$APPROVAL"
expect_skipped stale 'Update public guide' no_eligible_public_scopes
jq -n '{docs:"Public documentation and reference guides.", site:"Public website pages and accessibility."}' > "$APPROVAL"
write_answer docs 0.78 0.22
out=$(run_tool suggest ambiguous --public-summary 'Update public guide') || fail 'ambiguous failed'
assert_equals 'none (abstained)' "$out" 'below floor abstains'
write_answer docs 0.85 0.15
out=$(run_tool suggest boundary --public-summary 'Update public guide') || fail 'boundary failed'
assert_equals docs "$out" 'threshold includes exactly 0.85'
# Set a complete normalized distribution for explicit none.
jq -n '{model:"typesafe/jev-1.13-20260917",answers:{mate:{type:"choice",choice:"none",probabilities:{docs:0.02,site:0.03,none:0.95}}}}' > "$RESPONSE"
out=$(run_tool suggest unrelated --public-summary 'Public task outside documented scopes') || fail 'none failed'
assert_equals none "$out" 'high-confidence none'
run_tool actual docs-task docs || fail 'actual label failed'
run_tool actual ambiguous main || fail 'actual label failed'
run_tool actual unrelated main || fail 'actual label failed'
run_tool actual private-task main || fail 'actual label failed'
summary=$(run_tool compare) || fail 'compare failed'
assert_equals 'labeled=4 matched=1 differed=0 abstained=1 none=1 skipped=1 unlabeled=8' "$summary" 'latest labeled comparison'
[ "$(wc -l < "$LOG" | tr -d ' ')" -eq 16 ] || fail 'expected exactly one event per call'
pass 'abstention and comparison with actual manual routing'

# An incomplete Choice distribution is not trusted, even with a strong winner.
jq -n '{model:"typesafe/jev-1.13-20260917",answers:{mate:{type:"choice",choice:"docs",probabilities:{docs:1}}}}' > "$RESPONSE"
out=$(run_tool suggest malformed --public-summary 'Update public guide') || fail 'malformed response failed'
assert_equals skipped "$out" 'incomplete response skipped'
jq -e 'select(.task_id == "malformed") | .reason == "invalid_response" and .suggested == "skipped"' "$LOG" >/dev/null || fail 'invalid response not logged'
pass 'response must cover every offered option'

rm -f "$APPROVAL"
expect_skipped unapproved 'Update public guide' no_public_scopes
pass 'missing approval skips'
