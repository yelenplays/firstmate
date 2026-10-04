#!/usr/bin/env node
// fm-slack-read.mjs - read Slack thread replies and channel messages WITH their
// author user ids, through slack-axi's own installed, already-authenticated client.
//
// Why this exists: slack-axi's CLI renders every author as a display name and
// drops the user id, and a display name is something any workspace member can
// copy. The Slack bridge (bin/fm-slack-bridge.sh) must accept a thread reply as
// the captain's word only when its author id equals the configured captain id,
// so it needs the raw id. This helper loads slack-axi's own session and thread
// modules in-process and returns exactly the fields the bridge needs.
//
// Token boundary: the helper never reads, prints, stores, or logs a token.
// slack-axi resolves its own stored credential inside activeSession(); the
// helper only uses the returned client, prints no session field, and reduces
// every Slack error to its bare error code before reporting it.
//
// Verified-shape guard: it imports slack-axi internals, so it runs only against
// a slack-axi version listed in VERIFIED_VERSIONS whose modules export the
// expected functions. Anything else exits 3 with one line naming the found
// version, and the bridge keeps inbound off until the helper is re-verified.
//
// Usage: fm-slack-read.mjs < request.json
//   request: {"threads":[{"channel":"C..","parents":["1791140432.559729",...]}],
//             "history":[{"channel":"C..","oldest":"1791140432.559729"}]}
// Output, one tab-separated record per line, text base64-encoded (UTF-8), with
// "-" standing for an empty value so no column is ever empty:
//   reply    <channel> <parent-ts> <ts> <user|-> <bot:0|1> <subtype|-> <text-b64>
//   message  <channel> -           <ts> <user|-> <bot:0|1> <subtype|-> <text-b64> <name-b64>
//   done
// The trailing `done` line proves the read completed; a caller treats output
// without it as a failed read. Exit codes: 0 ok, 1 read failure, 2 usage,
// 3 slack-axi missing or not a verified version/shape.
import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { delimiter, dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

const VERIFIED_VERSIONS = new Set(["1.2.0"]);

function die(code, message) {
  process.stderr.write(`fm-slack-read: ${message}\n`);
  process.exit(code);
}

function findSlackAxiPackage() {
  for (const dir of (process.env.PATH || "").split(delimiter)) {
    if (!dir) continue;
    const candidate = join(dir, "slack-axi");
    let real;
    try {
      if (!statSync(candidate).isFile()) continue;
      real = realpathSync(candidate);
    } catch {
      continue;
    }
    let cur = dirname(real);
    for (;;) {
      const pkg = join(cur, "package.json");
      if (existsSync(pkg)) {
        try {
          const meta = JSON.parse(readFileSync(pkg, "utf-8"));
          if (meta && meta.name === "slack-axi") return { root: cur, version: String(meta.version || "") };
        } catch {
          // keep walking: an unreadable package.json is not slack-axi's
        }
      }
      const up = dirname(cur);
      if (up === cur) break;
      cur = up;
    }
    return null;
  }
  return null;
}

// Slack error objects can carry request details; report only a bare code.
function errorCode(err) {
  const raw = (err && ((err.data && err.data.error) || err.code)) || "unknown_error";
  const code = String(raw);
  return /^[A-Za-z0-9_.-]{1,64}$/.test(code) ? code : "unknown_error";
}

// Slack escapes only these three in message text.
function decodeEntities(text) {
  return text.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
}

// Empty text is "-", never an empty column: a caller splitting on tabs with
// `read` would otherwise collapse two adjacent separators and shift fields.
const b64 = (s) => (s ? Buffer.from(s, "utf-8").toString("base64") : "-");
const field = (s) => (s && /^[A-Za-z0-9_.-]+$/.test(s) ? s : "-");
const validChannel = (c) => typeof c === "string" && /^[CGD][A-Z0-9]{2,}$/.test(c);
const validTs = (t) => typeof t === "string" && /^[0-9]{10}\.[0-9]{6}$/.test(t);

function record(kind, channel, parent, msg, extra = []) {
  const bot = msg.botId || msg.subtype === "bot_message" ? "1" : "0";
  const user = typeof msg.user === "string" && /^[UW][A-Z0-9]+$/.test(msg.user) ? msg.user : "-";
  const cols = [kind, channel, parent, msg.ts, user, bot, field(msg.subtype), b64(decodeEntities(msg.text || "")), ...extra];
  return `${cols.join("\t")}\n`;
}

async function main() {
  let request;
  try {
    request = JSON.parse(readFileSync(0, "utf-8"));
  } catch {
    die(2, "expected a JSON request on stdin");
  }
  const threads = Array.isArray(request.threads) ? request.threads : [];
  const history = Array.isArray(request.history) ? request.history : [];
  for (const t of threads) {
    if (!validChannel(t.channel) || !Array.isArray(t.parents) || !t.parents.every(validTs)) {
      die(2, "invalid threads entry");
    }
  }
  for (const h of history) {
    if (!validChannel(h.channel) || !validTs(h.oldest)) die(2, "invalid history entry");
  }

  const pkg = findSlackAxiPackage();
  if (!pkg) die(3, "slack-axi is not installed on PATH; inbound stays off");
  if (!VERIFIED_VERSIONS.has(pkg.version)) {
    die(3, `slack-axi ${pkg.version || "(unknown)"} is not a verified version for reading author ids (verified: ${[...VERIFIED_VERSIONS].join(", ")}); inbound stays off`);
  }
  let sessionMod;
  let threadsMod;
  try {
    sessionMod = await import(pathToFileURL(join(pkg.root, "dist/src/session.js")).href);
    threadsMod = await import(pathToFileURL(join(pkg.root, "dist/src/slack/threads.js")).href);
  } catch {
    die(3, `slack-axi ${pkg.version} modules could not be loaded; inbound stays off`);
  }
  if (typeof sessionMod.activeSession !== "function"
    || typeof threadsMod.fetchThread !== "function"
    || typeof threadsMod.fetchWindow !== "function") {
    die(3, `slack-axi ${pkg.version} does not have the verified module shape; inbound stays off`);
  }

  let session;
  try {
    session = await sessionMod.activeSession({});
  } catch (err) {
    die(1, `slack-axi session unavailable: ${errorCode(err)}`);
  }
  if (!session || !session.client) die(3, `slack-axi ${pkg.version} session has an unexpected shape; inbound stays off`);

  const out = [];
  try {
    for (const t of threads) {
      const wanted = new Set(t.parents);
      const oldest = t.parents.reduce((a, b) => (Number(a) <= Number(b) ? a : b));
      // One history call per channel finds which bridge posts have replies at all.
      const top = await threadsMod.fetchWindow(session, t.channel, Number(oldest) * 1000, Date.now() + 60000);
      for (const parent of top) {
        if (!wanted.has(parent.ts) || !(parent.replyCount > 0)) continue;
        const all = await threadsMod.fetchThread(session, t.channel, parent.ts);
        for (const m of all) {
          if (m.ts === parent.ts || typeof m.ts !== "string") continue;
          out.push(record("reply", t.channel, parent.ts, m));
        }
      }
    }
    const names = new Map();
    for (const h of history) {
      const top = await threadsMod.fetchWindow(session, h.channel, Number(h.oldest) * 1000, Date.now() + 60000);
      for (const m of top) {
        if (typeof m.ts !== "string" || Number(m.ts) <= Number(h.oldest)) continue;
        let name = "";
        if (typeof m.user === "string" && session.client.users && typeof session.client.users.info === "function") {
          if (!names.has(m.user)) {
            try {
              const info = await session.client.users.info({ user: m.user });
              const u = (info && info.user) || {};
              const p = u.profile || {};
              names.set(m.user, String(p.display_name || u.real_name || u.name || ""));
            } catch {
              names.set(m.user, "");
            }
          }
          name = names.get(m.user);
        }
        out.push(record("message", h.channel, "-", m, [b64(name)]));
      }
    }
  } catch (err) {
    die(1, `slack read failed: ${errorCode(err)}`);
  }
  process.stdout.write(out.join(""));
  process.stdout.write("done\n");
}

main().catch(() => die(1, "slack read failed: unknown_error"));
