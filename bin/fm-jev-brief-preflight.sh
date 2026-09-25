#!/usr/bin/env bash
# fm-jev-brief-preflight.sh - shadow spawn-path brief completeness check.
#
# Usage:
#   fm-jev-brief-preflight.sh --brief <file> --task <id> \
#     [--kind ship|scout] [--mode <mode>]
#
# bin/fm-spawn.sh runs this after its structural brief refusals and before any
# endpoint exists. It reads the brief's structural facts (worker kind, recorded
# delivery, and whether Task, Definition of done, Captain's intent, and
# Firstmate spec are present), applies fm_brief_preflight_verdict from
# bin/fm-dod-lib.sh, logs, and exits. The verdict is deterministic and local:
# no model or network call is made. The name keeps its Jev prefix because the
# check began as a Jev call whose recorded answers the rule reproduces.
# Shadow only: a defect never refuses launch. Structural leftovers ({TASK},
# empty Task, half-filled intent/spec, Captain-addressed intent) stay
# fm-spawn.sh refusals.
#
# Verdicts: missing_acceptance when the Definition of done is missing,
# otherwise need_human (structure alone cannot prove a brief complete).
#
# Output: silent on need_human and on skips. missing_acceptance prints one
# stderr warning naming the missing element; spawn still proceeds.
# Exit 0 except usage (exit 2).
#
# Log: one JSONL object appended to $FM_HOME/state/<id>.jev-brief-preflight.jsonl
# per verdict: purpose, task, kind, mode, verdict, missing, surfaced,
# shadow=true, block=false, and rule=deterministic.
# FM_JEV_BRIEF_PREFLIGHT=off, unrecognized delivery metadata, or a missing jq
# writes nothing.
#
# Environment: FM_HOME, FM_JEV_BRIEF_PREFLIGHT (default shadow; off skips).
# docs/configuration.md "Brief preflight" owns the operator contract.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

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
    --task)
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

case "${FM_JEV_BRIEF_PREFLIGHT:-shadow}" in
  off)
    exit 0
    ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

task_body=$(fm_brief_heading_body "$brief_file" "# Task")
dod_body=$(fm_brief_heading_body "$brief_file" "# Definition of done")
delivery=$(printf '%s\n' "$dod_body" | sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' | head -n 1)
[ -n "$delivery" ] || delivery=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$brief_file" | head -n 1)
case "$mode" in ''|direct-PR|local-only|no-mistakes) ;; *) exit 0 ;; esac
case "$delivery" in ''|direct-PR|local-only|no-mistakes) ;; *) exit 0 ;; esac
has_task=false
has_dod=false
has_intent=false
has_spec=false
[[ "$task_body" =~ [^[:space:]] ]] && has_task=true
[[ "$dod_body" =~ [^[:space:]] ]] && has_dod=true
fm_brief_task_heading_present "$brief_file" "## Captain's intent" && has_intent=true
fm_brief_task_heading_present "$brief_file" "## Firstmate spec" && has_spec=true

verdict=$(fm_brief_preflight_verdict "$kind" "$has_task" "$has_dod" "$has_intent" "$has_spec")
missing=
surfaced=no
case "$verdict" in
  missing_acceptance)
    missing='acceptance criteria or definition of done'
    surfaced=yes
    printf 'warning: brief preflight: %s is missing %s (%s); spawn continues\n' \
      "$brief_file" "$missing" "$verdict" >&2
    ;;
esac

log_path="$FM_HOME/state/${task_id}.jev-brief-preflight.jsonl"
mkdir -p "$FM_HOME/state" || exit 0
log_payload=$(jq -nc \
  --arg task "$task_id" \
  --arg kind "$kind" \
  --arg mode "$mode" \
  --arg verdict "$verdict" \
  --arg missing "$missing" \
  --arg surfaced "$surfaced" \
  '{
    purpose: "brief-preflight",
    task: $task,
    kind: $kind,
    mode: $mode,
    verdict: $verdict,
    missing: $missing,
    surfaced: ($surfaced == "yes"),
    shadow: true,
    block: false,
    rule: "deterministic"
  }') || exit 0
printf '%s\n' "$log_payload" >> "$log_path" || true
exit 0
