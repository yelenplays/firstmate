#!/usr/bin/env bash
# Firstmate's harness-neutral, read-only Megamind preflight surface (pilot).
# Usage: fm-megamind-preflight.sh classify "<request text>"
#                                        print exactly substantive|bypass
#        fm-megamind-preflight.sh classify-provenance credential-submission
#                                        print bypass without accepting or reading
#                                        the credential payload
#        fm-megamind-preflight.sh run --request "<text>" [--model-class local|cloud]
#                                        run Megamind preflight and print one typed
#                                        fm/megamind-preflight/v1 JSON document
#        fm-megamind-preflight.sh continue --selection-id <id> --offer <wiki>
#                                        consume one private ambiguous offer and
#                                        print one typed authorization projection
#        fm-megamind-preflight.sh check print the same document shape describing
#                                        configuration, executable, and version
#                                        availability without routing a request
#
# Contract (owner: this header; policy owner: .agents/skills/megamind-preflight):
# - Every substantive Firstmate AI request goes through `run` BEFORE the answer,
#   plan, dispatch, or investigation relies on model knowledge. `classify` is the
#   deterministic conservative screen: it prints bypass ONLY for traffic that is
#   never substantive (empty input, a bare single-token harness slash command,
#   the four explicitly named control and monitoring kinds that the protocol
#   owner bin/fm-operational-input.sh resolves for a message - session-start,
#   watcher, turn-end-guard, away-supervisor, each including its landed legacy
#   prefix - and exact single acknowledgments) and substantive for everything
#   else. Slash-leading or path-leading prose, any operational input carrying a
#   task brief, and every shape the owner can only place in its untyped
#   `legacy-operational` catch-all - an unrecognized kind, a future version
#   token, a bare untyped prefix - stay substantive, so an unrecognized message
#   always takes the mandatory path. A credential supplied through an active,
#   trusted credential exchange takes the separate `classify-provenance
#   credential-submission` path: callers pass only that provenance token and
#   never the credential payload, so secret text cannot reach classify, run,
#   Megamind argv, or proof logging. Every unknown provenance is substantive.
# - `run` resolves the Megamind executable from the first line of local gitignored
#   config/megamind-executable (absent: plain `megamind-axi` on PATH) and the
#   pilot wiki estate from the first line of config/megamind-estate (absent:
#   not_configured failure - wiki roots are never guessed). Config values are
#   whitespace-trimmed and a leading `~` is expanded to $HOME; no other shell
#   expansion, globbing, or eval is applied to them. The model class comes
#   from --model-class, then config/megamind-model-class, then the restrictive
#   default `cloud` (every verified primary harness is a cloud model). Megamind
#   versions 0.3.x, 0.4.x, 0.5.x, and 0.6.x are accepted because all four
#   preserve the host-consumed `megamind/preflight-result/v2` fields; malformed,
#   older, and future versions remain version_incompatible until their
#   compatibility is established. The probe is anchored on identity: it parses
#   only a `megamind-axi <token>` line of `--version`, requires exactly one such
#   line, and bounds that token's length and character set. Other output lines
#   are ignored, raw executable output never reaches the typed document, and
#   failure.detected carries that bounded token or `unknown`.
# - The accepted v2 result must retain the host-consumed typed fields and their
#   required container types: identity strings, model class, status, thresholds,
#   result arrays, and match/offer confidence and path fields. The privacy
#   fields `filtered` and `redacted_count` are optional: a present one is type-
#   and range-checked, and an absent one keeps its existing safe default.
#   Additive upstream fields remain ignored or privacy-filtered by the existing
#   normalization boundary; missing or incompatible consumed fields are
#   malformed_output.
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
#   echoed; only filtered_count is. The self-describing decision thresholds pass
#   through and are required: output without reliance_floor, offer_floor, and
#   ambiguity_band all present as numbers in 0..1 is malformed_output. Matches
#   carry validated freshness, a non-verbatim provenance summary (fixed lexical
#   classes in canonical trigger/name/scope order, per-class counts, total signal
#   count, and optional semantic score; upstream class order is not load-bearing,
#   but a class set inconsistent with the counts is not validated), and optional
#   positive numeric context-budget fields. A lexical evidence packet that fails
#   that validation is withheld rather than guessed: lexical_classes is [] and
#   both signal_counts and lexical_signal_count are null on an otherwise normal
#   outcome, while a separately validated numeric semantic_score still passes
#   through. Raw evidence strings, request-derived tokens, content, identities,
#   roots, and paths never enter those evidence fields.
#   `notes` is host-owned: one fixed per-outcome line chosen here, never
#   Megamind's own notes, which can name below-floor wikis, out-of-band
#   candidates, and absolute roots.
# - Any missing, incompatible, malformed, or failed preflight prints the typed
#   document with outcome=error and a stable failure.code instead of a result:
#   not_configured, estate_missing, invalid_model_class, executable_missing,
#   version_incompatible, jq_missing, megamind_error (with upstream_code),
#   malformed_output. The typed document and the proof line are also emitted
#   without jq, so jq_missing can disclose itself. Exit code is 0 for definitive
#   outcomes, 1 for errors.
# - An ambiguous `run` retains the complete original v2 JSON packet, exact
#   request, and binding identity in one mode-0600 record under the private
#   state/megamind-offer-selections directory. The normalized result exposes
#   only an opaque selection_id; the request and packet never enter chat, proof,
#   status, metadata, or worker instructions. The record binds request_hash,
#   preflight_id, catalog_hash, model class, executable and version, estate
#   identity, date semantics, and the current session identity.
# - `continue` accepts only that opaque selection_id and the exact offered wiki.
#   It resolves every executable, estate, packet, request, and model value from
#   the private record, invokes the same executable's `select-offer` command,
#   validates the complete `megamind/preflight-selection-result/v1` result, and
#   emits only a fixed host-owned authorization projection. It uses a private
#   lock for one-time consumption, retires the pending record only after the
#   projection is durably published, and preserves it when retry remains safe.
#   A plain ambiguous worker preflight remains unauthorized.
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
SELECTION_SCHEMA="fm/megamind-preflight-selection/v1"
MEGAMIND_SCHEMA="megamind/preflight-result/v2"
MEGAMIND_SELECTION_SCHEMA="megamind/preflight-selection-result/v1"
SUPPORTED_VERSION_LINES='0.3.x, 0.4.x, 0.5.x, or 0.6.x'
LOG_FILE="$STATE/megamind-preflight.jsonl"
SELECTION_DIR="$STATE/megamind-offer-selections"
READ_POLICY="Read only the allows paths listed under each matched wiki root, within any returned context budget; use the follow_up ladder for page content; never read, infer, or widen to any other wiki path."
RUN_USAGE='usage: fm-megamind-preflight.sh run --request "<text>" [--model-class local|cloud] [--today YYYY-MM-DD]'
CONTINUE_USAGE='usage: fm-megamind-preflight.sh continue --selection-id <id> --offer <wiki>'

is_supported_version() {  # <version> - accept only proven complete 0.3.x/0.4.x/0.5.x/0.6.x releases
  local version="$1"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  case "$version" in
    0.3.*|0.4.*|0.5.*|0.6.*) return 0 ;;
    *) return 1 ;;
  esac
}

detect_version() {  # <executable> - print its one anchored megamind-axi version token, or nothing
  # Identity is required and the disclosure is bounded: the raw stream is never
  # captured, only whole `megamind-axi <token>` lines are parsed, and a probe
  # that prints no such line - or more than one - names no single build and
  # yields nothing, so the gate fails closed on it.
  local parsed="" candidate
  while IFS= read -r candidate; do
    [ -z "$parsed" ] || return 1
    parsed="$candidate"
  done < <("$1" --version 2>/dev/null |
    sed -n 's/^megamind-axi \([0-9A-Za-z][0-9A-Za-z.+-]\{0,31\}\)$/\1/p')
  [ -n "$parsed" ] || return 1
  printf '%s\n' "$parsed"
}

# Operational-input kinds that are pure control or routine monitoring. Every
# entry is a kind the protocol owner recognizes explicitly, so each landed legacy
# monitoring prefix still resolves here through its own kind. The kinds that
# carry a real task brief - from-firstmate and launch-brief - and the owner's
# untyped `legacy-operational` catch-all are deliberately absent: dispatched work
# is substantive, and a shape the owner could not subtype is unrecognized traffic
# that belongs on the mandatory path.
BYPASS_OPERATIONAL_KINDS='session-start watcher turn-end-guard away-supervisor'

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

hash_text() {  # <text> - print a portable SHA-256 digest
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

hash_file() {  # <file> - print a portable SHA-256 digest
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

valid_today() {  # <date> - accept the upstream command's explicit ISO date shape
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

current_today() {
  if [ -n "${FM_MEGAMIND_TODAY:-}" ]; then
    valid_today "$FM_MEGAMIND_TODAY" || return 1
    printf '%s\n' "$FM_MEGAMIND_TODAY"
  else
    date -u +%Y-%m-%d
  fi
}

current_session_identity() {  # the locked primary session or an explicit host session token
  local value pid
  value="${FM_MEGAMIND_SESSION_ID:-${FM_SESSION_ID:-}}"
  if [ -n "$value" ]; then
    case "$value" in
      *[!A-Za-z0-9._:-]*) return 1 ;;
      *) printf 'session:%s\n' "$value"; return 0 ;;
    esac
  fi
  if [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ]; then
    pid="$(cat "$STATE/.lock" 2>/dev/null || true)"
    case "$pid" in
      ''|*[!0-9]*) return 1 ;;
      *) printf 'lock:%s\n' "$pid"; return 0 ;;
    esac
  fi
  return 1
}

resolved_executable() {  # <configured executable> - print the exact executable path used
  local found="$1"
  if [[ "$found" = /* ]]; then
    [ -x "$found" ] || return 1
    CDPATH='' cd -P -- "$(dirname -- "$found")" 2>/dev/null || return 1
    printf '%s/%s\n' "$PWD" "$(basename -- "$found")"
  else
    command -v "$found"
  fi
}

estate_identity() {  # <estate> - hash the canonical estate identity, never expose its path
  local real
  real="$(CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P)" || return 1
  hash_text "megamind-estate/v1\n$real"
}

new_nonce() {
  local nonce
  nonce="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]' || true)"
  [ -n "$nonce" ] || nonce="$(hash_text "$$:$PPID:$(date +%s%N)")"
  printf '%s\n' "$nonce"
}

selection_path() {  # <selection-id> - script-owned private pending path
  printf '%s/%s.pending.json\n' "$SELECTION_DIR" "$1"
}

authorization_path() {  # <selection-id> - script-owned private consumed result path
  printf '%s/%s.authorization.json\n' "$SELECTION_DIR" "$1"
}

valid_selection_id() {
  [ "${#1}" -ge 16 ] && [ "${#1}" -le 128 ] && [[ "$1" =~ ^[A-Fa-f0-9]+$ ]]
}

private_mode() {  # <file> - print portable numeric permission bits
  if [ "$(uname)" = Darwin ]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

private_publish() {  # <destination> - publish stdin as mode-0600 in its existing private directory
  local destination="$1" tmp old_umask
  tmp="${destination}.tmp.${BASHPID:-$$}"
  old_umask="$(umask)"
  umask 077
  if ! cat > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$destination"; then
    umask "$old_umask"
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  umask "$old_umask"
}

selection_error() {  # <code> <message> [extra JSON object]
  local code="$1" message="$2" extra="${3:-{}}"
  if ! command -v jq >/dev/null 2>&1; then
    printf '{"schema_version":"%s","outcome":"error","failure":{"code":"%s","message":"%s"}}\n' \
      "$SELECTION_SCHEMA" "$(json_escape "$code")" "$(json_escape "$message")"
    return 1
  fi
  jq -cn --arg schema "$SELECTION_SCHEMA" --arg code "$code" --arg message "$message" \
    --argjson extra "$extra" \
    '{schema_version:$schema,outcome:"error",failure:({code:$code,message:$message} + $extra)}'
  return 1
}

classify_provenance() {  # <trusted-provenance> - print substantive|bypass, never read payload text
  case "$1" in
    credential-submission) printf 'bypass\n' ;;
    *) printf 'substantive\n' ;;
  esac
}

retain_ambiguous() {  # <raw upstream packet> <request> <normalized document> - write one private pending selection
  local raw="$1" request="$2" normalized="$3"
  local preflight_id request_hash catalog_hash model_class nonce session_id exe estate today
  local exe_path exe_hash estate_hash selection_id pending
  if ! printf '%s' "$raw" | jq -e --arg request "$request" \
      '. | type == "object" and .schema_version == "megamind/preflight-result/v2"
       and .status == "ambiguous"' >/dev/null 2>&1; then
    return 1
  fi
  preflight_id="$(printf '%s' "$normalized" | jq -r '.preflight_id')"
  request_hash="$(printf '%s' "$normalized" | jq -r '.request_hash')"
  catalog_hash="$(printf '%s' "$normalized" | jq -r '.catalog_hash')"
  model_class="$(printf '%s' "$normalized" | jq -r '.model_class')"
  exe="$(resolve_executable)"
  estate="$(config_path "$CONFIG/megamind-estate" 2>/dev/null || true)"
  today="${RUN_TODAY:-}"
  session_id="$(current_session_identity || printf 'parent:%s' "$PPID")"
  exe_path="$(resolved_executable "$exe" 2>/dev/null || true)"
  exe_hash="$(hash_file "$exe_path" 2>/dev/null || true)"
  estate_hash="$(estate_identity "$estate" 2>/dev/null || true)"
  [ -n "$exe_path" ] && [ -n "$exe_hash" ] && [ -n "$estate_hash" ] \
    || return 1
  nonce="$(new_nonce)" || return 1
  selection_id="$(hash_text "$(jq -cn --arg request_hash "$request_hash" \
    --arg preflight_id "$preflight_id" --arg catalog_hash "$catalog_hash" \
    --arg model_class "$model_class" --arg executable "$exe_path" \
    --arg version "$RUN_VERSION" --arg estate "$estate_hash" --arg today "$today" \
    --arg session "$session_id" --arg nonce "$nonce" \
    '{request_hash:$request_hash,preflight_id:$preflight_id,catalog_hash:$catalog_hash,
      model_class:$model_class,executable:$executable,version:$version,estate:$estate,
      today:$today,session:$session,nonce:$nonce}' )")" || return 1
  mkdir -p -- "$SELECTION_DIR" 2>/dev/null || return 1
  chmod 700 "$SELECTION_DIR" 2>/dev/null || return 1
  pending="$(selection_path "$selection_id")"
  [ ! -L "$pending" ] || return 1
  if ! jq -cn --arg schema "$SELECTION_SCHEMA" --arg selection_id "$selection_id" \
      --arg request "$request" --arg request_hash "$request_hash" \
      --arg preflight_id "$preflight_id" --arg catalog_hash "$catalog_hash" \
      --arg model_class "$model_class" --arg executable "$exe_path" \
      --arg executable_hash "$exe_hash" --arg version "$RUN_VERSION" \
      --arg estate_identity "$estate_hash" --arg today "$today" \
      --arg session_identity "$session_id" --arg nonce "$nonce" \
      --argjson packet "$raw" \
      '{schema_version:$schema,status:"pending",selection_id:$selection_id,
        request:$request,request_hash:$request_hash,preflight_id:$preflight_id,
        catalog_hash:$catalog_hash,model_class:$model_class,
        executable:{path:$executable,sha256:$executable_hash,version:$version},
        estate_identity:$estate_identity,today:$today,session_identity:$session_identity,
        nonce:$nonce,packet:$packet}' \
      | private_publish "$pending"; then
    return 1
  fi
  PENDING_SELECTION_ID="$selection_id"
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
  version="$(detect_version "$exe")"
  if ! is_supported_version "$version"; then
    emit_error version_incompatible "megamind-axi $SUPPORTED_VERSION_LINES are required" \
      "$(jq -cn --arg detected "${version:-unknown}" '{detected: $detected}')"
    return 1
  fi
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
  local request="" model_class_flag="" today_flag=""
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
      --today)
        [ $# -ge 2 ] || { printf '%s\n' "$RUN_USAGE" >&2; return 2; }
        today_flag="$2"; shift; shift ;;
      *) printf '%s\n' "$RUN_USAGE" >&2; return 2 ;;
    esac
  done
  [ -n "$request" ] || { printf '%s\n' "$RUN_USAGE" >&2; return 2; }

  local exe estate model_class version raw rc outcome today
  RUN_VERSION=
  exe="$(resolve_executable)"
  model_class="$(resolve_model_class "$model_class_flag")"
  estate="$(config_path "$CONFIG/megamind-estate" 2>/dev/null || true)"
  if [ -n "$today_flag" ]; then
    valid_today "$today_flag" || {
      emit_error invalid_today "date must use YYYY-MM-DD"
      log_proof error invalid_today "" "" "$model_class" "" '[]'
      return 1
    }
    today="$today_flag"
  else
    today="$(current_today 2>/dev/null || true)"
    [ -n "$today" ] || {
      emit_error invalid_today "could not establish the Megamind date"
      log_proof error invalid_today "" "" "$model_class" "" '[]'
      return 1
    }
  fi
  RUN_TODAY="$today"

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
  version="$(detect_version "$exe")"
  RUN_VERSION="$version"
  if ! is_supported_version "$version"; then
    emit_error version_incompatible "megamind-axi $SUPPORTED_VERSION_LINES are required" \
      "$(jq -cn --arg detected "${version:-unknown}" '{detected: $detected}')"
    log_proof error version_incompatible "" "" "$model_class" "" '[]'
    return 1
  fi

  # Read-only Megamind call. Megamind owns routing, thresholds, privacy
  # filtering, and budgets; nothing here widens what it returns. The request
  # goes last, after `--`, so a dash-leading request stays a request.
  raw="$("$exe" preflight --model-class "$model_class" --estate "$estate" --today "$today" --format json --no-help-hints -- "$request" 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    local upstream
    upstream="$(printf '%s' "$raw" | jq -r 'select(.schema_version == "megamind/error/v1") | .code // empty' 2>/dev/null || true)"
    emit_error megamind_error "Megamind preflight failed (exit $rc)" \
      "$(jq -cn --arg code "${upstream:-unknown}" '{upstream_code: $code}')"
    log_proof error megamind_error "" "" "$model_class" "" '[]'
    return 1
  fi
  if ! printf '%s' "$raw" | jq -e --arg s "$MEGAMIND_SCHEMA" '
      def nonempty_string: type == "string" and length > 0;
      def score_object:
        type == "object"
        and (.score | type == "number" and . >= 0 and . <= 1);
      def valid_match:
        type == "object"
        and (.name | nonempty_string)
        and (.root | nonempty_string)
        and (.access | type == "string")
        and (.routing_mode | type == "string")
        and (.confidence | score_object)
        and (.allows | type == "array")
        and all(.allows[]; type == "string")
        and (.follow_up | type == "string");
      def valid_offer:
        type == "object"
        and (.name | nonempty_string)
        and (.root | nonempty_string)
        and (.confidence | score_object);
      (.schema_version == $s)
      and (.request_hash | nonempty_string)
      and (.model_class == "local" or .model_class == "cloud")
      and (.status | type == "string")
      and ((.confidence == null) or (.confidence | type == "number"))
      and ((.preflight_id | nonempty_string))
      and ((.catalog_hash | nonempty_string))
      and ((.thresholds | type) == "object")
      and ([.thresholds.reliance_floor, .thresholds.offer_floor, .thresholds.ambiguity_band]
        | all(type == "number" and . >= 0 and . <= 1))
      and (.matches | type == "array")
      and all(.matches[]; valid_match)
      and (.offers | type == "array")
      and all(.offers[]; valid_offer)
      and ((.filtered == null) or (.filtered | type == "array"))
      and ((.redacted_count == null)
        or (.redacted_count | type == "number" and floor == . and . >= 0))
    ' >/dev/null 2>&1; then
    emit_error malformed_output "Megamind preflight output is not a valid $MEGAMIND_SCHEMA document"
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
     def safe_date:
       if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . else null end;
     def positive_number: type == "number" and . > 0;
     def positive_integer: positive_number and floor == .;
     def safe_freshness:
       if type == "object" then {
         half_life_days: (.half_life_days | if positive_number then . else null end),
         last_confirmed: (.last_confirmed | safe_date),
         stale: (.stale | if type == "boolean" then . else null end)
       } else null end;
     def safe_signal_counts:
       if type == "object"
          and ((keys | sort) == ["name", "scope", "trigger"])
          and all(.[]; type == "number" and floor == . and . >= 0)
       then {trigger: .trigger, name: .name, scope: .scope}
       else null end;
     def safe_lexical_classes($counts):
       (["trigger", "name", "scope"] | map(select($counts[.] > 0))) as $derived |
       if type == "array" and (sort == ($derived | sort))
       then $derived
       else null end;
     def safe_provenance:
       . as $match |
       ($match.evidence | if type == "object" then . else null end) as $evidence |
       ($evidence.signal_counts | safe_signal_counts) as $counts |
       ($evidence.lexical_classes | safe_lexical_classes($counts)) as $classes |
       ({semantic_score: ($evidence.semantic
          | if type == "number" then . else null end)}
        + if $counts != null and $classes != null then {
            lexical_classes: $classes,
            signal_counts: $counts,
            lexical_signal_count: ([$counts[]] | add)
          } else {
            lexical_classes: [],
            signal_counts: null,
            lexical_signal_count: null
          } end);
     def safe_budget:
       . as $budget | {
         max_candidates: ($budget.max_candidates | if positive_integer then . else null end),
         max_context_chars: ($budget.max_context_chars | if positive_integer then . else null end)
       } | with_entries(select(.value != null));
     def host_note:
       if . == "matched" then "Megamind matched at least one wiki: read only the listed allows paths, within any returned budget, and nothing else."
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
       thresholds: {
         reliance_floor: .thresholds.reliance_floor,
         offer_floor: .thresholds.offer_floor,
         ambiguity_band: .thresholds.ambiguity_band
       },
       matches: [.matches[]? |
         . as $match |
         ({
           wiki: $match.name,
           root: $match.root,
           access: $match.access,
           routing_mode: $match.routing_mode,
           confidence: $match.confidence.score,
           freshness: ($match.freshness | safe_freshness),
           provenance: ($match | safe_provenance),
           allows: [$match.allows[]? | select(safe_path)],
           follow_up: $match.follow_up
         } + (if (($match.context_budget | type) == "object")
              then {context_budget: ($match.context_budget | safe_budget)}
              else {} end))
       ],
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
  if [ "$outcome" = ambiguous ]; then
    if ! retain_ambiguous "$raw" "$request" "$normalized"; then
      emit_error selection_pending_write_failed "the ambiguous offer could not be retained privately"
      log_proof error selection_pending_write_failed "" "" "$model_class" "" '[]'
      return 1
    fi
    normalized="$(printf '%s' "$normalized" | jq -c --arg id "$PENDING_SELECTION_ID" '. + {selection_id:$id}')"
  fi
  log_proof "$outcome" "" \
    "$(printf '%s' "$normalized" | jq -r '.preflight_id // ""')" \
    "$(printf '%s' "$normalized" | jq -r '.request_hash // ""')" \
    "$model_class" \
    "$(printf '%s' "$normalized" | jq -r '.catalog_hash // ""')" \
    "$(printf '%s' "$normalized" | jq -c '[.matches[]?.wiki]')"
  printf '%s\n' "$normalized"
}

cmd_continue() (
  local selection_id="" offer="" pending packet_tmp raw rc
  local request request_hash preflight_id catalog_hash model_class stored_today stored_session
  local stored_exe stored_exe_hash stored_version stored_estate_hash
  local exe estate version today exe_path exe_hash estate_hash offer_root offer_count
  while [ $# -gt 0 ]; do
    case "$1" in
      --selection-id)
        [ $# -ge 2 ] || { printf '%s\n' "$CONTINUE_USAGE" >&2; return 2; }
        selection_id="$2"; shift 2 ;;
      --offer)
        [ $# -ge 2 ] || { printf '%s\n' "$CONTINUE_USAGE" >&2; return 2; }
        offer="$2"; shift 2 ;;
      *) printf '%s\n' "$CONTINUE_USAGE" >&2; return 2 ;;
    esac
  done
  valid_selection_id "$selection_id" || { selection_error selection_id_invalid "selection identity is not valid"; return 1; }
  if [ -z "$offer" ] || [[ "$offer" = -* ]] \
    || printf '%s' "$offer" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    selection_error offer_invalid "the selected offer is not a usable wiki name"
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { selection_error jq_missing "jq is required to consume a selection"; return 1; }
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { selection_error state_invalid "the owning state directory is unavailable"; return 1; }
  [ -d "$SELECTION_DIR" ] && [ ! -L "$SELECTION_DIR" ] || { selection_error selection_missing "the pending selection is unavailable"; return 1; }
  pending="$(selection_path "$selection_id")"
  [ -f "$pending" ] && [ ! -L "$pending" ] || {
    if [ -f "$(authorization_path "$selection_id")" ] && [ ! -L "$(authorization_path "$selection_id")" ]; then
      selection_error selection_replayed "the pending selection has already been consumed"
    else
      selection_error selection_missing "the pending selection is unavailable"
    fi
    return 1
  }
  [ "$(private_mode "$pending" 2>/dev/null)" = 600 ] \
    || { selection_error selection_invalid "the pending selection is not private"; return 1; }

  local continue_lock="$SELECTION_DIR/.continue.lock"
  if ! mkdir -- "$continue_lock" 2>/dev/null; then
    selection_error selection_busy "another selection continuation is active"
    return 1
  fi
  trap 'rm -f -- "${packet_tmp:-}" 2>/dev/null || true; rmdir -- "$continue_lock" 2>/dev/null || true' EXIT

  if ! jq -e --arg id "$selection_id" '
      type == "object" and .schema_version == "fm/megamind-preflight-selection/v1"
      and .status == "pending" and .selection_id == $id
      and (.request | type == "string" and length > 0)
      and (.request_hash | type == "string" and length > 0)
      and (.preflight_id | type == "string" and length > 0)
      and (.catalog_hash | type == "string" and length > 0)
      and (.model_class == "local" or .model_class == "cloud")
      and (.executable | type == "object")
      and (.executable.path | type == "string" and length > 0)
      and (.executable.sha256 | type == "string" and test("^[A-Fa-f0-9]{64}$"))
      and (.executable.version | type == "string" and length > 0)
      and (.estate_identity | type == "string" and length > 0)
      and (.today | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
      and (.session_identity | type == "string" and length > 0)
      and (.nonce | type == "string" and length > 0)
      and (.packet | type == "object")
      and ((.packet.request == null) or (.packet.request == .request))' "$pending" >/dev/null 2>&1; then
    selection_error selection_malformed "the pending selection is malformed"
    return 1
  fi
  request="$(jq -r '.request' "$pending")"
  request_hash="$(jq -r '.request_hash' "$pending")"
  preflight_id="$(jq -r '.preflight_id' "$pending")"
  catalog_hash="$(jq -r '.catalog_hash' "$pending")"
  model_class="$(jq -r '.model_class' "$pending")"
  stored_exe="$(jq -r '.executable.path' "$pending")"
  stored_exe_hash="$(jq -r '.executable.sha256' "$pending")"
  stored_version="$(jq -r '.executable.version' "$pending")"
  stored_estate_hash="$(jq -r '.estate_identity' "$pending")"
  stored_today="$(jq -r '.today' "$pending")"
  stored_session="$(jq -r '.session_identity' "$pending")"
  if ! jq -e --arg request "$request" '.packet.request == $request' "$pending" >/dev/null 2>&1; then
    selection_error packet_malformed "the original packet is not bound to the original request"
    return 1
  fi

  exe="$(resolve_executable)"
  estate="$(config_path "$CONFIG/megamind-estate" 2>/dev/null || true)"
  version="$(detect_version "$exe" 2>/dev/null || true)"
  today="$(current_today 2>/dev/null || true)"
  exe_path="$(resolved_executable "$exe" 2>/dev/null || true)"
  exe_hash="$(hash_file "$exe_path" 2>/dev/null || true)"
  estate_hash="$(estate_identity "$estate" 2>/dev/null || true)"
  [ "$model_class" = "$(resolve_model_class "")" ] \
    || { selection_error binding_changed "the model class changed since the offer"; return 1; }
  [ "$stored_exe" = "$exe_path" ] && [ "$stored_exe_hash" = "$exe_hash" ] \
    && [ "$stored_version" = "$version" ] \
    || { selection_error binding_changed "the Megamind executable or version changed since the offer"; return 1; }
  [ -n "$estate_hash" ] && [ "$stored_estate_hash" = "$estate_hash" ] \
    || { selection_error binding_changed "the Megamind estate changed since the offer"; return 1; }
  [ "$stored_today" = "$today" ] \
    || { selection_error binding_changed "the Megamind date changed since the offer"; return 1; }
  [ "$stored_session" = "$(current_session_identity || printf 'parent:%s' "$PPID")" ] \
    || { selection_error binding_changed "the current Firstmate session does not own this offer"; return 1; }

  offer_count="$(jq -r --arg wiki "$offer" '[.packet.offers[]? | select(.name == $wiki)] | length' "$pending")"
  [ "$offer_count" = 1 ] \
    || { selection_error offer_invalid "the selected wiki is not exactly one current offer"; return 1; }
  offer_root="$(jq -r --arg wiki "$offer" '.packet.offers[] | select(.name == $wiki) | .root' "$pending")"
  packet_tmp="$SELECTION_DIR/.$selection_id.packet.${BASHPID:-$$}"
  if ! jq -c '.packet' "$pending" | private_publish "$packet_tmp"; then
    selection_error packet_unavailable "the private original preflight packet could not be prepared"
    return 1
  fi

  # The command, request, packet path, estate, model class, and date all come
  # from the private pending record or the current owning-home binding.
  raw="$("$exe_path" --format json --no-help-hints --today "$today" select-offer "$offer" \
    --request "$request" --preflight-result "$packet_tmp" --model-class "$model_class" \
    --estate "$estate" 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    local upstream
    upstream="$(printf '%s' "$raw" | jq -r 'select(.schema_version == "megamind/error/v1") | .code // empty' 2>/dev/null || true)"
    selection_error upstream_error "Megamind could not authorize the selected offer" \
      "$(jq -cn --arg code "${upstream:-unknown}" '{upstream_code:$code}')"
    return 1
  fi
  if ! printf '%s' "$raw" | jq -e --arg schema "$MEGAMIND_SELECTION_SCHEMA" \
      --arg preflight_id "$preflight_id" --arg request_hash "$request_hash" \
      --arg catalog_hash "$catalog_hash" --arg model_class "$model_class" \
      --arg offer "$offer" --arg root "$offer_root" --arg request "$request" '
      def text: type == "string" and length > 0;
      def safe_path: type == "string" and length > 0 and (startswith("/") | not)
        and (startswith("~") | not) and (test("(^|/)\\.\\.(/|$)") | not);
      def score: type == "number" and . >= 0 and . <= 1;
      def safe_budget: type == "object"
        and ((.max_candidates == null) or (.max_candidates | type == "number" and . > 0 and floor == .))
        and ((.max_context_chars == null) or (.max_context_chars | type == "number" and . > 0 and floor == .));
      (.schema_version == $schema) and (.status == "authorized")
      and (.preflight_id == $preflight_id) and (.request_hash == $request_hash)
      and (.catalog_hash == $catalog_hash) and (.model_class == $model_class)
      and (.selection_id | text) and (.root_facts_hash | text)
      and (.selection | type == "object" and .status == "explicit-user-selection"
        and .basis == "selected-current-offer" and .source_disposition == "offer"
        and .source_status == "ambiguous" and .preflight_id == $preflight_id
        and .confidence_changed == false)
      and (.selected | type == "object" and .name == $offer and .root == $root)
      and (.selected.score | score)
      and (.selected.confidence | type == "object" and (.score | score)
        and (.meets_floor == false))
      and (.selected.access == "full" or .selected.access == "digest-only")
      and (.selected.routing_mode | text and . != "pointer")
      and (.selected.provisional == false)
      and (.selected.allows | type == "array" and length > 0 and all(.[]; safe_path))
      and (.selected.follow_up | text and (contains($request) | not))
      and ((.selected.context_budget == null) or (.selected.context_budget | safe_budget))
      and ((.selected.catalog_visibility == null)
        or (.selected.catalog_visibility == "full" or .selected.catalog_visibility == "redacted"))
      and ((.selected.redacted == null) or (.selected.redacted | type == "boolean"))
      and ((.selected.trust == null) or (.selected.trust == "trusted" or .selected.trust == "untrusted"
        or .selected.trust == "unknown" or .selected.trust == true or .selected.trust == false))
      and ((.selected.freshness == null) or (.selected.freshness | type == "object"))
    ' >/dev/null 2>&1; then
    selection_error malformed_result "Megamind returned a malformed or unsafe selection result"
    return 1
  fi

  local projection result_file
  result_file="$(authorization_path "$selection_id")"
  [ ! -e "$result_file" ] && [ ! -L "$result_file" ] \
    || { selection_error selection_replayed "the selection authorization already exists"; return 1; }
  projection="$(printf '%s' "$raw" | jq -c --arg schema "$SELECTION_SCHEMA" \
    --arg id "$selection_id" --arg policy "$READ_POLICY" '
      def positive: type == "number" and . > 0;
      def safe_budget: if type == "object" then {
        max_candidates: (.max_candidates | if positive and floor == . then . else null end),
        max_context_chars: (.max_context_chars | if positive and floor == . then . else null end)
      } | with_entries(select(.value != null)) else null end;
      def safe_date: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . else null end;
      def safe_freshness: if type == "object" then {
        half_life_days: (.half_life_days | if positive then . else null end),
        last_confirmed: (.last_confirmed | safe_date),
        stale: (.stale | if type == "boolean" then . else null end)
      } else null end;
      def safe_counts: if type == "object" and ((keys | sort) == ["name","scope","trigger"])
        and all(.[]; type == "number" and floor == . and . >= 0)
        then {trigger:.trigger,name:.name,scope:.scope} else null end;
      def safe_classes($counts): (["trigger","name","scope"] | map(select($counts[.] > 0))) as $wanted |
        if type == "array" and (sort == ($wanted | sort)) then $wanted else null end;
      def safe_evidence: . as $e | ($e | if type == "object" then . else {} end) as $x
        | ($x.signal_counts | safe_counts) as $counts
        | ($x.lexical_classes | safe_classes($counts)) as $classes
        | ({semantic_score: ($x.semantic | if type == "number" then . else null end)}
          + if $counts != null and $classes != null then {lexical_classes:$classes,signal_counts:$counts,
              lexical_signal_count:([$counts[]] | add)} else {lexical_classes:[],signal_counts:null,
              lexical_signal_count:null} end);
      {schema_version:$schema,outcome:"authorized",failure:null,
       preflight_id:.preflight_id,request_hash:.request_hash,catalog_hash:.catalog_hash,
       model_class:.model_class,selection_id:$id,upstream_selection_id:.selection_id,
       root_facts_hash:.root_facts_hash,
       selection:{status:"explicit-user-selection",basis:"selected-current-offer",
         source_disposition:"offer",source_status:"ambiguous",preflight_id:.preflight_id,
         confidence_changed:false,threshold_matched:false},
       selected:{wiki:.selected.name,root:.selected.root,score:.selected.score,
         confidence:{score:.selected.confidence.score,meets_floor:false},
         freshness:(.selected.freshness | safe_freshness),
         evidence:(.selected.evidence | safe_evidence),
         access:.selected.access,routing_mode:.selected.routing_mode,
         allows:.selected.allows,follow_up:.selected.follow_up,
         provisional:false}
         + (if (.selected.context_budget | type) == "object"
            then {context_budget:(.selected.context_budget | safe_budget)} else {} end)
         + (if (.selected.catalog_visibility != null)
            then {catalog_visibility:.selected.catalog_visibility} else {} end)
         + (if (.selected.redacted != null) then {redacted:.selected.redacted} else {} end)
         + (if (.selected.trust != null) then {trust:.selected.trust} else {} end),
       notes:["Explicit selection authorizes only the selected offer current bounded access surface; it is not a threshold match."],
       read_policy:$policy}' )" || {
    selection_error projection_failed "the selection authorization could not be projected safely"
    return 1
  }
  if ! printf '%s\n' "$projection" | private_publish "$result_file"; then
    selection_error projection_failed "the selection authorization could not be published privately"
    return 1
  fi
  rm -f -- "$pending" || {
    selection_error retirement_failed "the consumed selection could not be retired safely"
    return 1
  }
  printf '%s\n' "$projection"
)

main() {
  [ $# -ge 1 ] || { printf 'usage: fm-megamind-preflight.sh classify|classify-provenance|run|continue|check ...\n' >&2; return 2; }
  local cmd="$1"; shift
  case "$cmd" in
    classify)
      [ $# -eq 1 ] || { printf 'usage: fm-megamind-preflight.sh classify "<request text>"\n' >&2; return 2; }
      classify "$1"
      ;;
    classify-provenance)
      [ $# -eq 1 ] || { printf 'usage: fm-megamind-preflight.sh classify-provenance credential-submission\n' >&2; return 2; }
      classify_provenance "$1"
      ;;
    run) cmd_run "$@" ;;
    continue) cmd_continue "$@" ;;
    check) cmd_check ;;
    *) printf 'usage: fm-megamind-preflight.sh classify|classify-provenance|run|continue|check ...\n' >&2; return 2 ;;
  esac
}

main "$@"
