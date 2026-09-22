#!/usr/bin/env bash
# fm-jev-act-first.sh - advisory Jev ranking of what to act on first at startup.
#
# Usage:
#   fm-jev-act-first.sh --drain-file <path> [--status-dir <dir>]
#
# bin/fm-session-start.sh is the production caller: on the locked path it
# hands this helper the wake-drain output it already printed, and prints what
# comes back as its bounded ACT FIRST section right after the wake queue. It is
# advisory only: it never acknowledges a wake, answers a decision, steers,
# dispatches, or edits any record, and every item it ranks was already printed
# in full above it.
#
# Items (no model call), in this order, at most 12, each capped to 160
# characters:
#   decision   every line of the drain's OPEN DECISIONS section
#   execution  every task/owner/next-action row of UNFINISHED EXECUTION
#   status     the newest line of each state/<id>.status in --status-dir whose
#              task still has state/<id>.meta, when that line is failed: or
#              blocked:
#   wake       every raw wake record (epoch, seq, kind, key, payload)
# Fewer than two items makes no call: there is nothing to rank.
#
# What Jev sees (one Choice call through bin/fm-jev-lib.sh): the items above,
# each sanitized by fm_jev_compact_state, as criteria keyed i1..iN. The Choice
# probabilities are the ranking; malformed probabilities fall back to the
# single pick. No status log body, brief, report, or backlog body is sent.
#
# Output (stdout), only on a usable answer: at most five lines,
#   <rank>. <item> (p=<probability>)
# Nothing at all when Jev is off (no key), the call fails, the answer is
# malformed, or there are fewer than two items, so the caller can print the
# section only when this helper printed something. The caller owns the hard
# time bound; JEV_TIMEOUT is used as given. Exit 0 except usage (exit 2).
#
# Log: one JSONL object per attempted call appended to
# ${FM_STATE_OVERRIDE:-$FM_HOME/state}/jev-act-first.jsonl with
# purpose=act-first, advisory=true, item_count, offered item kinds, choice,
# confidence, ranked item keys, route, http, latency_ms, decide_code, ts.
# Secrets follow fm_jev_log_call redaction.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, plus the Jev library keys and
# JEV_* settings documented in bin/fm-jev-lib.sh. This script does not roll
# its own HTTP.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'jev-act-first: %s\n' "$1" >&2
  exit 2
}

DRAIN_FILE=
STATUS_DIR=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --drain-file) [ $# -ge 2 ] || die "--drain-file needs a path"; DRAIN_FILE=$2; shift 2 ;;
    --status-dir) [ $# -ge 2 ] || die "--status-dir needs a path"; STATUS_DIR=$2; shift 2 ;;
    *) die "unexpected argument: $1" ;;
  esac
done
[ -n "$DRAIN_FILE" ] || die "usage: fm-jev-act-first.sh --drain-file <path> [--status-dir <dir>]"
[ -r "$DRAIN_FILE" ] || die "drain file is not readable: $DRAIN_FILE"

STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG_PATH="$STATE_DIR/jev-act-first.jsonl"
ITEM_MAX=12
ITEM_CHARS=160
SHOW_MAX=5

command -v jq >/dev/null 2>&1 || exit 0

has_key() {
  local typesafe_key openrouter_key
  typesafe_key=${TYPESAFE_API_KEY:-}
  openrouter_key=${OPENROUTER_API_KEY:-}
  if [ -z "$typesafe_key" ]; then
    typesafe_key=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
  fi
  if [ -z "$openrouter_key" ]; then
    openrouter_key=$(fmx_env_get OPENROUTER_API_KEY "$FM_HOME/.env")
  fi
  [ -n "$typesafe_key" ] || [ -n "$openrouter_key" ]
}
has_key || exit 0

# Drain items as kind<TAB>text, grouped decision, execution, wake.
drain_items() {
  awk -F '\t' '
    /^OPEN DECISIONS \(/ { sec = "decision"; next }
    /^OPEN DECISIONS:/ { sec = ""; next }
    /^UNFINISHED EXECUTION \(/ { sec = "execution"; next }
    /^[A-Z][A-Z ]+[ (:]/ && $0 !~ /\t/ { sec = ""; next }
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && NF >= 5 {
      p = $5
      for (i = 6; i <= NF; i++) p = p " " $i
      wake[++nw] = "wake " $3 " " $4 (p == "" ? "" : ": " p)
      next
    }
    sec == "decision" && NF == 1 && $0 != "" { dec[++nd] = "decision " $0; next }
    sec == "execution" && NF == 3 { exe[++ne] = "execution " $1 " owner=" $2 " next=" $3; next }
    END {
      for (i = 1; i <= nd; i++) print "decision\t" dec[i]
      for (i = 1; i <= ne; i++) print "execution\t" exe[i]
      for (i = 1; i <= nw; i++) print "wake\t" wake[i]
    }
  ' "$DRAIN_FILE"
}

# Newest failed:/blocked: line of each live task's status log.
status_items() {
  local status task last
  [ -n "$STATUS_DIR" ] && [ -d "$STATUS_DIR" ] || return 0
  for status in "$STATUS_DIR"/*.status; do
    [ -f "$status" ] || continue
    task=${status##*/}
    task=${task%.status}
    [ -f "$STATUS_DIR/$task.meta" ] || continue
    last=$(tail -n 1 "$status" 2>/dev/null | tr '\t' ' ')
    case "$last" in
      failed:*|blocked:*|failed\ \[*|blocked\ \[*) printf 'status\tstatus %s %s\n' "$task" "$last" ;;
    esac
  done
}

items='[]'
n=0
while IFS=$(printf '\t') read -r kind text; do
  [ -n "$text" ] || continue
  text=$(fm_jev_compact_state "$text") || continue
  text=${text:0:$ITEM_CHARS}
  if jq -e --arg t "$text" 'any(.[]; .text == $t)' <<<"$items" >/dev/null 2>&1; then
    continue
  fi
  n=$((n + 1))
  items=$(jq -c --arg k "i$n" --arg kind "$kind" --arg t "$text" '. + [{key: $k, kind: $kind, text: $t}]' <<<"$items") || exit 0
  [ "$n" -lt "$ITEM_MAX" ] || break
done < <(
  drain_items | awk -F '\t' '$1 != "wake"'
  status_items
  drain_items | awk -F '\t' '$1 == "wake"'
)
[ "$n" -ge 2 ] || exit 0

state=$(fm_jev_compact_state "$(jq -r '"Actionable items a Firstmate supervisor sees at session start:", (.[] | "\(.key): \(.text)")' <<<"$items")") || exit 0
questions=$(jq -nc --argjson c "$(jq -c 'map({key: .key, value: .text}) | from_entries' <<<"$items")" '{
  first: {
    type: "choice",
    instructions: "Which item should the supervisor act on first? Rank by urgency and by how much other work waits on it: an open captain decision, a failure, or a blocker before routine progress and heartbeat wakes.",
    criteria: $c
  }
}') || exit 0

decide_code=0
mkdir -p "$STATE_DIR" 2>/dev/null || true
response=$(fm_jev_decide "$state" "$questions") || decide_code=$?

choice=
confidence=
ranked='[]'
if [ "$decide_code" -eq 0 ] && [ -n "$response" ]; then
  choice=$(jq -r '.answers.first.choice // empty' <<<"$response" 2>/dev/null)
  confidence=$(jq -r '.answers.first.confidence | select(type == "number") // empty' <<<"$response" 2>/dev/null)
  if [ -n "$choice" ] && jq -e --arg c "$choice" 'any(.[]; .key == $c)' <<<"$items" >/dev/null 2>&1; then
    probs=$(jq -c '.answers.first.probabilities // empty' <<<"$response" 2>/dev/null)
    if [ -n "$probs" ] && fm_jev_probabilities_sum_ok "$probs"; then
      ranked=$(jq -c --argjson p "$probs" '
        map(. + {p: ($p[.key] // 0)}) | map(select(.p > 0)) | sort_by(-.p)
      ' <<<"$items")
    elif [ -n "$confidence" ]; then
      ranked=$(jq -c --arg c "$choice" --arg conf "$confidence" \
        'map(select(.key == $c) | . + {p: ($conf | tonumber)})' <<<"$items")
    fi
  fi
fi

payload=$(jq -nc \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)" \
  --arg choice "$choice" \
  --arg confidence "$confidence" \
  --arg route "${FM_JEV_LAST_ROUTE:-}" \
  --arg http "${FM_JEV_LAST_HTTP:-}" \
  --arg latency "${FM_JEV_LAST_LATENCY_MS:-}" \
  --argjson kinds "$(jq -c '[.[].kind]' <<<"$items")" \
  --argjson ranked "$(jq -c '[.[:5][].key]' <<<"$ranked")" \
  --argjson decide_code "$decide_code" \
  '{
    purpose: "act-first",
    advisory: true,
    item_count: ($kinds | length),
    item_kinds: $kinds,
    choice: (if $choice == "" then null else $choice end),
    confidence: (try ($confidence | tonumber) catch null),
    ranked_keys: $ranked,
    route: $route,
    http: $http,
    latency_ms: (try ($latency | tonumber) catch null),
    decide_code: $decide_code,
    ts: $ts
  }' 2>/dev/null) && fm_jev_log_call "$payload" "$LOG_PATH" || true

jq -r --argjson max "$SHOW_MAX" '
  .[:$max] | to_entries[] | "\(.key + 1). \(.value.text) (p=\(.value.p))"
' <<<"$ranked"
exit 0
