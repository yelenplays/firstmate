#!/usr/bin/env bash
# fm-jev-status-triage.sh - escalation-only Jev read of one status line.
#
# Usage:
#   fm-jev-status-triage.sh        reads the status line on stdin
#
# Prints exactly one verdict word on stdout:
#   escalate  - the captain_relevant Noul met FM_JEV_SUPERVISION_NOUL_FLOOR
#   suppress  - a valid Noul below the floor (the model read it as routine)
# Anything else - a missing key, a Jev error, a non-200, a timeout, a malformed
# answer, an out-of-range Noul - prints no verdict and exits nonzero, so the
# caller's deterministic verdict stands untouched. Exit 2 is usage.
#
# Caller scope: invoke only for a line the bash classifier did NOT already
# accept - a note:/resolved: declaration, a nonstandard verb, or verb-less
# free text (bin/fm-classify-lib.sh status_line_jev_in_scope owns that gate).
# Declared verbs are never re-litigated here, and this helper can only
# escalate or abstain: it has no way to downgrade a line.
#
# Evidence and thresholds: data/jev-supervision-triage-v1/report.md. On the
# 222-line corpus the captain_relevant Noul never missed a needs-decision,
# blocked, or failed line at 0.5 (all >= 0.56) while routine lines sat at
# 0.08-0.30, so 0.5 is the floor. The verb Choice question rides along for
# the JSONL audit trail only; only the Noul gates the verdict.
#
# One bounded HTTP call per invocation through bin/fm-jev-lib.sh. JEV_TIMEOUT
# defaults to FM_JEV_SUPERVISION_TIMEOUT_SECS (3s) because a triage answer
# older than ~2s has lost its value; an explicitly set JEV_TIMEOUT still wins.
# State is the single status line, secret-scrubbed by fm_jev_compact_state.
# Every attempted call appends one JSONL record:
#   ${FM_STATE_OVERRIDE:-$FM_HOME/state}/jev-status-triage.jsonl
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_JEV_SUPERVISION_NOUL_FLOOR,
# FM_JEV_SUPERVISION_TIMEOUT_SECS, plus the Jev library keys and JEV_*
# settings documented in bin/fm-jev-lib.sh. This script does not roll its
# own HTTP.
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
  printf 'jev-status-triage: %s\n' "$1" >&2
  exit 2
}

fail() {
  printf 'jev-status-triage: %s\n' "$1" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
done

line=$(cat)
[ -n "$line" ] || fail "empty status line on stdin"
command -v jq >/dev/null 2>&1 || fail "jq required"

# The supervision-path bound: a triage answer older than ~2s has already lost
# its value (report section 6), so default JEV_TIMEOUT to 3s. An explicit
# JEV_TIMEOUT in the environment still wins.
JEV_TIMEOUT=${JEV_TIMEOUT:-${FM_JEV_SUPERVISION_TIMEOUT_SECS:-3}}
export JEV_TIMEOUT

FLOOR=${FM_JEV_SUPERVISION_NOUL_FLOOR:-0.5}
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG_PATH="$STATE_DIR/jev-status-triage.jsonl"

iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown'
}

log_call() {
  local status=$1 noul=$2 verb_choice=$3 verb_confidence=$4 decide_code=$5
  local payload
  payload=$(jq -nc \
    --arg ts "$(iso_now)" \
    --arg status "$status" \
    --arg noul "$noul" \
    --arg verb_choice "$verb_choice" \
    --arg verb_confidence "$verb_confidence" \
    --arg route "${FM_JEV_LAST_ROUTE:-}" \
    --arg http "${FM_JEV_LAST_HTTP:-}" \
    --arg latency "${FM_JEV_LAST_LATENCY_MS:-}" \
    --arg excerpt "$(printf '%s' "${state:-}" | head -c 200)" \
    --argjson chars "${#line}" \
    --argjson decide_code "$decide_code" \
    '{
      purpose: "status-triage",
      advisory: true,
      escalate_only: true,
      status: $status,
      noul: (try ($noul | tonumber) catch null),
      verb_choice: (if $verb_choice == "" then null else $verb_choice end),
      verb_confidence: (try ($verb_confidence | tonumber) catch null),
      line_chars: $chars,
      line_excerpt: $excerpt,
      route: $route,
      http: $http,
      latency_ms: (try ($latency | tonumber) catch null),
      decide_code: $decide_code,
      ts: $ts
    }' 2>/dev/null) || return 0
  fm_jev_log_call "$payload" "$LOG_PATH" || true
}

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

has_key || fail "off (no TYPESAFE_API_KEY or OPENROUTER_API_KEY)"

state=$(fm_jev_compact_state "$line") || fail "status line exceeds the state cap"

# The exact question pair the evidence corpus measured (jev-status.sh in the
# report directory): a verb Choice for the audit trail, and the
# captain_relevant Noul that gates the verdict.
questions=$(jq -nc '{
  verb: {
    type: "choice",
    instructions: "Classify this Firstmate crewmate status line into exactly one status verb class. Judge by what the line declares about the task, not by its leading token: a line announcing an outcome is done even if it narrates past work, and a line asking for a human decision is needs-decision even if phrased as a question.",
    criteria: {
      working: "Routine progress report: work is under way, nothing terminal, no request for help or decision.",
      done: "Declares a finished outcome: work completed, shipped, merged, verified, or a terminal record of completion.",
      "needs-decision": "Asks for a human/captain decision or presents options that need a human pick before work continues.",
      blocked: "Declares the worker is stuck or cannot proceed: waiting on help, a missing prerequisite, a failed delivery, or an external outage it cannot clear itself.",
      failed: "Declares a terminal failure of the task or a child task.",
      paused: "Declares a deliberate idle wait on a known external dependency expected to clear on its own.",
      resolved: "Closes a previously opened decision or blocker; records the answer or that it cleared.",
      note: "Pure note/observation with no status change requested or implied.",
      "captain-held": "Records that an item was transferred into the durable captain-held backlog.",
      other: "None of the above fits: unrecognizable prose, partial line, or a different declaration."
    }
  },
  captain_relevant: {
    type: "noul",
    instructions: "Is this status line something the supervising firstmate must surface to the human captain - a terminal outcome, a blocker needing help, a decision request, or an explicit hold transfer? Routine progress, routine pauses on declared waits, acknowledgements, and closure lines that only confirm an already-seen resolution are NOT captain-relevant."
  }
}') || fail "jq is required"

decide_code=0
response=
mkdir -p "$STATE_DIR" 2>/dev/null || true
response_file=$(mktemp "$STATE_DIR/jev-status-triage.response.XXXXXX") || fail "mktemp failed"
fm_jev_decide "$state" "$questions" > "$response_file" || decide_code=$?
response=$(cat "$response_file" 2>/dev/null || true)
rm -f "$response_file"

if [ "$decide_code" -ne 0 ] || [ -z "$response" ]; then
  log_call error '' '' '' "$decide_code"
  fail "no verdict (decide_code=$decide_code)"
fi

noul=$(jq -er '
  .answers.captain_relevant.noul | select(type == "number" and . >= 0 and . <= 1)
' <<<"$response" 2>/dev/null) || {
  log_call error '' '' '' "$decide_code"
  fail "invalid noul answer"
}
verb_choice=$(jq -r '.answers.verb.choice // empty' <<<"$response" 2>/dev/null || true)
verb_confidence=$(jq -r '.answers.verb.confidence // empty' <<<"$response" 2>/dev/null || true)

# Gate on the Noul alone: the corpus showed Choice can be confidently wrong
# where the Noul stays calibrated (the dashboard sample, Choice 0.74 vs Noul
# 0.31). A Noul at or above the floor escalates; a valid Noul below it is an
# advisory abstain, reported as suppress.
if awk -v n="$noul" -v f="$FLOOR" 'BEGIN { exit !(n + 0 >= f + 0) }'; then
  verdict=escalate
else
  verdict=suppress
fi
log_call "$verdict" "$noul" "$verb_choice" "$verb_confidence" "$decide_code"
printf '%s\n' "$verdict"
