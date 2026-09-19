# Bounded live-validation follow-up

Verdict: inconclusive for live provider integration, not a product test failure.
No source fix is justified by the reproduced environment limitations.
This is the final authorized follow-up round; remaining blockers return to Firstmate for disposition.

## Exact remaining scenarios and blockers

1. Retrieve a real wiki miss for metadata-only advisory classification while leaving a real hit unchanged.
   Blockers: `command -v wiki-tool` fails; FM_WIKI_ENGINE and FM_WIKI_CATALOG are absent; worktree config/wiki-engine and config/wiki-catalog are absent.
   No executable engine or isolated catalog is configured within the authorized boundary.
   Installation, starting an absent engine, and accessing real vaults/catalogs or another home are prohibited.
   Positive remote classification additionally lacks both supported API credentials.
2. Successfully score only actually presented completions once across concurrent drains, including CRLF/trailing-tab completions and external FM_STATE_OVERRIDE, without closing tasks or modifying worker status bytes.
   Blockers: TYPESAFE_API_KEY and OPENROUTER_API_KEY are empty/unset in the inherited environment, and the worktree .env does not exist.
   The real classifier CLI confirms resolution failure: verdict skipped, sent no, decide_code 2.
   No configured authenticated Jev provider is available within the authorized boundary.
3. Receive malformed JSON, HTTP failure responses, or unsupported confidence from a live provider and retain conservative outcomes and attempted-send metadata.
   Blockers: the same unavailable provider credentials, plus no configured controllable live provider capable of deliberately returning these error responses.
   A normal successful model request would not establish malformed-response coverage.
   No missing service was started or installed to manufacture live evidence.

Standalone live smoke requests are authorized by the latest decision.
The prohibition on live HTTP in automated tests is NOT the reason successful standalone smoke testing is unavailable.
No credential was printed or persisted, no private catalog was accessed, and no wiki bodies, excerpts, or conflict lines were sent.
The requested investigation report data/jev-everything-rag-v1/report.md is absent from this worktree; no other checkout was searched.

## Evidence separation

round3-live-cli.json records fresh real CLI executions for absent engine and absent credentials, capability checks, and the persisted skipped advisory record.
These are live local CLI observations, not successful live wiki retrieval or model scoring.
Earlier round2-live-cli.json evidence is historical and is not counted as freshly rerun coverage.

The focused fake-transport suites are recorded separately in round3-focused-tests.json and round3-fm-*.log.
The positive model cases rely on synthetic Jev answers: evidenced/not_evidenced/need_human completion judgments and positive miss classification.
The wiki miss/missing-source integration and unchanged-hit behavior rely on a fake wiki engine and fake transport.
The overlapping-drain in-flight serialization, first-record deduplication, actual-presentation filtering, capped/suppressed backstops, tab/CRLF variants in default/external state, exact status-byte preservation, and no-teardown checks rely on fake transport.
The HTTP 500, invalid JSON, transport failure, low confidence, and missing/null confidence cases rely on fake transport.
No real-model correctness, live-provider concurrency, or malformed live-provider response coverage is claimed.

## Result

All three named focused suites passed (exit 0); no failing test reproduced.
No source or test changes were necessary.
No lint, formatting, static analysis, full suite, push, PR, or CI phase was run.
Tested HEAD: df3e43fa95cca3265483487665bc993a9cac7c0c
Temporary worktree fixtures removed. Final git status --short: clean
