#!/usr/bin/env bash
# fm-rule-guard.sh - deterministic checks that enforce captain rules on replies.
#
# Usage:
#   fm-rule-guard.sh --claude      Claude Stop hook (JSON on stdin)
#   fm-rule-guard.sh scan          check reply text on stdin
#   fm-rule-guard.sh list          print "<check-id><TAB><summary>" per check
#
# docs/captain-rules.md owns the operator contract (when a correction becomes a
# check, and how a rule links to one). This header owns the check registry,
# modes, state, and exit codes.
#
# Checks are always on; a rule in config/captain-rules.md names the check that
# enforces it, and bin/fm-rules.sh accepts only ids `list` prints.
#   bang-interactive  A reply line hands the captain a "! <command>" line for a
#                     sudo, rebuild, login, password, or keychain step. Those
#                     need a real Terminal window: put the command on the
#                     clipboard with pbcopy and verify the result yourself. A
#                     line where a negation (never, nie, kein, not, ...) comes
#                     before the "!" quotes the rule and passes.
#
# `--claude` reads `.last_assistant_message` from the Stop payload and acts only
# in a primary seat (the main home or a secondmate home, never a task worktree,
# no-mistakes gate, or supervision branch). It fails open when the field is
# absent or not a string. A violation blocks the stop with exit 2 and a stderr
# hint, which Claude Code feeds back so the reply is rewritten before the
# captain relies on it. When `stop_hook_active` is true and the reply is the
# same one the guard last blocked, the stop is released and logged instead of
# blocking forever.
#
# State: $STATE/captain-rules/log.jsonl gets guard-block and guard-release
# events (fm-rules-event.v1); $STATE/captain-rules/guard-last-block holds the
# hash of the last blocked reply.
#
# Exit codes: `scan` 0 clean, 1 violation (one "<check-id>: <line>" per hit on
# stdout); `--claude` 0 allow, 2 block; usage errors 2.
#
# Codex and Pi have no Stop payload with the reply text wired here, so the
# checks bind only Claude primaries; other harnesses get the rule as context.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RSTATE="$STATE/captain-rules"
LOG="$RSTATE/log.jsonl"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

usage() {
  printf 'Usage: %s --claude | scan | list\n' "$(basename "$0")" >&2
}

cmd_list() {
  printf '%s\t%s\n' bang-interactive \
    'blocks a "! <command>" line for sudo, rebuild, login, password, or keychain steps'
}

# Print "<check-id>: <line>" for every violating line of stdin; exit 1 on a hit.
scan_text() {
  # shellcheck disable=SC2016 # Perl owns every $ expression in this literal program.
  perl -CSD -ne '
    BEGIN { $hit = 0 }
    chomp;
    my $line = $_;
    while ($line =~ /(?:^|[\s`"\x27(>*])!\s+(?=[^\n]*?(?:\bsudo\b|\bdarwin-rebuild\b|\bnixos-rebuild\b|\brebuild\.sh\b|\blogin\b|\bauth\s+refresh\b|\bpasswd\b|\badd-generic-password\b|\bop\s+signin\b))/g) {
      my $before = lc substr($line, 0, $-[0]);
      next if $before =~ /\b(?:nie|niemals|never|kein|keine|keinen|no|not|nicht|don\x27t|statt|instead\s+of)\b/;
      print "bang-interactive: $line\n";
      $hit = 1;
      last;
    }
    END { exit $hit }
  '
}

log_event() {  # <event> <check> <hash>
  mkdir -p "$RSTATE" 2>/dev/null || return 0
  jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg event "$1" --arg check "$2" --arg hash "$3" \
    '{schema:"fm-rules-event.v1",at:$at,event:$event,check:$check,hash:$hash}' >> "$LOG" 2>/dev/null || true
}

in_scope() {
  [ -z "${FM_TASK_ID:-}" ] || return 1
  [ -z "${FM_SUPERVISION_ACTOR:-}" ] || return 1
  [ -z "${FM_MEMORY_CAPTURE_CHILD:-}" ] || return 1
  fm_is_gate_agent "$FM_ROOT" && return 1
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 1
  return 0
}

cmd_claude() {
  local input message active hits hash last=
  input=$(cat 2>/dev/null || true)
  in_scope || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  message=$(printf '%s' "$input" | jq -r 'if (.last_assistant_message | type) == "string" then .last_assistant_message else empty end' 2>/dev/null) || exit 0
  [ -n "$message" ] || exit 0
  hits=$(printf '%s\n' "$message" | scan_text) && exit 0
  hash=$(printf '%s' "$message" | shasum -a 256 2>/dev/null | awk '{print $1}')
  active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)
  [ -f "$RSTATE/guard-last-block" ] && read -r last < "$RSTATE/guard-last-block"
  if [ "$active" = true ] && [ -n "$hash" ] && [ "$hash" = "$last" ]; then
    log_event guard-release bang-interactive "$hash"
    exit 0
  fi
  mkdir -p "$RSTATE" 2>/dev/null && printf '%s\n' "$hash" > "$RSTATE/guard-last-block"
  log_event guard-block bang-interactive "$hash"
  {
    printf 'CAPTAIN RULE BLOCK (bang-interactive): this reply hands the captain a "! <command>" line for a step that needs a password, sudo, or an interactive login:\n'
    printf '%s\n' "$hits" | sed 's/^bang-interactive: /  /'
    printf 'The captain ruled this out: the "!" prefix runs inside this session, where sudo and login prompts fail.\n'
    printf 'Rewrite the reply: put the exact command on the clipboard with pbcopy, tell the captain to paste it into a real Terminal window, then verify the result yourself.\n'
  } >&2
  exit 2
}

case "${1:-}" in
  --claude) cmd_claude ;;
  scan) scan_text ;;
  list) cmd_list ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
