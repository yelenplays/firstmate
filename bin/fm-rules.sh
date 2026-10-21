#!/usr/bin/env bash
# fm-rules.sh - the captain-rules source and its projections.
#
# Usage:
#   fm-rules.sh list
#   fm-rules.sh render
#   fm-rules.sh session
#   fm-rules.sh brief-section
#   fm-rules.sh add [--check <check-id>] <rule-id> <rule text...>
#   fm-rules.sh confirm [--check <check-id>] <candidate-id> <rule-id> <rule text...>
#   fm-rules.sh dismiss <candidate-id>
#   fm-rules.sh revoke <rule-id>
#   fm-rules.sh check <rule-id> <check-id>
#   fm-rules.sh nocheck <rule-id> <reason...>
#   fm-rules.sh unchecked
#   fm-rules.sh deliver
#   fm-rules.sh prompt-hook
#   fm-rules.sh report [--days <n>] [--transcripts <dir>] [--now <epoch>]
#   fm-rules.sh weekly-check | weekly-arm | weekly-disarm
#
# docs/captain-rules.md owns the operator contract: what a rule is, the capture
# and confirmation loop, precedence, the rule-to-check pattern, and the weekly
# report. This header owns flags, the file format, state files, and exit codes.
#
# Source: $CONFIG/captain-rules.md (config/ is gitignored and home-local; the
# primary's copy is inherited by every secondmate home through
# bin/fm-config-inherit-lib.sh). One rule per line:
#   - [<rule-id>] <one-line imperative> <!-- since=YYYY-MM-DD seen=N[ last=YYYY-MM-DD][ check=<id>|nocheck=YYYY-MM-DD] -->
# Rule ids match ^[a-z0-9][a-z0-9-]{0,47}$; a rule text is one line of at most
# 300 characters without control characters, "<!--", or "-->". Each tab is
# stored as a space first (also when a hand edit put one in the file), so the
# tab-separated rows behind every projection can never split a rule. Lines that are not rule lines are kept
# verbatim. Every write goes through this script and lands by rename. Each
# mutating subcommand (add, confirm, dismiss, revoke, check, nocheck, and the
# candidate write of prompt-hook) holds $STATE/captain-rules/store.lock, the
# portable bin/fm-wake-lib.sh lock, for its whole read-modify-write, so
# concurrent writers never lose each other's rules, repeats, or bookkeeping.
#
# `add` on a new id records the rule with seen=1. `add` or `confirm` on an
# existing id is a repeat: seen grows by one, last is today, and a new text
# replaces the old one. A rule with seen >= 2, no check, and no nocheck record
# is "repeated without a check" and is listed by `unchecked`, `render`, and
# `report`. `--check` and `check` accept only an id that
# `bin/fm-rule-guard.sh list` prints.
#
# Budget: the rendered block must fit FM_RULES_MAX_CHARS characters (default
# 6000, at least 200), which keeps it well inside the harness hook-context
# limit. `add`, `confirm`, and `check` refuse with exit 4, before anything is
# written or reported as saved, when the result would pass the budget and grow
# the block; the refusal asks to consolidate rules (restate an existing rule id
# with a shorter or merged text, or revoke an obsolete one). Writes that do not
# grow the block always land, so consolidation works even over budget.
#
# Projections: `render` prints the always-loaded block (header with the
# precedence line, every rule, the unchecked list) and never cuts it; it prints
# nothing when there are no rules. `session` is the Claude SessionStart hook: `render` for a primary seat
# (the main home or a secondmate home), silent in task worktrees, no-mistakes
# gates, and the supervision branch. bin/fm-session-start.sh prints the same
# block for non-Claude primaries on full and compact digests.
# Delivery: a write that changes the worker-facing rule lines (a new rule, a
# changed text, a revocation, a linked check) delivers the complete new set to
# every live consumer before it returns, still under the store lock so
# deliveries arrive in write order: bin/fm-config-push.sh for every live
# secondmate (it copies config/captain-rules.md and sends that home's reread
# instruction), then `deliver` inside each secondmate home, found from its meta
# home= or the data/secondmates.md registry and reached directly when local or
# through bin/fm-on.sh when remote, then one "CAPTAIN RULES UPDATE
# <generation>" record through bin/fm-send.sh into the steering inbox of every
# ship or scout task recorded in this home's state/*.meta. `deliver` in a
# secondmate home hands that home's own copy to its own workers and always
# prints "delivered <generation>: ..."; the primary counts a secondmate as
# reached only when that generation is its own, so a skipped or failed push is
# reported instead of resending an old set. A repeat that leaves the lines
# unchanged delivers nothing. `deliver` repeats the delivery of the current set
# by hand, for example after an exit 5; secondmate homes nested more than four
# deep are reported as not reached.
#
# `brief-section` prints the "# Captain rules" section bin/fm-brief.sh puts in
# ship and scout briefs with the same complete rule list, or nothing when there
# are no rules.
#
# Capture: `prompt-hook` is the Claude UserPromptSubmit hook for the primary
# home's own main session (not a secondmate, worker, gate, or supervision
# branch). A captain prompt that reads like a correction or a standing rule
# writes a candidate and injects one instruction telling main to confirm it
# with `confirm` or drop it with `dismiss`; no rule is ever written by the
# hook itself. A bare "nein"/"no" within FM_RULES_REVOKE_WINDOW seconds
# (default 1800) of the last `confirm` injects the matching `revoke` command.
#
# Report: `report` prints a Markdown summary of the last --days (default 7):
# rules added and repeated, guard blocks, rules repeated without a check,
# candidates, and correction-like captain prompts found in the Claude
# transcripts under --transcripts (default: this home's Claude project dir).
# It records the run for `weekly-check`, the watcher check body;
# docs/captain-rules.md owns reminder timing and report delivery.
# `weekly-arm` writes and binds state/captain-rules-weekly.check.sh;
# `weekly-disarm` unbinds and removes it.
#
# State: $STATE/captain-rules/ holds log.jsonl (fm-rules-event.v1 lines, with a
# deliver event per delivery),
# candidates/<candidate-id>, last-confirmed, last-report, weekly-announced, and
# store.lock.
#
# Rule-store mutations and candidate confirm/dismiss refuse in a secondmate
# home: config/ there is a copy the primary re-pushes on every convergence.
# Home-local report and reminder state can still be written there.
#
# Exit codes: 0 success; 1 not found (unknown rule or candidate); 2 usage
# error, a rule write in a secondmate home, or an unusable store; 3 invalid rule id, text, or
# check id; 4 the write would push the rendered block past FM_RULES_MAX_CHARS;
# 5 the change is saved but at least one live consumer was not reached (each
# one is named on stderr).
#
# Environment: FM_HOME, FM_CONFIG_OVERRIDE, FM_STATE_OVERRIDE, FM_ROOT_OVERRIDE,
# FM_RULES_MAX_CHARS, FM_RULES_REVOKE_WINDOW, FM_RULES_TODAY (tests),
# CLAUDE_CONFIG_DIR.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RULES_FILE="$CONFIG/captain-rules.md"
RSTATE="$STATE/captain-rules"
LOG="$RSTATE/log.jsonl"
GUARD="$SCRIPT_DIR/fm-rule-guard.sh"
WEEKLY_ID=captain-rules-weekly
STORE_LOCK="$RSTATE/store.lock"
STORE_LOCKED=
export FM_HOME

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

rules_usage() {
  cat >&2 <<'EOF'
Usage:
  fm-rules.sh list
  fm-rules.sh render
  fm-rules.sh session
  fm-rules.sh brief-section
  fm-rules.sh add [--check <check-id>] <rule-id> <rule text...>
  fm-rules.sh confirm [--check <check-id>] <candidate-id> <rule-id> <rule text...>
  fm-rules.sh dismiss <candidate-id>
  fm-rules.sh revoke <rule-id>
  fm-rules.sh check <rule-id> <check-id>
  fm-rules.sh nocheck <rule-id> <reason...>
  fm-rules.sh unchecked
  fm-rules.sh deliver
  fm-rules.sh prompt-hook
  fm-rules.sh report [--days <n>] [--transcripts <dir>] [--now <epoch>]
  fm-rules.sh weekly-check | weekly-arm | weekly-disarm
EOF
}

die() {
  printf 'fm-rules: %s\n' "$1" >&2
  exit "${2:-2}"
}

today() {
  if [ -n "${FM_RULES_TODAY:-}" ]; then printf '%s\n' "$FM_RULES_TODAY"; else date +%Y-%m-%d; fi
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

valid_rule_id() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]]
}

valid_text() {
  local text=$1
  [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ] || return 1
  [ "${#text}" -le 300 ] || return 1
  case "$text" in *[[:cntrl:]]*|*'<!--'*|*'-->'*) return 1 ;; esac
  return 0
}

# Tabs are ordinary copied whitespace; store each one as a space so the
# tab-separated row format can never split a rule. Other control characters,
# newlines included, are refused by valid_text.
normalize_text() {
  printf '%s' "${1//$'\t'/ }"
}

valid_check_id() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] || return 1
  "$GUARD" list 2>/dev/null | awk '{print $1}' | grep -qxF -- "$1"
}

log_event() {  # <event> [key value]...
  # shellcheck disable=SC2016 # jq owns every $ expression in this filter.
  local args=(--arg at "$(now_iso)" --arg event "$1") filter='{schema:"fm-rules-event.v1",at:$at,event:$event'
  shift
  while [ $# -ge 2 ]; do
    args+=(--arg "$1" "$2")
    filter="$filter,$1:\$$1"
    shift 2
  done
  mkdir -p "$RSTATE" 2>/dev/null || return 0
  jq -nc "${args[@]}" "$filter}" >> "$LOG" 2>/dev/null || true
}

# Print one TSV row per rule: id, text, since, seen, last, check, nocheck.
rules_rows() {  # [rules-file]
  local file=${1:-$RULES_FILE}
  [ -f "$file" ] || return 0
  # shellcheck disable=SC2016 # Perl owns every $ expression in this literal program.
  perl -ne '
    next unless /^- \[([a-z0-9][a-z0-9-]{0,47})\] (.*?) <!--(.*?)-->\s*$/;
    my ($id, $text, $meta) = ($1, $2, $3);
    $text =~ s/[\x00-\x1f\x7f]+/ /g;
    my %m = map { /^([a-z]+)=(\S*)$/ ? ($1, $2) : () } split /\s+/, $meta;
    print join("\t", $id, $text, $m{since} // "", $m{seen} // 1, $m{last} // "",
      $m{check} // "", $m{nocheck} // ""), "\n";
  ' "$file"
}

# Hold the store lock until this process exits. Mutating subcommands call it
# before their first read so the whole read-modify-write is one transaction.
store_lock() {
  mkdir -p "$RSTATE" 2>/dev/null || return 1
  if ! command -v fm_lock_acquire_wait >/dev/null 2>&1; then
    # bin/fm-wake-lib.sh is a canonical lint root in its own right; keep this an
    # analysis boundary for the same reason bin/fm-lease-lib.sh does.
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/fm-wake-lib.sh" || return 1
  fi
  fm_lock_acquire_wait "$STORE_LOCK" || return 1
  STORE_LOCKED=1
  trap store_unlock EXIT
}

store_unlock() {
  [ -n "$STORE_LOCKED" ] || return 0
  STORE_LOCKED=
  fm_lock_release "$STORE_LOCK"
}

RULES_BUDGET=${FM_RULES_MAX_CHARS:-6000}

require_budget() {
  [[ "$RULES_BUDGET" =~ ^[0-9]+$ ]] && [ "$RULES_BUDGET" -ge 200 ] \
    || die "FM_RULES_MAX_CHARS must be a number of at least 200"
}

# Refuse a rewrite whose rendered block would pass the budget and grow.
check_budget() {  # <new-rules-file>
  local max=$RULES_BUDGET old new
  new=$(render_block "$1")
  [ "${#new}" -gt "$max" ] || return 0
  old=$(render_block "$RULES_FILE")
  [ "${#new}" -gt "${#old}" ] || return 0
  printf 'fm-rules: not saved: the captain rules block would be %s characters, over its %s-character budget (FM_RULES_MAX_CHARS).\n' "${#new}" "$max" >&2
  printf 'fm-rules: consolidate rules first: restate an existing rule id with a shorter or merged text (add <rule-id> "<text>"), or revoke one that no longer applies (see %s/fm-rules.sh list), then retry.\n' "$SCRIPT_DIR" >&2
  return 1
}

rule_exists() {
  rules_rows | awk -F'\t' -v id="$1" '$1 == id { found = 1 } END { exit found ? 0 : 1 }'
}

# Rewrite the rules file through one Perl pass and land it by rename.
# Modes: upsert <id> <text> <today> <check|"">; drop <id>; setcheck <id> <check>;
# setnocheck <id> <today>. Returns 0 when upsert added a new rule, 3 when an
# existing rule changed, and 1 when the rule does not exist.
rewrite_rules() {
  local mode=$1 tmp
  shift
  mkdir -p "$CONFIG" || die "cannot create $CONFIG"
  [ ! -L "$RULES_FILE" ] || die "refusing a symlinked $RULES_FILE"
  tmp=$(mktemp "$CONFIG/.captain-rules.XXXXXX") || die "mktemp failed"
  # shellcheck disable=SC2016 # Perl owns every $ expression in this literal program.
  local rc=0
  FM_RULES_MODE=$mode perl -e '
    my $mode = $ENV{FM_RULES_MODE};
    my ($file, $id, $a, $b, $c) = @ARGV;
    my @lines;
    if (open my $fh, "<", $file) { @lines = <$fh>; close $fh; }
    if (!@lines) {
      @lines = ("# Captain rules\n",
        "<!-- fm-rules v1: one rule per line, written by bin/fm-rules.sh; docs/captain-rules.md owns the contract. -->\n",
        "\n");
    }
    my $found = 0;
    my @out;
    for my $line (@lines) {
      if ($line =~ /^- \[\Q$id\E\] (.*?) <!--(.*?)-->\s*$/) {
        my ($text, $meta) = ($1, $2);
        my %m = map { /^([a-z]+)=(\S*)$/ ? ($1, $2) : () } split /\s+/, $meta;
        $found = 1;
        next if $mode eq "drop";
        if ($mode eq "upsert") {
          $text = $a;
          $m{seen} = ($m{seen} // 1) + 1;
          $m{last} = $b;
          if ($c ne "") { $m{check} = $c; delete $m{nocheck}; }
        } elsif ($mode eq "setcheck") {
          $m{check} = $a; delete $m{nocheck};
        } elsif ($mode eq "setnocheck") {
          $m{nocheck} = $a; delete $m{check};
        }
        $m{since} //= $m{last} // "";
        my @keys = grep { exists $m{$_} } qw(since seen last check nocheck);
        $line = "- [$id] $text <!-- " . join(" ", map { "$_=$m{$_}" } @keys) . " -->\n";
      }
      push @out, $line;
    }
    if (!$found) {
      exit 4 unless $mode eq "upsert";
      $out[-1] .= "\n" unless $out[-1] =~ /\n\z/;
      my $meta = "since=$b seen=1" . ($c ne "" ? " check=$c" : "");
      push @out, "- [$id] $a <!-- $meta -->\n";
    }
    print @out;
    exit($found ? 3 : 0);
  ' "$RULES_FILE" "$@" > "$tmp" || rc=$?
  if { [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; } && { [ "$mode" = upsert ] || [ "$mode" = setcheck ]; } \
    && ! check_budget "$tmp"; then
    rm -f -- "$tmp"
    exit 4
  fi
  case "$rc" in
    0|3) mv -f -- "$tmp" "$RULES_FILE" || { rm -f -- "$tmp"; die "cannot write $RULES_FILE"; } ;;
    4) rm -f -- "$tmp"; return 1 ;;
    *) rm -f -- "$tmp"; die "cannot rewrite $RULES_FILE" ;;
  esac
  return "$rc"
}

# Shared by add and confirm: prints "added" or "repeated" and logs the event.
upsert_rule() {  # <id> <text> <check> [candidate]
  local id=$1 text check=$3 candidate=${4:-} rc=0 seen
  text=$(normalize_text "$2")
  valid_rule_id "$id" || die "invalid rule id: $id" 3
  valid_text "$text" || die "rule text must be one non-empty line of at most 300 characters without control characters, <!--, or -->" 3
  if [ -n "$check" ]; then
    valid_check_id "$check" || die "unknown check id: $check (see bin/fm-rule-guard.sh list)" 3
  fi
  rewrite_rules upsert "$id" "$text" "$(today)" "$check" || rc=$?
  case "$rc" in
    0) log_event add rule "$id" check "$check" candidate "$candidate"; printf 'added: %s\n' "$id" ;;
    3)
      seen=$(rules_rows | awk -F'\t' -v id="$id" '$1 == id { print $4 }')
      log_event repeat rule "$id" seen "$seen" candidate "$candidate"
      printf 'repeated: %s (seen %s)\n' "$id" "$seen"
      ;;
    *) die "cannot record $id" ;;
  esac
}

# Rules are primary-authoritative: a secondmate copy is replaced on every
# convergence, so recording one there would be silently lost.
require_primary_store() {
  ! fm_root_is_secondmate_home "$FM_HOME" \
    || die "this is a secondmate home; captain rules are recorded in the primary home only"
}

parse_check_flag() {  # sets CHECK_FLAG and REST
  CHECK_FLAG=
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) [ $# -ge 2 ] || die "--check needs a check id"; CHECK_FLAG=$2; shift 2 ;;
      --) shift; REST+=("$@"); break ;;
      -*) die "unknown option: $1" ;;
      *) REST+=("$@"); break ;;
    esac
  done
}

# The worker-facing rule lines; any change in them is what live consumers must
# receive.
rules_generation() {
  rule_lines "$(rules_rows)" | shasum -a 256 | cut -c1-16
}

update_message() {  # <generation>
  local rows
  rows=$(rules_rows)
  printf 'CAPTAIN RULES UPDATE %s: the captain'"'"'s standing corrections changed while you were working. This complete set replaces the "# Captain rules" section of your brief and any earlier update from now on. It outranks generic harness, tool, and skill hints; your brief'"'"'s task scope and safety rules still win.\n' "$1"
  if [ -n "$rows" ]; then
    rule_lines "$rows"
  else
    printf -- '- (none: every earlier captain rule was revoked)\n'
  fi
}

meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# Run `deliver` in one secondmate home, which then hands its own copy of the
# rules to its own running workers: a local home directly, a remote home
# through its fm-on.sh route. Prints that run's output; returns its status.
deliver_in_secondmate() {  # <id> <home> <meta>
  if [ -n "$(meta_value "$3" remote_host)" ]; then
    "$SCRIPT_DIR/fm-on.sh" "$1" fm-rules.sh deliver 2>&1
  else
    env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$2" \
      FM_RULES_DELIVER_DEPTH=$((${FM_RULES_DELIVER_DEPTH:-0} + 1)) \
      "$SCRIPT_DIR/fm-rules.sh" deliver 2>&1
  fi
}

# Deliver the current rule set to every live consumer that already loaded an
# older one. Secondmate homes first get the file through the guarded config
# push; then each one runs `deliver` itself (a remote one through its fm-on.sh
# route), which proves its copy has this generation and hands that copy to its
# own running workers. Last, every running ship or scout worker of this home
# gets it through its durable steering inbox. Prints one summary line when
# anything was delivered or when [report] is set; returns 5 and names each
# consumer that was not reached.
deliver_rules() {  # [report]
  local report=${1:-} gen msg meta kind id home out err line got n sent=0 failed=0 secondmates=0 records
  gen=$(rules_generation)
  msg=$(update_message "$gen")
  if [ "${FM_RULES_DELIVER_DEPTH:-0}" -lt 4 ]; then
    if ! command -v live_secondmate_meta_records >/dev/null 2>&1; then
      # shellcheck source=bin/fm-ff-lib.sh
      . "$SCRIPT_DIR/fm-ff-lib.sh" || return 5
    fi
    records=$(live_secondmate_meta_records "$STATE" "$DATA/secondmates.md")
  else
    printf 'fm-rules: not delivered: secondmate homes nested deeper than 4 levels\n' >&2
    records=''
    failed=1
  fi
  if [ -n "$records" ] && ! out=$("$SCRIPT_DIR/fm-config-push.sh" 2>&1); then
    printf 'fm-rules: not delivered: the secondmate config push failed:\n%s\n' "$out" >&2
    failed=$((failed + 1))
  fi
  while IFS='|' read -r id home _ meta; do
    [ -n "$id" ] || continue
    secondmates=$((secondmates + 1))
    if [ -z "$home" ]; then
      printf 'fm-rules: not delivered: secondmate %s has no home= and no registry home\n' "$id" >&2
      failed=$((failed + 1))
      continue
    fi
    if [ -z "$(meta_value "$meta" remote_host)" ] && [ ! -d "$home/state" ]; then
      printf 'fm-rules: not delivered: secondmate %s home %s has no state directory\n' "$id" "$home" >&2
      failed=$((failed + 1))
      continue
    fi
    out=$(deliver_in_secondmate "$id" "$home" "$meta")
    line=$(printf '%s\n' "$out" | grep -E '^delivered [0-9a-f]+: [0-9]+ running worker' | tail -n 1)
    got=$(printf '%s\n' "$line" | sed -n 's/^delivered \([0-9a-f]*\):.*/\1/p')
    n=$(printf '%s\n' "$line" | sed -n 's/^delivered [0-9a-f]*: \([0-9]*\) running worker.*/\1/p')
    if [ -n "$got" ] && [ "$got" != "$gen" ]; then
      printf 'fm-rules: not delivered: secondmate %s still has rule set %s instead of %s\n' "$id" "$got" "$gen" >&2
      failed=$((failed + 1))
      continue
    fi
    sent=$((sent + ${n:-0}))
    if [ -z "$got" ] || ! printf '%s\n' "$out" | grep -qE '^delivered [0-9a-f]+: .*, 0 not reached$'; then
      printf 'fm-rules: not delivered: the running workers of secondmate %s: %s\n' "$id" \
        "$(printf '%s\n' "$out" | grep -v '^delivered ' | tail -n 1)" >&2
      failed=$((failed + 1))
    fi
  done <<< "$records"
  err=$(mktemp "${TMPDIR:-/tmp}/fm-rules-deliver.XXXXXX") || err=/dev/null
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(meta_value "$meta" kind)
    [ "$kind" = ship ] || [ "$kind" = scout ] || continue
    id=${meta##*/}
    id=${id%.meta}
    if "$SCRIPT_DIR/fm-send.sh" "$id" "$msg" >/dev/null 2>"$err"; then
      sent=$((sent + 1))
    else
      printf 'fm-rules: not delivered: worker %s in %s: %s\n' "$id" "$FM_HOME" "$(tail -n 1 "$err" 2>/dev/null)" >&2
      failed=$((failed + 1))
    fi
  done
  [ "$err" = /dev/null ] || rm -f -- "$err"
  log_event deliver generation "$gen" workers "$sent" secondmates "$secondmates" failed "$failed"
  if [ -n "$report" ] || [ "$sent" -gt 0 ] || [ "$secondmates" -gt 0 ] || [ "$failed" -gt 0 ]; then
    printf 'delivered %s: %s running worker(s), %s secondmate home(s), %s not reached\n' \
      "$gen" "$sent" "$secondmates" "$failed"
  fi
  if [ "$failed" -gt 0 ]; then
    printf 'fm-rules: the rule change is saved, but not every live consumer has it; retry with %s/fm-rules.sh deliver\n' "$SCRIPT_DIR" >&2
    return 5
  fi
  return 0
}

# Deliver after a write that changed what consumers see; exit 5 when a live
# consumer was not reached.
deliver_if_changed() {  # <generation-before>
  [ "$(rules_generation)" != "$1" ] || return 0
  deliver_rules || exit 5
}

cmd_deliver() {
  [ $# -eq 0 ] || die "deliver takes no arguments"
  # A secondmate home delivers its own copy of the rules to its own workers.
  store_lock || die "cannot take $STORE_LOCK"
  deliver_rules report || exit 5
}

cmd_add() {
  require_primary_store
  require_budget
  store_lock || die "cannot take $STORE_LOCK"
  local before
  before=$(rules_generation)
  parse_check_flag "$@"
  [ "${#REST[@]}" -ge 2 ] || { rules_usage; die "add needs a rule id and text"; }
  local id=${REST[0]} text="${REST[*]:1}"
  upsert_rule "$id" "$text" "$CHECK_FLAG"
  deliver_if_changed "$before"
}

candidate_path() {
  [[ "$1" =~ ^c-[0-9]+-[0-9a-f]{4}$ ]] || die "invalid candidate id: $1" 3
  printf '%s/candidates/%s\n' "$RSTATE" "$1"
}

cmd_confirm() {
  require_primary_store
  require_budget
  store_lock || die "cannot take $STORE_LOCK"
  local before
  before=$(rules_generation)
  parse_check_flag "$@"
  [ "${#REST[@]}" -ge 3 ] || { rules_usage; die "confirm needs a candidate id, a rule id, and text"; }
  local cid=${REST[0]} id=${REST[1]} text="${REST[*]:2}" path
  path=$(candidate_path "$cid")
  [ -f "$path" ] || die "no open candidate: $cid" 1
  upsert_rule "$id" "$text" "$CHECK_FLAG" "$cid"
  rm -f -- "$path"
  log_event confirm rule "$id" candidate "$cid"
  printf '%s %s\n' "$(date +%s)" "$id" > "$RSTATE/last-confirmed"
  deliver_if_changed "$before"
}

cmd_dismiss() {
  require_primary_store
  store_lock || die "cannot take $STORE_LOCK"
  [ $# -eq 1 ] || die "dismiss takes one candidate id"
  local path
  path=$(candidate_path "$1")
  [ -f "$path" ] || die "no open candidate: $1" 1
  rm -f -- "$path"
  log_event dismiss candidate "$1"
  printf 'dismissed: %s\n' "$1"
}

cmd_revoke() {
  require_primary_store
  store_lock || die "cannot take $STORE_LOCK"
  local before
  before=$(rules_generation)
  [ $# -eq 1 ] || die "revoke takes one rule id"
  valid_rule_id "$1" || die "invalid rule id: $1" 3
  local text
  text=$(rules_rows | awk -F'\t' -v id="$1" '$1 == id { print $2 }')
  [ -n "$text" ] || die "no rule: $1" 1
  rewrite_rules drop "$1" || [ $? -eq 3 ] || die "cannot revoke $1"
  log_event revoke rule "$1" text "$text"
  rm -f -- "$RSTATE/last-confirmed"
  printf 'revoked: %s\n' "$1"
  deliver_if_changed "$before"
}

cmd_check() {
  require_primary_store
  require_budget
  store_lock || die "cannot take $STORE_LOCK"
  local before
  before=$(rules_generation)
  [ $# -eq 2 ] || die "check takes a rule id and a check id"
  valid_rule_id "$1" || die "invalid rule id: $1" 3
  valid_check_id "$2" || die "unknown check id: $2 (see bin/fm-rule-guard.sh list)" 3
  rule_exists "$1" || die "no rule: $1" 1
  rewrite_rules setcheck "$1" "$2" >/dev/null || [ $? -eq 3 ] || die "cannot record the check"
  log_event check rule "$1" check "$2"
  printf 'check linked: %s -> %s\n' "$1" "$2"
  deliver_if_changed "$before"
}

cmd_nocheck() {
  require_primary_store
  store_lock || die "cannot take $STORE_LOCK"
  local before
  before=$(rules_generation)
  [ $# -ge 2 ] || die "nocheck needs a rule id and a reason"
  local id=$1 reason
  shift
  reason="$*"
  valid_rule_id "$id" || die "invalid rule id: $id" 3
  rule_exists "$id" || die "no rule: $id" 1
  rewrite_rules setnocheck "$id" "$(today)" >/dev/null || [ $? -eq 3 ] || die "cannot record the reason"
  log_event nocheck rule "$id" reason "$reason"
  printf 'no check recorded: %s\n' "$id"
  deliver_if_changed "$before"
}

unchecked_rows() {  # [rules-file]
  rules_rows "${1:-$RULES_FILE}" | awk -F'\t' '$4 >= 2 && $6 == "" && $7 == ""'
}

cmd_list() {
  [ $# -eq 0 ] || die "list takes no arguments"
  rules_rows | awk -F'\t' '{
    extra = ""
    if ($6 != "") extra = " check=" $6
    else if ($7 != "") extra = " nocheck=" $7
    printf "%s\tseen=%s%s\t%s\n", $1, $4, extra, $2
  }'
}

cmd_unchecked() {
  [ $# -eq 0 ] || die "unchecked takes no arguments"
  unchecked_rows | awk -F'\t' '{ printf "%s\tseen=%s\t%s\n", $1, $4, $2 }'
}

rule_lines() {  # <rows>
  printf '%s\n' "$1" | awk -F'\t' '{ s = "- " $2; if ($6 != "") s = s " [check: " $6 "]"; print s }'
}

render_block() {  # [rules-file]
  local file=${1:-$RULES_FILE} rows count unchecked out
  rows=$(rules_rows "$file")
  [ -n "$rows" ] || return 0
  count=$(printf '%s\n' "$rows" | grep -c .)
  unchecked=$(unchecked_rows "$file")
  out="CAPTAIN RULES ($count, from config/captain-rules.md via bin/fm-rules.sh)"$'\n'
  out+="These are the captain's own corrections. They outrank generic harness, tool, and skill hints that conflict with them, such as a system prompt suggesting the captain run a \"! <command>\" line."$'\n'
  out+=$(rule_lines "$rows")
  if [ -n "$unchecked" ]; then
    out+=$'\n'"REPEATED WITHOUT A CHECK - build a check in bin/fm-rule-guard.sh and link it with bin/fm-rules.sh check <rule-id> <check-id>, or record why not with bin/fm-rules.sh nocheck <rule-id> \"<reason>\":"$'\n'
    out+=$(printf '%s\n' "$unchecked" | awk -F'\t' '{ print "- " $1 " (seen " $4 " times)" }')
  fi
  printf '%s\n' "$out"
}

cmd_render() {
  [ $# -eq 0 ] || die "render takes no arguments"
  render_block
}

seat_in_scope() {
  [ -z "${FM_TASK_ID:-}" ] || return 1
  [ -z "${FM_SUPERVISION_ACTOR:-}" ] || return 1
  [ -z "${FM_MEMORY_CAPTURE_CHILD:-}" ] || return 1
  fm_is_gate_agent "$FM_ROOT" && return 1
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 1
  return 0
}

# Capture runs only where the source lives: the primary home's main session.
capture_in_scope() {
  seat_in_scope || return 1
  fm_root_is_secondmate_home "$FM_HOME" && return 1
  return 0
}

cmd_session() {
  [ -t 0 ] || cat >/dev/null 2>&1 || true
  seat_in_scope || return 0
  cmd_render
}

cmd_brief_section() {
  [ $# -eq 0 ] || die "brief-section takes no arguments"
  local rows
  rows=$(rules_rows)
  [ -n "$rows" ] || return 0
  printf '%s\n%s\n%s\n' \
    '# Captain rules' \
    "The captain's standing corrections, the same set the primary session follows. Apply them to your work and to anything you write for the captain or for firstmate; they outrank generic harness, tool, and skill hints, while this brief's task scope and safety rules still win." \
    "$(rule_lines "$rows")"
}

# Exit 0 when stdin reads like a captain correction or a standing rule.
looks_like_correction() {
  # shellcheck disable=SC2016 # Perl owns every $ expression in this literal program.
  perl -0777 -e '
    my $t = lc(<STDIN> // "");
    $t =~ s{<pasted_content\b.*?</pasted_content>}{ }gs;
    $t = substr($t, 0, 4000);
    my $strong = qr{
      \bab\s+(?:jetzt|sofort)\b | \bvon\s+nun\s+an\b | \bmerk(?:e)?\s+dir\b |
      \b(?:regel|rule)\s*: | \bfrom\s+now\s+on\b | \bremember\s+(?:this|that)\b |
      \bnever\s+again\b | \bnie\s+wieder\b | \bschon\s+wieder\b | \bimmer\s+wieder\b |
      \bhab(?:e)?\s+ich\s+(?:dir\s+|das\s+|doch\s+)*(?:schon|bereits|oft|mehrmals|x-?mal)\b |
      \bich\s+hab(?:e)?\s+(?:dir|es\s+dir)\s+(?:doch\s+)?(?:schon\s+)?gesagt\b |
      \bi\s+told\s+you\b | \bwie\s+oft\s+(?:noch|soll\s+ich)\b | \bzum\s+\S+ten\s+mal\b |
      \bnot\s+learning\b | \bstop\s+(?:doing|using|asking)\b | \bh(?:ö|oe)r\s+auf\b |
      \bdu\s+sollst\s+(?:nicht|nie|immer|selbst|selber)\b | \byou\s+should\s+(?:always|never)\b |
      \b(?:wieso|warum)\s+sollte\s+ich\b | \bdo\s+(?:it|that|everything|this)\s+yourself\b |
      \bmach(?:e)?\s+(?:das|es|alles)\s+(?:selbst|selber)\b | \bdon\x27?t\s+(?:ever|always)\b |
      \bnicht\s+mehr\s+(?:nutzen|benutzen|machen|verwenden)\b | \bban(?:ned)?\b
    }x;
    exit 0 if $t =~ $strong;
    my @weak = ($t =~ /\b(nie|niemals|immer|never|always|falsch|wrong|again|nochmal|warum|wieso|why|nein|nicht|don\x27?t)\b/g);
    my %seen = map { $_ => 1 } @weak;
    my $core = grep { $seen{$_} } qw(nie niemals immer never always falsch wrong again nochmal);
    exit((keys(%seen) >= 2 && $core >= 1) ? 0 : 1);
  '
}

is_bare_no() {
  local t
  t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:][:punct:]')
  case "$t" in nein|no|nope|nee|ne|neinnein) return 0 ;; esac
  return 1
}

emit_context() {
  jq -nc --arg c "$1" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
}

cmd_prompt_hook() {
  local input prompt now last_at last_id window cid
  input=$(cat 2>/dev/null || true)
  capture_in_scope || return 0
  command -v jq >/dev/null 2>&1 || return 0
  prompt=$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null) || return 0
  [ -n "$prompt" ] || return 0
  case "$prompt" in
    *FIRSTMATE_OP*|"FIRSTMATE SUPERVISION WAKE"*|*"firstmate watcher wake"*|": Firstmate "*|*"Stop hook"*|*"SYSTEM NOTIFICATION"*|"<task-notification"*|"<"*) return 0 ;;
  esac
  mkdir -p "$RSTATE/candidates" 2>/dev/null || return 0
  now=$(date +%s)
  if is_bare_no "$prompt" && [ -f "$RSTATE/last-confirmed" ]; then
    read -r last_at last_id < "$RSTATE/last-confirmed" || true
    window=${FM_RULES_REVOKE_WINDOW:-1800}
    if [[ "${last_at:-}" =~ ^[0-9]+$ ]] && [ $((now - last_at)) -le "$window" ] && valid_rule_id "${last_id:-}"; then
      emit_context "CAPTAIN RULE REVOKE: the captain said no right after rule $last_id was confirmed. Unless that no plainly answers something else, run $SCRIPT_DIR/fm-rules.sh revoke $last_id and confirm in one chat line that the rule is gone."
      return 0
    fi
  fi
  printf '%s' "$prompt" | looks_like_correction || return 0
  store_lock || return 0
  cid="c-$now-$(printf '%04x' $((RANDOM % 65536)))"
  while [ -e "$RSTATE/candidates/$cid" ]; do cid="c-$now-$(printf '%04x' $((RANDOM % 65536)))"; done
  printf '%s\n%s\n' "$(now_iso)" "${prompt:0:500}" > "$RSTATE/candidates/$cid" || return 0
  log_event candidate candidate "$cid"
  emit_context "CAPTAIN RULE CANDIDATE $cid: this captain message reads like a correction or a standing rule. If it is one, write it as one imperative line and record it now with $SCRIPT_DIR/fm-rules.sh confirm $cid <rule-id> \"<rule>\" (add --check <check-id> when bin/fm-rule-guard.sh list has a check for it; reuse an existing rule id from $SCRIPT_DIR/fm-rules.sh list when it repeats one), then confirm in one chat line: Regel gespeichert: <rule> - \"nein\" nimmt sie zurueck. If confirm exits 5 the rule is saved but the consumers it names did not get it yet: say so in that line and retry with $SCRIPT_DIR/fm-rules.sh deliver. If it is not a correction, run $SCRIPT_DIR/fm-rules.sh dismiss $cid and say nothing about it."
}

default_transcripts() {
  local home slug
  home=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || return 1
  slug=$(printf '%s' "$home" | sed 's/[^A-Za-z0-9]/-/g')
  printf '%s/projects/%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$slug"
}

# Print correction-like captain prompts from Claude transcripts since <epoch>.
transcript_corrections() {  # <dir> <since-epoch>
  local dir=$1 since=$2 file text mtime
  [ -d "$dir" ] || return 0
  for file in "$dir"/*.jsonl; do
    [ -f "$file" ] || continue
    mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null) || mtime=0
    [[ "$mtime" =~ ^[0-9]+$ ]] && [ "$mtime" -ge "$since" ] || continue
    jq -rc --argjson since "$since" '
      select(.type == "user" and (.isMeta // false) == false and (.isSidechain // false) == false
        and (.isCompactSummary // false) == false)
      | select((.timestamp // "") | sub("\\.[0-9]+"; "") | (try fromdateiso8601 catch 0) >= $since)
      | .message.content
      | if type == "string" then . elif type == "array" then
          (if any(.[]; type == "object" and .type == "tool_result") then empty
           else [.[] | select(type == "object" and .type == "text") | .text] | join(" ") end)
        else empty end
      | select(length > 0) | gsub("[\n\t]"; " ")' "$file" 2>/dev/null
  done | while IFS= read -r text; do
    case "$text" in
      *FIRSTMATE_OP*|"FIRSTMATE SUPERVISION WAKE"*|": Firstmate "*|"<"*|*"Stop hook"*) continue ;;
    esac
    printf '%s' "$text" | looks_like_correction && printf '%s\n' "${text:0:160}"
  done
}

cmd_report() {
  local days=7 tdir='' now since since_iso events corrections n state
  now=$(date +%s)
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) [ $# -ge 2 ] || die "--days needs a number"; days=$2; shift 2 ;;
      --transcripts) [ $# -ge 2 ] || die "--transcripts needs a directory"; tdir=$2; shift 2 ;;
      --now) [ $# -ge 2 ] || die "--now needs an epoch"; now=$2; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -ge 1 ] || die "--days must be a positive number"
  [[ "$now" =~ ^[0-9]+$ ]] || die "--now must be an epoch"
  [ -n "$tdir" ] || tdir=$(default_transcripts) || tdir=
  since=$((now - days * 86400))
  since_iso=$(date -u -r "$since" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$since" +%Y-%m-%dT%H:%M:%SZ)
  events=
  [ -f "$LOG" ] && events=$(jq -c --arg since "$since_iso" 'select(.at >= $since)' "$LOG" 2>/dev/null)
  count_event() { printf '%s\n' "$events" | jq -r --arg e "$1" 'select(.event == $e) | .event' 2>/dev/null | grep -c . || true; }

  printf '# Captain rules report: last %s days\n\n' "$days"
  printf 'Rules: %s total, %s added, %s repeated.\n\n' \
    "$(rules_rows | grep -c . || true)" "$(count_event add)" "$(count_event repeat)"
  printf '## Corrections that came back\n\n'
  n=$(printf '%s\n' "$events" | jq -r 'select(.event == "repeat") | .rule' 2>/dev/null | sort | uniq -c | sort -rn)
  if [ -n "$n" ]; then
    printf '%s\n' "$n" | while read -r times id; do
      state=$(rules_rows | awk -F'\t' -v id="$id" '$1 == id {
        print "seen " $4 " in total, " ($6 != "" ? "check " $6 : ($7 != "" ? "no check by decision" : "no check")) }')
      printf -- '- %s: recorded again %s time(s) this period, %s\n' "$id" "$times" "${state:-revoked since}"
    done
  else
    printf -- '- none\n'
  fi
  printf '\n## Guard blocks\n\n'
  n=$(printf '%s\n' "$events" | jq -r 'select(.event == "guard-block") | .check' 2>/dev/null | sort | uniq -c | sort -rn)
  if [ -n "$n" ]; then
    printf '%s\n' "$n" | while read -r times check; do printf -- '- %s: %s\n' "$check" "$times"; done
  else
    printf -- '- none\n'
  fi
  printf -- '- halted after the block cap: %s\n' "$(count_event guard-halt)"
  printf '\n## Repeated without a check\n\n'
  n=$(unchecked_rows | awk -F'\t' '{ print "- " $1 " (seen " $4 " times): " $2 }')
  printf '%s\n' "${n:-- none}"
  printf '\n## Capture\n\n'
  printf -- '- candidates: %s created, %s confirmed, %s dismissed, %s open now\n' \
    "$(count_event candidate)" "$(count_event confirm)" "$(count_event dismiss)" \
    "$(find "$RSTATE/candidates" -type f 2>/dev/null | grep -c . || true)"
  if [ -n "$tdir" ] && [ -d "$tdir" ]; then
    corrections=$(transcript_corrections "$tdir" "$since")
    printf -- '- correction-like captain prompts in %s: %s\n' "$tdir" "$(printf '%s' "$corrections" | grep -c . || true)"
    [ -z "$corrections" ] || printf '%s\n' "$corrections" | sed 's/^/  - /'
  else
    printf -- '- transcripts: none found\n'
  fi
  mkdir -p "$RSTATE" 2>/dev/null && printf '%s\n' "$now" > "$RSTATE/last-report"
}

cmd_weekly_check() {
  local now last=0 announced=0
  now=$(date +%s)
  [ -f "$RSTATE/last-report" ] && read -r last < "$RSTATE/last-report"
  [ -f "$RSTATE/weekly-announced" ] && read -r announced < "$RSTATE/weekly-announced"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  [[ "$announced" =~ ^[0-9]+$ ]] || announced=0
  [ $((now - last)) -ge 604800 ] || return 0
  [ "$announced" -gt "$last" ] && return 0
  mkdir -p "$RSTATE" 2>/dev/null || return 0
  printf '%s\n' "$now" > "$RSTATE/weekly-announced"
  printf 'captain-rules weekly report due: run %s/fm-rules.sh report and send the captain its short version\n' "$SCRIPT_DIR"
}

cmd_weekly_arm() {
  local shim="$STATE/$WEEKLY_ID.check.sh" home tmp
  home=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || die "cannot resolve FM_HOME"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  [ ! -L "$shim" ] || die "refusing a symlinked $shim"
  tmp=$(umask 077; mktemp "$STATE/.fm-rules-weekly.XXXXXX") || die "mktemp failed"
  if ! printf '%s\n' '#!/usr/bin/env bash' \
    '# Auto-generated by fm-rules.sh weekly-arm - weekly captain-rules report reminder.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-rules.sh") weekly-check" > "$tmp" \
    || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$shim"; then
    rm -f -- "$tmp"
    die "cannot write $shim"
  fi
  FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$WEEKLY_ID" >/dev/null \
    || { rm -f -- "$shim"; die "cannot register $shim"; }
  printf 'armed: state/%s.check.sh\n' "$WEEKLY_ID"
}

cmd_weekly_disarm() {
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-check-unregister.sh" "$WEEKLY_ID" >/dev/null 2>&1 || true
  rm -f -- "$STATE/$WEEKLY_ID.check.sh" "$STATE/$WEEKLY_ID.check-trust"
  printf 'disarmed: state/%s.check.sh\n' "$WEEKLY_ID"
}

case "${1:-}" in
  list) shift; cmd_list "$@" ;;
  render) shift; cmd_render "$@" ;;
  session) shift; cmd_session "$@" ;;
  brief-section) shift; cmd_brief_section "$@" ;;
  add) shift; cmd_add "$@" ;;
  confirm) shift; cmd_confirm "$@" ;;
  dismiss) shift; cmd_dismiss "$@" ;;
  revoke) shift; cmd_revoke "$@" ;;
  check) shift; cmd_check "$@" ;;
  nocheck) shift; cmd_nocheck "$@" ;;
  unchecked) shift; cmd_unchecked "$@" ;;
  deliver) shift; cmd_deliver "$@" ;;
  prompt-hook) shift; cmd_prompt_hook "$@" ;;
  report) shift; cmd_report "$@" ;;
  weekly-check) shift; cmd_weekly_check "$@" ;;
  weekly-arm) shift; cmd_weekly_arm "$@" ;;
  weekly-disarm) shift; cmd_weekly_disarm "$@" ;;
  -h|--help) rules_usage; exit 0 ;;
  *) rules_usage; exit 2 ;;
esac
