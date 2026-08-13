#!/usr/bin/env bash
# Opt-in live guard for installed primary prompt interception adapters.
# The guard uses a synthetic coordinator that blocks before inference, so no
# provider credential or network call is needed and no real wiki is touched.
set -u

if [ "${FM_MEGAMIND_PRIMARY_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_MEGAMIND_PRIMARY_LIVE=1 to run live primary interception guards"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
LAB="$ROOT/.no-mistakes/megamind-primary-live.$$"
mkdir -p "$LAB"
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT

run_claude_block() {
  command -v claude >/dev/null 2>&1 || { echo "absent: claude"; return 0; }
  local project="$LAB/claude/project" home="$LAB/claude/home" out rc
  mkdir -p "$project/bin" "$project/.claude" "$home/state" "$home/config"
  cp "$ROOT/bin/fm-claude-primary-prompt.sh" "$project/bin/"
  cat > "$project/bin/fm-megamind-primary.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"decision":"block","failure_code":"synthetic_block"}'
SH
  chmod 700 "$project/bin/"*.sh
  printf '%s\n' "$$" > "$home/state/.lock"
  # shellcheck disable=SC2016 # Claude expands CLAUDE_PROJECT_DIR in the hook process.
  printf '%s\n' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"exec \"$CLAUDE_PROJECT_DIR\"/bin/fm-claude-primary-prompt.sh"}]}]}}' > "$project/.claude/settings.json"
  set +e
  out=$(cd "$project" && CLAUDE_PROJECT_DIR="$project" FM_HOME="$home" \
    claude --print --output-format json --dangerously-skip-permissions \
    'SYNTHETIC-BLOCK-CANARY' 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "Claude block guard exited $rc"
  printf '%s\n' "$out" | grep -Fq 'UserPromptSubmit operation blocked by hook' \
    || fail "Claude did not report the blocked prompt"
  printf '%s\n' "$out" | grep -Fq '"num_turns":0' \
    || fail "Claude block guard allowed a provider turn: $out"
  printf 'live: claude %s blocked before inference with zero provider turns\n' "$(claude --version 2>/dev/null)"
}

# An ambiguous preflight is only usable if the control the block advertises
# survives the real CLI. Claude resolves a leading-slash prompt as one of its own
# commands and answers "Unknown command" before any UserPromptSubmit hook runs,
# which no portable test can observe, so the round trip is driven here.
run_claude_offer_control() {
  command -v claude >/dev/null 2>&1 || { echo "absent: claude"; return 0; }
  local project="$LAB/claude-offer/project" home="$LAB/claude-offer/home" out control replay rc
  mkdir -p "$project/bin" "$project/.claude" "$home/state" "$home/config"
  cp "$ROOT/bin/fm-claude-primary-prompt.sh" "$project/bin/"
  cat > "$project/bin/fm-megamind-primary.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_HOME:?}/state/offer-coordinator-calls"
if [ "${1:-}" = continue ]; then
  printf '%s\n' '{"decision":"block","failure_code":"synthetic_selection"}'
else
  printf '%s\n' '{"decision":"offer","selection_id":"0123456789abcdef","offers":[{"wiki":"SyntheticWiki"}]}'
fi
SH
  chmod 700 "$project/bin/"*.sh
  printf '%s\n' "$$" > "$home/state/.lock"
  : > "$home/state/offer-coordinator-calls"
  # shellcheck disable=SC2016 # Claude expands CLAUDE_PROJECT_DIR in the hook process.
  printf '%s\n' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"exec \"$CLAUDE_PROJECT_DIR\"/bin/fm-claude-primary-prompt.sh"}]}]}}' > "$project/.claude/settings.json"

  set +e
  out=$(cd "$project" && CLAUDE_PROJECT_DIR="$project" FM_HOME="$home" \
    claude --print --output-format json --dangerously-skip-permissions \
    'SYNTHETIC-OFFER-CANARY' 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "Claude offer guard exited $rc"
  # Capture any leading punctuation too, so the replay below is byte-for-byte
  # what the block told the captain to send rather than a sanitized version.
  control=$(printf '%s' "$out" | jq -r '.result // ""' | grep -Eo '[^[:space:]]*fm-megamind-select [0-9A-Fa-f]{16,128} <offer>') \
    || fail "the ambiguous block advertised no recoverable host control: $out"
  replay=${control/<offer>/SyntheticWiki}

  # Send the advertised control back exactly as the captain reads it.
  set +e
  out=$(cd "$project" && CLAUDE_PROJECT_DIR="$project" FM_HOME="$home" \
    claude --print --output-format json --dangerously-skip-permissions "$replay" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "Claude offer control exited $rc"
  printf '%s\n' "$out" | grep -Fq 'Unknown command' \
    && fail "Claude consumed the advertised control as one of its own commands: $out"
  printf '%s\n' "$out" | grep -Fq '"num_turns":0' \
    || fail "the advertised control started a provider turn instead of reaching the host gate: $out"
  grep -Fq -- "continue --harness claude" "$home/state/offer-coordinator-calls" \
    || fail "the advertised control never reached the coordinator's selection path"
  grep -Fq -- "--selection-id 0123456789abcdef --offer SyntheticWiki" "$home/state/offer-coordinator-calls" \
    || fail "the advertised control did not carry the offered selection verbatim"
  printf 'live: claude %s round-tripped the advertised offer control back through the hook\n' "$(claude --version 2>/dev/null)"
}

run_pi_block() {
  command -v pi >/dev/null 2>&1 || { echo "absent: pi"; return 0; }
  local project="$LAB/pi/project" home="$LAB/pi/home" out rc calls
  mkdir -p "$project/.pi/extensions/lib" "$project/bin" "$home/state" "$home/config"
  cp "$ROOT/.pi/extensions/fm-primary-megamind.ts" "$project/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-megamind-offer-picker.ts" "$project/.pi/extensions/lib/"
  # The subcommand is recorded, not a bare marker: the adapter asks the
  # coordinator two different questions, and only one of them carries a prompt.
  cat > "$project/bin/fm-megamind-primary.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${FM_HOME:?}/state/live-coordinator-called"
printf '%s\n' '{"decision":"block","failure_code":"synthetic_block"}'
SH
  chmod 700 "$project/bin/fm-megamind-primary.sh"
  printf '%s\n' "$$" > "$home/state/.lock"
  set +e
  out=$(cd "$project" && FM_HOME="$home" FM_MEGAMIND_PRIMARY_AUTOMATIC=1 \
    pi --print --approve --no-session --no-context-files --no-extensions \
    -e .pi/extensions/fm-primary-megamind.ts --model openai-codex/gpt-5.6-sol \
    'SYNTHETIC-BLOCK-CANARY' 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "Pi block guard exited $rc: $out"
  [ -f "$home/state/live-coordinator-called" ] \
    || fail "Pi never reached the coordinator at all: $out"
  calls=$(tr '\n' ' ' < "$home/state/live-coordinator-called")
  # `process` is the one call that carries the prompt, so exactly one of them is
  # what "routed one prompt" means. `governed` carries no prompt at all: it is
  # the exit-status-only opt-in question the adapter asks before it turns a
  # blocked decision into a handled, unsent prompt, so an ungoverned session
  # never loses its prompt to this adapter. Both must appear, in that order.
  [ "$(grep -c '^process$' "$home/state/live-coordinator-called")" = 1 ] \
    || fail "Pi did not route exactly one prompt through the coordinator: $calls"
  [ "$calls" = "process governed " ] \
    || fail "Pi did not confirm the opt-in gate before withholding the prompt: $calls"
  printf 'live: pi %s blocked before inference with one governed coordinator submission\n' "$(pi --version 2>/dev/null)"
}

run_unsupported_check() {
  local harness version result
  for harness in codex opencode grok kimi; do
    if command -v "$harness" >/dev/null 2>&1; then
      version=$($harness --version 2>/dev/null | head -1 || true)
      result=$(FM_MEGAMIND_PRIMARY_AUTOMATIC=1 "$ROOT/bin/fm-megamind-primary.sh" check --harness "$harness")
      printf '%s\n' "$result" | jq -e --arg h "$harness" '.harness == $h and .automatic == "unsupported" and .code == "primary_prompt_interception_unproven"' >/dev/null \
        || fail "$harness did not have a deterministic unsupported result"
      printf 'unsupported: %s %s automatic primary interception unproven; ordinary operation retained\n' "$harness" "$version"
    else
      printf 'absent: %s\n' "$harness"
    fi
  done
  if command -v pi-signed >/dev/null 2>&1; then
    printf 'installed: pi-signed %s; identity shares the Pi adapter guard\n' "$(pi-signed --version 2>/dev/null)"
  else
    printf 'absent: pi-signed\n'
  fi
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
run_claude_block
run_claude_offer_control
run_pi_block
run_unsupported_check
printf 'ok - installed primary interception guards covered every detected harness\n'
