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

# Blocking is the one response this transport may never give an offer. Claude
# erases a blocked prompt and shows its reason to the captain alone - the model
# is never invoked - so an offer routed here is not a question Claude answers.
# It is a hex control the captain retypes by hand against a request that no
# longer exists. The coordinator resolves ambiguity itself for this adapter, and
# an offer that reaches the transport anyway must still cost nothing.
test_an_offer_never_costs_the_prompt() {
  local lab out
  lab=$(new_lab offer-is-not-a-block)
  FM_TEST_CALLS="$lab/calls"; export FM_TEST_CALLS
  : > "$FM_TEST_CALLS"

  out=$(hook "$lab" 'a substantive synthetic request')
  [ "$(printf '%s' "$out" | jq -r '.decision // empty')" != block ] \
    || fail "an offer blocked the prompt, which the captain alone can ever answer: $out"
  [ "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)" = UserPromptSubmit ] \
    || fail "an offer did not return Claude's context shape: $out"
  assert_contains "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)" \
    'SyntheticWiki' 'the offer never named the wiki it could not resolve'
  pass "claude transport: an unresolved offer continues the prompt instead of erasing it"
}

# The exact host controls remain live for a selection retained before this
# session, so a pending offer on disk is still spendable rather than stranded.
test_exact_controls_still_reach_the_coordinator() {
  local lab out calls
  lab=$(new_lab round-trip)
  FM_TEST_CALLS="$lab/calls"; export FM_TEST_CALLS
  : > "$FM_TEST_CALLS"

  out=$(hook "$lab" 'fm-megamind-select 0123456789abcdef SyntheticWiki')
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
  pass "claude transport: the exact offered and no-wiki controls still reach the coordinator"
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

test_an_offer_never_costs_the_prompt
test_exact_controls_still_reach_the_coordinator
test_inexact_controls_stay_ordinary_prompts
test_only_a_governed_session_can_lose_a_prompt
