# shellcheck shell=bash
# Shared TypeSafe Jev caller for Firstmate shadow features.
# Usage: . bin/fm-jev-lib.sh
#
# This file is the single owner of how Firstmate talks to TypeSafe Jev. Feature
# tasks source it and call the helpers below; they do not roll their own HTTP
# client. It is a sourceable library, not a user CLI: executing it prints a
# one-line usage hint and exits 2.
#
# Dual route (resolved at each fm_jev_decide call):
#   - TypeSafe POST https://api.typesafe.ai/v1/systemone with TYPESAFE_API_KEY,
#     pinned model FM_JEV_TYPESAFE_MODEL unless JEV_MODEL is set.
#   - OpenRouter POST https://openrouter.ai/api/alpha/decisions with
#     OPENROUTER_API_KEY, pinned model FM_JEV_OPENROUTER_MODEL unless JEV_MODEL
#     is set.
#   Both defaults are versioned builds, never a moving alias such as
#   jev-latest, so answers cannot shift without a change here; this file is
#   the one owner of the pins, and callers never name a model of their own.
#   An explicit JEV_MODEL override should be a dated pin; any unpinned override
#   is honored but warns once on stderr.
#   JEV_ROUTE=openrouter selects OpenRouter even when a TypeSafe key is also
#   present. JEV_ROUTE=typesafe requires a TypeSafe key. With JEV_ROUTE unset,
#   a TypeSafe key wins; otherwise a present OpenRouter key is used. Each key,
#   JEV_ROUTE, JEV_MODEL, JEV_TIMEOUT, JEV_URL, and JEV_BASE is taken from the
#   process environment first, else from $FM_HOME/.env via fmx_env_get
#   (bin/fm-env-lib.sh); the environment wins.
#   JEV_URL is a complete POST URL used verbatim (nothing is appended).
#   JEV_BASE applies only on the TypeSafe route when JEV_URL is unset: the
#   default /v1/systemone path is appended to that origin. OpenRouter never
#   receives /v1/systemone from JEV_BASE.
#
# Key handling matches bin/fm-dispatch-resolve.sh: the chosen secret lives in a
# function-local non-exported variable and reaches curl only as an
# Authorization header read from a file descriptor, never on argv. Curl runs
# in a subshell with the API-key names unset so the secret is absent from the
# child environment. Nothing prints, logs, or writes the key.
#
# Public helpers:
#   fm_jev_decide <state> <questions-json> [--string] [--before-send <function>]
#     Evaluation seam: with FM_JEV_REPLAY_DIR set, the answer comes from the
#     cassette <dir>/<sha256 of the canonical {state, questions}>.json and no
#     key or network is needed; a missing cassette is exit 1 (logged to
#     FM_JEV_REPLAY_MISS_LOG when set), because the request changed since it
#     was recorded. --before-send still runs on a replayed request, before the
#     cassette lookup; its model is JEV_MODEL when set, else "replay". With
#     FM_JEV_RECORD_DIR set, every successful live answer is also written
#     there as {model, response}. bin/fm-jev-eval.sh owns both.
#     POST {model, state, questions}. By default, <state> is a JSON object or
#     array when the argument parses as one, otherwise a string; --string
#     forces a JSON string. <questions-json> is a JSON object. An optional
#     --before-send shell function receives the complete assembled request as
#     one JSON argument, including the resolved model, before transport.
#     A non-zero result refuses the request without calling curl, returns 2,
#     and sets FM_JEV_LAST_REQUEST_REJECTED=1 (reset to empty on every call).
#     Prints the full JSON response on stdout. Non-zero on hard failure:
#     2 for usage/config (missing args, missing key, missing jq/curl, questions
#     not a JSON object, invalid validator) or validator refusal; 1 for
#     transport or a non-JSON / non-200 response. Sets FM_JEV_LAST_ROUTE,
#     FM_JEV_LAST_URL, FM_JEV_LAST_MODEL, FM_JEV_LAST_HTTP, and
#     FM_JEV_LAST_LATENCY_MS on every attempted call (empty HTTP/latency when
#     the call never reached curl).
#   fm_jev_response_model <response-json>
#     Prints the response's `model` string, the exact build that answered, or
#     nothing when absent. Callers that record a call's result log it as
#     response_model next to the answer.
#   fm_jev_key_configured
#     Succeeds when either API key is present in the process environment or
#     $FM_HOME/.env; it does not validate JEV_ROUTE and never reaches the network.
#     Callers use it as the no-key fast path; fm_jev_decide reports route errors.
#   fm_jev_choice_confidence_ok <confidence> [<floor>]
#     Succeeds when <confidence> is a number in 0..1 at or above <floor>.
#     Default floor is 0.7 (new shadows); typed dispatch uses the top-2 margin.
#     JEV_CONFIDENCE_FLOOR overrides the default when <floor> is omitted.
#   fm_jev_probabilities_sum_ok <probabilities-json>
#     Succeeds when the value is a JSON object of numbers in 0..1 that sum to
#     approximately 1 within 0.01.
#   FM_JEV_CHOICE_TOP2_JQ
#     The shared jq definition `jev_choice_top2` for the resolver and replay
#     scorer; it owns top-2 ordering and margin arithmetic.
#   fm_jev_log_call <json-object> [<path>]
#     Appends one JSONL line. Default path is $FM_HOME/state/jev-calls.jsonl.
#     Known secret-shaped object keys are replaced with [redacted]; live
#     TYPESAFE_API_KEY / OPENROUTER_API_KEY values are stripped from the line.
#   fm_jev_compact_state <state>
#     Strips obvious secret-shaped tokens and prints the remainder. Refuses
#     (exit 1) when the raw state exceeds JEV_STATE_MAX_BYTES (default 8192).
#     A credential value is consumed through the end of its line, or its whole
#     flow or block value, so escaped quotes inside it never end the redaction
#     early, and every GitHub token prefix (ghp_, gho_, ghu_, ghs_, ghr_,
#     github_pat_) is stripped.
#   fm_jev_iso_now
#     Prints the current UTC time as an ISO-8601 second timestamp.
#   fm_jev_site_mode <site>
#     Prints act or advise for one call site named in tests/jev-eval/sites.json.
#     act needs per-site evidence in the latest scorecard (FM_JEV_EVAL_SCORES,
#     default $FM_HOME/state/jev-eval/latest.json, written by bin/fm-jev-eval.sh)
#     that is final, matches the effective model, is no older than
#     FM_JEV_EVAL_MAX_AGE_SECS (default 8 days), and gives that site at least
#     FM_JEV_EVAL_MIN_CASES cases, agreement with gold
#     at or above FM_JEV_EVAL_BAR (0.95), and zero dangerous misses. Anything
#     else, including a missing or unreadable scorecard, is advise; merge-gate
#     is always advise. An advise site still asks Jev but hands its answer to
#     the human or the caller's own judgment instead of acting on it.
#   fm_jev_supervision_timeout
#     Prints the per-call HTTP bound for the supervision consults: JEV_TIMEOUT
#     from the environment or $FM_HOME/.env when it is a positive integer,
#     else FM_JEV_SUPERVISION_TIMEOUT_SECS, else 3.
#   fm_jev_supervision_free_text_ok <state-dir> <task-id>
#     The supervision payload boundary. Succeeds only when this home is the
#     primary firstmate home (no .fm-secondmate-home marker under $FM_HOME),
#     the task record <state-dir>/<task-id>.meta is a regular file whose kind
#     is ship or scout, and its project= is this firstmate repository itself
#     (same resolved path as the code root, or the same resolved Git common directory).
#     Any other case, including an unreadable record or a missing kind, fails.
#     Supervision triage, the wedge check, and the shadow done verifier all
#     gate their free-text payloads on it.
#   fm_jev_supervision_state <status-line|pane-tail> <text> <free-text:0|1>
#     Prints the Jev state for one supervision consult. With free-text 1 it is
#     the size-capped text (FM_JEV_SUPERVISION_FREE_TEXT_MAX_CHARS, first chars
#     of a status line, last chars of a pane tail) run through
#     fm_jev_compact_state; a pane tail also masks every 32+ character opaque
#     token and any bare "token <value>". With free-text 0 it is a JSON object
#     of structured facts only - verb, counts (for a pane tail, also how often
#     its most repeated line recurs), and fixed-vocabulary signal flags - and
#     carries no text from the input.
#
# Environment (library-specific):
#   TYPESAFE_API_KEY, OPENROUTER_API_KEY, JEV_ROUTE, JEV_MODEL, JEV_URL,
#   JEV_BASE, JEV_TIMEOUT (positive integer seconds, default 25),
#   JEV_CONFIDENCE_FLOOR, JEV_STATE_MAX_BYTES, FM_HOME, FM_JEV_REPLAY_DIR,
#   FM_JEV_REPLAY_MISS_LOG, FM_JEV_RECORD_DIR, FM_JEV_EVAL_SCORES,
#   FM_JEV_EVAL_MAX_AGE_SECS.
#   docs/configuration.md "Typed dispatch resolution" owns the override names.
#
# bin/fm-dispatch-resolve.sh uses this library for the HTTP call.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  printf 'fm-jev-lib.sh is a sourceable library. Usage: . bin/fm-jev-lib.sh\n' >&2
  exit 2
fi

if [ -n "${_FM_JEV_LIB_SOURCED:-}" ]; then
  return 0
fi
_FM_JEV_LIB_SOURCED=1

_FM_JEV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FM_JEV_ROOT="$(cd "$_FM_JEV_LIB_DIR/.." && pwd)"

# shellcheck source=bin/fm-env-lib.sh
. "$_FM_JEV_LIB_DIR/fm-env-lib.sh"

FM_JEV_TYPESAFE_BASE='https://api.typesafe.ai'
FM_JEV_TYPESAFE_PATH='/v1/systemone'
FM_JEV_TYPESAFE_URL="${FM_JEV_TYPESAFE_BASE}${FM_JEV_TYPESAFE_PATH}"
FM_JEV_OPENROUTER_URL='https://openrouter.ai/api/alpha/decisions'
# Pinned versioned builds; changing either is a deliberate, re-probed change.
FM_JEV_TYPESAFE_MODEL='jev-1.13.0'
FM_JEV_OPENROUTER_MODEL='typesafe/jev-1.13-20260917'
# The autonomy bar every call site must clear before fm_jev_site_mode says act.
FM_JEV_EVAL_BAR=0.95
FM_JEV_EVAL_MIN_CASES=20
FM_JEV_EVAL_MAX_AGE_DEFAULT=691200
FM_JEV_CONFIDENCE_FLOOR=0.7
FM_JEV_STATE_MAX_BYTES=8192
FM_JEV_TIMEOUT=25

_fm_jev_err() {
  printf 'jev: %s\n' "$1" >&2
}

_fm_jev_now_ms() {
  local raw sec frac
  raw=${EPOCHREALTIME:-}
  case "$raw" in
    *[0-9][.,][0-9]*)
      sec=${raw%%[.,]*}
      frac=${raw#*[.,]}
      frac="${frac}000"
      frac=${frac:0:3}
      case "$sec$frac" in
        ''|*[!0-9]*) ;;
        *) printf '%s\n' "$((sec * 1000 + 10#$frac))"; return 0 ;;
      esac
      ;;
  esac
  sec=$(date +%s 2>/dev/null || printf '0')
  case "$sec" in ''|*[!0-9]*) sec=0 ;; esac
  printf '%s\n' "$((sec * 1000))"
}

_fm_jev_home() {
  printf '%s' "${FM_HOME:-$_FM_JEV_ROOT}"
}

# Non-secret JEV_* value: process environment wins, else $FM_HOME/.env.
_fm_jev_cfg() {
  local key=$1 val
  val=${!key-}
  if [ -z "$val" ]; then
    val=$(fmx_env_get "$key" "$(_fm_jev_home)/.env")
  fi
  printf '%s' "$val"
}

_fm_jev_timeout() {
  local timeout
  timeout=$(_fm_jev_cfg JEV_TIMEOUT)
  [ -n "$timeout" ] || timeout=$FM_JEV_TIMEOUT
  case "$timeout" in
    ''|*[!0-9]*|0) printf '%s' "$FM_JEV_TIMEOUT" ;;
    *) printf '%s' "$timeout" ;;
  esac
}

_fm_jev_state_max() {
  local max=${JEV_STATE_MAX_BYTES:-$FM_JEV_STATE_MAX_BYTES}
  case "$max" in
    ''|*[!0-9]*|0) printf '%s' "$FM_JEV_STATE_MAX_BYTES" ;;
    *) printf '%s' "$max" ;;
  esac
}

# Resolve route into _fm_jev_route, _fm_jev_url, _fm_jev_model, _fm_jev_key.
# The key variable is local to the caller of this function (fm_jev_decide).
_fm_jev_resolve_route() {
  local typesafe_key openrouter_key home route configured_model pinned_model
  typesafe_key=${TYPESAFE_API_KEY_PRIVATE:-${TYPESAFE_API_KEY:-}}
  openrouter_key=${OPENROUTER_API_KEY_PRIVATE:-${OPENROUTER_API_KEY:-}}
  home=$(_fm_jev_home)
  if [ -z "$typesafe_key" ]; then
    typesafe_key=$(fmx_env_get TYPESAFE_API_KEY "$home/.env")
  fi
  if [ -z "$openrouter_key" ]; then
    openrouter_key=$(fmx_env_get OPENROUTER_API_KEY "$home/.env")
  fi
  route=$(_fm_jev_cfg JEV_ROUTE)
  case "$route" in
    openrouter)
      if [ -z "$openrouter_key" ]; then
        _fm_jev_err "OPENROUTER_API_KEY missing for JEV_ROUTE=openrouter"
        return 2
      fi
      _fm_jev_route=openrouter
      ;;
    typesafe)
      if [ -z "$typesafe_key" ]; then
        _fm_jev_err "TYPESAFE_API_KEY missing for JEV_ROUTE=typesafe"
        return 2
      fi
      _fm_jev_route=typesafe
      ;;
    '')
      if [ -n "$typesafe_key" ]; then
        _fm_jev_route=typesafe
      elif [ -n "$openrouter_key" ]; then
        _fm_jev_route=openrouter
      else
        _fm_jev_err "no TYPESAFE_API_KEY or OPENROUTER_API_KEY in the environment or $home/.env"
        return 2
      fi
      ;;
    *)
      _fm_jev_err "unknown JEV_ROUTE=$route (want openrouter, typesafe, or empty)"
      return 2
      ;;
  esac
  if [ "$_fm_jev_route" = openrouter ]; then
    _fm_jev_key=$openrouter_key
    pinned_model=$FM_JEV_OPENROUTER_MODEL
  else
    _fm_jev_key=$typesafe_key
    pinned_model=$FM_JEV_TYPESAFE_MODEL
  fi
  configured_model=$(_fm_jev_cfg JEV_MODEL)
  if [ -n "$configured_model" ]; then
    _fm_jev_model=$configured_model
    if [ "$_fm_jev_model" != "$pinned_model" ] && [[ ! "$_fm_jev_model" =~ -[0-9]{8}$ ]]; then
      _fm_jev_err "JEV_MODEL override '$configured_model' is not a dated pin; use a dated build or the route's pinned model"
    fi
  else
    _fm_jev_model=$pinned_model
  fi
  _fm_jev_url=$(_fm_jev_cfg JEV_URL)
  if [ -z "$_fm_jev_url" ]; then
    if [ "$_fm_jev_route" = openrouter ]; then
      _fm_jev_url=$FM_JEV_OPENROUTER_URL
    else
      _fm_jev_url=$(_fm_jev_cfg JEV_BASE)
      if [ -n "$_fm_jev_url" ]; then
        _fm_jev_url=${_fm_jev_url%/}$FM_JEV_TYPESAFE_PATH
      else
        _fm_jev_url=$FM_JEV_TYPESAFE_URL
      fi
    fi
  fi
}

fm_jev_decide() {
  local state questions payload request resp_file http t0 t1 timeout state_mode before_send
  local _fm_jev_route _fm_jev_url _fm_jev_model _fm_jev_key
  export -n TYPESAFE_API_KEY OPENROUTER_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY_PRIVATE 2>/dev/null || true
  FM_JEV_LAST_ROUTE=''
  FM_JEV_LAST_URL=''
  FM_JEV_LAST_MODEL=''
  FM_JEV_LAST_HTTP=''
  FM_JEV_LAST_LATENCY_MS=''
  FM_JEV_LAST_REQUEST_REJECTED=''
  if [ $# -lt 2 ]; then
    _fm_jev_err "usage: fm_jev_decide <state> <questions-json> [--string] [--before-send <function>]"
    return 2
  fi
  state=$1
  questions=$2
  shift 2
  state_mode=auto
  before_send=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --string)
        state_mode=string
        shift
        ;;
      --before-send)
        if [ "$#" -lt 2 ] || [ -n "$before_send" ]; then
          _fm_jev_err "usage: fm_jev_decide <state> <questions-json> [--string] [--before-send <function>]"
          return 2
        fi
        before_send=$2
        shift 2
        ;;
      *)
        _fm_jev_err "usage: fm_jev_decide <state> <questions-json> [--string] [--before-send <function>]"
        return 2
        ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || { _fm_jev_err "jq required"; return 2; }
  command -v curl >/dev/null 2>&1 || { _fm_jev_err "curl not installed"; return 2; }
  printf '%s' "$questions" | jq -e 'type == "object"' >/dev/null 2>&1 || {
    _fm_jev_err "questions must be a JSON object"
    return 2
  }
  if [ "$state_mode" = auto ] && printf '%s' "$state" | jq -e 'type == "object" or type == "array"' >/dev/null 2>&1; then
    payload=$(jq -cn --argjson state "$state" --argjson questions "$questions" \
      '{state: $state, questions: $questions}') || {
      _fm_jev_err "could not build request"
      return 2
    }
  else
    payload=$(jq -cn --arg state "$state" --argjson questions "$questions" \
      '{state: $state, questions: $questions}') || {
      _fm_jev_err "could not build request"
      return 2
    }
  fi
  if [ -n "${FM_JEV_REPLAY_DIR:-}" ]; then
    if [ -n "$before_send" ]; then
      request=$(printf '%s' "$payload" | jq --arg model "$(_fm_jev_cfg JEV_MODEL)" '{model: (if $model == "" then "replay" else $model end)} + .') || {
        _fm_jev_err "could not build request"
        return 2
      }
      _fm_jev_before_send "$before_send" "$request" || return 2
    fi
    _fm_jev_replay "$payload"
    return
  fi
  _fm_jev_resolve_route || return 2
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_JEV_LAST_ROUTE=$_fm_jev_route
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_JEV_LAST_URL=$_fm_jev_url
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_JEV_LAST_MODEL=$_fm_jev_model
  request=$(printf '%s' "$payload" | jq --arg model "$_fm_jev_model" '{model: $model} + .') || {
    _fm_jev_err "could not build request"
    return 2
  }
  _fm_jev_before_send "$before_send" "$request" || return 2
  resp_file=$(mktemp) || { _fm_jev_err "mktemp failed"; return 2; }
  timeout=$(_fm_jev_timeout)
  t0=$(_fm_jev_now_ms)
  http=$(
    printf '%s' "$request" | curl -sS --max-time "$timeout" -o "$resp_file" -w '%{http_code}' \
      -X POST "$_fm_jev_url" -H 'Content-Type: application/json' \
      -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$_fm_jev_key") \
      --data-binary @- 2>/dev/null
  ) || http=000
  t1=$(_fm_jev_now_ms)
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_JEV_LAST_HTTP=$http
  FM_JEV_LAST_LATENCY_MS=$((t1 - t0))
  if [ "$http" != 200 ]; then
    _fm_jev_err "http $http after ${FM_JEV_LAST_LATENCY_MS} ms: $(head -c 200 "$resp_file" 2>/dev/null | tr '\n' ' ')"
    rm -f "$resp_file"
    return 1
  fi
  if ! jq -e 'type == "object"' "$resp_file" >/dev/null 2>&1; then
    _fm_jev_err "response is not a JSON object"
    rm -f "$resp_file"
    return 1
  fi
  if [ -n "${FM_JEV_RECORD_DIR:-}" ]; then
    _fm_jev_record "$payload" "$resp_file" || _fm_jev_err "could not record the answer under $FM_JEV_RECORD_DIR"
  fi
  cat "$resp_file"
  rm -f "$resp_file"
  return 0
}

# Runs the optional --before-send validator on the assembled request. A
# missing function is a usage error; a refusal sets
# FM_JEV_LAST_REQUEST_REJECTED=1. Either way the caller returns 2.
_fm_jev_before_send() {  # <function-or-empty> <request-json>
  [ -n "$1" ] || return 0
  declare -F "$1" >/dev/null 2>&1 || { _fm_jev_err "request validator is not a function"; return 2; }
  if ! "$1" "$2"; then
    # shellcheck disable=SC2034 # Read by sourcing callers after fm_jev_decide returns.
    FM_JEV_LAST_REQUEST_REJECTED=1
    return 2
  fi
}

# Cassette key: the sha256 of the canonical {state, questions} payload. The
# model is left out so a pin change is caught by comparing the recorded model,
# not by a silent key miss.
_fm_jev_cassette_key() {
  local canonical
  canonical=$(printf '%s' "$1" | jq -cS .) || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$canonical" | sha256sum | cut -c1-64
  else
    printf '%s' "$canonical" | shasum -a 256 | cut -c1-64
  fi
}

_fm_jev_replay() {
  local key cassette
  key=$(_fm_jev_cassette_key "$1") || { _fm_jev_err "could not key the request"; return 2; }
  cassette=$FM_JEV_REPLAY_DIR/$key.json
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_JEV_LAST_ROUTE=replay
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_JEV_LAST_URL=$cassette
  FM_JEV_LAST_LATENCY_MS=0
  if [ ! -f "$cassette" ]; then
    FM_JEV_LAST_HTTP=000
    [ -z "${FM_JEV_REPLAY_MISS_LOG:-}" ] || printf '%s\n' "$key" >>"$FM_JEV_REPLAY_MISS_LOG"
    _fm_jev_err "replay miss $key: the request changed since it was recorded"
    return 1
  fi
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_JEV_LAST_MODEL=$(jq -r '.model // empty' "$cassette" 2>/dev/null)
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_JEV_LAST_HTTP=200
  jq -c '.response' "$cassette"
}

_fm_jev_record() {
  local key
  key=$(_fm_jev_cassette_key "$1") || return 1
  mkdir -p "$FM_JEV_RECORD_DIR" || return 1
  jq -cS --arg model "$FM_JEV_LAST_MODEL" '{model: $model, response: .}' "$2" >"$FM_JEV_RECORD_DIR/$key.json"
}

fm_jev_response_model() {
  printf '%s' "${1:-}" | jq -r 'if type == "object" and (.model | type) == "string" then .model else empty end' 2>/dev/null || true
}

fm_jev_key_configured() {
  local typesafe_key openrouter_key home
  [ -z "${FM_JEV_REPLAY_DIR:-}" ] || return 0
  home=$(_fm_jev_home)
  typesafe_key=${TYPESAFE_API_KEY:-}
  openrouter_key=${OPENROUTER_API_KEY:-}
  [ -n "$typesafe_key" ] || typesafe_key=$(fmx_env_get TYPESAFE_API_KEY "$home/.env")
  [ -n "$openrouter_key" ] || openrouter_key=$(fmx_env_get OPENROUTER_API_KEY "$home/.env")
  [ -n "$typesafe_key" ] || [ -n "$openrouter_key" ]
}

fm_jev_choice_confidence_ok() {
  local confidence floor
  if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    _fm_jev_err "usage: fm_jev_choice_confidence_ok <confidence> [<floor>]"
    return 2
  fi
  confidence=$1
  floor=${2:-${JEV_CONFIDENCE_FLOOR:-$FM_JEV_CONFIDENCE_FLOOR}}
  awk -v c="$confidence" -v f="$floor" 'BEGIN {
    if (c !~ /^-?[0-9]+(\.[0-9]+)?$/ || f !~ /^-?[0-9]+(\.[0-9]+)?$/) exit 1
    if (c+0 < 0 || c+0 > 1) exit 1
    exit !(c+0 >= f+0)
  }'
}

fm_jev_probabilities_sum_ok() {
  if [ $# -ne 1 ]; then
    _fm_jev_err "usage: fm_jev_probabilities_sum_ok <probabilities-json>"
    return 2
  fi
  command -v jq >/dev/null 2>&1 || { _fm_jev_err "jq required"; return 2; }
  printf '%s' "$1" | jq -e '
    type == "object"
    and (keys | length) > 0
    and all(.[]; type == "number" and . >= 0 and . <= 1)
    and (([.[]] | add) as $t | $t >= 0.99 and $t <= 1.01)
  ' >/dev/null 2>&1
}

# shellcheck disable=SC2016,SC2034  # a jq program expanded by jq, consumed by the scripts that source this library
FM_JEV_CHOICE_TOP2_JQ='def jev_choice_top2:
  (to_entries | sort_by(-.value, .key)) as $s
  | ((($s[0].value // 0) - ($s[1].value // 0))) as $raw_margin
  | {first: ($s[0].key // null), second: ($s[1].key // null), raw_margin: $raw_margin,
     margin: (($raw_margin * 10000 | round) / 10000)};'

# One owner of the benign-key exception both key scans apply: a key whose
# suffix is "pass" is sensitive only when its last segment is exactly pass
# (FM_MAIL_PASS, db-pass, mailPass, a bare YAML pass:), so a word such as
# Engpass is not; and a bare pass after a prose word, followed by prose words,
# is a sentence such as "Keyboard pass: every control reachable", not a key.
# Callers save RSTART and RLENGTH first, because match() here resets them.
# shellcheck disable=SC2016 # an awk program, expanded by awk
_FM_JEV_BENIGN_KEY_AWK='
    function benign_key(key_name, normalized_key, boundary, prev_char, after,    last) {
      if (normalized_key !~ /pass$/ || normalized_key ~ /(password|passwd)$/) return 0
      last = key_name
      sub(/^.*[-_.]/, "", last)
      if (last ~ /[a-z]/ && match(last, /[A-Z][a-z]*$/) && RSTART > 1) last = substr(last, RSTART)
      if (tolower(last) != "pass") return 1
      return key_name == last && boundary ~ /[ \t]/ && prev_char ~ /[[:alpha:]]/ \
        && after ~ /^[ \t]*[[:alpha:]][[:alpha:]-]*[ \t,;]+[[:alpha:]]/
    }
'

fm_jev_has_sensitive_key() {
  local text
  if [ $# -ne 1 ]; then
    _fm_jev_err "usage: fm_jev_has_sensitive_key <text>"
    return 2
  fi
  text=$1
  printf '%s' "$text" | awk "$_FM_JEV_BENIGN_KEY_AWK"'
    BEGIN {
      assignment_pattern = "(^|[^[:alnum:]_])([-[:alnum:]_.]+)[\042\047]?[ \t]*[:=]"
      sensitive_suffix_pattern = "(password|passwd|pwd|pass|secret|token|apikey|secretkey|accesskey|privatekey|clientsecret|auth|credential)$"
    }
    {
      remaining = $0
      while (length(remaining) > 0) {
        if (!match(remaining, assignment_pattern)) break
        assignment = substr(remaining, RSTART, RLENGTH)
        boundary = substr(assignment, 1, 1)
        key_name = assignment
        if (boundary ~ /[^[:alnum:]_]/) key_name = substr(assignment, 2)
        sub(/[\042\047]?[ \t]*[:=]$/, "", key_name)
        normalized_key = tolower(key_name)
        gsub(/[-_.]/, "", normalized_key)
        assignment_start = RSTART
        assignment_end = RSTART + RLENGTH
        if (normalized_key ~ sensitive_suffix_pattern \
          && !benign_key(key_name, normalized_key, boundary, \
            substr(remaining, assignment_start - 1, 1), substr(remaining, assignment_end))) {
          found = 1
          exit
        }
        remaining = substr(remaining, assignment_end)
      }
    }
    END { exit(found ? 0 : 1) }
  '
}

fm_jev_compact_state() {
  local state max bytes
  if [ $# -ne 1 ]; then
    _fm_jev_err "usage: fm_jev_compact_state <state>"
    return 2
  fi
  state=$1
  max=$(_fm_jev_state_max)
  bytes=$(printf '%s' "$state" | wc -c)
  bytes=${bytes// /}
  case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
  if [ "$bytes" -gt "$max" ]; then
    _fm_jev_err "state exceeds $max bytes"
    return 1
  fi
  printf '%s' "$state" | awk "$_FM_JEV_BENIGN_KEY_AWK"'
    # Whether a separated digit run of seven or more digits reads as a phone
    # number rather than a number shape that is common in task text: a phone
    # starts with "+", "(" or a trunk "0", or has at least three digit groups.
    # Never a phone: a dotted IPv4 address; a run led by an ISO date; a slash
    # list whose groups are all three or four digits (viewport widths such as
    # 320/390/768/1440, file modes such as 0700/0600); a list of decimals
    # (oklch(0.575 0.18 24), 17.07 - 31.07); a range of grouped thousands
    # (4.500-8.000). Runs joined by an inner parenthesis count piece by
    # piece. A two-group run with no lead,
    # such as a range (1600-3200, 2024-2026, lines 1028-1045), is no phone.
    function phone_shaped(run,    rest, groups, slash_groups, short_slash_groups, count, i, tokens, decimal) {
      if (run ~ /^[0-9][0-9]?[0-9]?[.][0-9][0-9]?[0-9]?[.][0-9][0-9]?[0-9]?[.][0-9][0-9]?[0-9]?$/) return 0
      if (run ~ /^[0-9][0-9][0-9][0-9][-.\/][0-9][0-9]?[-.\/][0-9][0-9]?([^0-9]|$)/) return 0
      if (run ~ /^[1-9][0-9]?[0-9]?([.,][0-9][0-9][0-9])+[ ]?-[ ]?[1-9][0-9]?[0-9]?([.,][0-9][0-9][0-9])+$/) return 0
      if (index(run, "/")) {
        slash_groups = split(run, groups, "/")
        short_slash_groups = 0
        for (i = 1; i <= slash_groups; i++) {
          if (groups[i] ~ /^[0-9][0-9][0-9][0-9]?$/) short_slash_groups++
        }
        if (short_slash_groups == slash_groups) return 0
      }
      if (run ~ /^[+(]/ || run ~ /^0[0-9]/) return 1
      count = split(run, tokens, /[ \t]+/)
      decimal = 0
      for (i = 1; i <= count; i++) {
        if (tokens[i] ~ /^[(]?[0-9]+[.][0-9]+[)]?$/) decimal++
      }
      if (decimal >= 2) return 0
      # Two runs joined by an inner parenthesis, such as 1600-3200 (300-3400,
      # are judged piece by piece; a leading +country run stays whole.
      if (match(run, /[0-9][ \t]*[(]/)) {
        count = split(run, tokens, /[ \t]*[(][ \t]*/)
        for (i = 1; i <= count; i++) {
          rest = tokens[i]
          sub(/[)].*$/, "", rest)
          decimal = rest
          gsub(/[^0-9]/, "", decimal)
          if (length(decimal) >= 7 && phone_shaped(rest)) return 1
        }
        return 0
      }
      if (run ~ /^0/) return 1
      rest = run
      count = 0
      while (match(rest, /[0-9]+/)) {
        count++
        rest = substr(rest, RSTART + RLENGTH)
      }
      return count >= 3
    }
    function flow_value_end(text,    depth, active_quote, escaped, pos, character, expected_open, stack) {
      if (substr(text, 1, 1) != "{" && substr(text, 1, 1) != "[") return 0
      depth = 1
      stack[depth] = substr(text, 1, 1)
      active_quote = ""
      escaped = 0
      for (pos = 2; pos <= length(text); pos++) {
        character = substr(text, pos, 1)
        if (active_quote != "") {
          if (escaped) escaped = 0
          else if (character == "\\") escaped = 1
          else if (character == active_quote) active_quote = ""
        } else if (character == "\"" || character == "\047") {
          active_quote = character
        } else if (character == "{" || character == "[") {
          depth++
          stack[depth] = character
        } else if (character == "}" || character == "]") {
          expected_open = character == "}" ? "{" : "["
          if (depth < 1 || stack[depth] != expected_open) return 0
          depth--
          if (depth == 0) return pos
        }
      }
      return 0
    }
    {
      if (NR > 1) buf = buf "\n"
      buf = buf $0
    }
    END {
      while (match(buf, /-----BEGIN [A-Z0-9 ]*PRIVATE KEY( [A-Z0-9]+)?-----/)) {
        prefix = substr(buf, 1, RSTART - 1)
        tail = substr(buf, RSTART + RLENGTH)
        if (match(tail, /-----END [A-Z0-9 ]*PRIVATE KEY( [A-Z0-9]+)?-----/)) {
          suffix = substr(tail, RSTART + RLENGTH)
          buf = prefix "[redacted]" suffix
        } else {
          buf = prefix "[redacted]"
        }
      }
      credential_uri_pattern = "[[:alpha:]][[:alnum:].+-]*://[^/@:?#[:space:]]*:[^/@?#[:space:]]+@[^/@?#[:space:]]+"
      while (match(buf, credential_uri_pattern)) {
        buf = substr(buf, 1, RSTART - 1) "[redacted]" substr(buf, RSTART + RLENGTH)
      }
      email_pattern = "(^|[^[:alnum:]_.%+-])[[:alnum:]_%+.-]+@[[:alnum:]][[:alnum:].-]*[.][[:alpha:]][[:alpha:]]+([^[:alnum:]_-]|$)"
      while (match(buf, email_pattern)) {
        buf = substr(buf, 1, RSTART - 1) "[redacted]" substr(buf, RSTART + RLENGTH)
      }
      phone_pattern = "(^|[^[:alnum:]+])([+][0-9][0-9() ./-]*[0-9]|[(][0-9]+[)][ ./-]*[0-9][0-9() ./-]*[0-9]|[0-9][0-9() ./-]*[-./() ][0-9() ./-]*[0-9])([^[:alnum:]+]|$)"
      date_pattern = "^([0-9][0-9][0-9][0-9][./ -][0-9][0-9]?[./ -][0-9][0-9]?|[0-9][0-9]?[./ -][0-9][0-9]?[./ -][0-9][0-9][0-9][0-9])([ Tt][0-9][0-9](:[0-9][0-9](:[0-9][0-9]([.][0-9]+)?)?)?([Zz]|[+-][0-9][0-9]:?[0-9][0-9])?)?$"
      search_from = 1
      while (search_from <= length(buf)) {
        tail = substr(buf, search_from)
        if (!match(tail, phone_pattern)) break
        start = search_from + RSTART - 1
        match_length = RLENGTH
        phone = substr(tail, RSTART, match_length)
        phone_start = start
        if (phone ~ /^[^0-9+]/ && phone !~ /^[(][0-9]+[)][ .\/-]*[0-9]/) {
          phone = substr(phone, 2)
          phone_start++
        }
        if (phone ~ /[^[:alnum:]]$/) phone = substr(phone, 1, length(phone) - 1)
        phone_end = phone_start + length(phone) - 1
        digits = phone
        gsub(/[^0-9]/, "", digits)
        # A digit run joined by a dot, dash, slash, or underscore to a letter
        # or digit outside it is part of a larger token (a receipt id such as
        # e1791449349.20521.20886, a version, a path), never a phone number.
        glued = (phone_start > 2 && substr(buf, phone_start - 1, 1) ~ /[._\/-]/ \
          && substr(buf, phone_start - 2, 1) ~ /[[:alnum:]]/) \
          || (substr(buf, phone_end + 1, 1) ~ /[._\/-]/ && substr(buf, phone_end + 2, 1) ~ /[[:alnum:]]/)
        if (length(digits) >= 7 && phone !~ date_pattern && !glued && phone_shaped(phone)) {
          buf = substr(buf, 1, start - 1) "[redacted]" substr(buf, start + match_length)
          search_from = start + 10
        } else if (match(phone, /[(][0-9]+[)][ .\/-]*[0-9]/) && RSTART > 1) {
          search_from = phone_start + RSTART - 1
        } else {
          search_from = start + match_length
        }
      }
      while (match(buf, /(TYPESAFE_API_KEY|OPENROUTER_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|FMX_PAIRING_TOKEN|FM_MAIL_PASS|GITHUB_TOKEN|GH_TOKEN|JEV_API_KEY)=[^[:space:]]+/)) {
        buf = substr(buf, 1, RSTART - 1) "[redacted]" substr(buf, RSTART + RLENGTH)
      }
      while (match(tolower(buf), /aws_(secret_access_key|access_key_id)[[:space:]]*[:=][[:space:]]*[^[:space:]]+/)) {
        buf = substr(buf, 1, RSTART - 1) "[redacted]" substr(buf, RSTART + RLENGTH)
      }
      assignment_pattern = "(^|[^[:alnum:]_])([-[:alnum:]_.]+)[\042\047]?[ \t]*[:=][ \t]*"
      sensitive_suffix_pattern = "(password|passwd|pwd|pass|secret|token|apikey|secretkey|accesskey|privatekey|clientsecret|auth|credential)$"
      search_from = 1
      while (search_from <= length(buf)) {
        tail = substr(buf, search_from)
        if (!match(tail, assignment_pattern)) break
        key_start = search_from + RSTART - 1
        match_length = RLENGTH
        assignment = substr(tail, RSTART, match_length)
        boundary = substr(assignment, 1, 1)
        key_name = assignment
        if (boundary ~ /[^[:alnum:]_]/) key_name = substr(assignment, 2)
        sub(/[\042\047]?[ \t]*[:=][ \t]*$/, "", key_name)
        normalized_key = tolower(key_name)
        gsub(/[-_.]/, "", normalized_key)
        if (normalized_key !~ sensitive_suffix_pattern \
          || benign_key(key_name, normalized_key, boundary, \
            substr(buf, key_start - 1, 1), substr(buf, key_start + match_length))) {
          search_from = key_start + match_length
        } else {
          prefix = substr(buf, 1, key_start - 1)
          if (key_start > 1 && boundary ~ /[^[:alnum:]_]/) prefix = prefix boundary
          tail = substr(buf, key_start + match_length)
          value_start = 1
          while (substr(tail, value_start, 1) ~ /[ \t]/) value_start++
          first_value_char = substr(tail, value_start, 1)
          if (first_value_char == "{" || first_value_char == "[") {
            structured_tail = substr(tail, value_start)
            structure_end = flow_value_end(structured_tail)
            if (structure_end > 0) {
              buf = prefix "[redacted]" substr(tail, value_start + structure_end)
            } else {
              buf = prefix "[redacted]"
            }
          } else {
            newline = index(tail, "\n")
            indicator = newline ? substr(tail, 1, newline - 1) : tail
            sub(/\r$/, "", indicator)
            empty_indicator = indicator
            sub(/[ \t]*#[^\n]*$/, "", empty_indicator)
            blank_value = empty_indicator ~ /^[ \t]*$/
            if (blank_value || indicator ~ /^[ \t]*[|>][+-]?[1-9]?[+-]?[ \t]*(#[^\n]*)?$/) {
              block_tail = newline ? substr(tail, newline + 1) : ""
              token_start = key_start
              if (boundary ~ /[^[:alnum:]_]/) token_start++
              line_start = token_start - 1
              while (line_start > 0 && substr(buf, line_start, 1) != "\n") line_start--
              line_head = substr(buf, line_start + 1, token_start - line_start - 1)
              match(line_head, /^[ \t]*/)
              key_indent = RLENGTH
              line_head = substr(line_head, key_indent + 1)
              if (line_head ~ /^-[ \t]/) {
                match(line_head, /^-[ \t]+/)
                key_indent += RLENGTH
              }
              flow_start = 0
              if (blank_value && length(block_tail) > 0) {
                block_newline = index(block_tail, "\n")
                block_line = block_newline ? substr(block_tail, 1, block_newline - 1) : block_tail
                block_line_for_indent = block_line
                sub(/\r$/, "", block_line_for_indent)
                match(block_line_for_indent, /^[ \t]*/)
                flow_indent = RLENGTH
                flow_char = substr(block_line_for_indent, flow_indent + 1, 1)
                if (flow_indent >= key_indent && (flow_char == "{" || flow_char == "[")) {
                  flow_start = newline + flow_indent + 1
                }
              }
              if (flow_start > 0) {
                structured_tail = substr(tail, flow_start)
                structure_end = flow_value_end(structured_tail)
                if (structure_end > 0) {
                  buf = prefix "[redacted]" substr(tail, flow_start + structure_end)
                } else {
                  buf = prefix "[redacted]"
                }
              } else {
                while (length(block_tail) > 0) {
                  block_newline = index(block_tail, "\n")
                  block_line = block_newline ? substr(block_tail, 1, block_newline - 1) : block_tail
                  block_line_for_indent = block_line
                  sub(/\r$/, "", block_line_for_indent)
                  if (block_line_for_indent != "") {
                    match(block_line_for_indent, /^[ \t]*/)
                    if (RLENGTH <= key_indent) break
                  }
                  if (block_newline) block_tail = substr(block_tail, block_newline + 1)
                  else {
                    block_tail = ""
                    break
                  }
                }
                buf = prefix "[redacted]"
                if (length(block_tail) > 0) buf = buf "\n" block_tail
              }
            } else {
              if (newline) tail = substr(tail, newline)
              else tail = ""
              buf = prefix "[redacted]" tail
            }
          }
          search_from = 1
        }
      }
      lowered = tolower(buf)
      while (match(lowered, /(fm_mail_pass|aws_access_key_id|[[:alnum:]_.-]*(password|passwd|pwd|secret|token)[[:alnum:]_.-]*|[[:alnum:]_.-]*api[[:space:]_-]*key[[:alnum:]_.-]*)["]?[[:space:]]*[:=][[:space:]]*("([^"\\]|\\.)*"?|[^[:space:],;]+)/)) {
        start = RSTART
        end = RSTART + RLENGTH
        buf = substr(buf, 1, start - 1) "[redacted]" substr(buf, end)
        lowered = tolower(buf)
      }
      while (match(tolower(buf), /authorization:[[:blank:]]*[^\n]*/)) {
        buf = substr(buf, 1, RSTART - 1) "[redacted]" substr(buf, RSTART + RLENGTH)
      }
      while (match(buf, /Bearer[[:space:]]+[^[:space:]]+/)) {
        buf = substr(buf, 1, RSTART - 1) "[redacted]" substr(buf, RSTART + RLENGTH)
      }
      token_pattern = "(^|[^[:alnum:]_-])(sk-or-[A-Za-z0-9_-]+|sk_(live|test)_[A-Za-z0-9_-]+|github_pat_[A-Za-z0-9_]+|glpat-[A-Za-z0-9_-]+|ghp_[A-Za-z0-9]+|gh(o|u|s|r)_[A-Za-z0-9_]+|xox(b|p|a|r|s)-[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{16,})"
      while (match(buf, token_pattern)) {
        matched = substr(buf, RSTART, RLENGTH)
        boundary = substr(matched, 1, 1)
        if (boundary ~ /[^[:alnum:]_-]/) {
          buf = substr(buf, 1, RSTART) "[redacted]" substr(buf, RSTART + RLENGTH)
        } else {
          buf = substr(buf, 1, RSTART - 1) "[redacted]" substr(buf, RSTART + RLENGTH)
        }
      }
      printf "%s", buf
    }
  '
}

_fm_jev_redact_live_keys() {
  local text=$1
  local typesafe_key=${TYPESAFE_API_KEY_PRIVATE:-${TYPESAFE_API_KEY:-}}
  local openrouter_key=${OPENROUTER_API_KEY_PRIVATE:-${OPENROUTER_API_KEY:-}}
  [ -n "$typesafe_key" ] && text=${text//"$typesafe_key"/[redacted]}
  [ -n "$openrouter_key" ] && text=${text//"$openrouter_key"/[redacted]}
  printf '%s' "$text"
}

fm_jev_log_call() {
  local json path dir line home
  if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    _fm_jev_err "usage: fm_jev_log_call <json-object> [<path>]"
    return 2
  fi
  command -v jq >/dev/null 2>&1 || { _fm_jev_err "jq required"; return 2; }
  json=$1
  home=$(_fm_jev_home)
  path=${2:-$home/state/jev-calls.jsonl}
  line=$(printf '%s' "$json" | jq -c '
    def redact:
      if type == "object" then
        with_entries(
          if (.key | test("(?i)(authorization|api[_-]?key|token|password|secret)"))
          then .value = "[redacted]"
          else .value |= redact
          end
        )
      elif type == "array" then map(redact)
      else .
      end;
    if type == "object" then redact else empty end
  ' 2>/dev/null) || line=''
  if [ -z "$line" ]; then
    _fm_jev_err "log payload must be a JSON object"
    return 2
  fi
  line=$(_fm_jev_redact_live_keys "$line")
  dir=$(dirname "$path")
  mkdir -p "$dir" || { _fm_jev_err "could not create $dir"; return 1; }
  printf '%s\n' "$line" >> "$path" || { _fm_jev_err "could not write $path"; return 1; }
}

_fm_jev_site_model() {
  local site=$1 model
  local _fm_jev_route _fm_jev_url _fm_jev_model _fm_jev_key
  if [ "$site" = worker-cli ]; then
    model=$(_fm_jev_cfg JEV_MODEL)
    printf '%s' "${model:-$FM_JEV_TYPESAFE_MODEL}"
    return
  fi
  _fm_jev_resolve_route || return
  printf '%s' "$_fm_jev_model"
}

# Act only on a final, fresh, passing score for this exact call site. The
# merge gate never acts: merge authority stays with the captain and yolo.
fm_jev_site_mode() {  # <site>
  local site=${1:-} scores max_age now model
  case "$site" in
    ''|merge-gate) printf 'advise\n'; return 0 ;;
  esac
  scores=${FM_JEV_EVAL_SCORES:-$(_fm_jev_home)/state/jev-eval/latest.json}
  max_age=${FM_JEV_EVAL_MAX_AGE_SECS:-$FM_JEV_EVAL_MAX_AGE_DEFAULT}
  case "$max_age" in ''|*[!0-9]*) max_age=$FM_JEV_EVAL_MAX_AGE_DEFAULT ;; esac
  now=$(date +%s)
  if [ -f "$scores" ] && model=$(_fm_jev_site_model "$site" 2>/dev/null) \
    && jq -e --arg site "$site" --arg model "$model" --argjson now "$now" --argjson max_age "$max_age" \
    --argjson bar "$FM_JEV_EVAL_BAR" --argjson min "$FM_JEV_EVAL_MIN_CASES" '
      .sites[$site] |
      type == "object" and .final == true and .model == $model
      and ((.generated_at | type) == "number") and .generated_at <= $now and ($now - .generated_at) <= $max_age
      and (.cases | type) == "number" and .cases >= $min
      and (.agreement | type) == "number" and .agreement >= $bar
      and .dangerous_misses == 0
    ' "$scores" >/dev/null 2>&1; then
    printf 'act\n'
  else
    printf 'advise\n'
  fi
}

fm_jev_iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown'
}

# --- supervision consults: timeout and outbound data boundary ---------------
# Shared by bin/fm-jev-status-triage.sh and bin/fm-jev-wedge-check.sh, and by
# bin/fm-classify-lib.sh's per-cycle budget, so the three read one answer.
FM_JEV_SUPERVISION_FREE_TEXT_MAX_CHARS=4000

fm_jev_supervision_timeout() {
  local secs
  secs=$(_fm_jev_cfg JEV_TIMEOUT)
  case "$secs" in
    ''|*[!0-9]*|0|??????????*) secs=${FM_JEV_SUPERVISION_TIMEOUT_SECS:-3} ;;
  esac
  case "$secs" in
    ''|*[!0-9]*|0|??????????*) secs=3 ;;
  esac
  printf '%s' "$((10#$secs))"
}

_fm_jev_realpath_dir() {
  (cd "$1" 2>/dev/null && pwd -P)
}

_fm_jev_git_common_dir() {
  local common_dir
  common_dir=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P "$1" 2>/dev/null && _fm_jev_realpath_dir "$common_dir")
}

fm_jev_supervision_free_text_ok() {  # <state-dir> <task-id>
  local state=$1 task=$2 home meta kind project project_real root_real project_common root_common
  [ -n "$state" ] && [ -n "$task" ] || return 1
  case "$task" in */*|.*) return 1 ;; esac
  home=${FM_HOME:-}
  [ -n "$home" ] && [ -d "$home" ] || return 1
  if [ -e "$home/.fm-secondmate-home" ] || [ -L "$home/.fm-secondmate-home" ]; then
    return 1
  fi
  meta="$state/$task.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || return 1
  kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-)
  case "$kind" in ship|scout) ;; *) return 1 ;; esac
  project=$(grep '^project=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-)
  [ -n "$project" ] && [ -d "$project" ] || return 1
  if [ -e "$project/.fm-secondmate-home" ] || [ -L "$project/.fm-secondmate-home" ]; then
    return 1
  fi
  project_real=$(_fm_jev_realpath_dir "$project") || return 1
  root_real=$(_fm_jev_realpath_dir "$_FM_JEV_ROOT") || return 1
  [ -n "$project_real" ] && [ -n "$root_real" ] || return 1
  [ "$project_real" = "$root_real" ] && return 0
  project_common=$(_fm_jev_git_common_dir "$project_real") || return 1
  root_common=$(_fm_jev_git_common_dir "$root_real") || return 1
  [ "$project_common" = "$root_common" ]
}

_fm_jev_signal() {  # <lowered-text> <extended-regex>
  if printf '%s' "$1" | grep -Eq -- "$2"; then printf 'true'; else printf 'false'; fi
}

fm_jev_supervision_state() {  # <status-line|pane-tail> <text> <free-text:0|1>
  local kind=$1 text=$2 free=$3 max lower verb last_line lines words repeated
  command -v jq >/dev/null 2>&1 || { _fm_jev_err "jq required"; return 2; }
  max=$FM_JEV_SUPERVISION_FREE_TEXT_MAX_CHARS
  if [ "$free" = 1 ]; then
    if [ "${#text}" -gt "$max" ]; then
      case "$kind" in
        pane-tail) text=${text: -$max} ;;
        *) text=${text:0:$max} ;;
      esac
    fi
    case "$kind" in
      pane-tail)
        # A screen also masks every long opaque token (32+ characters mixing
        # letters and digits) and a bare "token <value>", which the shared
        # scrub leaves alone so commit shas survive in other payloads. Adapted
        # from korallis/agent-stack orchestration/redact.js (Apache-2.0, see
        # NOTICE).
        fm_jev_compact_state "$text" | awk '
          { if (NR > 1) buf = buf "\n"; buf = buf $0 }
          END {
            out = ""
            while (match(buf, /[A-Za-z0-9_-]+/)) {
              word = substr(buf, RSTART, RLENGTH)
              out = out substr(buf, 1, RSTART - 1)
              out = out ((length(word) >= 32 && word ~ /[0-9]/ && word ~ /[A-Za-z]/) ? "[redacted]" : word)
              buf = substr(buf, RSTART + RLENGTH)
            }
            buf = out buf
            out = ""
            while (match(buf, /[Tt][Oo][Kk][Ee][Nn][[:space:]]+[A-Za-z0-9._-]+/)) {
              word = substr(buf, RSTART, RLENGTH)
              value = word; sub(/^[Tt][Oo][Kk][Ee][Nn][[:space:]]+/, "", value)
              out = out substr(buf, 1, RSTART - 1)
              out = out ((length(value) >= 16) ? substr(word, 1, 5) " [redacted]" : word)
              buf = substr(buf, RSTART + RLENGTH)
            }
            printf "%s", out buf
          }'
        return "${PIPESTATUS[0]}"
        ;;
    esac
    fm_jev_compact_state "$text"
    return
  fi
  lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
  words=$(printf '%s' "$text" | wc -w | tr -d '[:space:]')
  case "$kind" in
    status-line)
      verb=$(printf '%s' "$lower" | sed -nE '1s/^[[:space:]]*([a-z][a-z-]*)([[:space:]]*\[[^]]*\])?:.*/\1/p')
      case "$verb" in
        working|done|needs-decision|blocked|failed|paused|resolved|note|captain-held) ;;
        '') verb=none ;;
        *) verb=other ;;
      esac
      jq -nc \
        --arg verb "$verb" \
        --argjson chars "${#text}" \
        --argjson words "${words:-0}" \
        --argjson key_tag "$(_fm_jev_signal "$lower" '\[key=')" \
        --argjson question "$(_fm_jev_signal "$lower" '\?')" \
        --argjson decision "$(_fm_jev_signal "$lower" 'decid|decision|choose|option|approv|merge|sign-off|pick')" \
        --argjson blocker "$(_fm_jev_signal "$lower" 'block|stuck|cannot|can.t|unable|need help|waiting on|missing')" \
        --argjson failure "$(_fm_jev_signal "$lower" 'fail|error|broken|crash|abort')" \
        --argjson completion "$(_fm_jev_signal "$lower" 'done|finish|complete|shipped|merged|green|passed')" \
        --argjson link "$(_fm_jev_signal "$lower" 'https?://')" \
        '{payload: "structured", note: "Structured facts only; the status text is withheld by the Firstmate data boundary.",
          kind: "status-line", verb: $verb, chars: $chars, words: $words,
          signals: {key_tag: $key_tag, question: $question, decision_language: $decision,
            blocker_language: $blocker, failure_language: $failure,
            completion_language: $completion, link: $link}}'
      ;;
    pane-tail)
      lines=$(printf '%s\n' "$text" | awk 'NF { n++ } END { print n + 0 }')
      last_line=$(printf '%s\n' "$lower" | awk 'NF { l = $0 } END { print l }')
      # The count, never the text, of the most repeated wordy line (six or more
      # letters, so box rules and separators never count).
      repeated=$(printf '%s\n' "$text" | awk '
        { line = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
          letters = line; gsub(/[^A-Za-z]/, "", letters)
          if (length(letters) >= 6 && ++seen[line] > max) max = seen[line] }
        END { print max + 0 }')
      jq -nc \
        --argjson chars "${#text}" \
        --argjson lines "${lines:-0}" \
        --argjson repeated "${repeated:-0}" \
        --argjson prompt "$(_fm_jev_signal "$lower" '\(y/n\)|\[y/n\]|press enter|continue\?|do you want|approve|allow')" \
        --argjson quota "$(_fm_jev_signal "$lower" 'rate limit|usage limit|quota|429|credits')" \
        --argjson error "$(_fm_jev_signal "$lower" 'error|traceback|panic|exception|fatal|failed')" \
        --argjson permission "$(_fm_jev_signal "$lower" 'permission|denied|trust')" \
        --argjson busy "$(_fm_jev_signal "$lower" 'thinking|running|working|esc to interrupt|generating')" \
        --argjson finished "$(_fm_jev_signal "$lower" 'done|finished|complete|all tests pass')" \
        --argjson shell "$(_fm_jev_signal "$last_line" '[$%>#][[:space:]]*$')" \
        '{payload: "structured", note: "Structured facts only; the pane text is withheld by the Firstmate data boundary.",
          kind: "pane-tail", chars: $chars, nonblank_lines: $lines, repeated_line_max: $repeated,
          signals: {prompt_waiting: $prompt, quota_or_rate_limit: $quota, error_text: $error,
            permission_prompt: $permission, busy_indicator: $busy, completion_text: $finished,
            shell_prompt_last_line: $shell}}'
      ;;
    *)
      _fm_jev_err "unknown supervision state kind: $kind"
      return 2
      ;;
  esac
}
