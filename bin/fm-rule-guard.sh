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
#                     clipboard with pbcopy and verify the result yourself.
#                     Only a negated instruction in the same clause passes: a
#                     negation (never, nie, kein, not, ...) within the three
#                     words before "!", or "Never hand the captain a" right
#                     before it. Clauses end at , ; : . ? ! and a spaced dash.
#                     A negation that only negates a harmless word ("no
#                     worries", "kein Problem", "don't forget", "vergiss
#                     nicht") is not one, so the command still counts as
#                     handed over. Neither is an additive "not only", "not
#                     just", or "nicht nur", which asks for the command too.
#
# `--claude` reads `.last_assistant_message` from the Stop payload and acts only
# in a primary seat (the main home or a secondmate home, never a task worktree,
# no-mistakes gate, or supervision branch). It fails open when the field is
# absent or not a string. A violation blocks the stop with exit 2 and a stderr
# hint, which Claude Code feeds back so the reply is rewritten before the
# captain relies on it. Blocks are counted per session: a stop without
# `stop_hook_active` starts a new count, a forced continuation adds to it, and
# a clean stop clears it. A violating reply never ends the turn as a success:
# once the count would pass FM_RULE_GUARD_BLOCK_CAP (default 3, safely below
# Claude Code's own consecutive-block override; 0 halts the first violation),
# the hook prints Stop JSON with `continue: false` and a `stopReason` that tells
# the captain not to run the "!" line, and exits 0. Claude Code then ends the
# session's turn and shows that reason instead of continuing.
#
# State: $STATE/captain-rules/log.jsonl gets guard-block and guard-halt events
# (fm-rules-event.v1); $STATE/captain-rules/guard-blocks/<session> holds the
# current consecutive block count of one session. Counts untouched for a day
# are pruned.
#
# Exit codes: `scan` 0 clean, 1 violation (one "<check-id>: <line>" per hit on
# stdout); `--claude` 0 allow or halt, 2 block; usage errors 2.
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
      $before =~ s/^.*(?:[,;:.?!]|\s[-\x{2013}\x{2014}]\s)//;
      # Preserve the longer rule quotation without allowing distant negation.
      next if $before =~ /\bnever\s+hand\s+the\s+captain\s+a\s*$/;
      my @words = $before =~ /[\w\x27]+/g;
      my $nearby = join " ", (@words > 3 ? @words[-3..-1] : @words);
      my $around = join " ", (@words > 4 ? @words[-4..-1] : @words);
      next if $nearby =~ /\b(?:nie|niemals|never|kein|keine|keinen|no|not|nicht|don\x27t|statt|instead\s+of)\b/
        && $around !~ /\b(?:problems?|problemo|worr(?:y|ies|ied)|sorgen?|stress|pressure|doubt|rush|hurry|panic|panik|angst|drama|idea|ahnung|issues?|biggie|deal|forget|vergessen|vergiss|hesitate|z(?:\x{f6}|oe)gern?)\b/
        && $around !~ /\b(?:not|nicht)\s+(?:only|just|merely|nur|blo(?:\x{df}|ss)|lediglich|allein)\b/;
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

block_count_file() {  # <session-id>
  local id
  id=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-96)
  printf '%s/guard-blocks/%s\n' "$RSTATE" "${id:-unknown}"
}

cmd_claude() {
  local input message active hits hash session file count=0 cap=${FM_RULE_GUARD_BLOCK_CAP:-3}
  input=$(cat 2>/dev/null || true)
  in_scope || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  message=$(printf '%s' "$input" | jq -r 'if (.last_assistant_message | type) == "string" then .last_assistant_message else empty end' 2>/dev/null) || exit 0
  [ -n "$message" ] || exit 0
  session=$(printf '%s' "$input" | jq -r '.session_id // "unknown" | tostring' 2>/dev/null) || session=unknown
  file=$(block_count_file "$session")
  find "$RSTATE/guard-blocks" -type f -mmin +1440 -delete 2>/dev/null || true
  if hits=$(printf '%s\n' "$message" | scan_text); then
    rm -f -- "$file" 2>/dev/null || true
    exit 0
  fi
  case "$cap" in ''|*[!0-9]*) cap=3 ;; esac
  hash=$(printf '%s' "$message" | shasum -a 256 2>/dev/null | awk '{print $1}')
  active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)
  if [ "$active" = true ] && [ -f "$file" ]; then
    read -r count < "$file" || count=0
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
  fi
  count=$((count + 1))
  if [ "$count" -gt "$cap" ]; then
    rm -f -- "$file" 2>/dev/null || true
    log_event guard-halt bang-interactive "$hash"
    jq -nc --arg reason "CAPTAIN RULE BLOCK (bang-interactive): the reply above hands you a \"! <command>\" line for a sudo, rebuild, login, password, or keychain step and was not rewritten after $cap block(s). Do not run that \"!\" line in this session; paste the command into a real Terminal window instead (it can be put on the clipboard with pbcopy), then check the result." \
      '{continue:false,stopReason:$reason}'
    exit 0
  fi
  mkdir -p "${file%/*}" 2>/dev/null && printf '%s\n' "$count" > "$file"
  log_event guard-block bang-interactive "$hash"
  {
    printf 'CAPTAIN RULE BLOCK (bang-interactive): this reply hands the captain a "! <command>" line for a step that needs a password, sudo, or an interactive login:\n'
    printf '%s\n' "$hits" | sed 's/^bang-interactive: /  /'
    printf 'The captain ruled this out: the "!" prefix runs inside this session, where sudo and login prompts fail.\n'
    printf 'Rewrite the reply: put the exact command on the clipboard with pbcopy, tell the captain to paste it into a real Terminal window, then verify the result yourself.\n'
    printf 'This is block %s of %s; a reply that still hands over the "!" line after that ends the turn with a captain-facing halt instead.\n' "$count" "$cap"
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
