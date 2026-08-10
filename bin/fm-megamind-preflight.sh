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
#   never substantive (empty input, a bare single-token harness slash command,
#   the pure control and routine monitoring operational-input kinds recognized
#   by their protocol owner bin/fm-operational-input.sh, exact single
#   acknowledgments) and substantive for everything else. Slash-leading or
#   path-leading prose, and any operational input that carries a task brief,
#   stay substantive, so an unrecognized message always takes the mandatory path.
# - `run` resolves the Megamind executable from the first line of local gitignored
#   config/megamind-executable (absent: plain `megamind-axi` on PATH) and the
#   pilot wiki estate from the first line of config/megamind-estate (absent:
#   not_configured failure - wiki roots are never guessed). Config values are
#   whitespace-trimmed and a leading `~` is expanded to $HOME; no other shell
#   expansion, globbing, or eval is applied to them. The model class comes
#   from --model-class, then config/megamind-model-class, then the restrictive
#   default `cloud` (every verified primary harness is a cloud model). Only
#   megamind-axi 0.3.x is accepted; any other version is version_incompatible.
# - The Megamind call is read-only, and the request is passed after `--` so a
#   dash-leading request is never parsed as an option: `megamind-axi preflight
#   --model-class <class> --estate <dir> --format json --no-help-hints --
#   <request>`. Megamind owns routing, thresholds, privacy filtering, and
#   budgets; this script never reimplements them.
# - Outcome statuses pass through exactly: matched, ambiguous, no-match,
#   unavailable, privacy-filtered; any other status is malformed_output. A
#   matched document carries each match's validated `allows` paths (relative,
#   root-contained; absolute, tilde, and dot-dot entries are dropped and counted
#   in dropped_allows) plus Megamind's follow_up ladder command. Offers carry
#   names and roots only - never paths to load. Filtered wiki names are never
#   echoed; only filtered_count is. `notes` is host-owned: one fixed per-outcome
#   line chosen here, never Megamind's own notes, which can name below-floor
#   wikis, out-of-band candidates, and absolute roots.
# - Any missing, incompatible, malformed, or failed preflight prints the typed
#   document with outcome=error and a stable failure.code instead of a result:
#   not_configured, estate_missing, invalid_model_class, executable_missing,
#   version_incompatible, jq_missing, megamind_error (with upstream_code),
#   malformed_output. The typed document and the proof line are also emitted
#   without jq, so jq_missing can disclose itself. Exit code is 0 for definitive
#   outcomes, 1 for errors.
# - Proof logging is minimal and non-verbatim: each `run` appends one JSON line
#   to state/megamind-preflight.jsonl with ts, preflight_id, request_hash,
#   model_class, catalog_hash, outcome, matched wiki names, and failure code.
#   Request text, wiki content, and bypass traffic are never logged.
# - Harness and runtime-backend neutral: the script depends only on bash, jq,
#   and the resolved megamind-axi; it reads no harness, backend, or terminal
#   state. tests/fm-megamind-preflight.test.sh pins that neutrality.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

SCHEMA="fm/megamind-preflight/v1"
MEGAMIND_SCHEMA="megamind/preflight-result/v2"
REQUIRED_VERSION="0.3"
LOG_FILE="$STATE/megamind-preflight.jsonl"
READ_POLICY="Read only the allows paths listed under each matched wiki root, within that wiki's context budget; use the follow_up ladder for page content; never read, infer, or widen to any other wiki path."
RUN_USAGE='usage: fm-megamind-preflight.sh run --request "<text>" [--model-class local|cloud]'

# Operational-input kinds that are pure control or routine monitoring. The kinds
# that carry a real task brief - from-firstmate and launch-brief - are deliberately
# absent, because dispatched work is substantive.
BYPASS_OPERATIONAL_KINDS='session-start watcher turn-end-guard away-supervisor legacy-operational'

trim_ws() {  # <text> - print it without leading or trailing whitespace
  local text="$1"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}

expand_leading_tilde() {  # <path> - expand a leading ~ or ~/ to $HOME, nothing else
  # The tilde is held in a variable so every use below is an unambiguously
  # literal one-character match rather than something a shell might expand.
  local path="$1" tilde='~'
  if [ -z "${HOME:-}" ]; then
    printf '%s' "$path"
    return 0
  fi
  case "$path" in
    "$tilde") printf '%s' "$HOME" ;;
    "$tilde"/*) printf '%s' "$HOME/${path#"$tilde"/}" ;;
    *) printf '%s' "$path" ;;
  esac
}

first_line() {  # <file> - print first non-empty, non-comment line trimmed, or nothing
  [ -f "$1" ] || return 1
  local line trimmed
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="$(trim_ws "$line")"
    case "$trimmed" in
      ''|'#'*) continue ;;
      *) printf '%s\n' "$trimmed"; return 0 ;;
    esac
  done < "$1"
  return 1
}

config_path() {  # <file> - first_line plus leading-tilde expansion, no other expansion
  local raw
  raw="$(first_line "$1")" || return 1
  printf '%s\n' "$(expand_leading_tilde "$raw")"
}

json_escape() {  # <text> - print it escaped for use inside a JSON string
  local text="$1"
  text="${text//\\/\\\\}"
  text="${text//\"/\\\"}"
  text="${text//$'\n'/\\n}"
  text="${text//$'\r'/\\r}"
  text="${text//$'\t'/\\t}"
  printf '%s' "$text"
}

emit_error() {  # <code> <message> [extra-jq-filter-as-json]
  local code="$1" message="$2" extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  # jq_missing is the one failure that must be disclosable without jq, so the
  # typed document has a literal fallback. Only that path can reach it: every
  # other failure is raised after the jq probe has already succeeded.
  if ! command -v jq >/dev/null 2>&1; then
    printf '{"schema_version":"%s","outcome":"error","failure":{"code":"%s","message":"%s"},"model_class":null,"preflight_id":null,"catalog_hash":null,"request_hash":null,"confidence":null,"matches":[],"offers":[],"filtered_count":0,"redacted_count":0,"dropped_allows":0,"notes":[],"read_policy":null}\n' \
      "$(json_escape "$SCHEMA")" "$(json_escape "$code")" "$(json_escape "$message")"
    return 0
  fi
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
  # A run without jq never reaches Megamind, so it never has matched wikis.
  if ! command -v jq >/dev/null 2>&1; then
    local failure_json='null'
    [ -z "$failure" ] || failure_json="\"$(json_escape "$failure")\""
    printf '{"ts":"%s","preflight_id":"%s","request_hash":"%s","model_class":"%s","catalog_hash":"%s","outcome":"%s","wikis":[],"failure":%s}\n' \
      "$(json_escape "$ts")" "$(json_escape "$preflight_id")" "$(json_escape "$request_hash")" \
      "$(json_escape "$model_class")" "$(json_escape "$catalog_hash")" "$(json_escape "$outcome")" \
      "$failure_json" >> "$LOG_FILE" 2>/dev/null || true
    return 0
  fi
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
  if configured="$(config_path "$CONFIG/megamind-executable")"; then
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
  local text="$1" lowered op_kind rest
  # Operational-input provenance is carried by exact bytes at position 0 and is
  # owned by bin/fm-operational-input.sh, so the kind is asked for rather than
  # restated here. Only its control and monitoring kinds bypass.
  if fm_operational_input_classify "$text" op_kind; then
    case " $BYPASS_OPERATIONAL_KINDS " in
      *" $op_kind "*) printf 'bypass\n'; return ;;
    esac
    printf 'substantive\n'; return
  fi
  text="$(trim_ws "$text")"
  # Empty input is never substantive.
  [ -n "$text" ] || { printf 'bypass\n'; return; }
  # A bare single-token harness slash command is a pure control message. Any
  # other slash-leading text - a leading absolute path, a command with prose
  # arguments - is a request and stays on the mandatory path.
  case "$text" in
    /[A-Za-z]*)
      rest="${text#/}"
      case "$rest" in
        *[!A-Za-z0-9_:-]*) : ;;
        *) printf 'bypass\n'; return ;;
      esac
      ;;
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
  estate="$(config_path "$CONFIG/megamind-estate" 2>/dev/null || true)"
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
  # Every option value is arity-checked before the shift: `shift 2` with one
  # positional left shifts nothing and would spin this loop forever on the
  # mandatory path, so a missing value must fail closed here instead.
  while [ $# -gt 0 ]; do
    case "$1" in
      --request)
        [ $# -ge 2 ] || { printf '%s\n' "$RUN_USAGE" >&2; return 2; }
        request="$2"; shift; shift ;;
      --model-class)
        [ $# -ge 2 ] || { printf '%s\n' "$RUN_USAGE" >&2; return 2; }
        model_class_flag="$2"; shift; shift ;;
      *) printf '%s\n' "$RUN_USAGE" >&2; return 2 ;;
    esac
  done
  [ -n "$request" ] || { printf '%s\n' "$RUN_USAGE" >&2; return 2; }

  local exe estate model_class version raw rc outcome
  exe="$(resolve_executable)"
  model_class="$(resolve_model_class "$model_class_flag")"
  estate="$(config_path "$CONFIG/megamind-estate" 2>/dev/null || true)"

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
  # filtering, and budgets; nothing here widens what it returns. The request
  # goes last, after `--`, so a dash-leading request stays a request.
  raw="$("$exe" preflight --model-class "$model_class" --estate "$estate" --format json --no-help-hints -- "$request" 2>/dev/null)" && rc=0 || rc=$?
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
  # never name privacy-filtered wikis, validate every allows path to stay
  # relative and root-contained before it may be read, and replace Megamind's
  # own notes - which can name below-floor wikis, out-of-band candidates, and
  # absolute roots - with one fixed host-owned line per outcome.
  local normalized
  normalized="$(printf '%s' "$raw" | jq -c \
    --arg schema "$SCHEMA" \
    --arg policy "$READ_POLICY" \
    'def safe_path: (type == "string") and (length > 0)
       and (startswith("/") | not) and (startswith("~") | not)
       and (test("(^|/)\\.\\.(/|$)") | not);
     def host_note:
       if . == "matched" then "Megamind matched at least one wiki: read only the listed allows paths, within the returned budget, and nothing else."
       elif . == "ambiguous" then "Megamind found no single confident wiki: offer the listed candidates as a choice and load nothing."
       elif . == "no-match" then "Megamind matched no wiki: do the work ordinarily and stay quiet about the estate."
       elif . == "privacy-filtered" then "Megamind withheld every candidate for this model class: only the count is disclosed, never a name."
       elif . == "unavailable" then "Megamind has no usable wiki cards: disclose the gap instead of assuming coverage."
       else "Megamind returned an unrecognized status: treat it as a blocker for substantive work." end;
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
       notes: [(.status | host_note)],
       read_policy: $policy
     }' 2>/dev/null)" || {
    emit_error malformed_output "Megamind preflight output could not be normalized"
    log_proof error malformed_output "" "" "$model_class" "" '[]'
    return 1
  }

  outcome="$(printf '%s' "$normalized" | jq -r '.outcome')"
  case "$outcome" in
    matched|ambiguous|no-match|unavailable|privacy-filtered) : ;;
    *)
      emit_error malformed_output "Megamind preflight reported a status outside the $MEGAMIND_SCHEMA set"
      log_proof error malformed_output "" "" "$model_class" "" '[]'
      return 1
      ;;
  esac
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
