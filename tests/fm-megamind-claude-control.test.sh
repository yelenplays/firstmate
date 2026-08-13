#!/usr/bin/env bash
# Portable proof for the Claude UserPromptSubmit transport's offer control.
# The transport is only reachable through Claude's hook payload, so this drives
# the real hook over stdin/stdout and never inspects its source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
HOOK="$ROOT/bin/fm-claude-primary-prompt.sh"
TMP_ROOT=$(fm_test_tmproot fm-megamind-claude-control)

# The hook resolves its coordinator under CLAUDE_PROJECT_DIR, so a lab supplies a
# synthetic one: no wiki is read and no provider turn is ever started.
new_lab() {
  local lab="$TMP_ROOT/$1"
  mkdir -p "$lab/bin"
  cat > "$lab/bin/fm-megamind-primary.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_CALLS:?}"
if [ "${1:-}" = continue ]; then
  printf '%s\n' '{"decision":"proceed-with-admission","context":{"text":"synthetic admitted context"},"replay_prompt":"the original request"}'
elif [ "${1:-}" = continue-no-context ]; then
  printf '%s\n' '{"decision":"proceed-no-context","context":null,"admitted_chars":0,"replay_prompt":"the original request without wiki evidence"}'
else
  printf '%s\n' '{"decision":"offer","selection_id":"0123456789abcdef","offers":[{"wiki":"SyntheticWiki"}]}'
fi
SH
  chmod 700 "$lab/bin/fm-megamind-primary.sh"
  printf '%s\n' "$lab"
}

hook() {
  local lab=$1 prompt=$2
  jq -cn --arg p "$prompt" '{prompt:$p,session_id:"session-synthetic"}' \
    | CLAUDE_PROJECT_DIR="$lab" "$HOOK"
}

# An ambiguous preflight is only usable if the control the block advertises is
# one the captain can actually send. Claude resolves a leading-slash prompt as
# one of its own commands and answers "Unknown command" before any
# UserPromptSubmit hook runs, so a slash-prefixed control would dead-end every
# offer: the hook that owns the selection would never be executed at all.
test_offer_control_is_sendable_and_round_trips() {
  local lab out reason control replay calls
  lab=$(new_lab round-trip)
  FM_TEST_CALLS="$lab/calls"; export FM_TEST_CALLS
  : > "$FM_TEST_CALLS"

  out=$(hook "$lab" 'a substantive synthetic request')
  [ "$(printf '%s' "$out" | jq -r .decision)" = block ] \
    || fail "an ambiguous offer did not block the prompt: $out"
  reason=$(printf '%s' "$out" | jq -r .reason)
  assert_contains "$reason" 'SyntheticWiki' 'the offer block never named the offered wiki'
  assert_not_contains "$reason" '/fm-megamind-select' \
    'the offer block advertised a Claude slash command, which is consumed as an unknown command before this hook runs'
  assert_contains "$reason" 'fm-megamind-none 0123456789abcdef' \
    'the Claude offer block did not expose the shared no-wiki disposition'

  # Recover the advertised control from the block the captain actually reads,
  # then send it back verbatim. Nothing but this public text is trusted.
  control=$(printf '%s' "$reason" | grep -Eo '[^[:space:]]*fm-megamind-select [0-9A-Fa-f]{16,128} <offer>') \
    || fail "the offer block advertised no recoverable host control: $reason"
  replay=${control/<offer>/SyntheticWiki}

  out=$(hook "$lab" "$replay")
  calls=$(tail -n 1 "$FM_TEST_CALLS")
  assert_contains "$calls" 'continue --harness claude' \
    "the advertised control did not reach the coordinator's selection path: $calls"
  assert_contains "$calls" '--selection-id 0123456789abcdef --offer SyntheticWiki' \
    "the control did not carry the offered selection verbatim: $calls"
  [ "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)" = UserPromptSubmit ] \
    || fail "a completed selection did not return Claude's context shape: $out"
  assert_contains "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)" \
    'synthetic admitted context' 'the admitted context was not injected after selection'

  out=$(hook "$lab" 'fm-megamind-none 0123456789abcdef')
  calls=$(tail -n 1 "$FM_TEST_CALLS")
  assert_contains "$calls" 'continue-no-context --harness claude' \
    "the advertised no-wiki control did not reach the coordinator: $calls"
  assert_contains "$calls" '--selection-id 0123456789abcdef --include-replay' \
    "the no-wiki control did not request the exact private replay: $calls"
  [ "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)" = UserPromptSubmit ] \
    || fail "the no-wiki control did not return Claude's context shape: $out"
  assert_contains "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)" \
    'the original request without wiki evidence' 'the no-wiki control did not replay the original request'
  pass "claude transport: offered and no-wiki controls are sendable and reach the coordinator"
}

# The control is an exact host transport, not a free-form consent phrase: an
# approximation must stay ordinary traffic rather than authorize a wiki.
test_inexact_controls_stay_ordinary_prompts() {
  local lab calls prompt
  lab=$(new_lab inexact)
  FM_TEST_CALLS="$lab/calls"; export FM_TEST_CALLS
  for prompt in \
    'fm-megamind-select 0123456789abcdef' \
    'fm-megamind-select nothex0123456789 SyntheticWiki' \
    'please fm-megamind-select 0123456789abcdef SyntheticWiki' \
    'fm-megamind-select 0123456789abcdef SyntheticWiki now please' \
    'fm-megamind-none' \
    'please fm-megamind-none 0123456789abcdef' \
    'fm-megamind-none 0123456789abcdef now'; do
    : > "$FM_TEST_CALLS"
    hook "$lab" "$prompt" >/dev/null
    calls=$(tail -n 1 "$FM_TEST_CALLS")
    assert_not_contains "$calls" continue "an inexact control authorized a selection: $prompt"
    assert_contains "$calls" 'process --harness claude' \
      "an inexact control was not classified as an ordinary prompt: $prompt"
  done
  pass "claude transport: only the exact host control authorizes an offer"
}

# The hook is registered unconditionally while automatic primary mode is opt-in,
# so a transport precondition failure must not cost a session that never opted in
# the prompt it was never asked to govern. The coordinator owns that eligibility
# and the transport must honor it before it may block anything.
test_only_a_governed_session_can_lose_a_prompt() {
  local lab out rc
  lab="$TMP_ROOT/governance"
  mkdir -p "$lab/bin"
  write_coordinator() {  # <governed exit status>
    cat > "$lab/bin/fm-megamind-primary.sh" <<SH
#!/usr/bin/env bash
set -u
[ "\${1:-}" = governed ] && exit $1
exit 3
SH
    chmod 700 "$lab/bin/fm-megamind-primary.sh"
  }

  write_coordinator 1
  out=$(jq -cn '{prompt:"a substantive synthetic request",session_id:"session-synthetic"}' \
    | CLAUDE_PROJECT_DIR="$lab" "$HOOK" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "an ungoverned session lost its prompt to a transport failure (exit $rc): $out"
  [ -z "$out" ] || fail "an ungoverned session was not left alone: $out"

  write_coordinator 0
  out=$(jq -cn '{prompt:"a substantive synthetic request",session_id:"session-synthetic"}' \
    | CLAUDE_PROJECT_DIR="$lab" "$HOOK" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "a governed transport failure did not block the prompt (exit $rc): $out"
  assert_contains "$out" 'Firstmate' 'a governed block disclosed no reason on stderr'
  pass "claude transport: only a governed session can lose a prompt to a transport failure"
}

test_offer_control_is_sendable_and_round_trips
test_inexact_controls_stay_ordinary_prompts
test_only_a_governed_session_can_lose_a_prompt
