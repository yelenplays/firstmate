#!/usr/bin/env bash
# fm-jev-wedge-check.sh - second-opinion Jev read of one pane tail.
#
# Usage:
#   fm-jev-wedge-check.sh [--task <id> --state-dir <dir>]
#                                   reads the pane tail on stdin
#
# Prints exactly one verdict word on stdout:
#   escalate  - the stuck Noul met the 0.5 floor
#   suppress  - a valid Noul below the floor (the pane reads as not-stuck)
# Anything else - a missing key, a Jev error, a non-200, a timeout, a malformed
# answer, an out-of-range Noul - prints no verdict and exits nonzero, so the
# caller's structural verdict stands untouched. Exit 2 is usage.
#
# Caller scope: invoke only at the escalation boundary - the moment the
# structural wedge stack has already decided to escalate - never per poll.
# The verdict gate is the Noul alone, never the Choice: the corpus showed a
# pane the Choice confidently misread (0.74 stuck) while its Noul stayed 0.31.
#
# Evidence and thresholds: data/jev-supervision-triage-v1/report.md. On the
# 13-tail labelled corpus, noul >= 0.5 reproduced the intended verdict on
# every sample - the one genuine wedge scored 0.69, healthy idle/busy/dead
# panes stayed at 0.06-0.35 - so 0.5 is the floor.
#
# One bounded HTTP call per invocation through bin/fm-jev-lib.sh. The HTTP
# bound is fm_jev_supervision_timeout: an explicit JEV_TIMEOUT (environment or
# $FM_HOME/.env) wins, else FM_JEV_SUPERVISION_TIMEOUT_SECS (3s), because a
# triage answer older than ~2s has lost its value.
#
# Data boundary (fm_jev_supervision_free_text_ok owns the rule): the pane tail
# itself - its last chars, size-capped and secret-scrubbed - is sent only when
# --task names a firstmate-repository task in the primary home. Every other
# case, including a call with no --task, sends structured facts only
# (fm_jev_supervision_state) and records no text excerpt. Never status files,
# backlog, or report bodies. Every attempted call appends one JSONL record:
#   ${FM_STATE_OVERRIDE:-$FM_HOME/state}/jev-wedge-check.jsonl
#
# Environment: FM_HOME, FM_STATE_OVERRIDE,
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
  printf 'jev-wedge-check: %s\n' "$1" >&2
  exit 2
}

fail() {
  printf 'jev-wedge-check: %s\n' "$1" >&2
  exit 1
}

task_id=
task_state_dir=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --task)
      [ $# -ge 2 ] || die "--task needs a value"
      task_id=$2
      shift 2
      ;;
    --state-dir)
      [ $# -ge 2 ] || die "--state-dir needs a value"
      task_state_dir=$2
      shift 2
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
done

tail_text=$(cat)
[ -n "$tail_text" ] || fail "empty pane tail on stdin"
command -v jq >/dev/null 2>&1 || fail "jq required"

JEV_TIMEOUT=$(fm_jev_supervision_timeout)
export JEV_TIMEOUT

STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG_PATH="$STATE_DIR/jev-wedge-check.jsonl"

log_call() {
  local status=$1 noul=$2 state_choice=$3 state_confidence=$4 decide_code=$5
  local payload
  payload=$(jq -nc \
    --arg ts "$(fm_jev_iso_now)" \
    --arg status "$status" \
    --arg noul "$noul" \
    --arg state_choice "$state_choice" \
    --arg state_confidence "$state_confidence" \
    --arg route "${FM_JEV_LAST_ROUTE:-}" \
    --arg http "${FM_JEV_LAST_HTTP:-}" \
    --arg latency "${FM_JEV_LAST_LATENCY_MS:-}" \
    --arg payload "$payload_mode" \
    --arg excerpt "$excerpt" \
    --argjson chars "${#tail_text}" \
    --argjson decide_code "$decide_code" \
    '{
      purpose: "wedge-check",
      advisory: true,
      second_opinion: true,
      status: $status,
      noul: (try ($noul | tonumber) catch null),
      state_choice: (if $state_choice == "" then null else $state_choice end),
      state_confidence: (try ($state_confidence | tonumber) catch null),
      payload: $payload,
      tail_chars: $chars,
      tail_excerpt: (if $excerpt == "" then null else $excerpt end),
      route: $route,
      http: $http,
      latency_ms: (try ($latency | tonumber) catch null),
      decide_code: $decide_code,
      ts: $ts
    }' 2>/dev/null) || return 0
  fm_jev_log_call "$payload" "$LOG_PATH" || true
}

fm_jev_key_configured || fail "off (no TYPESAFE_API_KEY or OPENROUTER_API_KEY)"

free_text=0
payload_mode=structured
if [ -n "$task_id" ] && fm_jev_supervision_free_text_ok "${task_state_dir:-$STATE_DIR}" "$task_id"; then
  free_text=1
  payload_mode='free-text'
fi
state=$(fm_jev_supervision_state pane-tail "$tail_text" "$free_text") || fail "could not build the pane state"
excerpt=
[ "$free_text" -eq 0 ] || excerpt=$(printf '%s' "$state" | head -c 200)

# The exact question pair the evidence corpus measured (jev-panes.sh in the
# report directory): a state Choice for the audit trail, and the stuck Noul
# that gates the verdict.
questions=$(jq -nc '{
  state: {
    type: "choice",
    instructions: "You see the tail of a terminal pane running an autonomous coding worker under a fleet supervisor. Classify the worker state the pane shows. Judge only this pane content.",
    criteria: {
      genuinely_stuck: "The worker cannot make progress without intervention: it sits on a blocking dialog or quota/permission wall, is dead with unfinished work, loops the same failed action, or ended its turn mid-task with no resolution in sight.",
      working_busy: "The worker is actively producing: running tools, thinking, writing, or mid-turn with evidence of motion.",
      idle_finished: "The worker is at rest in an expected way: turn or task complete, declared wait, awaiting routing, or the endpoint simply holds no agent."
    }
  },
  stuck: {
    type: "noul",
    instructions: "Is this pane tail evidence of a genuinely stuck worker that a supervisor should escalate as a possible wedge right now? Yes only when the pane shows the worker cannot proceed without intervention - a blocking prompt, quota or permission wall, dead endpoint with unfinished work, or a turn that ended mid-task. A quiet pane mid-thought, a finished task, a declared wait, or an idle-but-healthy worker is not stuck."
  }
}') || fail "jq is required"

decide_code=0
response=
mkdir -p "$STATE_DIR" 2>/dev/null || true
response_file=$(mktemp "$STATE_DIR/jev-wedge-check.response.XXXXXX") || fail "mktemp failed"
fm_jev_decide "$state" "$questions" > "$response_file" || decide_code=$?
response=$(cat "$response_file" 2>/dev/null || true)
rm -f "$response_file"

if [ "$decide_code" -ne 0 ] || [ -z "$response" ]; then
  log_call error '' '' '' "$decide_code"
  fail "no verdict (decide_code=$decide_code)"
fi

noul=$(jq -er '
  .answers.stuck.noul | select(type == "number" and . >= 0 and . <= 1)
' <<<"$response" 2>/dev/null) || {
  log_call error '' '' '' "$decide_code"
  fail "invalid noul answer"
}
state_choice=$(jq -r '.answers.state.choice // empty' <<<"$response" 2>/dev/null || true)
state_confidence=$(jq -r '.answers.state.confidence // empty' <<<"$response" 2>/dev/null || true)

# Gate on the Noul alone (see the caller-scope note): a Noul at or above the
# floor escalates as the structural rule intended; a valid Noul below it
# suppresses this structural false positive.
if awk -v n="$noul" 'BEGIN { exit !(n + 0 >= 0.5) }'; then
  verdict=escalate
else
  verdict=suppress
fi
log_call "$verdict" "$noul" "$state_choice" "$state_confidence" "$decide_code"
printf '%s\n' "$verdict"
