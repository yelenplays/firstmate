# Validation boundaries

Target: bf43acf08465d221a6042674af610cda9372c50b
Base: 4ace8ee95f74a404d79d56fb6b5a11834e5e6fd5

## Live product evidence

`live-cli-transcript.json` records 11 real CLI invocations from `live-smoke.py`, run against isolated operational directories inside the supplied worktree. No executable, transport, or engine was substituted. The transport-failure check used real curl against loopback port 1, with a synthetic credential, and observed HTTP 000. No external provider request was made.

Passed: unconfigured wiki; missing catalog; invalid configured engine; no-credential miss classification; refusal of nested body, excerpts, conflict lines and citations; actual connection refusal with attempted-send metadata; completion presentation with quoted-empty credentials and no dedup record; direct advisory verifier writing to external effective state without altering original worker status bytes.

## Scenarios not driven live

1. Retrieve real wiki misses for metadata-only classification while leaving hits unchanged. Blocker: `wiki-tool` is absent from PATH, no isolated real engine/catalog is provided, and no Jev credential exists in the process environment or worktree `.env`. Supply an executable engine with an isolated synthetic catalog plus an authorized Jev credential to complete a standalone smoke. No installation, service startup, private catalog access, or other home access was attempted.
2. Successfully score only presented completions once across concurrent drains, whitespace variants, and external state, without closing tasks. Blocker: no configured Jev credential/provider is available in the allowed environment. Supply a credential for a standalone smoke using synthetic completions. Positive model verdicts, in-flight concurrency, presentation snapshot consistency, capped/suppressed selection, internal tabs, CRLF, trailing tabs, default/external state, and enabling credentials after quoted-empty values were validated with fake transport only.
3. Receive failed HTTP responses, malformed JSON, and unsupported confidence and retain conservative outcomes with attempted-send metadata. Blocker: no available configured provider or controllable real-provider failure response facility. Supply an authorized provider test facility to reproduce these responses live. Fake transport covered these response classes; the real connection-refusal smoke covers only connection failure, not HTTP errors or model response validation.

The prohibition on live HTTP in automated tests was respected. It was not interpreted as prohibiting an authorized standalone smoke; missing credentials and engine availability are the actual blockers.

## Focused regression validation

Command: `bash bin/fm-test-run.sh --jobs 1 tests/fm-jev-retrieval-miss.test.sh tests/fm-wiki-ask.test.sh tests/fm-jev-done-verify.test.sh`

All three passed without gate skips. These suites replace curl, and wiki integration also replaces wiki-tool. Their results are supporting behavioral regression coverage, not live Jev/wiki evidence. See `targeted-tests.log`.

## Scope and cleanup

No source changes, linters, static analysis, broad suite, delivery commands, or system changes. Temporary smoke operational directories were deleted after the run; final `git status --short` was empty. No UI changes are present; evidence is CLI output and persisted JSON records, so no screenshot was needed. The referenced `data/jev-everything-rag-v1/report.md` is absent from this worktree; the supplied intent and runtime change were used as acceptance context. Codebase-memory inventory was checked; no index was created because its server-owned persistent writes fall outside the allowed worktree boundary.

Overall: inconclusive for full live integration, with all executed checks passing. These are the same environment limitations previously declined; no new product failure was observed.
