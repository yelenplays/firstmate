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

run_pi_block() {
  command -v pi >/dev/null 2>&1 || { echo "absent: pi"; return 0; }
  local project="$LAB/pi/project" home="$LAB/pi/home" out rc
  mkdir -p "$project/.pi/extensions" "$project/bin" "$home/state" "$home/config"
  cp "$ROOT/.pi/extensions/fm-primary-megamind.ts" "$project/.pi/extensions/"
  cat > "$project/bin/fm-megamind-primary.sh" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "${FM_HOME:?}/state/live-coordinator-called"
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
  [ "$(wc -l < "$home/state/live-coordinator-called" | tr -d ' ')" = 1 ] \
    || fail "Pi did not route exactly one prompt through the coordinator"
  printf 'live: pi %s blocked before inference with one coordinator submission\n' "$(pi --version 2>/dev/null)"
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
run_pi_block
run_unsupported_check
printf 'ok - installed primary interception guards covered every detected harness\n'
