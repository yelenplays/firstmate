#!/usr/bin/env bash
set -euo pipefail
export FM_HOME="$PWD/.test-scratch/validator-home"
export FM_JEV_REPLAY_DIR="$FM_HOME/cassettes"
export FM_JEV_REPLAY_MISS_LOG="$FM_HOME/misses"
unset TYPESAFE_API_KEY OPENROUTER_API_KEY JEV_MODEL
mkdir -p "$FM_JEV_REPLAY_DIR"
. bin/fm-jev-lib.sh
reject_request() {
  printf '%s\n' "$1" >"$FM_HOME/rejected-request.json"
  return 1
}
allow_request() {
  printf '%s\n' "$1" >"$FM_HOME/allowed-request.json"
}
questions='{"safe":{"type":"noul","instructions":"Are all checks passing?"}}'
rc=0
fm_jev_decide 'All checks passed.' "$questions" --before-send reject_request >"$FM_HOME/out" 2>"$FM_HOME/err" || rc=$?
test "$rc" = 2
test "$FM_JEV_LAST_REQUEST_REJECTED" = 1
test ! -e "$FM_JEV_REPLAY_MISS_LOG"
jq -e '.model == "replay" and .state == "All checks passed." and .questions.safe.type == "noul"' "$FM_HOME/rejected-request.json" >/dev/null
printf 'Rejected replay: exit=%s rejected=%s; validator received complete request; cassette lookup not attempted.\n' "$rc" "$FM_JEV_LAST_REQUEST_REJECTED"
rc=0
fm_jev_decide 'All checks passed.' "$questions" --before-send allow_request >"$FM_HOME/out" 2>"$FM_HOME/err" || rc=$?
test "$rc" = 1
test -z "$FM_JEV_LAST_REQUEST_REJECTED"
test -s "$FM_JEV_REPLAY_MISS_LOG"
printf 'Allowed replay without cassette: exit=%s rejected marker cleared; replay miss recorded.\n' "$rc"
payload=$(jq -nc --arg state 'All checks passed.' --argjson questions "$questions" '{state:$state,questions:$questions}')
key=$(_fm_jev_cassette_key "$payload")
printf '{"model":"jev-1.13.0","response":{"model":"jev-1.13.0","answers":{"safe":{"noul":0.99}}}}\n' >"$FM_JEV_REPLAY_DIR/$key.json"
fm_jev_decide 'All checks passed.' "$questions" --before-send allow_request >"$FM_HOME/out"
jq -e '.answers.safe.noul == 0.99' "$FM_HOME/out" >/dev/null
printf 'Allowed replay with cassette: exit=0; answer='
jq -c . "$FM_HOME/out"
rc=0
fm_jev_decide 'All checks passed.' "$questions" --before-send reject_request >"$FM_HOME/out" 2>"$FM_HOME/err" || rc=$?
test "$rc" = 2
test "$FM_JEV_LAST_REQUEST_REJECTED" = 1
test ! -s "$FM_HOME/out"
printf 'Existing cassette cannot bypass validator: exit=%s rejected=%s, no response emitted.\n' "$rc" "$FM_JEV_LAST_REQUEST_REJECTED"
