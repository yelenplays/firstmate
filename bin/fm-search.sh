#!/usr/bin/env bash
# fm-search.sh - web search router for firstmate and its workers.
#
# One Jev class pick (query text only, see docs/configuration.md "Web search
# router") chooses between two provider chains; Jev failure, low confidence,
# --no-jev, a long query or a refused query falls back to chain F:
#   F: exa-keyless -> exa-lite -> tinyfish -> ketch --multi
#   K: exa-lite -> tinyfish -> exa-keyless -> ketch --multi
# Caps, floors and timeouts live in config/fm-search.json; the spend ledger and
# the route cache live in state/fm-search/ and never hold query text. Keys are
# read at call time from ~/.config/exa.key and ~/.config/tinyfish.key.
# The engine is bin/fm-search.py; `fm-search.sh --help` prints the interface.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 -I "$HERE/fm-search.py" "$@"
