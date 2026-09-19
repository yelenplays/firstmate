#!/usr/bin/env bash
# fm-jev-brief-preflight.sh - shadow spawn-path brief completeness check.
#
# Usage:
#   fm-jev-brief-preflight.sh --brief <file> --task <id> \
#     [--kind ship|scout] [--mode <mode>]
#
# bin/fm-spawn.sh runs this after its structural brief refusals and before any
# endpoint exists. It asks Jev one Choice over whether the brief's Task section
# plus recorded delivery contract is executable, logs the answer, and exits.
# Shadow only: a defect, low confidence, missing key, or Jev failure never
# refuses launch. Structural leftovers ({TASK}, empty Task, half-filled
# intent/spec, Captain-addressed intent) stay fm-spawn.sh refusals.
#
# Jev sees only the `# Task` body and `# Definition of done` body (including
# the recorded Delivery contract line). It never receives captain-private
# records, another home's data, page content, excerpts, conflict lines, or
# any key.
#
# Questions (via bin/fm-jev-lib.sh):
#   brief    Choice {complete, missing_acceptance, missing_constraints,
#            ambiguous_scope, need_human}
# Floor 0.7 (fm_jev_choice_confidence_ok / JEV_CONFIDENCE_FLOOR).
# This gate defaults JEV_TIMEOUT to 5 when unset so an outage cannot stall
# spawn; an explicit JEV_TIMEOUT still wins.
#
# Output: silent on complete, skip, failure, and below-floor answers.
# A high-confidence defect prints one stderr warning naming the missing
# element; spawn still proceeds. Exit 0 except usage/config (exit 2).
#
# Log: one JSONL object appended to $FM_HOME/state/<id>.jev-brief-preflight.jsonl
# when Jev was attempted or a verdict was produced. Absent key or
# FM_JEV_BRIEF_PREFLIGHT=off writes nothing. Secrets follow fm_jev_log_call
# redaction. The record always has block=false.
#
# Environment: FM_HOME, FM_JEV_BRIEF_PREFLIGHT (default shadow; off skips),
# plus the Jev library keys and JEV_* settings documented in bin/fm-jev-lib.sh.
# docs/configuration.md "Jev brief preflight" owns the operator contract.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

usage() {
  printf 'Usage: fm-jev-brief-preflight.sh --brief <file> --task <id> [--kind ship|scout] [--mode <mode>]\n' >&2
}

die() {
  printf 'jev-brief-preflight: %s\n' "$1" >&2
  exit 2
}

brief_file=
task_id=
kind=
mode=

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --brief)
      [ $# -ge 2 ] || die "missing value for $1"
      brief_file=$2
      shift 2
      ;;
    --task|--id)
      [ $# -ge 2 ] || die "missing value for $1"
      task_id=$2
      shift 2
      ;;
    --kind)
      [ $# -ge 2 ] || die "missing value for $1"
      kind=$2
      shift 2
      ;;
    --mode)
      [ $# -ge 2 ] || die "missing value for $1"
      mode=$2
      shift 2
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
done

[ -n "$brief_file" ] || { usage; die "--brief is required"; }
[ -n "$task_id" ] || { usage; die "--task is required"; }
case "$task_id" in
  *[^-A-Za-z0-9._:]*) die "invalid task id" ;;
esac
case "$kind" in
  ''|ship|scout) ;;
  *) die "kind must be ship or scout" ;;
esac
[ -f "$brief_file" ] && [ -r "$brief_file" ] || die "brief file not readable: $brief_file"

# Off is silent and writes nothing, matching an absent key.
case "${FM_JEV_BRIEF_PREFLIGHT:-shadow}" in
  off|0|false|no)
    exit 0
    ;;
esac

typesafe_key=${TYPESAFE_API_KEY:-}
openrouter_key=${OPENROUTER_API_KEY:-}
if [ -z "$typesafe_key" ]; then
  typesafe_key=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
fi
if [ -z "$openrouter_key" ]; then
  openrouter_key=$(fmx_env_get OPENROUTER_API_KEY "$FM_HOME/.env")
fi
if [ -z "$typesafe_key" ] && [ -z "$openrouter_key" ]; then
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

# Bound this gate so a hung API cannot stall spawn. An explicit JEV_TIMEOUT wins.
if [ -z "${JEV_TIMEOUT:-}" ]; then
  JEV_TIMEOUT=5
fi

task_body=$(fm_brief_heading_body "$brief_file" "# Task")
dod_body=$(fm_brief_heading_body "$brief_file" "# Definition of done")
delivery=$(printf '%s\n' "$dod_body" | sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' | head -n 1)
[ -n "$delivery" ] || delivery=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$brief_file" | head -n 1)

state=$(jq -n \
  --arg task_id "$task_id" \
  --arg kind "$kind" \
  --arg mode "$mode" \
  --arg delivery "$delivery" \
  --arg task "$task_body" \
  --arg dod "$dod_body" \
  '{
    task_id: $task_id,
    kind: $kind,
    delivery_mode: (if $mode == "" then $delivery else $mode end),
    recorded_delivery: $delivery,
    task: $task,
    definition_of_done: $dod
  }') || exit 0

compacted=
if ! compacted=$(fm_jev_compact_state "$state"); then
  state=$(jq -n \
    --arg task_id "$task_id" \
    --arg kind "$kind" \
    --arg mode "$mode" \
    --arg delivery "$delivery" \
    --arg task "$(printf '%s' "$task_body" | head -c 4000)" \
    '{
      task_id: $task_id,
      kind: $kind,
      delivery_mode: (if $mode == "" then $delivery else $mode end),
      recorded_delivery: $delivery,
      task: $task,
      definition_of_done: "(omitted)"
    }') || exit 0
  compacted=$(fm_jev_compact_state "$state") || compacted=$state
fi

questions=$(jq -nc '{
  brief: {
    type: "choice",
    instructions: "Judge whether this worker brief is executable. Read only `task` and `definition_of_done` (and delivery_mode). Pick complete when the task has an observable outcome, acceptance or a definition of done, and consistent constraints. Pick missing_acceptance when acceptance criteria or a definition of done are absent. Pick missing_constraints when bounds or out-of-scope limits are absent. Pick ambiguous_scope when the ask is too vague or contradictory to have one observable outcome. Pick need_human when this text cannot decide. Never use private records or secrets.",
    criteria: {
      complete: "The Task plus delivery contract is executable: observable outcome, acceptance or definition of done, and consistent constraints.",
      missing_acceptance: "No acceptance criteria and no definition of done an observer could check.",
      missing_constraints: "No constraints, bounds, or out-of-scope limits.",
      ambiguous_scope: "Vague or contradictory requirements; no single observable outcome.",
      need_human: "A human must inspect; this text cannot decide completeness."
    }
  }
}') || exit 0

missing_element() {
  case "$1" in
    missing_acceptance) printf '%s' 'acceptance criteria or definition of done' ;;
    missing_constraints) printf '%s' 'constraints or out-of-scope boundary' ;;
    ambiguous_scope) printf '%s' 'unambiguous observable outcome' ;;
    need_human) printf '%s' 'human review of brief completeness' ;;
    *) printf '%s' '' ;;
  esac
}

verdict=skipped
confidence=
missing=
surfaced=no
probabilities='{}'
decide_code=0
response=
decide_err=$(mktemp) || exit 0
response=$(fm_jev_decide "$compacted" "$questions" 2>"$decide_err") || decide_code=$?
rm -f "$decide_err"

if [ "$decide_code" -eq 0 ] && [ -n "$response" ]; then
  choice=$(printf '%s' "$response" | jq -r '.answers.brief.choice // empty')
  confidence=$(printf '%s' "$response" | jq -r '.answers.brief.confidence // empty')
  probabilities=$(printf '%s' "$response" | jq -c '.answers.brief.probabilities // {}')
  case "$choice" in
    complete|missing_acceptance|missing_constraints|ambiguous_scope|need_human)
      if [ -n "$probabilities" ] && [ "$probabilities" != '{}' ] &&
        ! fm_jev_probabilities_sum_ok "$probabilities"; then
        verdict=skipped
        confidence=
      else
        verdict=$choice
        missing=$(missing_element "$choice")
      fi
      ;;
    *)
      verdict=skipped
      confidence=
      ;;
  esac
  if [ "$verdict" != complete ] && [ "$verdict" != skipped ] &&
    [ -n "$confidence" ] && fm_jev_choice_confidence_ok "$confidence"; then
    surfaced=yes
    printf 'warning: brief preflight: %s is missing %s (jev %s confidence=%s); spawn continues\n' \
      "$brief_file" "$missing" "$verdict" "$confidence" >&2
  fi
fi

log_path="$FM_HOME/state/${task_id}.jev-brief-preflight.jsonl"
mkdir -p "$FM_HOME/state" || exit 0
log_payload=$(jq -nc \
  --arg task "$task_id" \
  --arg kind "$kind" \
  --arg mode "$mode" \
  --arg verdict "$verdict" \
  --arg missing "$missing" \
  --arg confidence "$confidence" \
  --arg surfaced "$surfaced" \
  --arg route "${FM_JEV_LAST_ROUTE:-}" \
  --arg model "${FM_JEV_LAST_MODEL:-}" \
  --arg http "${FM_JEV_LAST_HTTP:-}" \
  --arg latency "${FM_JEV_LAST_LATENCY_MS:-}" \
  --argjson decide_code "$decide_code" \
  --argjson probabilities "$probabilities" \
  '{
    purpose: "brief-preflight",
    task: $task,
    kind: $kind,
    mode: $mode,
    verdict: $verdict,
    missing: $missing,
    confidence: (try ($confidence | tonumber) catch null),
    probabilities: (if ($probabilities | type) == "object" then $probabilities else {} end),
    surfaced: ($surfaced == "yes"),
    shadow: true,
    block: false,
    route: $route,
    model: $model,
    http: $http,
    latency_ms: (try ($latency | tonumber) catch null),
    decide_code: $decide_code
  }') || exit 0
fm_jev_log_call "$log_payload" "$log_path" || true
exit 0
