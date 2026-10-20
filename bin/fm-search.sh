#!/usr/bin/env bash
# fm-search.sh - web search router for firstmate and its workers.
#
# docs/configuration.md "Web search router" owns routing, setup, caps and privacy.
# The engine is bin/fm-search.py; `fm-search.sh --help` prints flags and exit codes.
# Requires python3 and ketch on PATH; Jev setup is owned by bin/fm-jev.sh.
#
# --urls and --deep skip Jev and take precedence over --chain:
#   --urls: tinyfish -> exa-keyless -> exa-lite -> ketch-multi
#   --deep: exa-deep -> exa-keyless -> tinyfish -> ketch-multi
# --urls suppresses snippets only in text output; --deep uses the configured
# deep Exa search type. --limit defaults and other options are in --help;
# values above 20 are clamped to 20, and --urls and --deep are mutually exclusive.
# End options with -- before a single quoted query that starts with a dash:
#   fm-search.sh --no-jev -- "-bash: foo: command not found"
#
# Output: normalized results have title, url, date (YYYY-MM-DD or empty), snippet.
# Text output truncates snippets to 400 characters and ends with:
#   provider=<p> hops=<n> lat=<s> cost=$<x> route=<jev|default|forced>
# --json prints {"results": [...], "meta": {...}}; meta has provider, hops, lat,
# cost, route, and class when a Jev pick was used (including a cached pick).
# Hops includes skipped providers; lat is total elapsed seconds including routing
# and failed hops; cost is only the answering hop's cost, not the chain's total.
# Exhaustion emits one stderr diagnostic per hop, including failures and skips.
#
# Ledger format: headerless TSV, one line per call:
#   ts provider cost_usd lat_s n_results route
# ts is Unix seconds; lat_s covers the provider call, not routing or lock waits.
# lat_s and n_results are space-padded to a fixed width: a capped call is first
# written as a reservation (n_results -1, cost_usd at the configured Exa price
# or zero for TinyFish) and rewritten in place when it ends.
# --ledger reports the current UTC calendar month, not a rolling month.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 -I "$HERE/fm-search.py" "$@"
