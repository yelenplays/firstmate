# Bounded live validation

Result: inconclusive. This is the single additional round authorized after the prior test decision. No source changes. No credentials were searched for in other homes, no tools installed, and no shared service configuration changed.

## Executed

- `TMPDIR="$PWD/.jev-validation-tmp" bash tests/fm-jev-skill-select.test.sh`: exit 0. Behavioral regression coverage uses fake curl, not live Jev.
- `TMPDIR="$PWD/.jev-validation-tmp" bash tests/fm-spawn-jev-skill-live.test.sh`: exit 0. Covers delivery syntax, refreshed worker skills, Codex skill locations, query privacy and skip behavior, failure fallback, and disabled/missing-query relaunch resets. Uses fake Jev and fake worker/backend tools, not live worker coverage.
- Real `bin/fm-jev-skill-select.sh` in a temporary isolated FM_HOME: unconfirmed live request exits 2; confirmed live and shadow requests without keys exit 0 with an off message. All preserve the supplied overlay and create no selection record. Transcript: selector-cli-live.json.
- Presence-only environment check: TYPESAFE_API_KEY absent; OPENROUTER_API_KEY absent; worktree .env absent. tmux, codex, grok, claude, pi, herdr and jq binaries exist. Binary presence does not establish an authenticated isolated worker.
- Requested `data/jev-everything-rag-v1/report.md` is absent from this worktree. No other checkout was searched.
- Temporary test directory removed; git status clean. No UI changes or rendered visual surface was exercised; evidence is CLI output.

## Exact unsupported live scenarios

1. Launch an opted-in worker: selected skills reach its brief using the correct harness syntax. Blocker: neither Jev provider credential is available; no authenticated isolated worker was provisioned. Supply TYPESAFE_API_KEY or OPENROUTER_API_KEY and a worker configured to run entirely inside the permitted workspace.
2. Launch modern or legacy briefs containing private excerpts: only an explicit safe query is sent; missing or blank queries skip selection. Blocker: live request privacy needs a Jev credential; full launch/skip verification also needs an isolated launchable worker. Only the stubbed executable regression was driven. Provide the credential and isolated worker.
3. Launch after refreshing the worker revision: discover readable worker skills and the selected Codex skill home. Blocker: no Jev credential to obtain a real selection and no provisioned isolated worker. Provide both, with a skill catalog in that worker's permitted home.
4. Receive no suitable selection or a Jev failure: worker launch proceeds without injected skills. Blocker: a real none/error response and continued worker execution were not available without a configured Jev provider and isolated worker. The no-key selector fallback alone was exercised live; fake none/error launch regressions passed. Provide the provider and worker.
5. Relaunch after disabling selection or removing the query: clear live_loaded while retaining the cached choice. Blocker: cannot establish the prerequisite successful live selected launch without a Jev credential and isolated worker. Provide both; then disable selection or remove the query and relaunch the same task.

No live HTTP was added to automated tests. No full suite, lint, formatting, other pipeline phases, push, PR or CI actions were run. Stop after this bounded round for supervisor decision.
