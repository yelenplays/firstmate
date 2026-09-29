#!/usr/bin/env bash
# Behavioral regression for metadata-only wiki PR advisories.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TOOL="$ROOT/bin/fm-jev-pr-verdict.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-pr-verdict)
HOME_DIR="$TMP_ROOT/home"
WIKI="$TMP_ROOT/wikis"
BIN="$TMP_ROOT/bin"
mkdir -p "$HOME_DIR/state" "$WIKI/routing/cards" "$BIN"
cat > "$WIKI/routing/cards/share.yaml" <<'CARD'
repo: yelen-wikis/FehlerWiki
share_tier: team
share_gate: rein
cloud: ja
modus: voll
CARD
cat > "$BIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_FORGE_LOG"
case "$2" in
  */pulls/7)
    if [ "${4:-}" = '.head.sha' ]; then
      body="${TEST_AFTER_HEAD:-0123456789abcdef0123456789abcdef01234567}"
    else
      body="open|false|0123456789abcdef0123456789abcdef01234567|main"
    fi
    ;;
  */files\?*) body="${TEST_FILES:-2|false|false|true|false}" ;;
  */check-runs\?*) body="${TEST_CHECKS:-2|0|0}" ;;
  *) exit 1 ;;
esac
printf 'api_response:\n  body: %s\n  truncated: false\n' "$body"
SH
cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
out=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac
done
cat > "$TEST_JEV_REQUEST"
if [ -n "${TEST_JEV_RESPONSE:-}" ]; then
  printf '%s' "$TEST_JEV_RESPONSE" > "$out"
else
  printf '%s' '{"model":"jev-1.13.0","answers":{"advisory":{"type":"choice","choice":"pass","probabilities":{"pass":0.8,"concerns":0.2}}}}' > "$out"
fi
printf 200
SH
chmod +x "$BIN/gh-axi" "$BIN/curl"
export FM_HOME="$HOME_DIR" FM_WIKI_ROOT="$WIKI" TEST_FORGE_LOG="$TMP_ROOT/forge.log" TEST_JEV_REQUEST="$TMP_ROOT/request.json"
URL=https://github.com/yelen-wikis/FehlerWiki/pull/7
run_case() { PATH="$BIN:$PATH" bash "$TOOL" "$1"; }

unset TYPESAFE_API_KEY OPENROUTER_API_KEY TEST_FILES TEST_CHECKS TEST_JEV_RESPONSE
out=$(run_case "$URL") || fail 'no-key advisory failed'
[ -z "$out" ] && [ ! -e "$TEST_FORGE_LOG" ] || fail 'no key must skip before the forge'
pass 'no-key skip is silent and local'

export TYPESAFE_API_KEY=testing-only
out=$(run_case https://github.com/yelen-wikis/PrivateWiki/pull/7) || fail 'unlisted repo failed'
[ -z "$out" ] && [ ! -e "$TEST_FORGE_LOG" ] || fail 'unlisted vault must skip before the forge'
printf 'share_gate: gemischt-verboten\n' >> "$WIKI/routing/cards/share.yaml"
out=$(run_case "$URL") || fail 'ambiguous card failed'
[ -z "$out" ] && [ ! -e "$TEST_FORGE_LOG" ] || fail 'unsafe card must skip before the forge'
# Restore the one eligible card.
printf 'repo: yelen-wikis/FehlerWiki\nshare_tier: team\nshare_gate: rein\ncloud: ja\nmodus: voll\n' > "$WIKI/routing/cards/share.yaml"

out=$(run_case "$URL") || fail 'eligible advisory failed'
case "$out" in *"$URL: pass (p=0.8)"*'private-page content and required checks not certified'*'Human merge decision required.'*) ;; *) fail "missing advisory: $out" ;; esac
jq -e '.state.tier == "team" and .state.changed_file_count == 2 and .state.prose_path_category == true and (.state | has("repo") | not)' "$TEST_JEV_REQUEST" >/dev/null || fail 'unsafe Jev state'
if jq -c '.state' "$TEST_JEV_REQUEST" | grep -Eq 'FehlerWiki|github|/pull/|private-page|0123456789abcdef'; then fail 'PR identity or private prose leaked into Jev state'; fi
jq -e '.verdict == "pass" and .merge_authority == false and .probability == 0.8' "$HOME_DIR/state/jev-pr-verdict.jsonl" >/dev/null || fail 'advisory was not recorded'
pass 'carded PR receives probability and reasons with metadata-only state'

export TEST_FILES='2|true|false|true|false'
out=$(run_case "$URL") || fail 'restricted-path advisory failed'
case "$out" in *'concerns (local rule; Jev pass p=0.8); restricted path category;'*) ;; *) fail 'deterministic restriction did not override model pass'; esac
jq -e '.verdict == "concerns" and .probability == null and .jev_choice == "pass" and .jev_probability == 0.8 and .deterministic_override == true' "$HOME_DIR/state/jev-pr-verdict.jsonl" >/dev/null || fail 'override must not mislabel model probability'
jq -e '.state.restricted_path_category == true' "$TEST_JEV_REQUEST" >/dev/null || fail 'restricted category not represented'
pass 'restricted path never becomes advisory pass even if Jev picks pass'

export TEST_CHECKS='0|0|0'
out=$(run_case "$URL") || fail 'no-check advisory failed'
case "$out" in *'concerns (local rule; Jev pass p=0.8); restricted path category; no reported checks;'*) ;; *) fail 'missing checks did not force concerns'; esac
pass 'missing checks remain concerns'

export TEST_FILES='2|false|false|true|false' TEST_CHECKS='2|0|0'
export TEST_JEV_RESPONSE='{"model":"jev-1.13.0","answers":{"advisory":{"type":"choice","choice":"concerns","probabilities":{"pass":0.3,"concerns":0.7}}}}'
out=$(run_case "$URL") || fail 'model concern failed'
case "$out" in *'concerns (p=0.7); Jev flagged a metadata concern not explained by the bounded facts;'*) ;; *) fail 'unexplained concern lacks a truthful reason'; esac
export TEST_JEV_RESPONSE='{"answers":{"advisory":{"type":"choice","choice":"pass","probabilities":{"pass":0.9,"concerns":0.9}}}}'
out=$(run_case "$URL") || fail 'invalid response failed'
[ -z "$out" ] || fail 'invalid distribution must produce no advisory'
unset TEST_JEV_RESPONSE
pass 'model concerns are attributed and invalid distributions skip'

export TEST_AFTER_HEAD='abcdef0123456789abcdef0123456789abcdef01'
: > "$TEST_JEV_REQUEST"
out=$(run_case "$URL") || fail 'changed-head skip failed'
[ -z "$out" ] && [ ! -s "$TEST_JEV_REQUEST" ] || fail 'mixed heads must not reach Jev'
unset TEST_AFTER_HEAD
pass 'a head change during metadata collection skips the advisory'

export TEST_FILES='100|false|false|true|false'
: > "$TEST_JEV_REQUEST"
out=$(run_case "$URL") || fail 'large PR skip failed'
[ -z "$out" ] && [ ! -s "$TEST_JEV_REQUEST" ] || fail 'unbounded PR must not call Jev'
pass 'oversized file listing skips instead of assessing partial evidence'

rm -rf "$TMP_ROOT"
