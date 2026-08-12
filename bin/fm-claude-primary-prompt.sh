#!/usr/bin/env bash
# Claude UserPromptSubmit transport for the host-owned Megamind coordinator.
# The hook reads Claude's private JSON payload and emits only Claude's response
# shape; it never classifies, parses, reads wiki files, or runs a follow-up.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="${CLAUDE_PROJECT_DIR:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}}"
COORDINATOR="$ROOT/bin/fm-megamind-primary.sh"

# Exit 2 is Claude's block code and shows only stderr, so every transport
# failure names itself there. A prompt that disappears without a reason is
# indistinguishable from a broken editor; a disclosed blocker is not.
refuse() {
  printf 'Firstmate: %s. The prompt was not sent; no provider turn was started.\n' "$1" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || refuse 'jq is required by the Megamind prompt hook and was not found on PATH'
[ -x "$COORDINATOR" ] || refuse "the Megamind coordinator is missing or not executable ($COORDINATOR)"
payload=$(cat) || refuse 'the hook payload could not be read'
prompt=$(printf '%s' "$payload" | jq -r '(.prompt // .user_prompt // empty) | if type == "string" then . else empty end' 2>/dev/null) || refuse 'the hook payload could not be parsed'
session=$(printf '%s' "$payload" | jq -r '(.session_id // .sessionId // empty) | if type == "string" then . else empty end' 2>/dev/null) || refuse 'the hook payload could not be parsed'
[ -n "$prompt" ] || exit 0

# An exact host control is consumed before Claude sees it. The offer is passed
# as one opaque transport value; free-form consent never reaches the model.
if printf '%s' "$prompt" | jq -eR 'test("^/fm-megamind-select [0-9A-Fa-f]{16,128} [^[:space:]]+$")' >/dev/null 2>&1; then
  selection=$(printf '%s' "$prompt" | sed -E 's#^/fm-megamind-select ([0-9A-Fa-f]{16,128}) [^[:space:]]+$#\1#')
  offer=$(printf '%s' "$prompt" | sed -E 's#^/fm-megamind-select [0-9A-Fa-f]{16,128} ([^[:space:]]+)$#\1#')
  result=$(FM_HOME="${FM_HOME:-$ROOT}" "$COORDINATOR" continue --harness claude --session-id "$session" \
    --selection-id "$selection" --offer "$offer" --include-replay 2>/dev/null) \
    || refuse 'the Megamind coordinator could not complete this offer selection'
else
  submission="p$(date +%s).$$.$RANDOM"
  result=$(printf '%s' "$prompt" | FM_HOME="${FM_HOME:-$ROOT}" "$COORDINATOR" process --harness claude \
    --session-id "$session" --submission-id "$submission" 2>/dev/null) \
    || refuse 'the Megamind coordinator could not complete this preflight'
fi

decision=$(printf '%s' "$result" | jq -r '.decision // empty' 2>/dev/null) \
  || refuse 'the Megamind coordinator returned output this hook could not parse'
case "$decision" in
  bypass|proceed-no-context) exit 0 ;;
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
    offers=$(printf '%s' "$result" | jq -r '[.offers[]?.wiki] | join(", ")' 2>/dev/null || printf 'the listed offer')
    selection=$(printf '%s' "$result" | jq -r '.selection_id // empty' 2>/dev/null || true)
    if [ -n "$selection" ]; then
      reason="Choose one of $offers with the exact host control /fm-megamind-select $selection <offer>. No wiki content was loaded."
    else
      reason="Megamind returned an ambiguous result ($offers), but this session has no continuable selection. No wiki content was loaded."
    fi
    jq -cn --arg reason "$reason" '{decision:"block",reason:$reason}'
    ;;
  block)
    code=$(printf '%s' "$result" | jq -r '.failure_code // "preflight_failed"' 2>/dev/null || printf 'preflight_failed')
    jq -cn --arg reason "Firstmate preflight stopped this request ($code); no provider turn was started." \
      '{decision:"block",reason:$reason}'
    ;;
  *) refuse "the Megamind coordinator returned an unrecognized decision (${decision:-empty})" ;;
esac
