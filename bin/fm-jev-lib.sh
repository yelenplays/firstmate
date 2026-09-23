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
#     model jev-latest unless JEV_MODEL is set.
#   - OpenRouter POST https://openrouter.ai/api/alpha/decisions with
#     OPENROUTER_API_KEY, model typesafe/jev-1.13 unless JEV_MODEL is set.
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
#   fm_jev_decide <state> <questions-json> [--string]
#     POST {model, state, questions}. By default, <state> is a JSON object or
#     array when the argument parses as one, otherwise a string; --string
#     forces a JSON string. <questions-json> is a JSON object. Prints the full
#     JSON response on stdout. Non-zero on
#     hard failure: 2 for usage/config (missing args, missing key, missing
#     jq/curl, questions not a JSON object), 1 for transport or a non-JSON /
#     non-200 response. Sets FM_JEV_LAST_ROUTE, FM_JEV_LAST_URL,
#     FM_JEV_LAST_MODEL, FM_JEV_LAST_HTTP, and FM_JEV_LAST_LATENCY_MS on every
#     attempted call (empty HTTP/latency when the call never reached curl).
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
#     fm_jev_compact_state. With free-text 0 it is a JSON object of
#     structured facts only - verb, counts, and fixed-vocabulary signal flags -
#     and carries no text from the input.
#
# Environment (library-specific):
#   TYPESAFE_API_KEY, OPENROUTER_API_KEY, JEV_ROUTE, JEV_MODEL, JEV_URL,
#   JEV_BASE, JEV_TIMEOUT (positive integer seconds, default 25),
#   JEV_CONFIDENCE_FLOOR, JEV_STATE_MAX_BYTES, FM_HOME.
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
FM_JEV_TYPESAFE_MODEL='jev-latest'
FM_JEV_OPENROUTER_MODEL='typesafe/jev-1.13'
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
  local typesafe_key openrouter_key home route
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
    _fm_jev_model=$(_fm_jev_cfg JEV_MODEL)
    [ -n "$_fm_jev_model" ] || _fm_jev_model=$FM_JEV_OPENROUTER_MODEL
  else
    _fm_jev_key=$typesafe_key
    _fm_jev_model=$(_fm_jev_cfg JEV_MODEL)
    [ -n "$_fm_jev_model" ] || _fm_jev_model=$FM_JEV_TYPESAFE_MODEL
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
  local state questions request resp_file http t0 t1 timeout state_mode
  local _fm_jev_route _fm_jev_url _fm_jev_model _fm_jev_key
  export -n TYPESAFE_API_KEY OPENROUTER_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY_PRIVATE 2>/dev/null || true
  FM_JEV_LAST_ROUTE=''
  FM_JEV_LAST_URL=''
  FM_JEV_LAST_MODEL=''
  FM_JEV_LAST_HTTP=''
  FM_JEV_LAST_LATENCY_MS=''
  if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    _fm_jev_err "usage: fm_jev_decide <state> <questions-json> [--string]"
    return 2
  fi
  state=$1
  questions=$2
  state_mode=auto
  if [ $# -eq 3 ]; then
    if [ "$3" != --string ]; then
      _fm_jev_err "usage: fm_jev_decide <state> <questions-json> [--string]"
      return 2
    fi
    state_mode=string
  fi
  command -v jq >/dev/null 2>&1 || { _fm_jev_err "jq required"; return 2; }
  command -v curl >/dev/null 2>&1 || { _fm_jev_err "curl not installed"; return 2; }
  printf '%s' "$questions" | jq -e 'type == "object"' >/dev/null 2>&1 || {
    _fm_jev_err "questions must be a JSON object"
    return 2
  }
  _fm_jev_resolve_route || return 2
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_JEV_LAST_ROUTE=$_fm_jev_route
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_JEV_LAST_URL=$_fm_jev_url
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_JEV_LAST_MODEL=$_fm_jev_model
  if [ "$state_mode" = auto ] && printf '%s' "$state" | jq -e 'type == "object" or type == "array"' >/dev/null 2>&1; then
    request=$(jq -n --arg model "$_fm_jev_model" --argjson state "$state" --argjson questions "$questions" \
      '{model: $model, state: $state, questions: $questions}') || {
      _fm_jev_err "could not build request"
      return 2
    }
  else
    request=$(jq -n --arg model "$_fm_jev_model" --arg state "$state" --argjson questions "$questions" \
      '{model: $model, state: $state, questions: $questions}') || {
      _fm_jev_err "could not build request"
      return 2
    }
  fi
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
  cat "$resp_file"
  rm -f "$resp_file"
  return 0
}

fm_jev_key_configured() {
  local typesafe_key openrouter_key home
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

fm_jev_has_sensitive_key() {
  local text
  if [ $# -ne 1 ]; then
    _fm_jev_err "usage: fm_jev_has_sensitive_key <text>"
    return 2
  fi
  text=$1
  printf '%s' "$text" | awk '
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
        if (normalized_key ~ sensitive_suffix_pattern) {
          found = 1
          exit
        }
        remaining = substr(remaining, RSTART + RLENGTH)
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
  printf '%s' "$state" | awk '
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
      phone_pattern = "(^|[^[:alnum:]])([+][0-9][0-9() ./-]*[0-9]|[0-9][0-9() ./-]*[-./() ][0-9() ./-]*[0-9])([^[:alnum:]]|$)"
      date_pattern = "^([0-9][0-9][0-9][0-9][./ -][0-9][0-9]?[./ -][0-9][0-9]?|[0-9][0-9]?[./ -][0-9][0-9]?[./ -][0-9][0-9][0-9][0-9])([ Tt][0-9][0-9](:[0-9][0-9](:[0-9][0-9]([.][0-9]+)?)?)?([Zz]|[+-][0-9][0-9]:?[0-9][0-9])?)?$"
      search_from = 1
      while (search_from <= length(buf)) {
        tail = substr(buf, search_from)
        if (!match(tail, phone_pattern)) break
        start = search_from + RSTART - 1
        match_length = RLENGTH
        phone = substr(tail, RSTART, match_length)
        if (phone ~ /^[^[:alnum:]]/) phone = substr(phone, 2)
        if (phone ~ /[^[:alnum:]]$/) phone = substr(phone, 1, length(phone) - 1)
        digits = phone
        gsub(/[^0-9]/, "", digits)
        if (length(digits) >= 7 && phone !~ date_pattern) {
          buf = substr(buf, 1, start - 1) "[redacted]" substr(buf, start + match_length)
          search_from = start + 10
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
        if (normalized_key !~ sensitive_suffix_pattern) {
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
  local kind=$1 text=$2 free=$3 max lower verb last_line lines words
  command -v jq >/dev/null 2>&1 || { _fm_jev_err "jq required"; return 2; }
  max=$FM_JEV_SUPERVISION_FREE_TEXT_MAX_CHARS
  if [ "$free" = 1 ]; then
    if [ "${#text}" -gt "$max" ]; then
      case "$kind" in
        pane-tail) text=${text: -$max} ;;
        *) text=${text:0:$max} ;;
      esac
    fi
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
      jq -nc \
        --argjson chars "${#text}" \
        --argjson lines "${lines:-0}" \
        --argjson prompt "$(_fm_jev_signal "$lower" '\(y/n\)|\[y/n\]|press enter|continue\?|do you want|approve|allow')" \
        --argjson quota "$(_fm_jev_signal "$lower" 'rate limit|usage limit|quota|429|credits')" \
        --argjson error "$(_fm_jev_signal "$lower" 'error|traceback|panic|exception|fatal|failed')" \
        --argjson permission "$(_fm_jev_signal "$lower" 'permission|denied|trust')" \
        --argjson busy "$(_fm_jev_signal "$lower" 'thinking|running|working|esc to interrupt|generating')" \
        --argjson finished "$(_fm_jev_signal "$lower" 'done|finished|complete|all tests pass')" \
        --argjson shell "$(_fm_jev_signal "$last_line" '[$%>#][[:space:]]*$')" \
        '{payload: "structured", note: "Structured facts only; the pane text is withheld by the Firstmate data boundary.",
          kind: "pane-tail", chars: $chars, nonblank_lines: $lines,
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
