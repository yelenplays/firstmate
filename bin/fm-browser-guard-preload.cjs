'use strict';
// fm-browser-guard-preload.cjs - the Node half of the agent browser guard.
//
// Firstmate launches every crewmate, scout, and secondmate with
// NODE_OPTIONS=--require <this file> (bin/fm-browser-guard-env.sh owns the pane
// environment text), so any Node process a worker starts - a scratchpad script,
// `npx playwright test`, a puppeteer tool, chrome-devtools-mcp - loads this
// preload before its own code. The preload forces every browser launch it can
// reach to run headless, so a visible window cannot open on the captain's Mac
// no matter what the launcher asked for. It is enforcement, not advice: a
// worker never has to remember the rule, and a launcher that requests
// `headless: false` still ends up headless.
//
// Three enforcement layers, each covering what the one below cannot:
//
//   1. Launcher API (Module.prototype._compile). Every CommonJS module compiled
//      out of a playwright/puppeteer package gets a patch call appended to its
//      source, and the patch wraps `launch`, `launchPersistentContext`, and
//      `launchServer` on the launcher class prototype or the exported instance
//      so `headless: false` becomes `headless: true` before the library ever
//      builds its argument list. Hooking _compile rather than Module._load is
//      what makes this work for `import { chromium } from 'playwright-core'`
//      too: an ESM import of a CommonJS package still compiles it here, while
//      Module._load never runs for it. The library then uses its own headless
//      path - its own binary choice and its own flags - so the forced launch is
//      exactly the launch that library performs when asked for headless.
//   2. Process spawn (child_process spawn/spawnSync/execFile/execFileSync). The
//      browser command line is rewritten to carry the library's own headless
//      flag before the process starts. This is the backstop for launchers this
//      preload does not recognize as a library: a wrapper script, a driver,
//      or any other tool that starts a browser process. A browser is
//      recognized by its binary name only, never by debugging flags, so an
//      Electron app launched with --remote-debugging-port is left alone.
//   3. PATH shims (bin/fm-browser-guard-bin/open, .../osascript), which cover
//      the non-Node routes: `open <url>`, `open -a "Google Chrome"`, and
//      AppleScript browser activation. They refuse instead of forcing, because
//      no headless equivalent of those commands exists.
//
// Escapes: FM_ALLOW_HEADED_BROWSER=1 is the captain's opt-out. The guard prints
// exactly one line when it forces a launch or honors that opt-out, so both are
// visible in the worker's own transcript.
//
// Fail-safe posture: this file is loaded into EVERY Node process a worker
// starts, including the harness itself, so it must never be able to break one.
// All installation work is wrapped, every hook body is wrapped, nothing is
// written to stdout, and a failure anywhere leaves the process running exactly
// as it would have without the guard. The cost when it does not act is one
// filename test per compiled module and one command test per spawn.
//
// Coverage boundary (docs/browser-guard.md owns the full contract): a launcher
// that is neither a Node process nor one of the two PATH shims - a Python or
// Java Selenium run driving chromedriver, an absolute-path browser binary
// started from a shell, a script file passed to `osascript` - is outside this
// guard. Every browser started through Node, `open`, or `osascript -e` is
// inside it.

const OPT_OUT_VAR = 'FM_ALLOW_HEADED_BROWSER';
const PREFIX = 'fm-browser-guard: ';
const PATCH_GLOBAL = '__fmBrowserGuardPatch';

let forcedNoted = false;
let allowedNoted = false;

// headedAllowed reads the opt-out on every decision rather than once at load,
// so a captain who exports it in the pane after the worker started is honored.
function headedAllowed() {
  try {
    return process.env[OPT_OUT_VAR] === '1';
  } catch (err) {
    return false;
  }
}

function note(message) {
  try {
    process.stderr.write(PREFIX + message + '\n');
  } catch (err) {
    /* a closed stderr never becomes the guard's problem */
  }
}

function noteForced(label) {
  if (forcedNoted) return;
  forcedNoted = true;
  note('forced headless: ' + label + ' asked for a visible window; set ' + OPT_OUT_VAR + '=1 to allow it (captain only)');
}

function noteAllowed(label) {
  if (allowedNoted) return;
  allowedNoted = true;
  note(OPT_OUT_VAR + '=1 - allowing a visible window for ' + label);
}

// --- layer 1: launcher API -------------------------------------------------

const wrappedMethods = new WeakSet();

function asksForWindow(options) {
  if (!options || typeof options !== 'object') return false;
  const headless = options.headless;
  return headless === false || headless === 0 || headless === 'false' || headless === '0';
}

function forceHeadless(options) {
  const forced = {};
  for (const key of Object.keys(options)) forced[key] = options[key];
  forced.headless = true;
  return forced;
}

function wrapMethod(holder, name, optionsIndex, label) {
  let original;
  try {
    original = holder[name];
  } catch (err) {
    return false;
  }
  // The set holds the wrappers this preload installed, so a holder whose method
  // is already guarded is never wrapped twice, while a second holder that still
  // points at the unwrapped original gets its own wrapper.
  if (typeof original !== 'function' || wrappedMethods.has(original)) return false;
  const wrapper = function () {
    const args = Array.prototype.slice.call(arguments);
    try {
      if (asksForWindow(args[optionsIndex])) {
        if (headedAllowed()) noteAllowed(label);
        else {
          args[optionsIndex] = forceHeadless(args[optionsIndex]);
          noteForced(label);
        }
      }
    } catch (err) {
      /* an unpatched call is still better than a broken one */
    }
    return original.apply(this, args);
  };
  try {
    Object.defineProperty(wrapper, 'name', { value: name, configurable: true });
  } catch (err) {
    /* cosmetic only */
  }
  try {
    Object.defineProperty(holder, name, {
      value: wrapper,
      writable: true,
      configurable: true,
      enumerable: Object.prototype.propertyIsEnumerable.call(holder, name),
    });
  } catch (err) {
    return false;
  }
  wrappedMethods.add(wrapper);
  return true;
}

// launcherShape is deliberately loose: the patch only ever runs on modules
// inside a playwright/puppeteer package, where anything exposing `launch` plus
// a browser-launcher sibling is the launcher.
function launcherShape(target) {
  if (!target || (typeof target !== 'object' && typeof target !== 'function')) return false;
  let launch;
  try {
    launch = target.launch;
  } catch (err) {
    return false;
  }
  if (typeof launch !== 'function') return false;
  try {
    if (typeof target.launchPersistentContext === 'function') return true;
  } catch (err) {
    /* fall through to the executablePath test */
  }
  try {
    return typeof target.executablePath === 'function';
  } catch (err) {
    return false;
  }
}

function patchLaunchers(holder, label) {
  wrapMethod(holder, 'launch', 0, label);
  wrapMethod(holder, 'launchPersistentContext', 1, label);
  wrapMethod(holder, 'launchServer', 0, label);
}

function patchTarget(target, label) {
  if (!target || (typeof target !== 'object' && typeof target !== 'function')) return;
  let proto = null;
  try {
    proto = typeof target === 'function' ? target.prototype : Object.getPrototypeOf(target);
  } catch (err) {
    proto = null;
  }
  // A class prototype is patched first so every instance - including ones
  // created later - inherits the guard.
  if (proto && proto !== Object.prototype && launcherShape(proto)) {
    patchLaunchers(proto, label);
    return;
  }
  if (launcherShape(target)) patchLaunchers(target, label);
}

function patchExports(exports, filename) {
  if (!exports) return;
  const label = packageLabel(filename);
  try {
    patchTarget(exports, label);
  } catch (err) {
    /* keep going: the named exports below are the common shape */
  }
  let names;
  try {
    names = Object.getOwnPropertyNames(exports);
  } catch (err) {
    return;
  }
  for (const name of names) {
    if (name === 'prototype' || name === 'constructor') continue;
    let value;
    try {
      value = exports[name];
    } catch (err) {
      continue;
    }
    try {
      patchTarget(value, label);
    } catch (err) {
      /* one unreadable export never stops the rest */
    }
  }
}

// packageLabel names the launcher package in the one-line notice, so a forced
// launch reads as "playwright-core asked for a visible window" rather than as a
// path inside node_modules.
function packageLabel(filename) {
  if (typeof filename !== 'string' || !filename) return 'a browser launcher';
  const match = /node_modules[\\/]((?:@[^\\/]+[\\/])?[^\\/]+)/.exec(filename);
  return match ? match[1].replace(/\\/g, '/') : filename;
}

// browserLibraryFile matches every module inside a browser-automation package,
// in a flat node_modules tree or a pnpm store alike. Appending the patch call
// to each of them is safe: the patch is shape-checked and idempotent, and the
// entry module is the one that carries the launcher.
function browserLibraryFile(filename) {
  return (
    typeof filename === 'string' &&
    /[\\/]node_modules[\\/](?:playwright|playwright-core|puppeteer|puppeteer-core|@playwright[\\/]test)[\\/]/.test(filename)
  );
}

function installLauncherPatch() {
  const Module = require('module');
  const originalCompile = Module.prototype._compile;
  globalThis[PATCH_GLOBAL] = patchExports;
  const snippet =
    '\n;try{globalThis.' + PATCH_GLOBAL + '&&globalThis.' + PATCH_GLOBAL + '(module.exports,__filename);}catch(e){}\n';
  Module.prototype._compile = function (content, filename) {
    try {
      if (browserLibraryFile(filename) && typeof content === 'string' && content.indexOf(PATCH_GLOBAL) === -1) {
        content += snippet;
      }
    } catch (err) {
      /* compile the module unchanged */
    }
    return originalCompile.call(this, content, filename);
  };
}

// --- layer 2: process spawn ------------------------------------------------

// Chromium accepts a bare `--headless`, which is the flag Playwright itself
// passes and means the new headless implementation on every Chrome that
// supports it, so the forced launch matches the library's own headless launch
// on old and new builds alike.
const CHROMIUM_BINARY = /^(?:google chrome(?: (?:beta|dev|canary|for testing))?|chrome|chromium|chromium-browser|google-chrome|chrome-headless-shell|headless_shell|brave|brave-browser|msedge|microsoft edge|vivaldi|opera|thorium)$/;
const FIREFOX_BINARY = /^(?:firefox|firefox-bin|firefox-esr|firefoxdeveloperedition|firefox-nightly|nightly|mozilla firefox)$/;
const WEBKIT_BINARY = /^(?:pw_run\.sh|playwright|minibrowser)$/;

function baseName(command) {
  const text = String(command);
  const cut = Math.max(text.lastIndexOf('/'), text.lastIndexOf('\\'));
  const base = (cut === -1 ? text : text.slice(cut + 1)).toLowerCase();
  return base.endsWith('.exe') ? base.slice(0, -4) : base;
}

function hasArg(args, test) {
  for (const arg of args) {
    if (typeof arg === 'string' && test(arg)) return true;
  }
  return false;
}

function isHeadlessFlag(arg, family) {
  if (family === 'firefox') return arg === '-headless' || arg === '--headless';
  if (family === 'webkit') return arg === '--headless' || arg.startsWith('--headless=');
  if (arg === '--headless') return true;
  // A Chromium launch that explicitly asks for a visible window is not
  // headless, whatever value form it used.
  return /^--headless=/.test(arg) && !/^--headless=(?:false|0|no|off)$/i.test(arg);
}

function classifyBrowser(command) {
  const base = baseName(command);
  if (CHROMIUM_BINARY.test(base)) return 'chromium';
  if (FIREFOX_BINARY.test(base)) return 'firefox';
  if (WEBKIT_BINARY.test(base)) return 'webkit';
  return null;
}

// guardedArgv returns the rewritten argument list, or null when this spawn is
// not a browser launch or is already headless. A shell spawn is skipped: its
// argument list is a command line, not an argv, and rewriting it would corrupt
// it - the PATH shims and layer 1 cover those launchers instead.
function guardedArgv(command, args, options) {
  if (typeof command !== 'string' || !Array.isArray(args)) return null;
  if (options && typeof options === 'object' && options.shell) return null;
  const family = classifyBrowser(command);
  if (!family) return null;
  if (hasArg(args, (a) => isHeadlessFlag(a, family))) return null;
  const label = baseName(command) + ' (' + family + ')';
  if (headedAllowed()) {
    noteAllowed(label);
    return null;
  }
  const kept = family === 'chromium' ? args.filter((a) => !(typeof a === 'string' && /^--headless=/.test(a))) : args.slice();
  kept.push(family === 'firefox' ? '-headless' : '--headless');
  noteForced(label);
  return kept;
}

function copyStatics(from, to) {
  for (const key of Object.getOwnPropertyNames(from)) {
    if (key === 'length' || key === 'name' || key === 'prototype' || key === 'caller' || key === 'arguments') continue;
    try {
      Object.defineProperty(to, key, Object.getOwnPropertyDescriptor(from, key));
    } catch (err) {
      /* a non-copyable static is not worth failing over */
    }
  }
  // execFile carries its promisified form on a symbol, and dropping it would
  // silently change how every caller awaits it.
  for (const sym of Object.getOwnPropertySymbols(from)) {
    try {
      Object.defineProperty(to, sym, Object.getOwnPropertyDescriptor(from, sym));
    } catch (err) {
      /* same */
    }
  }
}

function installSpawnGuard() {
  const childProcess = require('child_process');
  for (const name of ['spawn', 'spawnSync', 'execFile', 'execFileSync']) {
    const original = childProcess[name];
    if (typeof original !== 'function') continue;
    const wrapper = function (command) {
      const argv = Array.prototype.slice.call(arguments);
      try {
        let args = argv[1];
        let options = argv[2];
        let insert = false;
        // spawn(cmd), spawn(cmd, options) and execFile(file, callback) omit the
        // argument list, so a bare browser launch still gets one to rewrite.
        if (!Array.isArray(args)) {
          if (args === undefined || args === null) {
            args = [];
          } else {
            if (typeof args === 'object') options = args;
            args = [];
            insert = true;
          }
        }
        const rewritten = guardedArgv(command, args, options);
        if (rewritten) {
          if (insert) argv.splice(1, 0, rewritten);
          else if (argv.length < 2) argv.push(rewritten);
          else argv[1] = rewritten;
        }
      } catch (err) {
        /* spawn exactly what the caller asked for */
      }
      return original.apply(this, argv);
    };
    copyStatics(original, wrapper);
    try {
      Object.defineProperty(childProcess, name, { value: wrapper, writable: true, configurable: true, enumerable: true });
    } catch (err) {
      /* leave the original in place */
    }
  }
}

// --- install ---------------------------------------------------------------

try {
  installLauncherPatch();
} catch (err) {
  /* layer 2 and the PATH shims still stand */
}
try {
  installSpawnGuard();
} catch (err) {
  /* layer 1 and the PATH shims still stand */
}
