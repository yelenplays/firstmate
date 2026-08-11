#!/usr/bin/env bash
# Clear one ordinary ship or scout worker's mandatory Megamind binding.
# Usage: fm-worker-preflight.sh <binding-home> <task-id>
#                               [--config <dir>] [--state <dir>] [--data <dir>]
#                               [--validate-only]
#
# Contract (owner: this header; policy owner: .agents/skills/megamind-preflight):
# - This script owns BOTH of the task's Megamind artifact paths, so no caller
#   re-derives them: the separately authored routing request at
#   <data>/<task-id>/megamind-request.md, and the validated typed result at
#   <state>/<task-id>.megamind-preflight.json. The operational directories
#   default to <binding-home>/config, /state, and /data; a caller that already
#   resolved its own passes them, and a relative one is resolved against the
#   caller's working directory exactly as docs/configuration.md "FM_HOME"
#   specifies.
# - The binding home is the Firstmate home that OWNS the worker, never the
#   worker's isolated project copy. It reaches the preflight only as this
#   short-lived command's FM_HOME. Every FM_*_OVERRIDE the preflight consults is
#   RESTATED here from that home's own operational directories, so an ambient
#   override inherited from another home can never redirect this binding's config
#   or drop its proof record somewhere else.
# - The routing request is a separately authored, smallest privacy-safe routing
#   representation - never the task brief. It must be a readable regular file
#   holding non-empty, bounded, placeholder-free text; an unresolved
#   {PLACEHOLDER} token, an empty file, an oversized one, or embedded control
#   characters block the worker rather than route an unauthored request. Each of
#   those refusals names the exact file to author or correct, because that path
#   is the operator's whole remedy; it reaches the operator's own typed refusal
#   only, never Megamind, the proof log, or the worker. The request text is read
#   from that file and passed to fm-megamind-preflight.sh as an argument, never
#   through an environment variable, and this script never echoes it.
# - matched, no-match, and privacy-filtered are the definitive authorized
#   outcomes: the validated typed document is written to the result path (0600,
#   replaced atomically) as the task's own private delivery surface, and nothing
#   is printed on stdout. Every other outcome - ambiguous, unavailable, error, or
#   an unrecognized status - blocks: the typed document goes to stdout for the
#   caller to surface and the exit status is 1. No result is ever guessed from
#   model knowledge.
# - A refusal never mutates the task. The result file is only ever REPLACED by a
#   freshly authorized document and is never removed here, because the
#   incarnation that owns it may still be running; bin/fm-teardown.sh retires it
#   with the task's other state.
# - --validate-only answers "would this launch be authorized?" without touching
#   the result file at all. bin/fm-control.sh uses it as a relaunch precondition
#   so a binding that cannot authorize the replacement refuses while the previous
#   worker, its record, and its isolated copy are still intact and unchanged.
#   bin/fm-spawn.sh then performs the authoritative publishing run BEFORE it
#   creates an endpoint, provisions a worktree, or publishes a task record.
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
  printf 'usage: fm-worker-preflight.sh <binding-home> <task-id> [--config <dir>] [--state <dir>] [--data <dir>] [--validate-only]\n' >&2
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

absolute_dir() {  # <path> - absolute spelling; an absolute path is preserved as given
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$PWD" "$1" ;;
  esac
}

# Typed refusal. It carries no request text and mutates nothing.
block() {  # <code> <message>
  local code="$1" message="$2"
  printf '{"schema_version":"%s","outcome":"error","failure":{"code":"%s","message":"%s"}}\n' \
    "$(json_escape "$SCHEMA")" "$(json_escape "$code")" "$(json_escape "$message")"
  printf 'worker preflight: %s\n' "$message" >&2
  exit 1
}

[ "$#" -ge 2 ] || { usage; exit 2; }
BINDING_HOME=$1
TASK_ID=$2
shift 2
BINDING_CONFIG=
BINDING_STATE=
BINDING_DATA=
VALIDATE_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      BINDING_CONFIG=$2; shift 2 ;;
    --state)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      BINDING_STATE=$2; shift 2 ;;
    --data)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      BINDING_DATA=$2; shift 2 ;;
    --validate-only)
      VALIDATE_ONLY=1; shift ;;
    *) usage; exit 2 ;;
  esac
done

# The task id becomes a path component of both artifacts, so it must name one
# task and nothing else.
case "$TASK_ID" in
  ''|.|..) block task_id_invalid "task id is not a usable task name" ;;
  */*) block task_id_invalid "task id must not contain a path separator" ;;
esac

BINDING_HOME=$(absolute_dir "$BINDING_HOME")
[ -d "$BINDING_HOME" ] || block binding_home_invalid "binding home is not a directory"
BINDING_CONFIG=$(absolute_dir "${BINDING_CONFIG:-$BINDING_HOME/config}")
BINDING_STATE=$(absolute_dir "${BINDING_STATE:-$BINDING_HOME/state}")
BINDING_DATA=$(absolute_dir "${BINDING_DATA:-$BINDING_HOME/data}")

REQUEST_FILE="$BINDING_DATA/$TASK_ID/megamind-request.md"
RESULT_FILE="$BINDING_STATE/$TASK_ID.megamind-preflight.json"

[ -d "$BINDING_STATE" ] || block result_path_invalid "binding state directory does not exist"
[ -w "$BINDING_STATE" ] || block result_path_invalid "binding state directory is not writable"
[ ! -L "$RESULT_FILE" ] || block result_path_invalid "the task's preflight result path is a symlink"

[ -e "$REQUEST_FILE" ] \
  || block routing_request_missing "no routing request for this task; author one privacy-safe routing line at $REQUEST_FILE"
[ -f "$REQUEST_FILE" ] && [ ! -L "$REQUEST_FILE" ] && [ -r "$REQUEST_FILE" ] \
  || block routing_request_invalid "the routing request at $REQUEST_FILE is not a readable regular file"
[ -x "$PREFLIGHT" ] || block preflight_unavailable "preflight command is unavailable"

REQUEST=$(cat "$REQUEST_FILE") \
  || block routing_request_invalid "the routing request at $REQUEST_FILE could not be read"
REQUEST="${REQUEST#"${REQUEST%%[![:space:]]*}"}"
REQUEST="${REQUEST%"${REQUEST##*[![:space:]]}"}"

[ -n "$REQUEST" ] \
  || block routing_request_empty "the routing request at $REQUEST_FILE is empty; author the smallest privacy-safe routing text for this task"
if printf '%s' "$REQUEST" | grep -Eq '\{[A-Za-z_][A-Za-z0-9_]*\}'; then
  block routing_request_unresolved "the routing request at $REQUEST_FILE still carries an unresolved {PLACEHOLDER}"
fi
if printf '%s' "$REQUEST" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  block routing_request_invalid "the routing request at $REQUEST_FILE carries control characters"
fi
[ "${#REQUEST}" -le "$MAX_REQUEST_CHARS" ] \
  || block routing_request_too_large "the routing request at $REQUEST_FILE exceeds $MAX_REQUEST_CHARS characters; it must stay a routing summary, not a brief"
REQUEST_LINES=$(printf '%s\n' "$REQUEST" | wc -l | tr -d '[:space:]')
[ "$REQUEST_LINES" -le "$MAX_REQUEST_LINES" ] \
  || block routing_request_too_large "the routing request at $REQUEST_FILE exceeds $MAX_REQUEST_LINES lines; it must stay a routing summary, not a brief"

# The binding home reaches the preflight only here, and every FM_*_OVERRIDE the
# preflight consults is restated from this binding's own resolved directories, so
# an ambient override inherited from another home can neither repoint the config
# it reads nor move the proof record it writes (bin/fm-megamind-preflight.sh
# resolves CONFIG and STATE from exactly those variables).
rc=0
result=$(FM_HOME="$BINDING_HOME" \
  FM_ROOT_OVERRIDE='' FM_PROJECTS_OVERRIDE='' \
  FM_CONFIG_OVERRIDE="$BINDING_CONFIG" FM_STATE_OVERRIDE="$BINDING_STATE" \
  FM_DATA_OVERRIDE="$BINDING_DATA" \
  "$PREFLIGHT" run --request "$REQUEST") || rc=$?
if [ "$rc" -ne 0 ]; then
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
    printf '%s\n' "$result"
    printf "worker preflight: outcome '%s' does not authorize substantive worker work\\n" "$outcome" >&2
    exit 1
    ;;
  *)
    printf '%s\n' "$result"
    printf 'worker preflight: the preflight returned an unrecognized outcome\n' >&2
    exit 1
    ;;
esac

[ "$VALIDATE_ONLY" -eq 0 ] || exit 0

RESULT_TMP="$BINDING_STATE/.$TASK_ID.megamind-preflight.json.${BASHPID:-$$}"
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
