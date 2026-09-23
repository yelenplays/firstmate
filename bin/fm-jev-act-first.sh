#!/usr/bin/env bash
# fm-jev-act-first.sh - advisory Jev ranking of what to act on first at startup.
#
# Usage:
#   fm-jev-act-first.sh --drain-file <path> [--status-dir <dir>] [--local]
#
# Two production callers, both fed the wake-drain output of one locked session
# start. bin/fm-session-start.sh runs --local, which never calls Jev or the
# network: it prints the items below in their fixed priority order as the
# digest's ACT FIRST section right after the wake queue. The deferred startup
# network stage (bin/fm-startup-network.sh) runs the Jev ranking off the
# digest's blocking path and reports it with its other deferred checks. It is
# advisory only: it never acknowledges a wake, answers a decision, steers,
# dispatches, or edits any record, and every item it ranks is already part of
# this digest.
#
# Items (no model call), in this order, at most 12, each capped to 160
# characters:
#   decision   every line of the drain's OPEN DECISIONS section
#   execution  every task/owner/next-action row of UNFINISHED EXECUTION
#   status     the newest line of each state/<id>.status in --status-dir whose
#              task still has state/<id>.meta, when that line is failed: or
#              blocked:
#   wake       every raw wake record (epoch, seq, kind, key, payload)
# One task in one state is one item: a blocker that appears as an open
# decision, a status line, and a status wake is kept once, as its
# highest-priority form. Fewer than two items makes no call: there is nothing
# to rank.
#
# What Jev sees (one Choice call through bin/fm-jev-lib.sh): the items above,
# each sanitized by fm_jev_compact_state, as criteria keyed i1..iN. The Choice
# probabilities are the ranking; malformed probabilities fall back to the
# single pick. No status log body, brief, report, or backlog body is sent.
#
# Output (stdout): at most five lines. --local prints `<rank>. <item>` in the
# priority order above whenever there are at least two items. Otherwise, only
# on a usable Jev answer, `<rank>. <item> (p=<probability>)`, and nothing at all
# when Jev is off (no key), the call fails, or the answer is malformed. Fewer
# than two items prints nothing in either mode, so a caller can print a section
# only when this helper printed something. The caller owns the time bound;
# JEV_TIMEOUT is used as given. Exit 0 except usage (exit 2).
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
LOCAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --drain-file) [ $# -ge 2 ] || die "--drain-file needs a path"; DRAIN_FILE=$2; shift 2 ;;
    --status-dir) [ $# -ge 2 ] || die "--status-dir needs a path"; STATUS_DIR=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
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

# Drain items as kind<TAB>identity<TAB>text, grouped decision, execution, wake.
# The identity is task|state where the line names both, so one task in one
# state collapses to its first (highest-priority) item; otherwise it is the text.
drain_items() {
  awk -F '\t' '
    /^OPEN DECISIONS \(/ { sec = "decision"; next }
    /^OPEN DECISIONS:/ { sec = ""; next }
    /^UNFINISHED EXECUTION \(/ { sec = "execution"; next }
    /^[A-Z][A-Z ]+[ (:]/ && $0 !~ /\t/ { sec = ""; next }
    function verb(s) { sub(/^\[[^]]*\][[:space:]]*/, "", s); sub(/[[:space:]]*(\[|:).*$/, "", s); return s }
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && NF >= 5 {
      p = $5
      for (i = 6; i <= NF; i++) p = p " " $i
      wake[++nw] = "wake " $3 " " $4 (p == "" ? "" : ": " p)
      wid[nw] = wake[nw]
      if ($3 == "signal" && $4 ~ /\.status$/ && p ~ /^[a-z-]+( \[[^]]*\])?:/) {
        t = $4
        sub(/\.status$/, "", t)
        wid[nw] = t "|" verb(p)
      }
      next
    }
    sec == "decision" && NF == 1 && $0 != "" {
      dec[++nd] = "decision " $0
      rest = $0
      sub(/^[^ ]+ /, "", rest)
      did[nd] = $0
      sub(/ .*/, "", did[nd])
      did[nd] = did[nd] "|" verb(rest)
      next
    }
    sec == "execution" && NF == 3 { exe[++ne] = "execution " $1 " owner=" $2 " next=" $3; eid[ne] = exe[ne]; next }
    END {
      for (i = 1; i <= nd; i++) print "decision\t" did[i] "\t" dec[i]
      for (i = 1; i <= ne; i++) print "execution\t" eid[i] "\t" exe[i]
      for (i = 1; i <= nw; i++) print "wake\t" wid[i] "\t" wake[i]
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
      failed:*|failed\ \[*) printf 'status\t%s|failed\tstatus %s %s\n' "$task" "$task" "$last" ;;
      blocked:*|blocked\ \[*) printf 'status\t%s|blocked\tstatus %s %s\n' "$task" "$task" "$last" ;;
    esac
  done
}

items='[]'
n=0
seen_ids=$'\n'
while IFS=$(printf '\t') read -r kind identity text; do
  [ -n "$text" ] || continue
  case "$seen_ids" in
    *$'\n'"$identity"$'\n'*) continue ;;
  esac
  seen_ids="$seen_ids$identity"$'\n'
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
if [ "$LOCAL" -eq 1 ]; then
  jq -r --argjson max "$SHOW_MAX" '.[:$max] | to_entries[] | "\(.key + 1). \(.value.text)"' <<<"$items"
  exit 0
fi
fm_jev_key_configured || exit 0

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
