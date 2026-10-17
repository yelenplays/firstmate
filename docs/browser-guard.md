# Agent browser guard

The agent browser guard forces covered browser launches headless or refuses them when no headless form exists.
`bin/fm-spawn.sh` establishes it for every crewmate, scout, and secondmate, on a fresh spawn and on a relaunch alike, without relying on a worker remembering an instruction.
The coverage below assumes an intact installation, the inherited guard environment, and no captain opt-out; the [boundaries](#boundaries) describe routes it cannot enforce.

## Covered launches

- A browser started through the patched Node launcher APIs or process calls described below runs headless.
- `open <url>`, `open -a "Google Chrome"`, `open -b <browser bundle>`, and `open <page.html>` are refused instead of opening a window, and the refusal is one line on stderr plus a non-zero exit.
- `osascript` scripts that address a browser or ask for a web URL are refused, including the script-on-stdin form older Python's `webbrowser` module sends through `PATH`.
- Python's `webbrowser.open` and other tools that honor `BROWSER` are refused in one line, including Python 3.13 and later, whose `webbrowser` pipes to `/usr/bin/osascript` by full path and so never reaches the `osascript` shim.
- Ordinary file opening, `open -R`, non-browser applications, and non-browser AppleScript keep working unchanged.
- The Node preload emits one `fm-browser-guard:` line for the first forced launch and one for the first allowed visible launch per process; later launches in that process do not repeat those notices.
  Each shim refusal or opt-out invocation emits its own notice.

## How it works

Three layers, each covering what the one below it cannot.
[`bin/fm-browser-guard-env.sh`](../bin/fm-browser-guard-env.sh) is the single owner of the environment text that turns them on, and `bin/fm-spawn.sh` embeds that text at the head of every launch command.

1. **The launcher API** - [`bin/fm-browser-guard-preload.cjs`](../bin/fm-browser-guard-preload.cjs) is loaded into every Node process through `NODE_OPTIONS=--require`.
   It appends a patch call to every CommonJS module compiled out of a playwright/puppeteer package and wraps `launch`, `launchPersistentContext`, and `launchServer` on the launcher class or the exported instance, so `headless: false` becomes `headless: true` before the library builds its argument list.
   Hooking `Module.prototype._compile` rather than `Module._load` is what also covers `import { chromium } from 'playwright-core'`, because an ESM import of a CommonJS package still compiles through it.
   The library then takes its own headless path - its own binary choice, its own flags - so the forced launch is exactly the launch that library performs when it is asked for headless.
2. **The browser process** - the same preload wraps `child_process.spawn`, `spawnSync`, `execFile` (including `util.promisify(execFile)`), and `execFileSync` and adds the library's own headless flag to a browser command line that is missing one: `--headless` for the Chromium family, `-headless` for Firefox, `--headless` for WebKit.
   It recognizes a browser by its binary name alone - Chrome, Chromium, Chrome for Testing, the headless shell, Edge, Brave and the other Chromium browsers, Firefox, and Playwright's WebKit - never by debugging flags, so an Electron app launched with `--remote-debugging-port` is left untouched, and a bare `spawn(chromePath)` with no argument list still gets the flag.
   This is the layer that catches a launcher's ESM build (puppeteer-core ships one), a wrapper script, a driver, and any other tool that starts a known browser binary.
   It is also the reason a `chrome-devtools-axi` run that opts into a headed browser still cannot open one.
3. **The PATH shims** - [`bin/fm-browser-guard-bin/open`](../bin/fm-browser-guard-bin/open) and [`bin/fm-browser-guard-bin/osascript`](../bin/fm-browser-guard-bin/osascript) are symlinks to [`bin/fm-browser-guard-open.sh`](../bin/fm-browser-guard-open.sh) and [`bin/fm-browser-guard-osascript.sh`](../bin/fm-browser-guard-osascript.sh), which the guard puts first on the pane's `PATH`.
   They cover the routes that never touch Node, and they refuse rather than forcing because `open` has no headless form.
   The guard also sets `BROWSER` to [`bin/fm-browser-guard-browser.sh`](../bin/fm-browser-guard-browser.sh), which Python's `webbrowser`, `gh`, and `git web--browse` call with the URL before anything else.
   It refuses the URL in one line but exits 0, because `webbrowser.open` treats a failing `BROWSER` as a cue to try its next entry, the full-path `osascript` pipe.
   [`bin/fm-browser-guard-shim-lib.sh`](../bin/fm-browser-guard-shim-lib.sh) is the single owner of which applications, bundle identifiers, targets, and AppleScript forms are browser launches.

The guard environment also sets `LAVISH_AXI_NO_OPEN=1`, lavish-axi's own switch for suppressing its local browser launch.
A worker's visual review therefore still serves its artifact and prints its review URL, and the firstmate that owns the captain's attention opens it in the unguarded primary session instead of a worker pane forcing a window or hitting a refusal.

The preload is loaded into every Node process a worker starts, including the harness itself, so it is built to be inert: all installation and hook work is wrapped, nothing is written to stdout, and a failure anywhere leaves the process behaving exactly as it would have without the guard.
Its cost when it does not act is one filename test per compiled module and one command test per spawn.

## The captain's escape hatch

`FM_ALLOW_HEADED_BROWSER=1` is the opt-out, and it is the captain's to set.
Scope it to one command to allow only that command's launches; exporting it in a shell allows subsequent child commands until it is unset.
It is not consumed after one launch.
Every layer reads its own process environment at use time; changing a pane shell's exports does not change an already-running worker's environment.
The notices described above name the opt-out when it is honored.
Firstmate never sets it for a worker, and no config file or flag turns the guard off for a fleet.
This is an environment-based backstop, not a sandbox preventing a worker from changing its own environment.

## Boundaries

- A launcher that is neither a Node process nor one of the two PATH shims is outside the guard: a Python or Java Selenium run driving `chromedriver`, an absolute-path browser binary started from a shell, or a script file passed to `osascript` (only `-e` and stdin scripts are read).
- A browser binary renamed to a name the spawn layer does not recognize is outside layer 2; a Playwright or Puppeteer launch of it is still forced headless by layer 1.
- A browser URL held in an AppleScript variable, or one assembled inside a shell string passed to `child_process.exec`, cannot be judged without evaluating the script, so the guard does not try.
- The guard covers agents Firstmate launches.
  The captain's own primary session is not guarded, so his own browser use and his login flows are unaffected.
- If the guard environment builder detects missing guard files, it emits a warning-only snippet and the worker continues unguarded rather than failing.
  File checks happen when the launch is built, not in the destination pane.
- If the preload path cannot be represented safely in `NODE_OPTIONS`, the launch warns and skips the Node layers while retaining the PATH shims and `BROWSER` hook.
  [`bin/fm-browser-guard-env.sh`](../bin/fm-browser-guard-env.sh) owns the path restrictions.

## Verification

[`tests/fm-browser-guard.test.sh`](../tests/fm-browser-guard.test.sh) drives the real spawn, executes the launch command the pane received, and asserts that a headed browser request from inside that environment ends headless.
It replays each launcher's recorded argument list from `tests/fixtures/browser-guard/`, exercises the launcher API through both an ESM and a CommonJS entry point, and covers the shims, the opt-out, idempotence, and the ordinary Node work the guard must not disturb.
[`docs/verification/browser-guard.md`](verification/browser-guard.md) records the live end-to-end evidence against real Playwright and Puppeteer launches, with the versions and commands that produced it.
