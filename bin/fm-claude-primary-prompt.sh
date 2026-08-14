#!/usr/bin/env bash
# Claude UserPromptSubmit transport for the host-owned Megamind coordinator.
# The hook reads Claude's private JSON payload and emits only Claude's response
# shape; it never classifies, parses, reads wiki files, or runs a follow-up.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="${CLAUDE_PROJECT_DIR:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}}"
COORDINATOR="$ROOT/bin/fm-megamind-primary.sh"

# This hook is registered unconditionally, but automatic primary mode is opt-in
# and the coordinator owns that eligibility. A session that never opted in must
# cost nothing and must not lose a prompt to an unrelated condition here, so the
# coordinator is asked first - by exit status, with no jq and no payload, so the
# answer never depends on the tooling that just failed. A home whose coordinator
# cannot even run is by definition governing nothing.
governed_session() {
  [ -x "$COORDINATOR" ] || return 1
  FM_HOME="${FM_HOME:-$ROOT}" "$COORDINATOR" governed --harness claude >/dev/null 2>&1
}

# Exit 2 is Claude's block code and shows only stderr, so every transport
# failure in a governed session names itself there. A prompt that disappears
# without a reason is indistinguishable from a broken editor; a disclosed
# blocker is not.
refuse() {
  governed_session || exit 0
  printf 'Firstmate: %s. The prompt was not sent; no provider turn was started.\n' "$1" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || refuse 'jq is required by the Megamind prompt hook and was not found on PATH'
[ -x "$COORDINATOR" ] || exit 0
payload=$(cat) || refuse 'the hook payload could not be read'
prompt=$(printf '%s' "$payload" | jq -r '(.prompt // .user_prompt // empty) | if type == "string" then . else empty end' 2>/dev/null) || refuse 'the hook payload could not be parsed'
session=$(printf '%s' "$payload" | jq -r '(.session_id // .sessionId // empty) | if type == "string" then . else empty end' 2>/dev/null) || refuse 'the hook payload could not be parsed'
[ -n "$prompt" ] || exit 0

# An exact host control is consumed here rather than classified. It carries no
# leading slash on purpose: Claude resolves a leading-slash prompt as one of its
# own commands and answers "Unknown command" without ever running this hook, so
# a slash-prefixed control would dead-end every ambiguous offer. The offer is
# passed as one opaque transport value; free-form consent never reaches the model.
if printf '%s' "$prompt" | jq -eR 'test("^fm-megamind-select [0-9A-Fa-f]{16,128} [^[:space:]]+$")' >/dev/null 2>&1; then
  selection=$(printf '%s' "$prompt" | sed -E 's#^fm-megamind-select ([0-9A-Fa-f]{16,128}) [^[:space:]]+$#\1#')
  offer=$(printf '%s' "$prompt" | sed -E 's#^fm-megamind-select [0-9A-Fa-f]{16,128} ([^[:space:]]+)$#\1#')
  result=$(FM_HOME="${FM_HOME:-$ROOT}" "$COORDINATOR" continue --harness claude --session-id "$session" \
    --selection-id "$selection" --offer "$offer" --include-replay 2>/dev/null) \
    || refuse 'the Megamind coordinator could not complete this offer selection'
elif printf '%s' "$prompt" | jq -eR 'test("^fm-megamind-none [0-9A-Fa-f]{16,128}$")' >/dev/null 2>&1; then
  selection=${prompt#fm-megamind-none }
  result=$(FM_HOME="${FM_HOME:-$ROOT}" "$COORDINATOR" continue-no-context --harness claude \
    --session-id "$session" --selection-id "$selection" --include-replay 2>/dev/null) \
    || refuse 'the Megamind coordinator could not continue without wiki evidence'
else
  submission="p$(date +%s).$$.$RANDOM"
  result=$(printf '%s' "$prompt" | FM_HOME="${FM_HOME:-$ROOT}" "$COORDINATOR" process --harness claude \
    --session-id "$session" --submission-id "$submission" 2>/dev/null) \
    || refuse 'the Megamind coordinator could not complete this preflight'
fi

decision=$(printf '%s' "$result" | jq -r '.decision // empty' 2>/dev/null) \
  || refuse 'the Megamind coordinator returned output this hook could not parse'
case "$decision" in
  bypass) exit 0 ;;
  proceed-no-context)
    replay=$(printf '%s' "$result" | jq -r '.replay_prompt // empty' 2>/dev/null) \
      || refuse 'the no-wiki replay prompt could not be read from the coordinator result'
    [ -n "$replay" ] || exit 0
    jq -cn --arg replay "$replay" \
      '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:("Firstmate continued without wiki evidence. Resume this exact original request once:\n" + $replay)}}'
    ;;
  proceed-with-admission)
    context=$(printf '%s' "$result" | jq -r '.context.text // empty' 2>/dev/null) \
      || refuse 'the admitted wiki context could not be read from the coordinator result'
    replay=$(printf '%s' "$result" | jq -r '.replay_prompt // empty' 2>/dev/null) \
      || refuse 'the replay prompt could not be read from the coordinator result'
    if [ -n "$replay" ]; then
      context="$context"$'\n\n'"Firstmate selected the requested wiki offer. Resume this exact original request once:"$'\n'"$replay"
    fi
    jq -cn --arg context "$context" \
      '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$context}}'
    ;;
  offer)
    # The coordinator resolves ambiguity itself for this adapter, so an offer
    # should never arrive here. If one ever does, it must not cost the prompt.
    # Blocking is the one response this transport cannot safely give a choice:
    # a blocked UserPromptSubmit erases the prompt and shows its reason to the
    # captain alone, never to the model, so the "choice" is a hex control typed
    # by hand against a request that no longer exists. Continue without wiki
    # evidence and say so instead.
    offers=$(printf '%s' "$result" | jq -r '[.offers[]?.wiki] | join(", ")' 2>/dev/null || printf 'the listed offer')
    jq -cn --arg offers "$offers" \
      '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:("Firstmate could not resolve a single wiki for this request (" + $offers + ") and continued without wiki evidence. No wiki content was loaded.")}}'
    ;;
  block)
    code=$(printf '%s' "$result" | jq -r '.failure_code // "preflight_failed"' 2>/dev/null || printf 'preflight_failed')
    jq -cn --arg reason "Firstmate preflight stopped this request ($code); no provider turn was started." \
      '{decision:"block",reason:$reason}'
    ;;
  *) refuse "the Megamind coordinator returned an unrecognized decision (${decision:-empty})" ;;
esac
