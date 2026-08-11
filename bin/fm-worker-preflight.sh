#!/usr/bin/env bash
# Clear one ordinary ship or scout worker's mandatory Megamind binding before
# that worker's task exists.
# Usage: fm-worker-preflight.sh <binding-home> <routing-request-file> <result-file>
#                               [--config <dir>] [--state <dir>]
#
# Contract (owner: this header; policy owner: .agents/skills/megamind-preflight):
# - The binding home is the Firstmate home that OWNS the worker, never the
#   worker's isolated project copy. It reaches the preflight only as this
#   short-lived command's FM_HOME. Every FM_*_OVERRIDE the preflight consults is
#   RESTATED here from that home's own operational directories - <home>/config and
#   <home>/state by default, or the exact directories the owner already resolved
#   when it passes --config/--state - so an ambient override inherited from
#   another home can never redirect this binding's config or drop its proof
#   record somewhere else (docs/configuration.md "FM_HOME" owns those overrides).
# - The routing request is a separately authored, smallest privacy-safe routing
#   representation - never the task brief. It must be a readable regular file
#   holding non-empty, bounded, placeholder-free text; an unresolved
#   {PLACEHOLDER} token, an empty file, an oversized one, or embedded control
#   characters block the worker rather than route an unauthored request. The
#   text is read from that file and passed to fm-megamind-preflight.sh as an
#   argument, never through an environment variable, and this script never
#   echoes it.
# - matched, no-match, and privacy-filtered are the definitive authorized
#   outcomes: the validated typed document is written to <result-file> (0600,
#   replaced atomically) as the task's own private delivery surface, and nothing
#   is printed on stdout. Every other outcome - ambiguous, unavailable, error, or
#   an unrecognized status - blocks: the typed document goes to stdout for the
#   caller to surface, any stale result file is removed, and the exit status is
#   1. No result is ever guessed from model knowledge.
# - bin/fm-spawn.sh runs this BEFORE it creates an endpoint, provisions a
#   worktree, or publishes a task record, so a blocked binding leaves no task
#   behind and is reported as a refusal rather than a spawn. The result never
#   travels through the worker's terminal; bin/fm-brief.sh's fixed scaffold
#   section points the worker at <result-file>.
# - Runtime- and provider-neutral: it reads no harness, backend, or terminal
#   state. Secondmate launches are not ordinary workers and are never routed
#   here; a secondmate's own fm-spawn.sh calls this with its own home, so a
#   primary binding never crosses the secondmate boundary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PREFLIGHT="$SCRIPT_DIR/fm-megamind-preflight.sh"

SCHEMA="fm/worker-preflight/v1"
# The routing representation is deliberately small: enough text for Megamind to
# match on, never a brief, a transcript, or pasted private detail.
MAX_REQUEST_CHARS=600
MAX_REQUEST_LINES=3

usage() {
  printf 'usage: fm-worker-preflight.sh <binding-home> <routing-request-file> <result-file> [--config <dir>] [--state <dir>]\n' >&2
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

# Typed, payload-free refusal. The routing request text never enters it.
block() {  # <code> <message>
  local code="$1" message="$2"
  [ -z "${RESULT_FILE:-}" ] || rm -f "$RESULT_FILE" 2>/dev/null || true
  printf '{"schema_version":"%s","outcome":"error","failure":{"code":"%s","message":"%s"}}\n' \
    "$(json_escape "$SCHEMA")" "$(json_escape "$code")" "$(json_escape "$message")"
  printf 'worker preflight: %s\n' "$message" >&2
  exit 1
}

[ "$#" -ge 3 ] || { usage; exit 2; }
BINDING_HOME=$1
REQUEST_FILE=$2
RESULT_ARG=$3
shift 3
BINDING_CONFIG=
BINDING_STATE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      BINDING_CONFIG=$2; shift 2 ;;
    --state)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      BINDING_STATE=$2; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
RESULT_FILE=

case "$RESULT_ARG" in
  /*) ;;
  *) block result_path_invalid "result file must be an absolute path" ;;
esac
RESULT_DIR=$(dirname "$RESULT_ARG")
[ -d "$RESULT_DIR" ] || block result_path_invalid "result directory does not exist"
[ -w "$RESULT_DIR" ] || block result_path_invalid "result directory is not writable"
[ ! -L "$RESULT_ARG" ] || block result_path_invalid "result file must not be a symlink"
RESULT_FILE=$RESULT_ARG
# A refused launch must never leave a previous authorization behind for the
# worker to read, so the stale record is cleared before anything else runs.
rm -f "$RESULT_FILE" 2>/dev/null || true

case "$BINDING_HOME" in
  /*) ;;
  *) block binding_home_invalid "binding home must be an absolute path" ;;
esac
[ -d "$BINDING_HOME" ] || block binding_home_invalid "binding home is not a directory"
[ -n "$BINDING_CONFIG" ] || BINDING_CONFIG="$BINDING_HOME/config"
[ -n "$BINDING_STATE" ] || BINDING_STATE="$BINDING_HOME/state"
case "$BINDING_CONFIG" in
  /*) ;;
  *) block binding_home_invalid "binding config directory must be an absolute path" ;;
esac
case "$BINDING_STATE" in
  /*) ;;
  *) block binding_home_invalid "binding state directory must be an absolute path" ;;
esac

case "$REQUEST_FILE" in
  /*) ;;
  *) block routing_request_invalid "routing request must be an absolute path" ;;
esac
[ -e "$REQUEST_FILE" ] \
  || block routing_request_missing "no separately authored routing request for this task"
[ -f "$REQUEST_FILE" ] && [ ! -L "$REQUEST_FILE" ] && [ -r "$REQUEST_FILE" ] \
  || block routing_request_invalid "routing request is not a readable regular file"
[ -x "$PREFLIGHT" ] || block preflight_unavailable "preflight command is unavailable"

REQUEST=$(cat "$REQUEST_FILE") || block routing_request_invalid "routing request could not be read"
REQUEST="${REQUEST#"${REQUEST%%[![:space:]]*}"}"
REQUEST="${REQUEST%"${REQUEST##*[![:space:]]}"}"

[ -n "$REQUEST" ] \
  || block routing_request_empty "routing request is empty; author the smallest privacy-safe routing text for this task"
if printf '%s' "$REQUEST" | grep -Eq '\{[A-Za-z_][A-Za-z0-9_]*\}'; then
  block routing_request_unresolved "routing request still carries an unresolved {PLACEHOLDER}"
fi
if printf '%s' "$REQUEST" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  block routing_request_invalid "routing request carries control characters"
fi
[ "${#REQUEST}" -le "$MAX_REQUEST_CHARS" ] \
  || block routing_request_too_large "routing request exceeds $MAX_REQUEST_CHARS characters; it must stay a routing summary, not a brief"
REQUEST_LINES=$(printf '%s\n' "$REQUEST" | wc -l | tr -d '[:space:]')
[ "$REQUEST_LINES" -le "$MAX_REQUEST_LINES" ] \
  || block routing_request_too_large "routing request exceeds $MAX_REQUEST_LINES lines; it must stay a routing summary, not a brief"

# The binding home reaches the preflight only here, and every FM_*_OVERRIDE the
# preflight consults is restated from this binding's own resolved directories, so
# an ambient override inherited from another home can neither repoint the config
# it reads nor move the proof record it writes (bin/fm-megamind-preflight.sh
# resolves CONFIG and STATE from exactly those variables).
rc=0
result=$(FM_HOME="$BINDING_HOME" \
  FM_ROOT_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' \
  FM_CONFIG_OVERRIDE="$BINDING_CONFIG" FM_STATE_OVERRIDE="$BINDING_STATE" \
  "$PREFLIGHT" run --request "$REQUEST") || rc=$?
if [ "$rc" -ne 0 ]; then
  rm -f "$RESULT_FILE" 2>/dev/null || true
  printf '%s\n' "$result"
  printf 'worker preflight: the owning home reported a failed preflight\n' >&2
  exit 1
fi

# jq is reachable here by construction: a run that could not use it exits above
# with the typed jq_missing failure.
outcome=$(printf '%s' "$result" | jq -r '.outcome // empty' 2>/dev/null || true)
case "$outcome" in
  matched|no-match|privacy-filtered) ;;
  ambiguous|unavailable)
    rm -f "$RESULT_FILE" 2>/dev/null || true
    printf '%s\n' "$result"
    printf "worker preflight: outcome '%s' does not authorize substantive worker work\\n" "$outcome" >&2
    exit 1
    ;;
  *)
    rm -f "$RESULT_FILE" 2>/dev/null || true
    printf '%s\n' "$result"
    printf 'worker preflight: the preflight returned an unrecognized outcome\n' >&2
    exit 1
    ;;
esac

RESULT_TMP="$RESULT_DIR/.$(basename "$RESULT_FILE").${BASHPID:-$$}"
OLD_UMASK=$(umask)
umask 077
if ! printf '%s\n' "$result" > "$RESULT_TMP"; then
  umask "$OLD_UMASK"
  rm -f "$RESULT_TMP" 2>/dev/null || true
  block result_write_failed "the authorized preflight result could not be written for this task"
fi
umask "$OLD_UMASK"
if ! mv -f "$RESULT_TMP" "$RESULT_FILE"; then
  rm -f "$RESULT_TMP" 2>/dev/null || true
  block result_write_failed "the authorized preflight result could not be published for this task"
fi
