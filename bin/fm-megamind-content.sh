#!/usr/bin/env bash
# Host-owned bounded content admission for Firstmate's validated Megamind result.
# Usage: fm-megamind-content.sh admit --task-id <task-id> [--owner-home <home>]
#        fm-megamind-content.sh admit --selection-id <selection-id> [--owner-home <home>]
#        fm-megamind-content.sh content --admission-id <opaque-id> [--owner-home <home>]
#
# Contract (owner: this header and fm-megamind-content.py; policy owner:
# .agents/skills/megamind-preflight):
# - This is the only worker-facing wiki content reader. It accepts only the
#   owning home's private task result or one script-issued selection authorization.
#   It never accepts a root, an absolute content path, an upstream packet, or an
#   allowlist supplied by the caller.
# - `admit` validates the private authorization, current owning-home binding,
#   executable/version, model class, estate identity, preflight/catalog/request
#   identities, wiki identity, and Megamind's own `access` and `routing_mode`
#   values - fm-megamind-content.py owns the accepted vocabulary for those two
#   and refuses anything outside it - then snapshots the root, card, and
#   candidate identities and writes one mode-0600 admission record.
#   It prints exactly one privacy-safe typed result and never prints content.
# - `content` accepts only the opaque admission id produced by `admit`, repeats
#   every binding and path check, then emits only the separately documented
#   content channel. It never executes or parses `follow_up`; that field is
#   informational and only explicit `allows` entries are loadable.
# - Directory-relative O_NOFOLLOW opens are required on macOS/Linux. The Python
#   owner refuses when the platform cannot prove component and final-target
#   identity, rejects symlinks, special files, hardlinks, traversal, root/card
#   swaps, changed files, invalid UTF-8, and budget overflow.
# - Character budgets count decoded Unicode code points, including one code point
#   for each newline and each combining mark. UTF-8 decoding is strict and no
#   bytes or characters beyond a ceiling are emitted or logged.
# - This command is harness- and runtime-neutral. Primary and ordinary workers
#   use the same command; workers pass the owning home named by their fixed
#   launch-time result path rather than reading that result directly.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHON="${FM_PYTHON:-python3}"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
command -v "$PYTHON" >/dev/null 2>&1 || {
  printf '%s\n' '{"schema_version":"fm/megamind-content-admission/v1","outcome":"refused","refusal_code":"python_unavailable","admission_id":null,"authorization_id":null,"selection_id":null,"wikis":[]}'
  exit 1
}
exec "$PYTHON" "$SCRIPT_DIR/fm-megamind-content.py" "$@"
