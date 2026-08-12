#!/usr/bin/env bash
# Host-owned Megamind coordinator for supported primary prompt adapters.
# Usage: fm-megamind-primary.sh check --harness <harness>
#        fm-megamind-primary.sh process --harness <harness> --session-id <id>
#        fm-megamind-primary.sh continue --harness <harness> --session-id <id> \
#          --selection-id <opaque-id> --offer <exact-offer> [--include-replay]
#
# The prompt for process is read privately from stdin. Adapters own only their
# hook transport and response shape; this script owns classification, preflight,
# offer continuation, bounded admission, and context framing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PREFLIGHT="$FM_ROOT/bin/fm-megamind-preflight.sh"
READER="$FM_ROOT/bin/fm-megamind-content.sh"
PRIMARY_SCOPE_LIB="$FM_ROOT/bin/fm-primary-scope-lib.sh"
GATE_REFUSE_LIB="$FM_ROOT/bin/fm-gate-refuse-lib.sh"
SCHEMA="fm/megamind-primary-decision/v1"
PRIMARY_DIR="$STATE/megamind-primary"
PRIMARY_TIMEOUT="${FM_MEGAMIND_PRIMARY_TIMEOUT:-120}"
case "$PRIMARY_TIMEOUT" in ''|*[!0-9]*) PRIMARY_TIMEOUT=120 ;; esac

# Bounding a child is a liveness guard, not an authorization one, so it uses
# whichever bounded-execution helper this host has - timeout(1), gtimeout, or
# perl's alarm - and runs the child directly when a host has none. Refusing
# every substantive prompt because one optional helper is absent would turn a
# missing convenience into a blanket outage, and each adapter transport already
# imposes its own hook timeout above this one.
bounded_exec() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$PRIMARY_TIMEOUT" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$PRIMARY_TIMEOUT" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' "$PRIMARY_TIMEOUT" "$@"
  else
    "$@"
  fi
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

private_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}

current_session_identity() {
  local pid
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  IFS= read -r pid < "$STATE/.lock" 2>/dev/null || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  printf 'lock:%s\n' "$pid"
}

session_hash() {
  hash_text "firstmate-primary-session/v1\n$1"
}

automatic_enabled() {
  if [ -n "${FM_MEGAMIND_PRIMARY_AUTOMATIC:-}" ]; then
    case "$FM_MEGAMIND_PRIMARY_AUTOMATIC" in 1|true|on|yes) return 0 ;; esac
    return 1
  fi
  [ -f "$CONFIG/megamind-primary-automatic" ] || return 1
  local value
  IFS= read -r value < "$CONFIG/megamind-primary-automatic" 2>/dev/null || return 1
  case "$value" in 1|true|on|yes) return 0 ;; esac
  return 1
}

primary_scope_allowed() {
  [ "${FM_PRIMARY_SCOPE_OVERRIDE:-}" = 1 ] && return 0
  [ -f "$PRIMARY_SCOPE_LIB" ] || return 1
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$PRIMARY_SCOPE_LIB"
  fm_primary_scope_matches "$FM_ROOT" "$STATE"
}

# The same eligibility owner every other tracked hook uses, so a no-mistakes
# gate agent never has its prompts governed by the home it is only validating.
gate_agent_session() {
  [ "${FM_PRIMARY_SCOPE_OVERRIDE:-}" = 1 ] && return 1
  [ -f "$GATE_REFUSE_LIB" ] || return 1
  # shellcheck source=bin/fm-gate-refuse-lib.sh
  . "$GATE_REFUSE_LIB"
  fm_is_gate_agent "$FM_ROOT"
}

valid_harness() {
  case "$1" in claude|pi|pi-signed) return 0 ;; *) return 1 ;; esac
}

harness_status() {
  local harness="$1"
  case "$harness" in
    claude|pi|pi-signed)
      printf '{"schema_version":"%s","harness":"%s","automatic":"supported","enabled":%s}\n' \
        "$SCHEMA" "$harness" "$(automatic_enabled && printf true || printf false)"
      ;;
    codex|opencode|grok|kimi)
      printf '{"schema_version":"%s","harness":"%s","automatic":"unsupported","code":"primary_prompt_interception_unproven","message":"automatic primary mode is unsupported for this harness; ordinary operation remains available"}\n' \
        "$SCHEMA" "$harness"
      ;;
    muse)
      printf '{"schema_version":"%s","harness":"muse","automatic":"unsupported","code":"primary_worker_only","message":"Muse is worker/scout-only; ordinary operation remains available"}\n' "$SCHEMA"
      ;;
    *)
      printf '{"schema_version":"%s","harness":"unknown","automatic":"unsupported","code":"harness_unknown","message":"automatic primary mode is unsupported for this harness; ordinary operation remains available"}\n' "$SCHEMA"
      return 1
      ;;
  esac
}

decision() {
  local kind="$1" submission="$2" shash="$3" failure="${4:-}" selection="${5:-}" offers="${6:-[]}" context="${7:-null}" counts="${8:-0}" replay="${9:-}"
  command -v jq >/dev/null 2>&1 || {
    printf '{"schema_version":"%s","decision":"block","failure_code":"jq_missing"}\n' "$SCHEMA"
    return 0
  }
  jq -cn \
    --arg schema "$SCHEMA" --arg decision "$kind" --arg submission "$submission" \
    --arg session "$shash" --arg failure "$failure" --arg selection "$selection" \
    --argjson offers "$offers" --argjson context "$context" --argjson counts "$counts" \
    --arg replay "$replay" \
    '{schema_version:$schema,decision:$decision,submission_id:(if $submission=="" then null else $submission end),session_identity:(if $session=="" then null else $session end),failure_code:(if $failure=="" then null else $failure end),selection_id:(if $selection=="" then null else $selection end),offers:$offers,context:(if $context==null then null else $context end),admitted_chars:$counts,replay_prompt:(if $replay=="" then null else $replay end)}'
}

safe_submission_id() {
  [ "${#1}" -ge 16 ] && [ "${#1}" -le 128 ] && [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]
}

prune_private_records() {
  mkdir -p "$PRIMARY_DIR" 2>/dev/null || return 0
  chmod 700 "$PRIMARY_DIR" 2>/dev/null || true
  find "$PRIMARY_DIR" -maxdepth 1 -type f -name '*.decision.json' -mtime +0 -delete 2>/dev/null || true
  find "$PRIMARY_DIR" -maxdepth 1 -type f -name '*.offer.json' -mtime +0 -delete 2>/dev/null || true
  find "$STATE" -maxdepth 1 -type f -name 'fm-primary-*.megamind-preflight.json' -mtime +0 -delete 2>/dev/null || true
}

publish_private() {
  local destination="$1" old tmp
  tmp="${destination}.tmp.${BASHPID:-$$}"
  old=$(umask); umask 077
  if ! cat > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$destination"; then
    rm -f -- "$tmp" 2>/dev/null || true
    umask "$old"
    return 1
  fi
  umask "$old"
}

safe_offer_json() {
  printf '%s' "$1" | jq -c '[.offers[]? | select(.wiki | type == "string" and length > 0) | {wiki:.wiki,confidence:(.confidence // null)}]'
}

context_json() {
  local admission="$1" content="$2" chars="$3"
  jq -cn --arg source "bin/fm-megamind-content.sh content" --arg provenance "megamind-bounded-reader" \
    --arg text "$content" --argjson chars "$chars" \
    '{schema_version:"fm/megamind-primary-context/v1",provenance:$provenance,reader:$source,admitted_chars:$chars,text:$text}'
}

admit_context() {
  local task_id="$1" preflight_file="$2" admission out content counts context
  chmod 600 "$preflight_file" 2>/dev/null || return 1
  out=$(FM_HOME="$FM_HOME" bounded_exec "$READER" admit --task-id "$task_id" 2>/dev/null) || return 1
  [ "$(printf '%s' "$out" | jq -r '.outcome // empty')" = admitted ] || return 1
  admission=$(printf '%s' "$out" | jq -r '.admission_id // empty')
  [ -n "$admission" ] || return 1
  content=$(FM_HOME="$FM_HOME" bounded_exec "$READER" content --admission-id "$admission" 2>/dev/null) || return 1
  counts=$(printf '%s' "$out" | jq -r '[.wikis[]?.context_chars // 0] | add // 0')
  context=$(context_json "$admission" "$content" "$counts") || return 1
  printf '%s\t%s\n' "$context" "$counts"
}

process_prompt_inner() {
  local harness="$1" session_id="$2" submission_id="$3" prompt="$4"
  local current_lock shash classify_result raw outcome selection offers task_id preflight_file admitted context counts
  # Whether this session is a governed primary at all is settled before any
  # live-session requirement. A checkout that never opted in - a gate worktree,
  # a linked worktree, a worker copy, or a home with the guard off - keeps its
  # ordinary behavior instead of losing every prompt to a missing session lock.
  if gate_agent_session; then
    decision bypass "$submission_id" ""
    return
  fi
  if ! primary_scope_allowed; then
    decision bypass "$submission_id" ""
    return
  fi
  if ! automatic_enabled; then
    decision bypass "$submission_id" ""
    return
  fi
  shash=$(session_hash "$session_id") || { decision block "$submission_id" "" session_identity_unavailable; return; }
  current_lock=$(current_session_identity 2>/dev/null || true)
  [ -n "$current_lock" ] || { decision block "$submission_id" "$shash" session_unavailable; return; }
  prune_private_records
  if ! valid_harness "$harness"; then
    decision block "$submission_id" "$shash" harness_unsupported
    return
  fi
  classify_result=$(printf '%s' "$prompt" | "$PREFLIGHT" classify-stdin 2>/dev/null || true)
  case "$classify_result" in
    bypass)
      decision bypass "$submission_id" "$shash"
      return
      ;;
    substantive) : ;;
    *) decision block "$submission_id" "$shash" classification_failed; return ;;
  esac
  task_id="fm-primary-$submission_id"
  preflight_file="$STATE/$task_id.megamind-preflight.json"
  if ! raw=$(printf '%s' "$prompt" | FM_HOME="$FM_HOME" bounded_exec "$PREFLIGHT" run --request-stdin 2>/dev/null); then
    local code
    code=$(printf '%s' "$raw" | jq -r '.failure.code // "preflight_failed"' 2>/dev/null || printf 'preflight_failed')
    decision block "$submission_id" "$shash" "$code"
    return
  fi
  outcome=$(printf '%s' "$raw" | jq -r '.outcome // empty' 2>/dev/null || true)
  case "$outcome" in
    no-match|privacy-filtered)
      decision proceed-no-context "$submission_id" "$shash"
      ;;
    matched)
      printf '%s\n' "$raw" | publish_private "$preflight_file" || { decision block "$submission_id" "$shash" authorization_write_failed; return; }
      admitted=$(admit_context "$task_id" "$preflight_file") || { decision block "$submission_id" "$shash" admission_failed; return; }
      context=${admitted%%$'\t'*}; counts=${admitted#*$'\t'}
      decision proceed-with-admission "$submission_id" "$shash" "" "" '[]' "$context" "$counts"
      ;;
    ambiguous)
      selection=$(printf '%s' "$raw" | jq -r '.selection_id // empty')
      offers=$(safe_offer_json "$raw") || { decision block "$submission_id" "$shash" offer_projection_failed; return; }
      if [ -n "$selection" ]; then
        jq -cn --arg schema "$SCHEMA" --arg selection "$selection" --arg session "$shash" --arg task "$task_id" \
          '{schema_version:$schema,selection_id:$selection,session_identity:$session,task_id:$task}' \
          | publish_private "$PRIMARY_DIR/$selection.offer.json" || { decision block "$submission_id" "$shash" offer_write_failed; return; }
      fi
      decision offer "$submission_id" "$shash" "" "$selection" "$offers"
      ;;
    unavailable) decision block "$submission_id" "$shash" unavailable ;;
    *) decision block "$submission_id" "$shash" preflight_failed ;;
  esac
}

process_prompt() {
  local harness="$1" session_id="$2" submission_id="$3" prompt="$4"
  local record="$PRIMARY_DIR/$submission_id.decision.json" lock="$PRIMARY_DIR/.$submission_id.lock" output
  prune_private_records
  if [ -f "$record" ] && [ ! -L "$record" ] && [ "$(private_mode "$record" 2>/dev/null)" = 600 ]; then
    cat "$record"
    return 0
  fi
  if ! mkdir -- "$lock" 2>/dev/null; then
    decision block "$submission_id" "" concurrent_submission
    return 0
  fi
  chmod 700 "$lock" 2>/dev/null || true
  output=$(process_prompt_inner "$harness" "$session_id" "$submission_id" "$prompt") || true
  if ! printf '%s\n' "$output" | publish_private "$record"; then
    rm -rf -- "$lock" 2>/dev/null || true
    decision block "$submission_id" "" decision_write_failed
    return 0
  fi
  rm -rf -- "$lock" 2>/dev/null || true
  printf '%s\n' "$output"
}

continue_selection() {
  local harness="$1" session_id="$2" selection_id="$3" offer="$4" include_replay="$5"
  local current_lock shash record stored_session raw task_id preflight_file admitted context counts replay pending_request
  valid_harness "$harness" || { decision block "" "" harness_unsupported; return; }
  current_lock=$(current_session_identity 2>/dev/null || true)
  shash=$(session_hash "$session_id" 2>/dev/null || true)
  [ -n "$current_lock" ] && [ -n "$shash" ] || { decision block "" "" session_unavailable; return; }
  safe_submission_id "$selection_id" || { decision block "" "$shash" selection_id_invalid; return; }
  [ -n "$offer" ] || { decision block "" "$shash" offer_invalid; return; }
  record="$PRIMARY_DIR/$selection_id.offer.json"
  [ -f "$record" ] && [ "$(private_mode "$record" 2>/dev/null)" = 600 ] || { decision block "" "$shash" selection_missing; return; }
  stored_session=$(jq -r '.session_identity // empty' "$record" 2>/dev/null || true)
  [ "$stored_session" = "$shash" ] || { decision block "" "$shash" wrong_session; return; }
  if [ "$include_replay" -eq 1 ]; then
    pending_request=$(jq -r '.request // empty' "$STATE/megamind-offer-selections/$selection_id.pending.json" 2>/dev/null || true)
    [ -n "$pending_request" ] || { decision block "" "$shash" replay_unavailable; return; }
  fi
  raw=$(FM_HOME="$FM_HOME" "$PREFLIGHT" continue --selection-id "$selection_id" --offer "$offer" 2>/dev/null) || {
    local code
    code=$(printf '%s' "$raw" | jq -r '.failure.code // "selection_failed"' 2>/dev/null || printf 'selection_failed')
    decision block "" "$shash" "$code"
    return
  }
  [ "$(printf '%s' "$raw" | jq -r '.outcome // empty')" = authorized ] || { decision block "" "$shash" selection_failed; return; }
  task_id=$(jq -r '.task_id // empty' "$record")
  # The continuation authorization is keyed by the opaque selection id.
  admitted=$(FM_HOME="$FM_HOME" bounded_exec "$READER" admit --selection-id "$selection_id" 2>/dev/null) || { decision block "" "$shash" admission_failed; return; }
  [ "$(printf '%s' "$admitted" | jq -r '.outcome // empty')" = admitted ] || { decision block "" "$shash" admission_failed; return; }
  local admission
  admission=$(printf '%s' "$admitted" | jq -r '.admission_id // empty')
  replay=
  if [ "$include_replay" -eq 1 ]; then
    # The original request is returned solely to a proven hook transport for one
    # replay, never to general output or a durable coordinator record.
    replay="$pending_request"
  fi
  local content
  content=$(FM_HOME="$FM_HOME" bounded_exec "$READER" content --admission-id "$admission" 2>/dev/null) || { decision block "" "$shash" content_failed; return; }
  counts=$(printf '%s' "$admitted" | jq -r '[.wikis[]?.context_chars // 0] | add // 0')
  context=$(context_json "$admission" "$content" "$counts") || { decision block "" "$shash" context_failed; return; }
  rm -f -- "$record" 2>/dev/null || true
  decision proceed-with-admission "" "$shash" "" "" '[]' "$context" "$counts" "$replay"
}

main() {
  local cmd="${1:-}" harness="" session_id="" submission_id="" selection_id="" offer="" provenance="" include_replay=0 prompt
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness) [ $# -ge 2 ] || exit 2; harness="$2"; shift 2 ;;
      --session-id) [ $# -ge 2 ] || exit 2; session_id="$2"; shift 2 ;;
      --submission-id) [ $# -ge 2 ] || exit 2; submission_id="$2"; shift 2 ;;
      --selection-id) [ $# -ge 2 ] || exit 2; selection_id="$2"; shift 2 ;;
      --offer) [ $# -ge 2 ] || exit 2; offer="$2"; shift 2 ;;
      --provenance) [ $# -ge 2 ] || exit 2; provenance="$2"; shift 2 ;;
      --include-replay) include_replay=1; shift ;;
      *) printf '%s\n' 'usage: fm-megamind-primary.sh check|process|continue' >&2; return 2 ;;
    esac
  done
  case "$cmd" in
    check) harness_status "$harness" ;;
    process)
      safe_submission_id "$submission_id" || { submission_id="p$(date +%s).$$.$RANDOM"; }
      case "$provenance" in
        '') prompt=$(cat) ;;
        credential-submission) prompt= ;;
        *) decision block "$submission_id" "" unknown_provenance; return 0 ;;
      esac
      process_prompt "$harness" "$session_id" "$submission_id" "$prompt"
      ;;
    continue) continue_selection "$harness" "$session_id" "$selection_id" "$offer" "$include_replay" ;;
    *) printf '%s\n' 'usage: fm-megamind-primary.sh check|process|continue' >&2; return 2 ;;
  esac
}

main "$@"
