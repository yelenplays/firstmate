#!/usr/bin/env bash
# Firstmate's harness-neutral, read-only Megamind preflight surface (pilot).
# Usage: fm-megamind-preflight.sh classify "<request text>"
#                                        print exactly substantive|bypass
#        fm-megamind-preflight.sh run --request "<text>" [--model-class local|cloud]
#                                        run Megamind preflight and print one typed
#                                        fm/megamind-preflight/v1 JSON document
#        fm-megamind-preflight.sh check print the same document shape describing
#                                        configuration, executable, and version
#                                        availability without routing a request
#
# Contract (owner: this header; policy owner: .agents/skills/megamind-preflight):
# - Every substantive Firstmate AI request goes through `run` BEFORE the answer,
#   plan, dispatch, or investigation relies on model knowledge. `classify` is the
#   deterministic conservative screen: it prints bypass ONLY for traffic that is
#   never substantive (empty input, harness slash commands, operational injection
#   markers, exact single acknowledgments) and substantive for everything else,
#   so an unrecognized message always takes the mandatory path.
# - `run` resolves the Megamind executable from the first line of local gitignored
#   config/megamind-executable (absent: plain `megamind-axi` on PATH) and the
#   pilot wiki estate from the first line of config/megamind-estate (absent:
#   not_configured failure - wiki roots are never guessed). The model class comes
#   from --model-class, then config/megamind-model-class, then the restrictive
#   default `cloud` (every verified primary harness is a cloud model). Only
#   megamind-axi 0.3.x is accepted; any other version is version_incompatible.
# - The Megamind call is read-only: `megamind-axi preflight <request>
#   --model-class <class> --estate <dir> --format json --no-help-hints`.
#   Megamind owns routing, thresholds, privacy filtering, and budgets; this
#   script never reimplements them.
# - Outcome statuses pass through exactly: matched, ambiguous, no-match,
#   unavailable, privacy-filtered. A matched document carries each match's
#   validated `allows` paths (relative, root-contained; absolute, tilde, and
#   dot-dot entries are dropped and counted in dropped_allows) plus Megamind's
#   follow_up ladder command. Offers carry names and roots only - never paths
#   to load. Filtered wiki names are never echoed; only filtered_count is.
# - Any missing, incompatible, malformed, or failed preflight prints the typed
#   document with outcome=error and a stable failure.code instead of a result:
#   not_configured, estate_missing, invalid_model_class, executable_missing,
#   version_incompatible, jq_missing, megamind_error (with upstream_code),
#   malformed_output. Exit code is 0 for definitive outcomes, 1 for errors.
# - Proof logging is minimal and non-verbatim: each `run` appends one JSON line
#   to state/megamind-preflight.jsonl with ts, preflight_id, request_hash,
#   model_class, catalog_hash, outcome, matched wiki names, and failure code.
#   Request text, wiki content, and bypass traffic are never logged.
# - Harness and runtime-backend neutral: the script depends only on bash, jq,
#   and the resolved megamind-axi; it reads no harness, backend, or terminal
#   state. tests/fm-megamind-preflight.test.sh pins that neutrality.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

SCHEMA="fm/megamind-preflight/v1"
MEGAMIND_SCHEMA="megamind/preflight-result/v2"
REQUIRED_VERSION="0.3"
LOG_FILE="$STATE/megamind-preflight.jsonl"
READ_POLICY="Read only the allows paths listed under each matched wiki root, within that wiki's context budget; use the follow_up ladder for page content; never read, infer, or widen to any other wiki path."

first_line() {  # <file> - print first non-empty, non-comment line, or nothing
  [ -f "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      *) printf '%s\n' "$line"; return 0 ;;
    esac
  done < "$1"
  return 1
}

emit_error() {  # <code> <message> [extra-jq-filter-as-json]
  local code="$1" message="$2" extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  jq -cn \
    --arg schema "$SCHEMA" \
    --arg code "$code" \
    --arg message "$message" \
    --argjson extra "$extra" \
    '{
      schema_version: $schema,
      outcome: "error",
      failure: ({code: $code, message: $message} + $extra),
      model_class: null,
      preflight_id: null,
      catalog_hash: null,
      request_hash: null,
      confidence: null,
      matches: [],
      offers: [],
      filtered_count: 0,
      redacted_count: 0,
      dropped_allows: 0,
      notes: [],
      read_policy: null
    }'
}

log_proof() {  # <outcome> <failure-code-or-empty> <preflight_id> <request_hash> <model_class> <catalog_hash> <wikis-json-array>
  local outcome="$1" failure="$2" preflight_id="$3" request_hash="$4" model_class="$5" catalog_hash="$6" wikis="$7"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$STATE" 2>/dev/null || return 0
  jq -cn \
    --arg ts "$ts" \
    --arg outcome "$outcome" \
    --arg failure "$failure" \
    --arg preflight_id "$preflight_id" \
    --arg request_hash "$request_hash" \
    --arg model_class "$model_class" \
    --arg catalog_hash "$catalog_hash" \
    --argjson wikis "$wikis" \
    '{ts: $ts, preflight_id: $preflight_id, request_hash: $request_hash,
      model_class: $model_class, catalog_hash: $catalog_hash, outcome: $outcome,
      wikis: $wikis, failure: (if $failure == "" then null else $failure end)}' \
    >> "$LOG_FILE" 2>/dev/null || true
}

resolve_executable() {  # print the configured executable or the PATH default
  local configured
  if configured="$(first_line "$CONFIG/megamind-executable")"; then
    printf '%s\n' "$configured"
  else
    printf '%s\n' "megamind-axi"
  fi
}

resolve_model_class() {  # <flag-value-or-empty> - print class or fail loudly
  local flag="$1" configured
  if [ -n "$flag" ]; then
    printf '%s\n' "$flag"
    return 0
  fi
  if configured="$(first_line "$CONFIG/megamind-model-class")"; then
    printf '%s\n' "$configured"
    return 0
  fi
  printf '%s\n' "cloud"
}

classify() {  # <request text> - print substantive|bypass
  local text="$1" lowered
  # Trim leading and trailing whitespace.
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  # Empty input is never substantive.
  [ -n "$text" ] || { printf 'bypass\n'; return; }
  case "$text" in
    # Harness slash commands are pure control messages.
    /*) printf 'bypass\n'; return ;;
    # Operational injection markers (away-mode daemon, wake machinery).
    FM_INJECT_MARK*) printf 'bypass\n'; return ;;
    $'\xe2\x81\xa3'"FIRSTMATE_OP: "*) printf 'bypass\n'; return ;;
  esac
  # Exact single acknowledgments, case-insensitive.
  lowered="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in
    ok|okay|yes|no|yep|nope|nah|aye|thanks|thank\ you|thx|ack|lgtm|shipshape|done|continue|proceed|go\ ahead)
      printf 'bypass\n'; return ;;
  esac
  printf 'substantive\n'
}

cmd_check() {
  local exe estate model_class version
  exe="$(resolve_executable)"
  model_class="$(resolve_model_class "")"
  estate="$(first_line "$CONFIG/megamind-estate" 2>/dev/null || true)"
  if ! command -v jq >/dev/null 2>&1; then
    emit_error jq_missing "jq is required to parse Megamind preflight output"
    return 1
  fi
  if [ -z "$estate" ]; then
    emit_error not_configured "config/megamind-estate is absent; pilot wiki roots are never guessed"
    return 1
  fi
  if [ ! -d "$estate" ]; then
    emit_error estate_missing "configured estate is not a directory"
    return 1
  fi
  case "$model_class" in
    local|cloud) : ;;
    *) emit_error invalid_model_class "model class must be local or cloud"; return 1 ;;
  esac
  if ! command -v "$exe" >/dev/null 2>&1; then
    emit_error executable_missing "Megamind executable not found: $exe"
    return 1
  fi
  version="$("$exe" --version 2>/dev/null | sed -n 's/^megamind-axi \([0-9][0-9.]*\)$/\1/p')"
  case "$version" in
    "$REQUIRED_VERSION".*) : ;;
    *)
      emit_error version_incompatible "megamind-axi $REQUIRED_VERSION.x is required" \
        "$(jq -cn --arg detected "${version:-unknown}" '{detected: $detected}')"
      return 1
      ;;
  esac
  jq -cn \
    --arg schema "$SCHEMA" \
    --arg exe "$exe" \
    --arg version "$version" \
    --arg estate "$estate" \
    --arg model_class "$model_class" \
    '{schema_version: $schema, outcome: "available", failure: null,
      executable: $exe, version: $version, estate: $estate,
      model_class: $model_class}'
}

cmd_run() {
  local request="" model_class_flag=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --request) request="${2:-}"; shift 2 ;;
      --model-class) model_class_flag="${2:-}"; shift 2 ;;
      *) printf 'usage: fm-megamind-preflight.sh run --request "<text>" [--model-class local|cloud]\n' >&2; return 2 ;;
    esac
  done
  [ -n "$request" ] || { printf 'usage: fm-megamind-preflight.sh run --request "<text>" [--model-class local|cloud]\n' >&2; return 2; }

  local exe estate model_class version raw rc outcome
  exe="$(resolve_executable)"
  model_class="$(resolve_model_class "$model_class_flag")"
  estate="$(first_line "$CONFIG/megamind-estate" 2>/dev/null || true)"

  if ! command -v jq >/dev/null 2>&1; then
    emit_error jq_missing "jq is required to parse Megamind preflight output"
    log_proof error jq_missing "" "" "$model_class" "" '[]'
    return 1
  fi
  if [ -z "$estate" ]; then
    emit_error not_configured "config/megamind-estate is absent; pilot wiki roots are never guessed"
    log_proof error not_configured "" "" "$model_class" "" '[]'
    return 1
  fi
  if [ ! -d "$estate" ]; then
    emit_error estate_missing "configured estate is not a directory"
    log_proof error estate_missing "" "" "$model_class" "" '[]'
    return 1
  fi
  case "$model_class" in
    local|cloud) : ;;
    *)
      emit_error invalid_model_class "model class must be local or cloud"
      log_proof error invalid_model_class "" "" "" "" '[]'
      return 1
      ;;
  esac
  if ! command -v "$exe" >/dev/null 2>&1; then
    emit_error executable_missing "Megamind executable not found: $exe"
    log_proof error executable_missing "" "" "$model_class" "" '[]'
    return 1
  fi
  version="$("$exe" --version 2>/dev/null | sed -n 's/^megamind-axi \([0-9][0-9.]*\)$/\1/p')"
  case "$version" in
    "$REQUIRED_VERSION".*) : ;;
    *)
      emit_error version_incompatible "megamind-axi $REQUIRED_VERSION.x is required" \
        "$(jq -cn --arg detected "${version:-unknown}" '{detected: $detected}')"
      log_proof error version_incompatible "" "" "$model_class" "" '[]'
      return 1
      ;;
  esac

  # Read-only Megamind call. Megamind owns routing, thresholds, privacy
  # filtering, and budgets; nothing here widens what it returns.
  raw="$("$exe" preflight "$request" --model-class "$model_class" --estate "$estate" --format json --no-help-hints 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    local upstream
    upstream="$(printf '%s' "$raw" | jq -r 'select(.schema_version == "megamind/error/v1") | .code // empty' 2>/dev/null || true)"
    emit_error megamind_error "Megamind preflight failed (exit $rc)" \
      "$(jq -cn --arg code "${upstream:-unknown}" '{upstream_code: $code}')"
    log_proof error megamind_error "" "" "$model_class" "" '[]'
    return 1
  fi
  if ! printf '%s' "$raw" | jq -e --arg s "$MEGAMIND_SCHEMA" '.schema_version == $s' >/dev/null 2>&1; then
    emit_error malformed_output "Megamind preflight output is not a $MEGAMIND_SCHEMA document"
    log_proof error malformed_output "" "" "$model_class" "" '[]'
    return 1
  fi

  # Normalize to the smallest permitted evidence: never echo the request text,
  # never name privacy-filtered wikis, and validate every allows path to stay
  # relative and root-contained before it may be read.
  local normalized
  normalized="$(printf '%s' "$raw" | jq -c \
    --arg schema "$SCHEMA" \
    --arg policy "$READ_POLICY" \
    'def safe_path: (type == "string") and (length > 0)
       and (startswith("/") | not) and (startswith("~") | not)
       and (test("(^|/)\\.\\.(/|$)") | not);
     ([.matches[]?.allows[]? | select(safe_path | not)] | length) as $dropped |
     {
       schema_version: $schema,
       outcome: .status,
       failure: null,
       model_class: .model_class,
       preflight_id: .preflight_id,
       catalog_hash: .catalog_hash,
       request_hash: .request_hash,
       confidence: .confidence,
       matches: [.matches[]? | {
         wiki: .name,
         root: .root,
         access: .access,
         routing_mode: .routing_mode,
         confidence: .confidence.score,
         allows: [.allows[]? | select(safe_path)],
         follow_up: .follow_up
       }],
       offers: [.offers[]? | {wiki: .name, root: .root, confidence: .confidence.score}],
       filtered_count: ([.filtered[]?] | length),
       redacted_count: (.redacted_count // 0),
       dropped_allows: $dropped,
       notes: [.notes[]?],
       read_policy: $policy
     }')" || {
    emit_error malformed_output "Megamind preflight output could not be normalized"
    log_proof error malformed_output "" "" "$model_class" "" '[]'
    return 1
  }

  outcome="$(printf '%s' "$normalized" | jq -r '.outcome')"
  log_proof "$outcome" "" \
    "$(printf '%s' "$normalized" | jq -r '.preflight_id // ""')" \
    "$(printf '%s' "$normalized" | jq -r '.request_hash // ""')" \
    "$model_class" \
    "$(printf '%s' "$normalized" | jq -r '.catalog_hash // ""')" \
    "$(printf '%s' "$normalized" | jq -c '[.matches[]?.wiki]')"
  printf '%s\n' "$normalized"
}

main() {
  [ $# -ge 1 ] || { printf 'usage: fm-megamind-preflight.sh classify|run|check ...\n' >&2; return 2; }
  local cmd="$1"; shift
  case "$cmd" in
    classify)
      [ $# -ge 1 ] || { printf 'usage: fm-megamind-preflight.sh classify "<request text>"\n' >&2; return 2; }
      classify "$1"
      ;;
    run) cmd_run "$@" ;;
    check) cmd_check ;;
    *) printf 'usage: fm-megamind-preflight.sh classify|run|check ...\n' >&2; return 2 ;;
  esac
}

main "$@"
