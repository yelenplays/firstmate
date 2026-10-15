# Agent browser guard verification

[`docs/browser-guard.md`](../browser-guard.md) owns the contract.
This record holds the live evidence behind it: what the real launchers send, and what the guard does to a real browser process.

Recorded 2026-10-15 on macOS (Apple Silicon) with Node v26.11.0, playwright-core 1.64.1, puppeteer-core 25.14.0, Chrome for Testing 153.0.8010.12 (the `chromium-1243` Playwright build) and Chrome for Testing 150.0.7871.24 (the puppeteer cache).

## What the real launchers send

Captured by pointing each launcher's `executablePath` at a recording stub that appends its argv and exits, so no browser process and no window is involved.
The recorded argument lists are committed as `tests/fixtures/browser-guard/<launcher>.args` and replayed by `tests/fm-browser-guard.test.sh`.

| Fixture | Recorded headed argv | Guarded outcome |
| --- | --- | --- |
| `playwright-chromium-headed` | 41 arguments, `--remote-debugging-pipe`, no headless flag | one `--headless` appended |
| `playwright-chromium-headless` | 45 arguments, already carries `--headless` | unchanged |
| `playwright-firefox-headed` | `-no-remote -wait-for-browser -foreground -profile <dir> -juggler-pipe -silent` | one `-headless` appended |
| `playwright-webkit-headed` | `--inspector-pipe --no-startup-window` | one `--headless` appended |
| `puppeteer-headed` | 32 arguments, `--remote-debugging-port=0`, no headless flag | one `--headless` appended |
| `puppeteer-headless` | 35 arguments, already carries `--headless=new` | unchanged |

## A real browser, forced from a headed request

Command shape (run from a scratch directory holding playwright-core and puppeteer-core, with the guard environment applied first):

```sh
snippet=$(bin/fm-browser-guard-env.sh --command)
/bin/sh -c "$snippet node e2e-playwright.mjs"
```

`e2e-playwright.mjs` calls `chromium.launch({ headless: false, executablePath: <cached Chrome for Testing> })`, renders a heading, and reports what the browser and the process table say.
Observed output:

```text
fm-browser-guard: forced headless: playwright-core asked for a visible window; set FM_ALLOW_HEADED_BROWSER=1 to allow it (captain only)
RESULT text=guarded-headless
RESULT browser_product=Chrome/153.0.8010.12
RESULT user_agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/153.0.0.0 Safari/537.36
RESULT browser_process_found=true
RESULT process_headless_flag=true
```

The same shape against `puppeteer.launch({ headless: false, executablePath: <cached Chrome for Testing 150> })`:

```text
fm-browser-guard: forced headless: google chrome for testing (chromium) asked for a visible window; set FM_ALLOW_HEADED_BROWSER=1 to allow it (captain only)
RESULT text=guarded-headless
RESULT headless_ua=true
RESULT process_headless_flag=true
```

`HeadlessChrome` in the user agent is the browser's own report that it is running headless, and the process-table check confirms the launched process carries `--headless`.
The control case, the same launcher without the guard environment, records a headed argv with no headless flag at all, which is the state the guard exists to remove.

## What the guard must not break

- `chrome-devtools-axi` against the shared headless shell on `127.0.0.1:9223`: a guarded `newpage`, `pages`, `closepage`, and `stop` cycle completed normally, with the tab created in the shared shell rather than a new browser.
- Node itself: `node -e`, a non-browser `spawnSync`, a shell-form `execSync`, and a promisified `execFile` all behave identically under the guard, and the preload writes nothing to stdout.
- The PATH shims pass `open ./report.md`, `open -R ./report.html`, `open -a TextEdit`, and non-browser AppleScript through to the real tools with their arguments intact.

## Refresh

Run `bash tests/fm-browser-guard.test.sh` for the portable half.
Re-capture the fixtures by running a launcher's headed and headless launch with a recording stub as `executablePath` and saving the argument list, then refresh this record's versions and outcomes.
