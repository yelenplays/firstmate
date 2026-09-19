# Final bounded test-phase evidence
Verdict: inconclusive. No product failure reproduced; no source changes made.

Live evidence: final-live-cli.json records unconfigured wiki behavior, missing-credential skip, nested body/excerpt/conflict_lines refusal without sending or logging their contents, rejected inline interface, and external-state done logging with unchanged status bytes. final-live-drain.json records a real drain presenting a completion with quoted-empty keys, unchanged worker status bytes, and no deduplication record. No stubs were used for these local live observations.

## Exact remaining live scenarios and blockers
1. Retrieve a real wiki miss, classify query/metadata only, and leave a real hit unchanged: wiki-tool is absent from PATH; engine/catalog environment and worktree configuration are absent. Provide an executable engine and an authorized isolated catalog. Positive classification also needs the credential below.
2. Successfully score only presented completions once across concurrent drains, both presentation paths, CRLF/trailing tabs, and external state without closing tasks: both supported API credentials are absent/empty in the environment and this worktree has no .env. Provide TYPESAFE_API_KEY or OPENROUTER_API_KEY for an authorized standalone provider smoke.
3. Receive HTTP failure, malformed JSON, and unsupported confidence from a live provider while retaining conservative outcomes and attempted-send metadata: no authenticated provider or controllable live provider error mode is configured. Provide an authorized provider/error-injection facility for these specific responses. A successful model call would not establish them.

Standalone live HTTP smoke is authorized. The prohibition on live HTTP in automated tests is not the blocker. No HTTP request was made, no credential exposed, no private catalog or other home accessed, and no absent service installed or started.

## Separate fake-transport regressions
All three focused commands exited 0 with TMPDIR set to the worktree .test-final-smoke/tmp:
- bash tests/fm-jev-done-verify.test.sh
- bash tests/fm-jev-retrieval-miss.test.sh
- bash tests/fm-wiki-ask.test.sh
Transcripts: final-done-regressions.log, final-retrieval-regressions.log, final-wiki-regressions.log.
Positive evidenced/not_evidenced/need_human and miss judgments, later-credential recovery, concurrency and first-record deduplication, actual-presentation/snapshot filtering, caps/suppression, whitespace variants, and no-close/teardown assertions rely on fake transport. Wiki hit/miss integration also uses a fake engine. HTTP errors, malformed JSON, transport failure, and low/missing/null confidence rely on fake transport. These are passing behavioral regressions, not live model evidence.

The requested investigation report is absent from this worktree; no other checkout was searched. No lint, static analysis, formatting, full suite, delivery, or pipeline-control commands ran. This CLI-only change has no graphical surface requiring screenshots. Earlier-round evidence is historical and not counted as fresh execution. Temporary fixtures are removed after validation. Return these remaining blockers for Firstmate disposition without another identical fix cycle.
