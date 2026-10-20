#!/usr/bin/env bash
# Live guard for the captain-rules Claude registrations (docs/captain-rules.md):
# a real Claude session in a fixture primary checkout that carries only this
# repo's tracked fm-rules.sh and fm-rule-guard.sh entries must (1) answer from a
# rule only its SessionStart block delivered, (2) act on the candidate the
# UserPromptSubmit hook injected, and (3) be blocked by the Stop guard when it
# hands the captain a "! sudo" line. The hooks read vendor payloads and emit
# vendor context, so only the real harness can prove them. Opt-in because it
# submits prompts:
#
#   FM_RULES_LIVE_E2E=1 tests/fm-rules-live-e2e.test.sh
#
# FM_RULES_LIVE_MODEL (default haiku) picks the model.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_RULES_LIVE_E2E jq claude

MODEL=${FM_RULES_LIVE_MODEL:-haiku}
LAB=$(fm_test_tmproot fm-rules-live)
VERSION=$(claude --version 2>/dev/null | head -n 1)
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_TASK_ID FM_SUPERVISION_ACTOR \
  FM_MEMORY_CAPTURE_CHILD NO_MISTAKES_GATE

# A primary checkout carrying only the tracked captain-rules registrations, so
# no other hook of this repo runs in it.
ROOT_LAB="$LAB/primary"
mkdir -p "$ROOT_LAB/state" "$ROOT_LAB/config" "$ROOT_LAB/.claude"
git init -q "$ROOT_LAB"
: > "$ROOT_LAB/AGENTS.md"
ln -s "$ROOT/bin" "$ROOT_LAB/bin"
jq '.hooks |= (with_entries(.value |= (map(.hooks |= map(select(.command | test("fm-rules.sh|fm-rule-guard.sh")))) | map(select(.hooks | length > 0)))) | with_entries(select(.value | length > 0))) | {hooks}' \
  "$ROOT/.claude/settings.json" > "$ROOT_LAB/.claude/settings.json"
[ "$(jq '[.hooks[][].hooks[]] | length' "$ROOT_LAB/.claude/settings.json")" = 3 ] \
  || fail "expected the three tracked captain-rules registrations, got: $(cat "$ROOT_LAB/.claude/settings.json")"
FM_HOME="$ROOT_LAB" "$ROOT_LAB/bin/fm-rules.sh" add codeword \
  'When the captain asks for the codeword, answer with exactly the word quartz-lantern.' >/dev/null \
  || fail 'seeding the codeword rule failed'

ask() {  # <prompt> -> final reply text
  (cd "$ROOT_LAB" && env -u CLAUDECODE claude -p --model "$MODEL" --dangerously-skip-permissions \
    --output-format json "$1" </dev/null 2>"$LAB/claude.err") | jq -r '.result // empty'
}

out=$(ask 'What is the codeword? Reply with only the codeword.')
assert_contains "$out" 'quartz-lantern' "claude $VERSION: the SessionStart rules block did not reach the model (reply: $out)"
printf 'ok - claude %s: the SessionStart hook loaded the captain rules into context\n' "$VERSION"

out=$(ask 'Ab jetzt nie wieder lange Antworten. Follow any captain-rule instruction you were given, then reply with exactly the word noted.')
[ -s "$ROOT_LAB/state/captain-rules/log.jsonl" ] || fail "claude $VERSION: the prompt hook logged nothing"
jq -e 'select(.event == "candidate")' "$ROOT_LAB/state/captain-rules/log.jsonl" >/dev/null \
  || fail "claude $VERSION: the prompt hook raised no candidate"
jq -e 'select(.event == "confirm" or .event == "dismiss")' "$ROOT_LAB/state/captain-rules/log.jsonl" >/dev/null \
  || fail "claude $VERSION: the model never acted on the injected candidate (reply: $out; log: $(cat "$ROOT_LAB/state/captain-rules/log.jsonl"))"
printf 'ok - claude %s: the UserPromptSubmit hook injected a candidate the model confirmed or dismissed\n' "$VERSION"

out=$(ask 'Reply with exactly these two lines and nothing else. Line one: Run this in your session: Line two: ! sudo darwin-rebuild switch')
jq -e 'select(.event == "guard-block" and .check == "bang-interactive")' "$ROOT_LAB/state/captain-rules/log.jsonl" >/dev/null \
  || fail "claude $VERSION: the Stop guard never blocked the handed-over sudo line (reply: $out)"
if printf '%s\n' "$out" | "$ROOT/bin/fm-rule-guard.sh" scan >/dev/null; then
  printf 'ok - claude %s: the Stop guard blocked the "! sudo" reply and the model rewrote it\n' "$VERSION"
else
  jq -e 'select(.event == "guard-release")' "$ROOT_LAB/state/captain-rules/log.jsonl" >/dev/null \
    || fail "claude $VERSION: a violating reply got through without a logged release (reply: $out)"
  printf 'ok - claude %s: the Stop guard blocked the "! sudo" reply and released the forced repeat\n' "$VERSION"
fi
pass "captain rules live: claude $VERSION proved the SessionStart, UserPromptSubmit, and Stop registrations"
