#!/usr/bin/env node
// Install the credential read guard (bin/fm-credguard-read.mjs) as a pre-tool
// hook in every worker harness on this machine that has a hook surface,
// idempotently, keeping every other hook and setting. docs/credguard.md owns
// the contract and the per-harness evidence.
//
// Ported from korallis/agent-stack system/credguard-read-install
// (https://github.com/korallis/agent-stack, Apache License 2.0, Copyright 2026
// The agent-stack authors; see NOTICE). Changes from the original: ES module;
// devin, kimi, grok, pi and omp targets beside claude and codex; a report line
// for every harness without covered wiring; the Playwright MCP matcher is left out.
//
// Usage: fm-credguard-install.mjs [--check] [--hook <path>] [--harness <name,...>]
//   --check    change nothing; exit 1 when any covered harness lacks the guard
//   --hook     the guard to wire (default: this checkout's bin/fm-credguard-read.mjs,
//              refused when this checkout is a linked git worktree, because a
//              task worktree is deleted at cleanup and the hook would vanish)
//   --harness  limit the run to these harnesses (default: every one listed below)
//
// Targets, resolved from the environment this command runs in:
//   claude  ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json: one PreToolUse group (Bash|Read|Grep)
//   codex   ${CODEX_HOME:-~/.codex}/config.toml: a managed block with one PreToolUse group (Bash) and its
//           trust recorded as Codex's own trusted_hash, so this exact command runs without a review prompt
//   devin   ~/.config/devin/config.json: one PreToolUse group (exec|read|grep); worker configs
//           are snapshots of this file (bin/fm-devin-config.sh), so workers inherit it
//   kimi    ${KIMI_CODE_HOME:-~/.kimi-code}/config.toml: a managed [[hooks]] PreToolUse block
//   grok    ${GROK_HOME:-~/.grok}/hooks/fm-credguard-read.json (global hooks are always trusted)
//   pi      ${PI_CODING_AGENT_DIR:-~/.pi/agent}/extensions/fm-credguard-read.ts
//   omp     ~/.omp/agent/extensions/fm-credguard-read.ts
// A harness whose executable is not on PATH is reported and left alone.
// A worker account pin uses another Claude or Pi config root: run this again
// with CLAUDE_CONFIG_DIR or PI_CODING_AGENT_DIR set to that root.
//
// Every file this changes is backed up first as <file>.bak-credguard-<time>.
// Output: one line per harness. "ok" = guard in place, "--" = missing or failed
// (counted in the exit code), "uncovered" = no hook surface a worker launch runs,
// "absent" = not installed on this machine. Exit 0 when every covered harness is ok.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const MARK = "fm-credguard-read.mjs";
const TIMEOUT = 10;
const TOML_BEGIN = "# BEGIN FIRSTMATE CREDENTIAL READ GUARD (managed by bin/fm-credguard-install.mjs; do not edit)";
const TOML_END = "# END FIRSTMATE CREDENTIAL READ GUARD";
const EXT_NAME = "fm-credguard-read.ts";
const GROK_NAME = "fm-credguard-read.json";

const q = (s) => `'${String(s).replace(/'/g, "'\\''")}'`;   // POSIX single-quote
const hookCommand = (hook, runtime) => `${q(hook)} --runtime ${runtime}`;

// ---- JSON settings with Claude-shaped PreToolUse groups (claude, devin) ----------------------------------------------
// Pure: settings with exactly one guard group. Only guard handlers are removed from existing groups (a group left with
// other handlers keeps them; one left empty goes); every other hook stays as it was.
function withPreToolGroup(settings, matcher, command) {
  const s = { ...settings, hooks: { ...(settings.hooks || {}) } };
  const list = (s.hooks.PreToolUse || []).map((g) => {
    const kept = (g.hooks || []).filter((h) => !String(h.command || "").includes(MARK));
    return kept.length === (g.hooks || []).length ? g : kept.length ? { ...g, hooks: kept } : null;
  }).filter(Boolean);
  s.hooks.PreToolUse = [...list, { matcher, hooks: [{ type: "command", command, timeout: TIMEOUT }] }];
  return s;
}
const hasPreToolGroup = (settings, matcher, command) => (settings.hooks?.PreToolUse || [])
  .some((g) => g.matcher === matcher && (g.hooks || []).some((h) => h.command === command));

// ---- Codex config.toml: trusted hook groups --------------------------------------------------------------------------
// Codex's trust hash for one command hook (codex-rs hooks discovery `command_hook_hash`): sha256 over the compact JSON
// of { event_name, matcher, hooks: [{ type, command, timeout, async }] } with every object's keys sorted.
function canon(v) {
  if (Array.isArray(v)) return v.map(canon);
  if (v && typeof v === "object") return Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])]));
  return v;
}
function codexHookHash({ event, matcher, command, timeout }) {
  const id = { event_name: event, hooks: [{ type: "command", command, timeout, async: false }] };
  if (matcher != null) id.matcher = matcher;
  return "sha256:" + crypto.createHash("sha256").update(JSON.stringify(canon(id)), "utf8").digest("hex");
}
// TOML is parsed by Python's tomllib (3.11+), so comments, spacing and quoting count as a real parser sees them.
// macOS's own /usr/bin/python3 predates tomllib, so a newer python3.X on PATH is used when python3 lacks it.
const TOML_PY = "import sys,json,tomllib;print(json.dumps(tomllib.loads(sys.stdin.read())))";
let tomlPython = null;
function findTomlPython() {
  if (tomlPython) return tomlPython;
  for (const py of ["python3", "python3.14", "python3.13", "python3.12", "python3.11"]) {
    const r = spawnSync(py, ["-c", "import tomllib"], { encoding: "utf8" });
    if (!r.error && r.status === 0) return (tomlPython = py);
  }
  throw new Error("reading TOML needs Python 3.11 or newer (tomllib) on PATH");
}
function parseToml(text) {
  const r = spawnSync(findTomlPython(), ["-c", TOML_PY], { input: text, encoding: "utf8" });
  if (r.status !== 0) throw new Error(`not valid TOML: ${(r.stderr || "").trim().split("\n").at(-1)}`);
  return JSON.parse(r.stdout);
}
function stripBlock(text) {
  const a = text.indexOf(TOML_BEGIN), b = text.indexOf(TOML_END);
  if (a < 0 || b < a) return text;
  return text.slice(0, a).replace(/\n+$/, "\n") + text.slice(b + TOML_END.length).replace(/^\n+/, "");
}
// Pure (given parse): config.toml text with the managed block (re)written at the end. Codex keys hook trust by
// position, <keySource>:pre_tool_use:<group>:<handler>, so the group index is the number of PreToolUse groups the rest
// of the file really has, and the result is parsed again to prove the guard sits there with its trust recorded.
function withCodexBlock(text, hook, keySource, parse = parseToml) {
  const base = stripBlock(text).replace(/\s*$/, "\n");
  const pre = parse(base).hooks?.PreToolUse;
  if (pre != null && !Array.isArray(pre)) throw new Error("hooks.PreToolUse is not an array of groups");
  const at = (pre || []).length, command = hookCommand(hook, "codex"), matcher = "Bash";
  const key = `${keySource}:pre_tool_use:${at}:0`, hash = codexHookHash({ event: "pre_tool_use", matcher, command, timeout: TIMEOUT });
  const lines = [TOML_BEGIN, "[[hooks.PreToolUse]]", `matcher = ${JSON.stringify(matcher)}`, "",
    "[[hooks.PreToolUse.hooks]]", 'type = "command"', `command = ${JSON.stringify(command)}`, `timeout = ${TIMEOUT}`, "",
    `[hooks.state.${JSON.stringify(key)}]`, `trusted_hash = ${JSON.stringify(hash)}`, TOML_END, ""];
  const next = base + "\n" + lines.join("\n"), parsed = parse(next);
  const found = (parsed.hooks?.PreToolUse || []).findIndex((x) => x.matcher === matcher && (x.hooks || []).some((h) => h.command === command));
  if (found !== at || parsed.hooks?.state?.[key]?.trusted_hash !== hash)
    throw new Error(`the guard would not sit at PreToolUse group ${at} with its trust recorded (found at ${found}); edit the file by hand`);
  return next;
}

// ---- Kimi config.toml: one managed [[hooks]] entry -------------------------------------------------------------------
function withKimiBlock(text, hook, parse = parseToml) {
  const base = stripBlock(text).replace(/\s*$/, "\n");
  const command = hookCommand(hook, "kimi");
  const next = base + "\n" + [TOML_BEGIN, "[[hooks]]", 'event = "PreToolUse"', `matcher = ${JSON.stringify("^(Bash|Read|Grep)$")}`,
    `command = ${JSON.stringify(command)}`, `timeout = ${TIMEOUT}`, TOML_END, ""].join("\n");
  const parsed = parse(next);
  if (!(parsed.hooks || []).some((h) => h.event === "PreToolUse" && h.command === command))
    throw new Error("the guard entry did not parse back as a PreToolUse hook; edit the file by hand");
  return next;
}

// ---- Generated whole files (grok hook, pi/omp extensions) ------------------------------------------------------------
function grokHookFile(hook) {
  return JSON.stringify({ hooks: { PreToolUse: [{ matcher: "", hooks: [{ type: "command", command: hookCommand(hook, "grok"), timeout: TIMEOUT }] }] } }, null, 2) + "\n";
}
function extensionFile(hook, runtime) {
  return `// Firstmate credential read guard for ${runtime}: generated by bin/fm-credguard-install.mjs; do not edit.
// Every tool call is handed to ${MARK}; exit 2 blocks it with the guard's reason. docs/credguard.md owns the contract.
import { spawn } from "node:child_process";

const HOOK = ${JSON.stringify(hook)};

function check(payload: string): Promise<{ code: number; stderr: string }> {
  return new Promise((done) => {
    let child;
    try {
      child = spawn(HOOK, ["--runtime", ${JSON.stringify(runtime)}], { stdio: ["pipe", "ignore", "pipe"] });
    } catch {
      done({ code: 0, stderr: "" });
      return;
    }
    let stderr = "";
    const timer = setTimeout(() => child.kill(), ${TIMEOUT * 1000});
    child.stderr?.on("data", (chunk) => { stderr += chunk.toString(); });
    child.on("error", () => { clearTimeout(timer); done({ code: 0, stderr: "" }); });
    child.on("close", (code) => { clearTimeout(timer); done({ code: code ?? 0, stderr }); });
    child.stdin?.on("error", () => {});
    child.stdin?.end(payload);
  });
}

export default function (pi: any) {
  pi.on?.("tool_call", async (event: any, ctx: any) => {
    if (!event) return {};
    const payload = JSON.stringify({ tool_name: event.toolName, tool_input: event.input ?? {}, cwd: ctx?.cwd ?? process.cwd() });
    const result = await check(payload);
    if (result.code !== 2) return {};
    return { block: true, reason: result.stderr.trim() || "blocked by the firstmate credential guard" };
  });
}
`;
}

// ---- file plumbing ---------------------------------------------------------------------------------------------------
const stamp = () => new Date().toISOString().replace(/[:.]/g, "");
function backup(file) {
  if (fs.existsSync(file)) fs.copyFileSync(file, `${file}.bak-credguard-${stamp()}`);
}
// A symlinked config (a dotfiles-managed file) is written through to its target, so the link stays a link.
function writeFile(file, text) {
  const target = fs.existsSync(file) && fs.lstatSync(file).isSymbolicLink() ? fs.realpathSync(file) : file;
  fs.mkdirSync(path.dirname(target), { recursive: true });
  backup(target);
  let mode = 0o644;
  try { mode = fs.statSync(target).mode & 0o777; } catch { /* new file */ }
  const tmp = `${target}.credguard-${process.pid}`;
  fs.writeFileSync(tmp, text, { mode });
  fs.chmodSync(tmp, mode);
  fs.renameSync(tmp, target);
}
const read = (file) => (fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null);
function onPath(name, env) {
  for (const dir of String(env.PATH || "").split(path.delimiter)) {
    if (!dir) continue;
    try { fs.accessSync(path.join(dir, name), fs.constants.X_OK); return true; } catch { /* next */ }
  }
  return false;
}

// ---- per-harness steps: each returns [status, message] ---------------------------------------------------------------
function jsonSettings(file, matcher, command, check, label) {
  const text = read(file);
  let settings = {};
  if (text !== null) {
    try { settings = JSON.parse(text); } catch (e) { return ["--", `${label}: ${file} is not valid JSON (${e.message}); left unchanged`]; }
    if (!settings || typeof settings !== "object" || Array.isArray(settings)) return ["--", `${label}: ${file} is not a JSON object; left unchanged`];
  }
  if (hasPreToolGroup(settings, matcher, command)) return ["ok", `${label}: guard in ${file} (PreToolUse ${matcher})`];
  if (check) return ["--", `${label}: guard missing from ${file}`];
  writeFile(file, JSON.stringify(withPreToolGroup(settings, matcher, command), null, 2) + "\n");
  return ["ok", `${label}: guard added to ${file} (PreToolUse ${matcher})`];
}

function tomlBlock(file, build, check, label, { create = false } = {}) {
  let text = read(file);
  if (text === null) {
    if (!create) return ["--", `${label}: ${file} not found; run the harness once so it writes its config, then run this again`];
    text = "";
  }
  let next;
  try { next = build(text); } catch (e) { return ["--", `${label}: ${file}: ${e.message}; left unchanged`]; }
  if (next === text) return ["ok", `${label}: guard in ${file}`];
  if (check) return ["--", `${label}: guard missing or outdated in ${file}`];
  writeFile(file, next);
  return ["ok", `${label}: guard written to ${file}`];
}

function wholeFile(file, text, check, label) {
  if (read(file) === text) return ["ok", `${label}: guard in ${file}`];
  if (check) return ["--", `${label}: guard missing or outdated in ${file}`];
  writeFile(file, text);
  return ["ok", `${label}: guard written to ${file}`];
}

// Harnesses with no hook surface a Firstmate worker launch runs, and why. Listed on every run so none is skipped silently.
const UNCOVERED = [
  ["codex crewmate and scout launches", "bin/fm-spawn.sh starts them with --disable hooks (Codex's hook-trust modal cannot be answered from Firstmate's key plane), so no hook runs there; Codex secondmates and interactive Codex sessions are covered"],
  ["muse", "no hook or plugin surface"],
  ["agy", "no hook or plugin surface"],
  ["rovo", "its event hooks cannot refuse a tool call"],
  ["opencode", "has a plugin surface, but no live-verified credential guard wiring yet"],
  ["cursor", "has a hooks.json surface, but no live-verified credential guard wiring yet"],
  ["gemini", "has a BeforeTool hook surface, but no live-verified credential guard wiring yet"],
];

function main(argv, env = process.env) {
  const flag = (n) => (argv.includes(n) ? argv[argv.indexOf(n) + 1] : undefined);
  if (argv.includes("-h") || argv.includes("--help")) {
    const src = fs.readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n");
    process.stdout.write(src.slice(1, src.findIndex((l) => l.startsWith("import "))).map((l) => l.replace(/^\/\/ ?/, "")).join("\n") + "\n");
    return 0;
  }
  const check = argv.includes("--check");
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  let hook = flag("--hook");
  if (hook) hook = path.resolve(hook);
  else {
    const git = (a) => spawnSync("git", ["-C", root, "rev-parse", "--path-format=absolute", a], { encoding: "utf8" }).stdout?.trim();
    const gd = git("--git-dir"), cd = git("--git-common-dir");
    if (gd && cd && gd !== cd) {
      process.stderr.write(`error: ${root} is a linked git worktree that is deleted at cleanup; run this from the primary checkout or pass --hook <path>\n`);
      return 2;
    }
    hook = path.join(root, "bin", MARK);
  }
  const home = env.HOME || os.homedir();
  const only = flag("--harness") ? new Set(flag("--harness").split(",").map((s) => s.trim()).filter(Boolean)) : null;
  const want = (h) => !only || only.has(h);
  let missing = 0;
  const say = (status, msg) => { process.stdout.write(`${status} ${msg}\n`); if (status === "--") missing++; };

  if (!fs.existsSync(hook)) say("--", `guard hook not found at ${hook}`);
  else say("ok", `guard hook at ${hook}`);

  const steps = [
    ["claude", "claude", () => jsonSettings(path.join(env.CLAUDE_CONFIG_DIR || path.join(home, ".claude"), "settings.json"), "Bash|Read|Grep", hookCommand(hook, "claude"), check, "claude")],
    ["codex", "codex", () => {
      const file = path.join(env.CODEX_HOME || path.join(home, ".codex"), "config.toml");
      const r = tomlBlock(file, (t) => withCodexBlock(t, hook, fs.existsSync(file) ? fs.realpathSync(file) : file), check, "codex", { create: true });
      try { if (parseToml(read(file) || "").features?.hooks === false) return ["--", `codex: [features] hooks = false in ${file}; no hook runs until it is removed`]; } catch { /* reported by r */ }
      return r;
    }],
    ["devin", "devin", () => jsonSettings(path.join(home, ".config", "devin", "config.json"), "exec|read|grep", hookCommand(hook, "devin"), check, "devin")],
    ["kimi", "kimi", () => tomlBlock(path.join(env.KIMI_CODE_HOME || path.join(home, ".kimi-code"), "config.toml"), (t) => withKimiBlock(t, hook), check, "kimi", { create: true })],
    ["grok", "grok", () => wholeFile(path.join(env.GROK_HOME || path.join(home, ".grok"), "hooks", GROK_NAME), grokHookFile(hook), check, "grok")],
    ["pi", "pi", () => wholeFile(path.join(env.PI_CODING_AGENT_DIR || path.join(home, ".pi", "agent"), "extensions", EXT_NAME), extensionFile(hook, "pi"), check, "pi")],
    ["omp", "omp", () => wholeFile(path.join(home, ".omp", "agent", "extensions", EXT_NAME), extensionFile(hook, "omp"), check, "omp")],
  ];
  for (const [name, bin, step] of steps) {
    if (!want(name)) continue;
    if (!onPath(bin, env)) { say("absent", `${name}: not installed on this machine; nothing written`); continue; }
    let r;
    try { r = step(); } catch (e) { r = ["--", `${name}: ${e.message}`]; }
    say(...r);
  }
  for (const [name, why] of UNCOVERED) if (!only || only.has(name.split(" ")[0])) say("uncovered", `${name}: ${why}`);
  return missing ? 1 : 0;
}

export { withPreToolGroup, hasPreToolGroup, codexHookHash, withCodexBlock, withKimiBlock, stripBlock, grokHookFile, extensionFile, TOML_BEGIN, TOML_END };

let self = false;
try { self = fs.realpathSync(process.argv[1] || "") === fs.realpathSync(fileURLToPath(import.meta.url)); } catch { /* imported */ }
if (self) process.exitCode = main(process.argv.slice(2));
