#!/usr/bin/env bash
# Host-owned deterministic Megamind research execution lane.
# Usage: fm-megamind-research.sh run --plan <private-plan.json> [--home <home>]
#        fm-megamind-research.sh resume --plan <fresh-admission-plan.json> [--home <home>]
#        fm-megamind-research.sh cancel --run-id <run-id> [--home <home>]
#
# Contract (owner: this wrapper and fm-megamind-research.py):
# - The input is an already-authorized fm/megamind-research-plan/v1 document.
#   The host validates its fresh admission, deterministic source list, fixed
#   argv adapter commands, URL safety, retry/deadline/cost/byte ceilings, and
#   model-class binding before any adapter runs.
# - Adapters are executed as argv arrays with shell=False, no credentials, no
#   source text in logs, no redirects, and bounded typed JSON output.
# - Retrieved bytes and pure schema-bound extraction results live only in the
#   mode-0700 state/megamind-research-quarantine tree as mode-0600 files.
#   Immutable hashes and typed tool/cost/latency receipts are private and
#   idempotent; this lane never edits a wiki or composes an answer.
# - Unsafe fetches, hostile adapter output, cancellation, cooldowns, retries,
#   and exhausted ceilings produce typed research-pending results. A completed
#   run always hands off for fresh governed admission before request identity
#   can resume.
# - The Python implementation owns exact validation and record mechanics. This
#   wrapper owns only command dispatch and intentionally performs no shell
#   reinterpretation of plan, URL, or adapter values.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec "${FM_PYTHON:-python3}" "$SCRIPT_DIR/fm-megamind-research.py" "$@"
