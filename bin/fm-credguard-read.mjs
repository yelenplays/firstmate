#!/usr/bin/env node
// Credential read guard: a PreToolUse decision that refuses a worker tool call
// which would PRINT a credential file (or a process environment) into the
// transcript, where it stays and gets copied, summarised and synced. Using the
// values without printing them stays allowed: `set -a; . .env; set +a; npm run
// migrate`, `--env-file .env`, dotenv loaders in scripts, `grep -q KEY .env`.
// docs/credguard.md is the human-readable contract; this file is the single
// decision owner and the hook entry point for every wired harness.
//
// Ported from korallis/agent-stack system/credguard-read-hook
// (https://github.com/korallis/agent-stack, Apache License 2.0, Copyright 2026
// The agent-stack authors; see NOTICE). Changes from the original: ES module;
// one normalized input for every harness payload shape (--runtime); the
// Playwright MCP, Vercel protection-bypass, published-history and
// /proc-based --env-names parts are left out; firstmate's default and local
// path lists; case-insensitive matching on macOS; firstmate deny wording.
//
// Usage:
//   fm-credguard-read.mjs --runtime <claude|codex|devin|kimi|grok|pi|omp|opencode|cursor|gemini>
//       Read one hook payload (JSON) on stdin and allow or deny it.
//   fm-credguard-read.mjs --keys <file>...
//       Key-names-only mode: print NAME for each NAME=value line of a
//       dotenv-style file and nothing else (no value, no PEM body).
//
// Deny output by runtime:
//   claude            stdout {"hookSpecificOutput":{...,"permissionDecision":"deny",...}}, exit 0
//   grok              stdout {"decision":"deny","reason":...} and the reason on stderr, exit 2
//   codex devin kimi  the reason on stderr, exit 2
//   pi omp            the reason on stderr, exit 2 (the extension returns {block: true, reason})
// Allow is exit 0 with no output.
//
// Protected paths: DEFAULT_PATTERNS plus one glob per line in the local,
// never-committed path list at ${XDG_CONFIG_HOME:-~/.config}/firstmate/credguard-read-paths
// (FM_CREDGUARD_READ_PATHS names another file). Blank lines and # comments are ignored.
//
// Best effort against ACCIDENTAL printing by a worker, not a sandbox: a script
// that reads and prints a file itself is not parsed. The guard never denies on
// its own errors (a broken hook must not stop every tool call);
// bin/fm-credguard-install.mjs --check reports whether it is installed.

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

// macOS volumes are case-insensitive by default, so `.ENV` opens `.env`.
const CASE_FOLD = process.platform === "darwin";

const DEFAULT_PATTERNS = [
  "**/.env", "**/.env.*", "**/*.env", "**/*runtime-url*", "**/*.pem", "**/prod.env",
  "~/.ssh/id_*", "~/.aws/credentials", "~/.netrc", "~/.codex/auth.json", "~/.config/gh/hosts.yml",
];
// Templates and public keys hold no secret values.
const EXEMPT = /(^|\/)\.env\.(example|sample|template)$|\.pub$/i;
const exempt = (abs) => EXEMPT.test(abs);

function patternsFile(env = process.env, home = os.homedir()) {
  if (env.FM_CREDGUARD_READ_PATHS) return env.FM_CREDGUARD_READ_PATHS;
  return path.join(env.XDG_CONFIG_HOME || path.join(home, ".config"), "firstmate", "credguard-read-paths");
}

function patterns(env = process.env, home = os.homedir()) {
  let extra = [];
  try {
    extra = fs.readFileSync(patternsFile(env, home), "utf8").split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
  } catch { /* no local list */ }
  return [...DEFAULT_PATTERNS, ...extra];
}

// A glob (**, *, ?, bracket classes; a leading ~/ is the home directory) as a regex over absolute paths.
// POSIX character classes inside a bracket expression, as regex class bodies (C locale).
const POSIX = { alpha: "A-Za-z", digit: "0-9", alnum: "A-Za-z0-9", upper: "A-Z", lower: "a-z", space: " \\t\\n\\r\\f\\v",
  blank: " \\t", punct: "!-\\/:-@\\[-`{-~", xdigit: "0-9A-Fa-f", word: "A-Za-z0-9_", print: " -~", graph: "!-~", cntrl: "\\x00-\\x1f\\x7f" };
// The bracket expression starting at g[i] ("["): its regex body, negation and closing index; null if it never closes.
function bracket(g, i) {
  let j = i + 1, neg = false, body = "";
  if (g[j] === "!" || g[j] === "^") { neg = true; j++; }
  if (g[j] === "]") { body += "\\]"; j++; }   // a leading ] is literal
  for (; j < g.length; j++) {
    if (g[j] === "]") return { body, neg, end: j };
    const cls = g[j] === "[" && g[j + 1] === ":" ? /^\[:([a-z]+):\]/.exec(g.slice(j)) : null;
    if (cls) { body += POSIX[cls[1]] ?? "\\s\\S"; j += cls[0].length - 1; continue; }   // an unknown class: assume anything
    body += /[\\\]^[]/.test(g[j]) ? "\\" + g[j] : g[j];
  }
  return null;
}

const reCache = new Map();
function globRe(glob, home) {
  const key = `${home}\0${glob}`;
  if (reCache.has(key)) return reCache.get(key);
  let g = glob.startsWith("~/") ? home + glob.slice(1) : glob, re = "";
  for (let i = 0; i < g.length; i++) {
    const c = g[i];
    if (c === "*" && g[i + 1] === "*") {
      if (g[i + 2] === "/") { re += "(?:.*/)?"; i += 2; } else { re += ".*"; i += 1; }
    } else if (c === "*") re += "[^/]*";
    else if (c === "?") re += "[^/]";
    else if (c === "[" && bracket(g, i)) {   // a bash bracket class: [abc], [!a-z], []x], [[:alpha:]]
      const b = bracket(g, i);
      re += b.neg ? `[^/${b.body}]` : `[${b.body}]`; i = b.end;
    } else re += c.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  }
  const out = new RegExp(`^${g.startsWith("/") ? "" : "(?:.*/)?"}${re}$`, CASE_FOLD ? "i" : "");
  reCache.set(key, out);
  return out;
}

// Basenames a wildcard word could expand to that are protected (cat .env*, cat *.pem): tested without the filesystem.
const SAMPLES = [".env", ".env.local", ".env.production", "app.env", "key.pem", "db-runtime-url", "prod.env"];

// Simple brace expansion ({a,b}; nested pairs one at a time), at most 64 words: `.{e,x}nv` names `.env` too.
function braces(word, out = [], depth = 0) {
  const m = depth < 8 && word.match(/^(.*?)\{([^{}]*,[^{}]*)\}(.*)$/s);
  if (!m) { out.push(word); return out; }
  for (const alt of m[2].split(",")) { if (out.length >= 64) break; braces(m[1] + alt + m[3], out, depth + 1); }
  return out;
}
// Every spelling a word can take: $HOME, and the variables this command set (each can hold several values: a for
// loop), then braces. At most 64. A variable the command didn't set stays as written ($X).
function expand(word, ctx) {
  let words = [String(word)];
  for (let guard = 0; guard < 8; guard++) {
    const next = [];
    let changed = false;
    for (const w of words) {
      // $NAME, ${NAME}, ${NAME[i]} / ${NAME[@]} (any element: every value it may hold). Other ${…} forms stay unresolved.
      const m = w.match(/\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]]*\])?\})/);
      if (m) m[1] = m[1] ?? m[2];
      const vals = m && (m[1] === "HOME" ? [ctx.home] : ctx.vars?.get(m[1]));
      if (!vals) { next.push(w); continue; }
      changed = true;
      for (const v of vals) { if (next.length >= 64) break; next.push(w.slice(0, m.index) + v + w.slice(m.index + m[0].length)); }
    }
    words = next;
    if (!changed) break;
  }
  return words.flatMap((w) => braces(w)).slice(0, 64);
}
// A `bash -c` string as the parent passes it: only the $NAME / ${NAME} the parent expands (mask "0") take the
// parent's values; single-quoted or escaped ones stay for the child. At most 64 spellings.
function parentExpand(text, mask, ctx) {
  const re = /\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]]*\])?\})/g;
  let m;
  while ((m = re.exec(text))) {
    if (mask[m.index] === "1") continue;
    const name = m[1] ?? m[2], vals = name === "HOME" ? [ctx.home] : ctx.vars?.get(name);
    if (!vals) continue;   // unknown to the parent: left for the child (conservative)
    const out = [];
    for (const v of vals) for (const rest of parentExpand(text.slice(m.index + m[0].length), mask.slice(m.index + m[0].length), ctx)) {
      if (out.length >= 64) break;
      out.push(text.slice(0, m.index) + v + rest);
    }
    return out;
  }
  return [text];
}
const unresolved = (w) => /\$[{A-Za-z_(]|`|\$\(…\)|<\(…\)/.test(w);   // a variable nobody set here, or a substitution

// Is this absolute path protected: by pattern, by being (under) a copy or link this command made of one, or by
// pointing (through an existing symlink) at one?
function taintedBy(abs, ctx) {
  for (const t of ctx.tainted || []) if (abs === t || abs.startsWith(t + "/")) return t;
  return null;
}
function checkAbs(abs, ctx) {
  if (taintedBy(abs, ctx)) return { path: abs, pattern: "a copy or link of a credential file made earlier in this command" };
  const byPattern = (x) => !exempt(x) && ctx.pats.find((p) => globRe(p, ctx.home).test(x));
  let p = byPattern(abs);
  if (p) return { path: abs, pattern: p };
  let real = null;
  try { real = fs.realpathSync.native(abs); } catch { /* doesn't exist (yet) */ }
  if (real && real !== abs && (p = byPattern(real))) return { path: abs, pattern: `${p}, through a link to ${real}` };
  return null;
}

// A glob word: expanded against the real directory when it can be read, with bash's rules (a name starting with "."
// matches only when the pattern starts with "." or dotglob is on), plus names this command tainted that may not exist
// yet; otherwise (unreadable directory, a glob in a directory part, or **) judged against sample names, conservatively.
function globHit(abs, ctx) {
  const dir = path.dirname(abs), base = path.basename(abs), starstar = abs.includes("**");
  const dotOK = ctx.dotglob || base.startsWith(".") || starstar, re = globRe(base, ctx.home);
  const okName = (n) => (dotOK || !n.startsWith(".")) && re.test(n);
  for (const t of ctx.tainted || []) {   // a copy made earlier in this command: in this directory, or this directory is inside one
    if ((path.dirname(t) === dir && okName(path.basename(t))) || dir === t || dir.startsWith(t + "/"))
      return { path: abs, pattern: "a copy or link of a credential file made earlier in this command" };
  }
  if (!/[*?[]/.test(dir) && !starstar) {
    let names = null;
    try { names = fs.readdirSync(dir); } catch { names = null; }
    if (names) {
      for (const n of names) if (okName(n)) { const h = checkAbs(path.join(dir, n), ctx); if (h) return { ...h, path: abs }; }
      return null;
    }
  }
  // A glob inside a protected tree (`secrets/*/x`): its fixed directory part decides, whatever the names.
  const fixed = abs.split("/"), cut = fixed.findIndex((seg) => /[*?[]/.test(seg));
  if (cut > 0) {
    const probe = fixed.slice(0, cut).join("/") + "/credguard-probe";
    const p = ctx.pats.find((x) => globRe(x, ctx.home).test(probe));
    if (p) return { path: abs, pattern: p };
  }
  for (const smp of SAMPLES) {
    if (!okName(smp)) continue;
    const cand = path.join(dir, smp);
    if (exempt(cand)) continue;
    const p = ctx.pats.find((x) => globRe(x, ctx.home).test(cand));
    if (p) return { path: abs, pattern: p };
  }
  return null;
}

// The protected path a word names, or null. Handles ~ and $HOME, this command's variables, braces, relative paths
// (against every directory this command may be in: cd, pushd, popd, subshells, env -C), `--opt=path`, `if=path`,
// `REV:path` (git show), wildcards and symlinks.
function protectedPath(word, ctx) {
  if (!word || word === "-") return null;
  const forms = new Set();
  for (const w of expand(word, ctx)) {
    forms.add(w);
    const eq = w.indexOf("="); if (eq > 0) forms.add(w.slice(eq + 1));
    const colon = w.indexOf(":"); if (colon > 0 && !w.includes("://")) forms.add(w.slice(colon + 1));
  }
  const cwds = ctx.cwds?.size ? [...ctx.cwds] : [ctx.cwd || "/"];
  for (let f of forms) {
    if (!f) continue;
    f = f.replace(/^~(?=\/|$)/, ctx.home);
    for (const abs of path.isAbsolute(f) ? [path.normalize(f)] : cwds.map((c) => path.join(c, f))) {
      const h = /[*?[]/.test(abs) ? globHit(abs, ctx) : checkAbs(abs, ctx);
      if (h) return h;
    }
  }
  return null;
}

// The $( … ) and ` … ` command substitutions in a text (a heredoc body), innermost handled by lex itself.
function substitutions(text) {
  const out = [];
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "\\") { i++; continue; }
    if (text[i] === "$" && text[i + 1] === "(") {
      let depth = 1, j = i + 2;
      for (; j < text.length && depth; j++) { if (text[j] === "(") depth++; else if (text[j] === ")") depth--; }
      out.push(text.slice(i + 2, j - 1)); i = j - 1;
    } else if (text[i] === "`") {
      const j = text.indexOf("`", i + 1); if (j < 0) break;
      out.push(text.slice(i + 1, j)); i = j;
    }
  }
  return out;
}

// ---- a small shell lexer: segments (simple commands) with their words and redirections -----------------------------
// This lexer is deliberately separate from bin/fm-arm-command-policy.mjs, which never expands anything: the read
// guard must track what the shell WOULD expand (variables this command set, the parent's half of a bash -c string,
// heredoc substitutions, ANSI-C quoting) to know which file a word names.
// Command substitutions ($(...), `...`, <(...)) become segments of their own. Heredoc bodies are data, not commands.
function lex(src) {
  // Each segment records its scope: `sub` (a subshell: parens, a pipeline element, background &, a substitution;
  // assignments there don't reach the parent) and `cond` (after && or ||: it may not run).
  let subDepth = 0;
  const newSeg = (o = {}) => ({ words: [], redirs: [], sub: subDepth > 0 || !!o.sub, cond: !!o.cond });
  // mask: one flag per character of the word, "1" where the parent shell takes it literally (single quotes, $'…',
  // a backslash escape), so a `bash -c "…"` string can be expanded the way the parent expands it.
  const segs = []; let seg = newSeg(), word = null, quotedAll = true, mask = "", i = 0;
  const heredocs = [];
  const endWord = () => { if (word !== null) { if (seg.pendingRedir) { seg.redirs.push({ op: seg.pendingRedir, target: word }); seg.pendingRedir = null; } else seg.words.push({ text: word, sq: quotedAll, mask }); } word = null; quotedAll = true; mask = ""; };
  const endSeg = (o) => { endWord(); if (seg.words.length || seg.redirs.length) segs.push(seg); seg = newSeg(o); };
  const add = (s, single = false, m = null) => { word = (word ?? "") + s; mask += m ?? (single ? "1" : "0").repeat(s.length); if (!single) quotedAll = false; };
  const sub = (open, close) => {   // returns the inner text of a balanced $( ... ) / <( ... )
    let depth = 1, j = i, q = null;
    for (; j < src.length; j++) {
      const c = src[j];
      if (q) { if (c === q) q = null; else if (c === "\\" && q === '"') j++; continue; }
      if (c === "'" || c === '"') q = c;
      else if (c === "\\") j++;
      else if (c === open) depth++;
      else if (c === close && --depth === 0) break;
    }
    const inner = src.slice(i, j); i = j + 1; return inner;
  };
  const substSegs = (text) => lex(text).map((x) => ({ ...x, subst: true, sub: true }));
  while (i < src.length) {
    const c = src[i];
    if (c === "\n") {
      endSeg(); i++;
      while (heredocs.length) {   // skip each pending heredoc body up to its delimiter line
        const { delim, strip, expands } = heredocs.shift(), body = [];
        while (i < src.length) {
          const nl = src.indexOf("\n", i), line = src.slice(i, nl < 0 ? src.length : nl);
          i = nl < 0 ? src.length : nl + 1;
          if ((strip ? line.replace(/^\t+/, "") : line) === delim) break;
          body.push(line);
        }
        // An unquoted delimiter (<<EOF) makes the shell run the body's command substitutions; <<'EOF' is literal.
        if (expands) for (const inner of substitutions(body.join("\n"))) segs.push(...substSegs(inner));
      }
      continue;
    }
    if (c === " " || c === "\t") { endWord(); i++; continue; }
    if (c === "#" && word === null) { while (i < src.length && src[i] !== "\n") i++; continue; }
    if (c === "\\") { if (src[i + 1] === "\n") { i += 2; continue; } add(src[i + 1] ?? "", false, src[i + 1] === undefined ? "" : "1"); i += 2; continue; }
    if (c === "$" && src[i + 1] === "'") {   // $'…': ANSI-C quoting, escapes decoded ($'\x2eenv' is .env)
      let j = i + 2, out = "";
      const ESC = { n: "\n", t: "\t", r: "\r", a: "\x07", b: "\b", e: "\x1b", f: "\f", v: "\v", "\\": "\\", "'": "'", '"': '"', "?": "?" };
      while (j < src.length && src[j] !== "'") {
        if (src[j] === "\\" && j + 1 < src.length) {
          const e = src[j + 1];
          let m;
          if ((m = src.slice(j + 1).match(/^x([0-9a-fA-F]{1,2})/))) { out += String.fromCharCode(parseInt(m[1], 16)); j += 1 + m[0].length; continue; }
          if ((m = src.slice(j + 1).match(/^U([0-9a-fA-F]{1,8})/))) { try { out += String.fromCodePoint(parseInt(m[1], 16)); } catch { /* not a code point */ } j += 1 + m[0].length; continue; }
          if ((m = src.slice(j + 1).match(/^u([0-9a-fA-F]{1,4})/))) { out += String.fromCharCode(parseInt(m[1], 16)); j += 1 + m[0].length; continue; }
          if ((m = src.slice(j + 1).match(/^[0-7]{1,3}/))) { out += String.fromCharCode(parseInt(m[0], 8)); j += 1 + m[0].length; continue; }
          out += ESC[e] ?? e; j += 2; continue;
        }
        out += src[j++];
      }
      add(out, true); i = j + 1; continue;
    }
    if (c === "'") { const j = src.indexOf("'", i + 1); add(src.slice(i + 1, j < 0 ? src.length : j), true); i = j < 0 ? src.length : j + 1; continue; }
    if (c === '"') {
      i++; let s = "", sm = "";
      while (i < src.length && src[i] !== '"') {
        if (src[i] === "\\") {   // in double quotes a backslash escapes only $ ` " \ and newline
          const e = src[i + 1] ?? "";
          if (e === "\n") { i += 2; continue; }
          if ("$`\"\\".includes(e) && e) { s += e; sm += "1"; } else { s += "\\" + e; sm += "0".repeat(1 + e.length); }
          i += 2; continue;
        }
        if (src[i] === "$" && src[i + 1] === "(") { i += 2; const inner = sub("(", ")"); segs.push(...substSegs(inner)); s += "$(…)"; sm += "0000"; continue; }
        if (src[i] === "`") { i++; const j = src.indexOf("`", i); segs.push(...substSegs(src.slice(i, j < 0 ? src.length : j))); s += "$(…)"; sm += "0000"; i = j < 0 ? src.length : j + 1; continue; }
        s += src[i++]; sm += "0";
      }
      i++; add(s, false, sm); continue;
    }
    if (c === "$" && src[i + 1] === "(" && src[i + 2] !== "(") { i += 2; const inner = sub("(", ")"); segs.push(...substSegs(inner)); add("$(…)"); continue; }
    if (c === "`") { i++; const j = src.indexOf("`", i); segs.push(...substSegs(src.slice(i, j < 0 ? src.length : j))); add("$(…)"); i = j < 0 ? src.length : j + 1; continue; }
    if ((c === "<" || c === ">") && src[i + 1] === "(") { i += 2; const inner = sub("(", ")"); segs.push(...substSegs(inner)); add("<(…)"); continue; }
    if (c === "(") { endSeg(); subDepth++; seg.sub = true; i++; continue; }   // ( subshell ), and the parens of (( … ))
    if (c === ")") { endSeg(); subDepth = Math.max(0, subDepth - 1); seg.sub = subDepth > 0; i++; continue; }
    if (c === "|" || c === ";" || c === "&") {
      if (c === "&" && src[i + 1] === ">") { endWord(); seg.pendingRedir = ">"; i += src[i + 2] === ">" ? 3 : 2; continue; }
      const op = (src[i + 1] === c || (c === "|" && src[i + 1] === "&")) ? src.slice(i, i + 2) : c;
      if (op === "&&" || op === "||") endSeg({ cond: true });
      else if (op === "|" || op === "|&") { seg.sub = true; endSeg({ sub: true }); }   // every pipeline element is a subshell
      else if (op === "&") { seg.sub = true; endSeg(); }                                  // backgrounded: a subshell
      else endSeg();
      i += op.length; continue;
    }
    if (c === "<" || c === ">") {
      const fdOnly = word !== null && /^\d+$/.test(word);
      if (fdOnly) word = null; else endWord();
      if (c === "<" && src[i + 1] === "<" && src[i + 2] === "<") { seg.pendingRedir = "<<<"; i += 3; continue; }
      if (c === "<" && src[i + 1] === "<") {   // heredoc: remember the delimiter; its body is skipped at the next newline
        i += 2; let strip = false; if (src[i] === "-") { strip = true; i++; }
        while (src[i] === " ") i++;
        let d = ""; while (i < src.length && !/[\s;|&<>]/.test(src[i])) d += src[i++];
        heredocs.push({ delim: d.replace(/['"\\]/g, ""), strip, expands: !/['"\\]/.test(d) }); continue;
      }
      let op = c; i++;
      if (src[i] === ">" || src[i] === "|") { op += src[i] === ">" ? ">" : ""; i++; }
      if (src[i] === "&") { i++; while (/\d|-/.test(src[i] || "")) i++; continue; }   // 2>&1, >&2: fd duplication
      seg.pendingRedir = op; continue;
    }
    add(c); i++;
  }
  endSeg();
  return segs;
}

const PRINT = new Set(["cat", "tac", "nl", "head", "tail", "less", "more", "most", "bat", "batcat", "jq", "yq", "xxd", "od", "hexdump",
  "strings", "base64", "base32", "cut", "sort", "uniq", "paste", "column", "fold", "fmt", "pr", "rev", "expand", "diff", "sdiff",
  "colordiff", "grep", "egrep", "fgrep", "zgrep", "rg", "ag", "ack", "awk", "gawk", "mawk", "sed", "perl", "tee", "vimcat",
  "highlight", "pygmentize", "view", "openssl", "envsubst", "plutil", "defaults", "pbcopy"]);
const WRAPPERS = new Set(["sudo", "command", "builtin", "exec", "nohup", "time", "nice", "ionice", "stdbuf", "unbuffer", "doas",
  "{", "}", "!", "if", "then", "elif", "else", "while", "until", "do"]);
const TTY = /^(-|\/dev\/(stdout|stderr|tty|fd\/[12])|\/proc\/self\/fd\/[12])$/;
const SHELLS = new Set(["bash", "sh", "zsh", "dash", "ksh", "mksh", "busybox"]);
// Interpreters whose inline code (-e/-c/…) is read for paths: `node -e "…readFileSync('.env')…"` reads a file as surely as cat.
const INTERP = /^(node|nodejs|bun|deno|python[0-9.]*|ruby|perl|php|osascript)$/;

// How each tool reads its arguments: `v` short options that take a value, `long` long options that take a value,
// `pat` first operand is a pattern/program unless one is given by `patOpt`, `quiet` options after which nothing of
// the input is printed, `files` options whose value is a file the tool reads.
const SPEC = {
  grep: { v: "ABCmefdD", long: "--max-count --regexp --file --context --after-context --before-context --label --include --exclude --exclude-dir --binary-files --devices --directories --color --colour",
    pat: true, patOpt: "e f --regexp --file", quiet: "q c l L --quiet --silent --count --files-with-matches --files-without-match", files: "f --file" },
  rg: { v: "ABCmefgtTMjEr", long: "--max-count --regexp --file --glob --iglob --type --type-not --context --after-context --before-context --threads --max-columns --type-add --replace --encoding --sort --sortr --color --colors",
    pat: true, patOpt: "e f --regexp --file", quiet: "q c l --quiet --count --count-matches --files --files-with-matches --files-without-match", files: "f --file" },
  ag: { v: "ABCmG", long: "--context --file-search-regex --max-count --after --before", pat: true, patOpt: "", quiet: "l L c --files-with-matches --files-without-matches --count" },
  ack: { v: "ABCm", long: "--type --context --max-count", pat: true, patOpt: "", quiet: "l L c --files-with-matches --files-without-matches --count" },
  awk: { v: "Fvf", long: "--field-separator --assign --file", pat: true, patOpt: "f --file", files: "f --file" },
  sed: { v: "efl", long: "--expression --file --line-length", pat: true, patOpt: "e f --expression --file", inplace: true },
  perl: { v: "eEIM", long: "", pat: false, inplace: true },
  jq: { v: "fL", long: "--from-file --arg:2 --argjson:2 --slurpfile:2 --rawfile:2 --indent --args --jsonargs", pat: true, patOpt: "f --from-file",
    files: "f --from-file --slurpfile --rawfile" },   // --rawfile NAME FILE: the last value is the file it reads
  head: { v: "nc", long: "--lines --bytes" }, tail: { v: "ncs", long: "--lines --bytes --sleep-interval --pid" },
  cut: { v: "bcdf", long: "--bytes --characters --delimiter --fields --output-delimiter" }, sort: { v: "kotST", long: "--key --output --field-separator --buffer-size --temporary-directory" },
};
for (const [a, b] of [["egrep", "grep"], ["fgrep", "grep"], ["zgrep", "grep"], ["gawk", "awk"], ["mawk", "awk"], ["yq", "jq"]]) SPEC[a] = SPEC[b];

// Pure: a tool's arguments as the tool itself reads them: options (with their values), then operands. `--` ends the
// options. For pattern-first tools the pattern operand is set aside (it names no file).
function parseArgs(verb, args) {
  const sp = SPEC[verb] || {}, longs = new Map((sp.long || "").split(" ").filter(Boolean).map((x) => { const [n, k] = x.split(":"); return [n, Number(k || 1)]; }));
  const patOpt = new Set((sp.patOpt || "").split(" ").filter(Boolean)), quietSet = new Set((sp.quiet || "").split(" ").filter(Boolean)),
    fileOpt = new Set((sp.files || "").split(" ").filter(Boolean));
  const out = { operands: [], files: [], quiet: false, inplace: false, patternGiven: false };
  const opt = (name, value) => {
    if (quietSet.has(name)) out.quiet = true;
    if (patOpt.has(name)) out.patternGiven = true;
    if (fileOpt.has(name) && value != null) out.files.push(value);
    if (sp.inplace && (name === "i" || name === "--in-place")) out.inplace = true;
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--") { out.operands.push(...args.slice(i + 1)); break; }
    if (a.startsWith("--") && a.length > 2) {
      const [name, eq] = [a.split("=")[0], a.includes("=") ? a.slice(a.indexOf("=") + 1) : null];
      if (longs.has(name) && eq === null) { opt(name, args[i + longs.get(name)]); i += longs.get(name); } else opt(name, eq);
      continue;
    }
    if (/^-./.test(a) && !/^-\d/.test(a)) {
      for (let j = 1; j < a.length; j++) {
        const ch = a[j];
        if ((sp.v || "").includes(ch)) { const val = j + 1 < a.length ? a.slice(j + 1) : args[++i]; opt(ch, val); break; }
        if (sp.inplace && ch === "i") { out.inplace = true; break; }   // sed -i[SUFFIX], perl -i[.bak]
        opt(ch, null);
      }
      continue;
    }
    out.operands.push(a);
  }
  if (sp.pat && !out.patternGiven && out.operands.length) out.operands.shift();
  return out;
}

// Process environments hold the workers' API keys and tokens. Pure: why this command (verb + args, one pipeline
// segment) would print environment VALUES, or null. Names alone are fine: compgen -e, `${NAME:+set}`.
const SECRET_NAME = /(KEY|TOKEN|SECRET|PASSW|PASSPHRASE|AUTH|CRED|COOKIE|SESSION|PRIVATE|SIGN|BEARER|DSN|DATABASE_URL|CONN(ECTION)?_?STR)/i;
const ENVIRON = /(^|\/)proc\/[^/\s]+\/environ\b/;
function envDump(verb, args, seg, ctx, commandIndex) {
  const expandedArg = (i) => {
    const word = seg?.words?.[commandIndex + 1 + i];
    return word ? parentExpand(word.text, word.mask, ctx) : [args[i]];
  };
  const words = [verb, ...args, ...(seg?.redirs || []).map((r) => r.target)];
  if (words.some((w) => ENVIRON.test(w)) && !["ls", "test", "[", "stat"].includes(verb)) return "it reads a process's environment from /proc/*/environ";
  const operands = args.filter((a) => !/^[-+]/.test(a));
  if (verb === "printenv") {
    const names = args.flatMap((a, i) => /^[-+]/.test(a) ? [] : expandedArg(i));
    return names.length === 0 ? "printenv with no name prints the whole environment"
      : names.some((n) => SECRET_NAME.test(n)) ? `printenv prints ${names.find((n) => SECRET_NAME.test(n))}, a secret-like variable` : null;
  }
  if (verb === "set" && args.length === 0) return "set with no arguments prints every variable";
  if (verb === "export" && (args.length === 0 || (args.includes("-p") && !operands.length))) return "export -p prints every exported variable";
  if (verb === "declare" || verb === "typeset") {
    if (args.length === 0) return `${verb} with no arguments prints every variable`;
    if (!operands.length && args.some((a) => /^-[a-zA-Z]*[xp]/.test(a))) return `${verb} ${args.join(" ")} prints the variables with their values`;
    if (args.some((a) => /^-[a-zA-Z]*p/.test(a)) && operands.some((n) => SECRET_NAME.test(n))) return `${verb} -p prints ${operands.find((n) => SECRET_NAME.test(n))}, a secret-like variable`;
  }
  const launchctlNames = args.slice(1).flatMap((_, i) => expandedArg(i + 1));
  if (verb === "launchctl" && args[0] === "getenv" && launchctlNames.some((n) => SECRET_NAME.test(n))) return `launchctl getenv prints ${launchctlNames.find((n) => SECRET_NAME.test(n))}, a secret-like variable`;
  if (verb === "ps") {
    // BSD-style option words (no dash) with e show each process's environment (ps e, eww, auxe); -E too. -e (dashed,
    // "every process") does not.
    // A dashless word is a BSD option cluster only if it isn't the value of an option that takes one (-o user, axo
    // etime, -p 1) and is made of BSD ps option letters.
    const takesValue = (w) => /^(-[a-zA-Z]*[oOpPuUgGCtqk]|--(format|sort|pid|ppid|user|group|tty|cols|columns|rows|width))$/.test(w)
      || (/^[a-zA-Z]+$/.test(w) && /[oOpUtk]$/.test(w));
    let env = false;
    for (let i = 0; i < args.length; i++) {
      const a = args[i];
      if (/environ/.test(a) || a === "-E" || /^-[a-zA-Z]*E/.test(a)) { env = true; break; }
      if (!a.startsWith("-") && /^[acefghjlmnrsuvwxSTXZLHOoUptk]+$/.test(a) && a.includes("e")) { env = true; break; }
      if (takesValue(a)) i++;
    }
    if (env) return "ps with e/eww/-E prints each process's environment";
  }
  return null;
}

// Pure: why this shell command would print a protected file or an environment, or null.
const ASSIGN = /^[A-Za-z_][A-Za-z0-9_]*=/;
function bashVerdict(command, ctx, depth = 0) {
  // State the command changes as it runs: the directories it may be in (every cd/pushd/env -C target is added and
  // none is dropped, so a subshell, popd or cd - can't hide one), dotglob, its own variables (each a list of possible
  // values), and the names it gave protected files (cp/ln/mv/dd/tee of one). Nested shells start from a copy.
  ctx = { ...ctx, vars: new Map(ctx.vars || []), tainted: new Set(ctx.tainted || []), dotglob: !!ctx.dotglob,
    cwds: new Set(ctx.cwds?.size ? ctx.cwds : [ctx.cwd || "/"]) };
  const segs = lex(String(command || ""));
  // An assignment that certainly happened in this shell replaces the value; one that may not have (a subshell, an
  // if/loop body, after && or ||) only adds its value to the possibilities.
  const setVar = (name, raw, scoped = false) => ctx.vars.set(name, scoped ? [...new Set([...(ctx.vars.get(name) || []), ...expand(raw, ctx)])] : expand(raw, ctx));
  let blockDepth = 0;
  const groups = [];   // for each open { … } group: whether it opened in conditional scope
  // Read fields as bash does: IFS whitespace trims and runs together, any other IFS character ends one field;
  // the last name takes the rest of the line.
  // Without -r a backslash escapes the next character (kept literally, never a separator) and is removed.
  const readTokens = (line, raw) => {
    const t = [];
    for (let i = 0; i < line.length; i++) {
      if (!raw && line[i] === "\\" && i + 1 < line.length) { if (line[i + 1] !== "\n") t.push({ c: line[i + 1], e: true }); i++; }
      else if (!raw && line[i] === "\\") continue;
      else t.push({ c: line[i], e: false });
    }
    return t;
  };
  const readFields = (tokens, names, ifs) => {
    let t = tokens;
    const ws = [...ifs].filter((c) => /\s/.test(c)).join(""), isWs = (x) => !x.e && ws.includes(x.c), isIfs = (x) => !x.e && ifs.includes(x.c);
    const str = (a) => a.map((x) => x.c).join("");
    let a = 0, b = t.length; while (a < b && isWs(t[a])) a++; while (b > a && isWs(t[b - 1])) b--; t = t.slice(a, b);
    const out = [];
    for (let i = 0; i < names.length - 1; i++) {
      let j = 0; while (j < t.length && !isIfs(t[j])) j++;
      out.push(str(t.slice(0, j))); t = t.slice(j);
      let m = 0; while (m < t.length && isWs(t[m])) m++;
      if (m < t.length && isIfs(t[m]) && !isWs(t[m])) m++;
      while (m < t.length && isWs(t[m])) m++;
      t = t.slice(m);
    }
    out.push(str(t)); return out;
  };
  const addDirs = (w) => { for (const t of expand(w, ctx)) if (!unresolved(t)) { const x = t.replace(/^~(?=\/|$)/, ctx.home);
    for (const c of path.isAbsolute(x) ? [path.normalize(x)] : [...ctx.cwds].map((d) => path.join(d, x))) ctx.cwds.add(c); } };
  const resolveAll = (w) => expand(w, ctx).flatMap((t) => { const x = t.replace(/^~(?=\/|$)/, ctx.home);
    return path.isAbsolute(x) ? [path.normalize(x)] : [...ctx.cwds].map((c) => path.join(c, x)); });
  // Backstop: a protected path named anywhere in the command. A later print of a value the guard can't resolve (a
  // variable it didn't see set, a substitution) may be that file, so it is refused rather than guessed.
  let mention = ctx.mention || null;
  for (const seg of segs) for (const w of [...seg.words.map((x) => x.text), ...seg.redirs.map((r) => r.target)]) {
    if (mention) break;
    const h = protectedPath(w, ctx); if (h) mention = h;
  }
  ctx.mention = mention;
  let sourced = null;
  for (const seg of segs) {
    const words = seg.words.map((w) => w.text);
    let k = 0;
    ctx.childEnv = null;
    if (/^(fi|done|esac)$/.test(words[0] || "")) blockDepth = Math.max(0, blockDepth - 1);
    for (let j = 0; words[j] === "}"; j++) if (groups.pop()) blockDepth = Math.max(0, blockDepth - 1);
    const scoped = seg.sub || seg.cond || blockDepth > 0;
    if (/^(if|while|until|for|case|select)$/.test(words[0] || "")) blockDepth++;
    for (let j = 0; words[j] === "{"; j++) { groups.push(scoped); if (scoped) blockDepth++; }   // `false && { …; F=x; }`: all of it may not run
    const prefix = [];   // FOO=bar before a command: that command's environment only
    // env -S expands ${F} from its own environment: the parent's plus the prefixes so far
    const envCtx = () => { const m = new Map(ctx.vars); for (const w of prefix) m.set(w.slice(0, w.indexOf("=")), expand(w.slice(w.indexOf("=") + 1), ctx)); return { ...ctx, vars: m }; };
    for (;;) {   // prefixes: FOO=bar, sudo/exec/nohup/…, shell keywords and braces, env [opts], timeout [opts] N
      if (k < words.length && ASSIGN.test(words[k])) { prefix.push(words[k]); k++; continue; }
      if (k < words.length && WRAPPERS.has(path.basename(words[k]))) { k++; while (k < words.length && /^-/.test(words[k])) k++; continue; }
      if (words[k] === "env") {
        k++;
        while (k < words.length && (/^-/.test(words[k]) || ASSIGN.test(words[k]))) {
          const w = words[k];
          if (w === "-S" || w === "--split-string") { const r = bashVerdict(words.slice(k + 1).join(" "), envCtx(), depth + 1); if (r) return r; k = words.length; break; }
          if (/^--split-string=/.test(w) || /^-S./.test(w)) { const r = bashVerdict([w.replace(/^--split-string=|^-S/, ""), ...words.slice(k + 1)].join(" "), envCtx(), depth + 1); if (r) return r; k = words.length; break; }
          if (ASSIGN.test(w)) prefix.push(w);   // env F=x cmd: cmd's environment only
          if (w === "-C" || w === "--chdir") addDirs(words[k + 1] || "");
          if (/^--chdir=/.test(w)) addDirs(w.slice(8));
          if (/^-C./.test(w)) addDirs(w.slice(2));   // -CDIR
          k += ["-u", "-C", "--unset", "--chdir"].includes(w) ? 2 : 1;
        }
        if (k >= words.length) {
          const split = words.slice(1).some((w) => w === "-S" || /^-S|^--split-string/.test(w));
          if (sourced && !split) return { why: `env prints the variables loaded from ${sourced.path}`, hit: sourced };
          if (!split) return { env: true, why: "env with no command prints the whole environment" };
          break;
        }
        continue;
      }
      if (words[k] === "timeout" || words[k] === "gtimeout") { k++; while (k < words.length && /^-/.test(words[k])) k += ["-s", "-k", "--signal", "--kill-after"].includes(words[k]) ? 2 : 1; k++; continue; }
      break;
    }
    if (k >= words.length) {   // only assignments: plain assignments in this shell
      for (const w of prefix) setVar(w.slice(0, w.indexOf("=")), w.slice(w.indexOf("=") + 1), scoped);
      if (!seg.redirs.length) continue;
    } else if (prefix.length) {   // F=x cmd: cmd's environment only. Its own words and redirections were expanded before
      // the assignment, with the old values; a shell it starts (bash -c, env -S, eval) sees the new ones.
      ctx.childEnv = new Map();
      for (const w of prefix) ctx.childEnv.set(w.slice(0, w.indexOf("=")), expand(w.slice(w.indexOf("=") + 1), { ...ctx, vars: new Map([...ctx.vars, ...ctx.childEnv]) }));
    }
    const childCtx = (extra = {}) => ({ ...ctx, ...extra, vars: new Map([...ctx.vars, ...(ctx.childEnv || [])]), childEnv: null });
    const verb = path.basename(words[k] || ""), args = words.slice(k + 1);
    const hitIn = (list) => { for (const w of list) { const h = protectedPath(w, ctx); if (h) return h; } return null; };
    const dump = envDump(verb, args, seg, ctx, k);
    if (dump) return { env: true, why: dump };
    if (verb === "cd" || verb === "pushd") { const t = args.find((a) => !/^-/.test(a) && !/^\+\d/.test(a)); addDirs(t === undefined ? ctx.home : t); continue; }
    if (verb === "popd") continue;   // every directory the command visited stays a candidate
    // dotglob: on counts everywhere; off counts only where it certainly applies to this shell
    if (verb === "shopt" && args.includes("dotglob")) { if (args.includes("-s")) ctx.dotglob = true; if (args.includes("-u") && !scoped) ctx.dotglob = false; continue; }
    if (["export", "declare", "typeset", "local", "readonly"].includes(verb)) for (const a of args) if (ASSIGN.test(a)) setVar(a.slice(0, a.indexOf("=")), a.slice(a.indexOf("=") + 1), scoped);
    if (verb === "for" && args[1] === "in") { setVar(args[0], "", true); ctx.vars.set(args[0], [...new Set([...(ctx.vars.get(args[0]) || []).filter(Boolean), ...args.slice(2).flatMap((w) => expand(w, ctx))])]); continue; }
    if (verb === "read" || verb === "mapfile" || verb === "readarray") {   // read A B <<< "x y z": A=x, B="y z"; else unknown
      const names = [], opt = {};
      for (let i = 0; i < args.length; i++) {   // -r -s -e; -n N -N N -d D -a NAME -p P -t T -u FD -i T, clustered or not
        const a = args[i];
        if (/^-./.test(a) && !opt.done) {
          if (a === "--") { opt.done = true; continue; }
          for (let c = 1; c < a.length; c++) { if ("nNdaptui".includes(a[c])) { opt[a[c]] = c + 1 < a.length ? a.slice(c + 1) : args[++i] ?? ""; break; } opt[a[c]] = true; }
          continue;
        }
        if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(a)) names.push(a);
      }
      if (opt.a) names.length = 0;
      const here = seg.redirs.find((r) => r.op === "<<<");
      if (here && verb === "read") {
        const ifsList = ctx.childEnv?.get("IFS") ?? ctx.vars.get("IFS") ?? [" \t\n"];   // IFS=: read …: read's own IFS
        for (const value of expand(here.target, ctx)) for (const ifs of ifsList) {
          let t = readTokens(value, !!opt.r);
          const delim = opt.d !== undefined ? (opt.d[0] ?? "\0") : "\n";
          const at = opt.N === undefined ? t.findIndex((x) => !x.e && x.c === delim) : -1;
          if (at >= 0) t = t.slice(0, at);
          const n = Number(opt.N ?? opt.n); if (Number.isFinite(n) && n >= 0) t = t.slice(0, n);
          if (opt.a) { for (const f of readFields(t, Array(64).fill(0), ifs).filter(Boolean)) setVar(opt.a, f, true); continue; }
          const names1 = names.length ? names : ["REPLY"];
          readFields(t, names1, ifs).forEach((f, i) => setVar(names1[i], f, true));
        }
      } else for (const n of [...names, opt.a].filter(Boolean)) if (!scoped) ctx.vars.delete(n);
      continue;
    }
    // bash -c / -lc / --norc -c …, sh -c, zsh -c, eval: the command string is a command of its own.
    if (SHELLS.has(verb) && depth < 3) {
      let dashC = false, cmd = null, cmdAt = -1;
      for (let i = 0; i < args.length; i++) {
        const a = args[i];
        if (a === "--") { if (dashC) { cmd = args[i + 1]; cmdAt = i + 1; } break; }
        if (["--rcfile", "--init-file", "-o", "-O", "+O", "+o"].includes(a)) { i++; continue; }
        if (/^-[A-Za-z]+$/.test(a)) { if (a.includes("c")) dashC = true; continue; }
        if (a.startsWith("--")) continue;
        if (dashC) { cmd = a; cmdAt = i; }
        break;
      }
      const dg = args.some((a, i) => a === "-O" && args[i + 1] === "dotglob");
      if (cmd != null) {   // the parent expands its part of the string first (old values), then the child runs it
        const w = seg.words[k + 1 + cmdAt];
        for (const c of w && w.mask ? parentExpand(cmd, w.mask, ctx) : [cmd]) { const r = bashVerdict(c, childCtx(dg ? { dotglob: true } : {}), depth + 1); if (r) return r; }
      }
    }
    if (INTERP.test(verb)) {   // inline code: every string literal and path-like word in it is a path it may read
      const flagged = args.findIndex((a, j) => /^(-e|-c|-p|-r|--eval|--print|-pe|-ne|-le)$/.test(a) || (verb === "deno" && j === 0 && a === "eval"));
      const glued = args.find((a) => /^-[ecpr]./.test(a) && !/^-[ecpr]$/.test(a));
      const code = flagged >= 0 ? args[flagged + 1] : glued ? glued.slice(2) : null;
      if (code) {
        const lits = [...code.matchAll(/(["'`])((?:\\.|(?!\1).)*)\1/g)].map((m) => m[2])
          .concat(code.split(/[\s()[\]{},;+]+/).filter((w) => /[/.~]/.test(w)));
        for (const w of lits) { const h = protectedPath(w.replace(/^["'`]|["'`]$/g, ""), ctx); if (h) return { why: `inline ${verb} code reads it`, hit: h }; }
      }
    }
    if (verb === "eval" && depth < 3) {   // eval's words: the old values; the text it runs: the prefix values too
      const c2 = childCtx();
      if (ctx.childEnv) for (const [n, v] of ctx.childEnv) c2.vars.set(n, [...new Set([...(ctx.vars.get(n) || []), ...v])]);
      const r = bashVerdict(args.join(" "), c2, depth + 1); if (r) return r;
    }
    // source/. a protected file: fine, unless a later step prints what it loaded.
    if ((verb === "source" || verb === ".") && args.length) { const h = hitIn([args[0]]); if (h) { sourced = h; continue; } }
    if (sourced) {
      const operands = args.filter((x) => !/^[-+]/.test(x));
      const dumps = verb === "printenv" || verb === "compgen"
        || (verb === "set" && args.length === 0)                                   // set with options only changes options
        || (verb === "export" && (args.length === 0 || (args.includes("-p") && !operands.length)))
        // declare/typeset -p prints the named variables (all of them without names); -x alone lists the exported ones
        || ((verb === "declare" || verb === "typeset") && (args.some((a) => /^-[a-zA-Z]*p/.test(a)) || (!operands.length && (args.length === 0 || args.some((a) => /^-[a-zA-Z]*x/.test(a))))));
      if (dumps) return { why: `${verb} prints the variables loaded from ${sourced.path}`, hit: sourced };
      if ((verb === "echo" || verb === "printf") && seg.words.slice(k + 1).some((w) => !w.sq && /\$[{A-Za-z_]/.test(w.text)))
        return { why: `${verb} prints a variable after ${sourced.path} was loaded`, hit: sourced };
    }
    const pa = parseArgs(verb, args);
    const quietOrInPlace = pa.quiet || pa.inplace;
    if (verb === "tee" && seg.redirs.some((r) => r.op === "<" && protectedPath(r.target, ctx)))
      for (const a of args.filter((x) => !/^-/.test(x))) for (const t of resolveAll(a)) ctx.tainted.add(t);
    // < file into something that prints its input (tee included: it copies its input to the terminal), or $(< file).
    for (const r of seg.redirs) {
      if (r.op !== "<") continue;
      const h = protectedPath(r.target, ctx) || (mention && !verb && unresolved(r.target) ? mention : null);
      if (h && (!verb || (PRINT.has(verb) && !quietOrInPlace))) return { why: verb ? `${verb} < ${r.target} prints it` : `$(< ${r.target}) expands to its contents`, hit: h };
    }
    if (!verb) continue;
    if (verb === "git") {
      const sub = args.find((a) => !/^-/.test(a)), h = hitIn(args);
      if (h && ["show", "diff", "log", "blame", "cat-file", "grep", "annotate"].includes(sub)) return { why: `git ${sub} prints it`, hit: h };
      continue;
    }
    if (["cp", "mv", "install", "rsync", "ln", "ditto"].includes(verb)) {
      // -t DIR / --target-directory=DIR names the destination directory; every other operand is a source.
      let tdir = null; const ops = [];
      for (let i = 0; i < args.length; i++) {
        const a = args[i];
        if (a === "-t" || a === "--target-directory") { tdir = args[++i]; continue; }
        if (/^--target-directory=/.test(a)) { tdir = a.slice(19); continue; }
        if (/^-[A-Za-z]*t./.test(a) && !a.startsWith("--")) { tdir = a.slice(a.indexOf("t") + 1); continue; }
        if (a.startsWith("-")) continue;
        ops.push(a);
      }
      const srcs = tdir !== null ? ops : ops.slice(0, -1), dest = tdir !== null ? tdir : ops.at(-1);
      // a source directory is protected when what's inside it is (cp -r <secrets dir> out/)
      const h = hitIn(srcs) || hitIn(srcs.map((x) => `${x.replace(/\/+$/, "")}/credguard-probe`));
      if (h && TTY.test(dest || "")) return { why: `${verb} to ${dest} prints it`, hit: h };
      if (h && dest) {   // the new name (a file, or a directory holding the copy) is the credential file too, for the rest of this command
        for (const d of resolveAll(dest)) {
          if (tdir === null) ctx.tainted.add(d);
          for (const src of srcs) for (const s0 of expand(src, ctx)) ctx.tainted.add(path.join(d, path.basename(s0)));
        }
      }
      continue;
    }
    if (verb === "dd") {
      const h = hitIn(args), of = args.find((a) => /^of=/.test(a));
      if (h && (!of || TTY.test(of.slice(3)))) return { why: "dd without of= prints it", hit: h };
      if (h && of) for (const t of resolveAll(of.slice(3))) ctx.tainted.add(t);
      continue;
    }
    if (!PRINT.has(verb) || verb === "tee" || quietOrInPlace) continue;   // tee FILE writes FILE; it doesn't print it
    const h = hitIn([...pa.operands, ...pa.files]);
    if (h) return { why: `${verb} prints it`, hit: h };
    const opaque = [...pa.operands, ...pa.files].find((w) => expand(w, ctx).some(unresolved));
    if (mention && opaque) return { why: `${verb} prints ${opaque}, a value the guard can't resolve, in a command that names ${mention.path}`, hit: mention };
  }
  return null;
}

// Key-names-only mode: the key names in a dotenv-style file, and nothing else. A key file (PEM armor) has no names,
// and a base64 line ending in "=" padding is key material, not NAME=value: both give nothing.
function keyNames(text) {
  if (/^-----BEGIN /m.test(String(text))) return [];
  return String(text).split("\n").filter((l) => !/^[A-Za-z0-9+/]{20,}={1,2}\s*$/.test(l))
    .map((l) => (l.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=/) || [])[1]).filter(Boolean);
}

// ---- one normalized call for every harness payload ------------------------------------------------------------------
// { kind: "shell", command, cwd } | { kind: "read", path, cwd } | { kind: "search", path, glob, content, cwd } | null.
// Tool names and input fields as each harness sends them (docs/credguard.md "Harness wiring" owns the evidence).
const SHELL_TOOLS = /^(bash|exec|exec_command|shell|run_shell_command|terminal|local_shell)$/i;
const READ_TOOLS = /^(read|read_file|readfile|view|view_file|cat)$/i;
const SEARCH_TOOLS = /^(grep|search|search_files|rg|ripgrep)$/i;
const NAMES_ONLY_MODES = new Set(["files_with_matches", "count", "files"]);

function normalize(runtime, input) {
  const name = String(input.tool_name ?? input.toolName ?? input.tool ?? "");
  const ti = input.tool_input ?? input.toolInput ?? input.input ?? {};
  const cwd = (typeof ti.cwd === "string" && ti.cwd) || input.cwd || process.cwd();
  // A string `command` on a tool that is not a known read or search tool is a shell call: Grok's shell tool name is
  // not pinned by any evidence here, only its toolInput.command field.
  const otherKnown = READ_TOOLS.test(name) || SEARCH_TOOLS.test(name);
  if (typeof ti.command === "string" && (SHELL_TOOLS.test(name) || !otherKnown)) return { kind: "shell", command: ti.command, cwd };
  const file = ti.file_path ?? ti.filePath ?? ti.path ?? ti.file;
  if (READ_TOOLS.test(name) && typeof file === "string") return { kind: "read", path: file, cwd };
  if (SEARCH_TOOLS.test(name)) {
    // Claude's Grep prints names only unless output_mode is "content"; every other search tool prints matching lines
    // unless its mode asks for names or counts only.
    const mode = ti.output_mode ?? ti.outputMode;
    const content = runtime === "claude" && !mode ? false : !NAMES_ONLY_MODES.has(String(mode ?? "content"));
    return { kind: "search", path: typeof file === "string" ? file : ".", glob: typeof ti.glob === "string" ? ti.glob : null, content, cwd };
  }
  return null;
}

// Pure: the decision for one hook payload. { deny: false } or { deny: true, reason }.
function decide(runtime, input, { home = os.homedir(), pats = patterns(process.env, home) } = {}) {
  const call = normalize(runtime, input || {});
  if (!call) return { deny: false };
  const ctx = { cwd: call.cwd, home, pats };
  let v = null;
  if (call.kind === "shell") v = bashVerdict(call.command, ctx);
  else if (call.kind === "read") { const h = protectedPath(call.path, ctx); if (h) v = { why: "reading it shows its contents", hit: h }; }
  else if (call.kind === "search" && call.content) {
    const h = protectedPath(call.path, ctx) || (call.glob && protectedPath(path.join(call.path, call.glob), ctx));
    if (h) v = { why: "a content search prints the matching lines", hit: h };
  }
  if (!v) return { deny: false };
  const keys = `${fileURLToPath(import.meta.url)} --keys`;
  if (v.env) return { deny: true, reason: [
    `firstmate credential guard: blocked, because ${v.why}. Environments hold API keys and tokens, and the transcript keeps whatever is printed.`,
    "Names only, never values:",
    "  exported variable names in this shell:  compgen -e",
    "  is one set:                             [ -n \"${NAME:+x}\" ] && echo set",
    "  processes without their environment:    ps -ef / ps aux (no e flag)",
    "Use a value by name inside the command that needs it; never print it. If a value is wrong, report it to firstmate.",
  ].join("\n") };
  const p = v.hit.path.startsWith(home + "/") ? "~" + v.hit.path.slice(home.length) : v.hit.path;
  return { deny: true, reason: [
    `firstmate credential guard: blocked, because this would print ${p} (a credential file, pattern ${v.hit.pattern}) into the transcript, where it stays: ${v.why}.`,
    "Use the values by name without printing them:",
    `  set -a; . ${p}; set +a; <the command that needs them>      (print nothing from it)`,
    "  or the tool's own option (--env-file, dotenv in the script).",
    `Check a key exists: grep -q '^NAME=' ${p} && echo present. List the key names only: ${keys} ${p}`,
    "  (it prints NAME for each NAME=value line and nothing else).",
    "Never print a value to check it; if a value is wrong, report it to firstmate (the owner rotates it).",
  ].join("\n") };
}

const RUNTIMES = new Set(["claude", "codex", "devin", "kimi", "grok", "pi", "omp", "opencode", "cursor", "gemini"]);

function main(argv) {
  if (argv[0] === "-h" || argv[0] === "--help") {
    const src = fs.readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n");
    process.stdout.write(src.slice(1, src.findIndex((l) => l.startsWith("import "))).map((l) => l.replace(/^\/\/ ?/, "")).join("\n") + "\n");
    return 0;
  }
  if (argv[0] === "--keys") {
    if (argv.length < 2) { process.stderr.write("usage: fm-credguard-read.mjs --keys <file>...\n"); return 2; }
    let rc = 0;
    for (const f of argv.slice(1)) {
      try { for (const n of keyNames(fs.readFileSync(f, "utf8"))) process.stdout.write(n + "\n"); }
      catch (e) { process.stderr.write(`${f}: ${e.code || "unreadable"}\n`); rc = 1; }
    }
    return rc;
  }
  const runtime = argv[0] === "--runtime" ? argv[1] : null;
  if (!RUNTIMES.has(runtime)) { process.stderr.write("usage: fm-credguard-read.mjs --runtime <claude|codex|devin|kimi|grok|pi|omp|opencode|cursor|gemini> | --keys <file>...\n"); return 2; }
  let d;
  try { d = decide(runtime, JSON.parse(fs.readFileSync(0, "utf8"))); } catch { return 0; }   // never deny on our own error
  if (!d.deny) return 0;
  if (runtime === "claude") {
    process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: d.reason } }));
    return 0;
  }
  if (runtime === "cursor") {
    process.stdout.write(JSON.stringify({ permission: "deny", user_message: d.reason }));
    return 0;
  }
  if (runtime === "gemini") {
    process.stdout.write(JSON.stringify({ decision: "deny", reason: d.reason }));
    return 0;
  }
  if (runtime === "grok") process.stdout.write(JSON.stringify({ decision: "deny", reason: d.reason }));
  process.stderr.write(d.reason + "\n");
  return 2;
}

export { DEFAULT_PATTERNS, SECRET_NAME, patterns, patternsFile, globRe, protectedPath, lex, parseArgs, envDump, bashVerdict, keyNames, normalize, decide };

let self = false;
try { self = fs.realpathSync(process.argv[1] || "") === fs.realpathSync(fileURLToPath(import.meta.url)); } catch { /* imported */ }
if (self) process.exitCode = main(process.argv.slice(2));
