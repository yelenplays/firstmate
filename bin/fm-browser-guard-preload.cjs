'use strict';
// fm-browser-guard-preload.cjs - the Node half of the agent browser guard.
//
// Loaded through NODE_OPTIONS by bin/fm-browser-guard-env.sh before worker
// code, including the harness itself. Installation and hook failures must not
// break unrelated Node work, and diagnostics must never write to stdout.
// docs/browser-guard.md owns the enforcement layers, coverage boundaries,
// opt-out, and notice policy; tests/fm-browser-guard.test.sh pins the behavior.

const OPT_OUT_VAR = 'FM_ALLOW_HEADED_BROWSER';
const PREFIX = 'fm-browser-guard: ';
const PATCH_GLOBAL = '__fmBrowserGuardPatch';

let forcedNoted = false;
let allowedNoted = false;

// Read on every decision so changes to this process's own environment apply;
// an export in another process cannot update this already-running process.
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
const CHROMIUM_BINARY = /^(?:google chrome(?: (?:beta|dev|canary|for testing))?|chrome|chromium|chromium-browser|google-chrome|chrome-headless-shell|headless_shell|brave|brave-browser|brave browser|msedge|microsoft edge|vivaldi|opera|thorium)$/;
const FIREFOX_BINARY = /^(?:firefox|firefox-bin|firefox-esr|firefoxdeveloperedition|firefox-nightly|mozilla firefox)$/;
const WEBKIT_BINARY = /^(?:pw_run\.sh|minibrowser)$/;
const WEBKIT_APP_PATH = /[\\/]playwright\.app[\\/]contents[\\/]macos[\\/]playwright$/;
const FIREFOX_APP_PATH = /[\\/]nightly\.app[\\/]contents[\\/]macos[\\/]nightly$/;

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
  const path = String(command).toLowerCase();
  if (WEBKIT_APP_PATH.test(path)) return 'webkit';
  if (FIREFOX_APP_PATH.test(path)) return 'firefox';
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
}

// MCP transports and other launchers build allowlisted environments instead
// of inheriting process.env. Reattach only the guard, not the parent's other
// variables, so a Node or Bun server behind that boundary cannot launch headed
// Chrome. The child loads the same stable loader the launch environment names,
// in the same NODE_OPTIONS and BUN_OPTIONS forms bin/fm-browser-guard-env.sh
// writes, so a child of a guarded pane carries the loader once, not twice.
function prependOption(value, option) {
  const current = value || '';
  return current.includes(option) ? current : option + (current ? ' ' + current : '');
}

function guardedOptions(options) {
  if (!options || typeof options !== 'object' || !options.env || headedAllowed()) return options;
  const path = require('path');
  const env = { ...options.env };
  const loader = path.join(__dirname, 'fm-browser-guard-load.cjs');
  env.NODE_OPTIONS = prependOption(env.NODE_OPTIONS, '--require "' + loader + '"');
  // Bun splits BUN_OPTIONS on whitespace and keeps quotes, so a loader path
  // outside this character set cannot be named there; the env snippet skips
  // Bun on the same rule.
  if (!/[^A-Za-z0-9._/+@,:=-]/.test(loader)) env.BUN_OPTIONS = prependOption(env.BUN_OPTIONS, '--preload=' + loader);
  env.FM_BROWSER_GUARD = '1';
  env.BROWSER = path.join(__dirname, 'fm-browser-guard-browser.sh');
  env.LAVISH_AXI_NO_OPEN = '1';
  const shims = path.join(__dirname, 'fm-browser-guard-bin');
  const childPath = env.PATH === undefined ? '/usr/bin:/bin' : env.PATH;
  env.PATH = childPath.split(path.delimiter)[0] === shims ? childPath : shims + path.delimiter + childPath;
  return { ...options, env };
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
        let optionsIndex = 2;
        let insert = false;
        // spawn(cmd), spawn(cmd, options) and execFile(file, callback) omit the
        // argument list, so a bare browser launch still gets one to rewrite.
        if (!Array.isArray(args)) {
          if (args === undefined || args === null) {
            args = [];
          } else {
            if (typeof args === 'object') {
              options = args;
              optionsIndex = 1;
            }
            args = [];
            insert = true;
          }
        }
        const guarded = guardedOptions(options);
        if (guarded !== options) argv[optionsIndex] = guarded;
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
    if (name === 'execFile') {
      // Node's original promisify hook calls its internal execFile, bypassing
      // this wrapper. Build the promise through the guarded callback path.
      const util = require('util');
      Object.defineProperty(wrapper, util.promisify.custom, {
        configurable: true,
        value: function () {
          const callArgs = Array.prototype.slice.call(arguments);
          let child;
          const promise = new Promise((resolve, reject) => {
            child = wrapper.apply(this, callArgs.concat((err, stdout, stderr) => {
              if (err) {
                err.stdout = stdout;
                err.stderr = stderr;
                reject(err);
              } else {
                resolve({ stdout, stderr });
              }
            }));
          });
          promise.child = child;
          return promise;
        },
      });
    }
    try {
      Object.defineProperty(childProcess, name, { value: wrapper, writable: true, configurable: true, enumerable: true });
    } catch (err) {
      /* leave the original in place */
    }
  }
}

// fork and execSync start their child through Node's module-internal spawn and
// spawnSync, which never reach the wrappers above, so an explicit env passed to
// either would drop the guard. They get only the guardedOptions step: a fork
// runs Node and execSync runs a shell, so neither argv is a browser's. exec is
// absent because it already calls the exported, wrapped execFile.
function installOptionsGuard() {
  const childProcess = require('child_process');
  for (const name of ['fork', 'execSync']) {
    const original = childProcess[name];
    if (typeof original !== 'function') continue;
    const wrapper = function () {
      const argv = Array.prototype.slice.call(arguments);
      try {
        // fork(module, args, options) and fork(module, options);
        // execSync(command, options).
        const optionsIndex = name === 'fork' && Array.isArray(argv[1]) ? 2 : 1;
        if (argv[optionsIndex] !== null && typeof argv[optionsIndex] === 'object' && !Array.isArray(argv[optionsIndex])) {
          argv[optionsIndex] = guardedOptions(argv[optionsIndex]);
        }
      } catch (err) {
        /* start exactly what the caller asked for */
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

// Bun's own Bun.spawn and Bun.spawnSync start processes without going through
// child_process, so under Bun they get the same argv and env steps. Both take
// either (cmd, options) or a single options object carrying `cmd`.
function installBunSpawnGuard() {
  const bun = globalThis.Bun;
  if (!bun || typeof bun !== 'object') return;
  for (const name of ['spawn', 'spawnSync']) {
    const original = bun[name];
    if (typeof original !== 'function') continue;
    const wrapper = function () {
      const argv = Array.prototype.slice.call(arguments);
      try {
        const single = !Array.isArray(argv[0]) && argv[0] !== null && typeof argv[0] === 'object';
        const options = single ? argv[0] : argv[1];
        const cmd = single ? options.cmd : argv[0];
        let guarded = guardedOptions(options);
        let command = cmd;
        if (Array.isArray(cmd) && cmd.length > 0) {
          const rewritten = guardedArgv(cmd[0], cmd.slice(1), null);
          if (rewritten) command = [cmd[0]].concat(rewritten);
        }
        if (single) {
          if (command !== cmd) guarded = { ...guarded, cmd: command };
          argv[0] = guarded;
        } else {
          argv[0] = command;
          if (guarded !== options) argv[1] = guarded;
        }
      } catch (err) {
        /* spawn exactly what the caller asked for */
      }
      return original.apply(this, argv);
    };
    copyStatics(original, wrapper);
    try {
      bun[name] = wrapper;
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
try {
  installOptionsGuard();
} catch (err) {
  /* the inherited environment still carries the guard */
}
try {
  installBunSpawnGuard();
} catch (err) {
  /* child_process and the PATH shims still stand */
}
