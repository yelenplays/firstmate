# Browser guard live verification

Candidate: `41e12a6371b04895ebfbbc9a1603732afd945526`

Platform: macOS; Node v26.11.0; Google Chrome 155.0.8059.80; locally installed playwright-core 1.64.1 and puppeteer-core 25.14.0.

## Executed

- `TMPDIR="$PWD/.guard-validation/tmp" bash tests/fm-browser-guard.test.sh` — targeted behavioral baseline completed successfully. Its fake terminal/browser fixtures are not live worker or browser evidence.
- `npm install --prefix "$PWD/.guard-validation/launchers" --cache "$PWD/.guard-validation/npm-cache" --ignore-scripts --no-audit --no-fund --package-lock=false playwright-core puppeteer-core` — project-local test dependencies only.
- Each live driver ran from the candidate worktree using `snippet=$(bin/fm-browser-guard-env.sh --command)` followed by `HOME="$PWD/.guard-validation/home" TMPDIR="$PWD/.guard-validation/tmp" /bin/sh -c "$snippet exec node <driver>"` (or `python3` for the shim driver).
- `node .guard-validation/launchers/live-api.cjs` — actual Playwright launch, launchPersistentContext, and launchServer with headless:false; all rendered content and reported HeadlessChrome. Caller options remained unchanged.
- `node .guard-validation/launchers/live-api.mjs` — actual ESM Playwright and Puppeteer headless:false launches; both rendered content and reported HeadlessChrome.
- `node .guard-validation/direct-browser.cjs` — actual Chrome --headless=false requests through spawn, spawnSync, execFile, promisified execFile, execFileSync; each rendered its HeadlessChrome user agent. A filtered child Node environment retained protection without copying a parent sentinel or mutating caller environment.
- `python3 .guard-validation/shim-live.py` — actual guarded open URL/application/bundle/HTML attempts, AppleScript and JXA stdin browser attempts, and Python webbrowser were refused. Real non-browser AppleScript returned 42; ordinary promisified Node echo was unchanged.
- `chrome-devtools-axi newpage <data URL>`, `eval`, `resize 1280 800`, `screenshot`, `pages`, and `stop` — isolated session fm-browser-guard-01M55, local HOME/profile, CHROME_DEVTOOLS_AXI_HEADED=1, explicit PATH-resolved MCP executable, and shared browser URL/auto-connect unset. Browser reported HeadlessChrome; its own process argv ended in --headless. The CLI screenshot command reported a filename but did not leave a file, so the persisted PNG was captured through Playwright's real page.screenshot instead and inspected visually.

## Evidence

- live-launcher-api.log: real launcher results and notices.
- live-node-browser.log: actual rendered DOM for every process API and filtered child.
- live-shims.log: commands, exit codes, stdout/stderr from real CLI calls.
- live-browser.log: actual MCP page result, browser user agent, and isolated browser process arguments.
- guarded-browser.png: actual Playwright-rendered page showing requested headed options and observed HeadlessChrome user agent.
- Driver sources are retained alongside this record for reproducibility. They were transient test drivers, not changes to product source.

## Limits

No real tmux worker/primary was launched: tmux is not on PATH and no repository-local executable was supplied. Actual spawn injection was exercised only with the existing test's fake pane and probe, not a real harness/login. No substitution with another runtime was attempted.

Electron, Firefox, MiniBrowser and pw_run.sh are not on PATH and no repository-local binaries were supplied. Their targeted fixture coverage is not a live application proof. An actual bare Chrome invocation without profile arguments was not attempted because it can use the operator's default profile; that regression was covered with the test's recording binary only. No captain opt-out was applied to a real browser.

## Cleanup

The isolated MCP session was stopped. Every driver closed its own browser. A process-table check found no Chrome parent using the test directory. All temporary profiles, dependencies, caches, fixture files, and drivers in .guard-validation were removed; evidence remains here. No source changes, linters, full test suite, push, PR, or CI phases were run.
