#!/usr/bin/env bash
# Run the mandatory Megamind preflight for one ordinary ship or scout worker.
# Usage: fm-worker-preflight.sh <binding-home> <request-file>
#
# The binding-home is the Firstmate home that owns the worker, not the worker's
# isolated project copy. The request-file is the already-created brief. This
# command is placed before the worker launch command by fm-spawn.sh, so a failed
# or unresolved preflight prevents the worker process from starting.
#
# Contract (owner: this header; policy owner: .agents/skills/megamind-preflight):
# - The binding home is passed only to this short-lived command as FM_HOME. It is
#   never exported to the worker process, and no config or credential is copied
#   into the isolated project copy.
# - The request is read from the regular, non-symlinked brief file and passed to
#   fm-megamind-preflight.sh without entering an environment variable. The
#   preflight script owns model-class resolution, typed outcomes, wiki allows,
#   and the binding owner's minimal proof record.
# - Missing, malformed, incompatible, failed, ambiguous, or unavailable
#   preflight blocks the worker. matched, no-match, and privacy-filtered are
#   definitive outcomes and allow the worker launch to continue after the typed
#   result is printed. No result is guessed from model knowledge.
# - This helper is runtime- and provider-neutral. fm-spawn.sh prepends it to
#   every ordinary ship/scout launch family, while secondmate launches omit it;
#   workers launched by a secondmate invoke this same helper from that
#   secondmate's own home and therefore use only that home's binding.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PREFLIGHT="$SCRIPT_DIR/fm-megamind-preflight.sh"

usage() {
  printf 'usage: fm-worker-preflight.sh <binding-home> <request-file>\n' >&2
}

fail() {
  printf 'worker preflight: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 2 ] || { usage; exit 2; }
BINDING_HOME=$1
REQUEST_FILE=$2

case "$BINDING_HOME" in
  /*) ;;
  *) fail "binding home must be an absolute path" ;;
esac
case "$REQUEST_FILE" in
  /*) ;;
  *) fail "request file must be an absolute path" ;;
esac
[ -d "$BINDING_HOME" ] || fail "binding home is not a directory"
[ -f "$REQUEST_FILE" ] && [ ! -L "$REQUEST_FILE" ] && [ -r "$REQUEST_FILE" ] \
  || fail "request file is not a readable regular file"
[ -x "$PREFLIGHT" ] || fail "preflight command is unavailable"

result=
rc=0
result=$(FM_HOME="$BINDING_HOME" "$PREFLIGHT" run --request "$(cat "$REQUEST_FILE")") || rc=$?
printf '%s\n' "$result"
[ "$rc" -eq 0 ] || exit "$rc"

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required to inspect the typed preflight result"
fi
outcome=$(printf '%s' "$result" | jq -r '.outcome // empty' 2>/dev/null || true)
case "$outcome" in
  matched|no-match|privacy-filtered) ;;
  ambiguous|unavailable)
    fail "preflight outcome '$outcome' does not authorize substantive worker work"
    ;;
  *)
    fail "preflight returned an unrecognized outcome"
    ;;
esac
