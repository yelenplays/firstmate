#!/usr/bin/env node
// fm-slack-bot.mjs - the Slack bridge's bot transport: post and read as this
// home's own Slack app ("Yelen's Firstmate") instead of the person's account.
//
// bin/fm-slack-bridge.sh runs this helper only when config/slack-bridge names a
// bot (bot-keychain-service); without one the bridge keeps using slack-axi.
// It calls the Slack Web API directly with the bot token and needs only the
// scopes in the bridge's manifest: chat:write, channels:history (groups:history
// for private channels), im:history, and im:write.
//
// Token boundary: the token lives only in the macOS Keychain, as the password of
// the generic item whose service name the request carries. The helper reads it
// with `security find-generic-password -s <service> -w` into memory, sends it
// only in the Authorization header to the Slack API, and never prints, stores,
// or logs it. Every Slack error is reduced to its bare error code, and a
// Keychain failure is reported by exit status, never by the tool's own output.
//
// Usage: fm-slack-bot.mjs <action> < request.json
//   post    {"keychain":"svc","channel":"C..|D..","text_b64":"<UTF-8 text, base64>",
//            "thread":"<ts>"?, "blocks_b64":"<Block Kit JSON list, base64>"?}
//           -> posted <channel> <ts>
//   read    {"keychain":"svc","threads":[{"channel":"C..","parents":["<ts>",..]}],
//            "history":[{"channel":"C..","oldest":"<ts>"}],
//            "dm":{"user":"U..","oldest":"<ts>"}?,
//            "mentions":{"channels":["C..",..],"oldest":"<ts>","since":"<ts>"}?}
//           -> the same records as bin/fm-slack-read.mjs, plus
//              dm <dm-channel> - <ts> <user|-> <bot:0|1> <subtype|-> <text-b64>
//              for each new top-level message in the bot's DM with that user,
//              mention <channel> <thread-ts|-> <ts> <user|-> <bot:0|1> <subtype|-> <text-b64>
//              for each message newer than `oldest` that mentions this bot,
//              top-level or in a thread whose parent is newer than `since`
//              (threads already listed in `threads` are left to that read),
//              `mark <ts>` with the newest message or thread reply seen there,
//              then `done`. With mentions, every record's text has this bot's
//              own <@id> mention removed.
//   verify  {"keychain":"svc","user":"U.."}
//           -> bot <bot-user-id> <team-id> <dm-channel>
// Exit codes: 0 ok, 1 Slack call failed, 2 usage, 3 no usable token.
//
// FM_SLACK_BOT_API_BASE replaces https://slack.com/api/ for tests, and only with
// a loopback http://127.0.0.1:<port>/ base, so an override can never send the
// token to another host.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const VALID_ACTIONS = new Set(["post", "find-reply", "read", "verify"]);

function die(code, message) {
  process.stderr.write(`fm-slack-bot: ${message}\n`);
  process.exit(code);
}

const validChannel = (c) => typeof c === "string" && /^[CGD][A-Z0-9]{2,}$/.test(c);
const validTs = (t) => typeof t === "string" && /^[0-9]{10}\.[0-9]{6}$/.test(t);
const validUser = (u) => typeof u === "string" && /^[UW][A-Z0-9]{2,}$/.test(u);
const validService = (s) => typeof s === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(s);

function apiBase() {
  const override = process.env.FM_SLACK_BOT_API_BASE;
  if (override === undefined || override === "") return "https://slack.com/api/";
  if (!/^http:\/\/127\.0\.0\.1:[0-9]{1,5}\/?$/.test(override)) {
    die(2, "FM_SLACK_BOT_API_BASE must be a loopback http://127.0.0.1:<port>/ base");
  }
  return override.endsWith("/") ? override : `${override}/`;
}

function keychainToken(service) {
  let raw;
  try {
    raw = execFileSync("security", ["find-generic-password", "-s", service, "-w"], {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 10000,
    });
  } catch (err) {
    if (err && err.code === "ENOENT") die(3, "the macOS `security` tool is not on PATH, so the bot token cannot be read from the Keychain");
    die(3, `no Keychain item with service ${service} could be read; store the bot token there first`);
  }
  const token = raw.replace(/\r?\n$/, "");
  if (!/^xoxb-[A-Za-z0-9-]+$/.test(token)) die(3, `the Keychain item ${service} does not hold a Slack bot token (xoxb-...)`);
  return token;
}

// Slack error objects can carry request details; report only a bare code.
function bareCode(raw) {
  const code = String(raw || "unknown_error");
  return /^[A-Za-z0-9_.-]{1,64}$/.test(code) ? code : "unknown_error";
}

class SlackError extends Error {
  constructor(method, code) {
    super(`${method}: ${code}`);
    this.method = method;
    this.slackCode = code;
  }
}

function client(token) {
  const base = apiBase();
  return async function call(method, args) {
    const body = new URLSearchParams();
    for (const [k, v] of Object.entries(args || {})) {
      if (v !== undefined && v !== null) body.set(k, String(v));
    }
    let res;
    try {
      res = await fetch(base + method, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
        },
        body,
        redirect: "error",
        signal: AbortSignal.timeout(10000),
      });
    } catch {
      throw new SlackError(method, "request_failed");
    }
    if (res.status === 429) throw new SlackError(method, "ratelimited");
    let data;
    try {
      data = await res.json();
    } catch {
      throw new SlackError(method, `http_${res.status}`);
    }
    if (!data || data.ok !== true) throw new SlackError(method, bareCode(data && data.error));
    return data;
  };
}

async function paged(call, method, args, key) {
  const all = [];
  let cursor;
  do {
    const data = await call(method, { ...args, limit: 200, cursor });
    all.push(...(Array.isArray(data[key]) ? data[key] : []));
    cursor = data.response_metadata && data.response_metadata.next_cursor;
  } while (cursor);
  return all;
}

// Slack escapes only these three in message text.
function decodeEntities(text) {
  return text.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
}

// Empty values are "-", never an empty column, so the bridge's tab split keeps
// every field in place.
const b64 = (s) => (s ? Buffer.from(s, "utf-8").toString("base64") : "-");
const field = (s) => (s && /^[A-Za-z0-9_.-]+$/.test(s) ? s : "-");

// Set once a read knows its own bot user id, so a "@bot ..." message arrives
// as the words addressed to the bot.
let selfMention = null;

function mentionsSelf(msg) {
  return selfMention !== null && typeof msg.text === "string" && new RegExp(selfMention.source).test(msg.text);
}

function stripSelf(text) {
  if (selfMention === null) return text;
  return text.replace(selfMention, "").replace(/[ \t]{2,}/g, " ").replace(/^[\s,:]+/, "").trim();
}

function record(kind, channel, parent, msg, extra = []) {
  const bot = msg.bot_id || msg.subtype === "bot_message" ? "1" : "0";
  const user = validUser(msg.user) ? msg.user : "-";
  const cols = [kind, channel, parent, msg.ts, user, bot, field(msg.subtype), b64(decodeEntities(stripSelf(msg.text || ""))), ...extra];
  return `${cols.join("\t")}\n`;
}

async function openDm(call, user) {
  const data = await call("conversations.open", { users: user });
  const id = data.channel && data.channel.id;
  if (!validChannel(id)) throw new SlackError("conversations.open", "unexpected_channel");
  return id;
}

async function actionPost(call, req) {
  if (!validChannel(req.channel)) die(2, "post needs a channel id");
  const text = typeof req.text_b64 === "string" && /^[A-Za-z0-9+/=]+$/.test(req.text_b64)
    ? Buffer.from(req.text_b64, "base64").toString("utf-8")
    : "";
  if (!text.trim()) die(2, "post needs text_b64");
  if (req.thread !== undefined && !validTs(req.thread)) die(2, "post thread must be a Slack ts");
  // Optional Block Kit layout from bin/fm-slack-render.mjs; `text` stays the
  // notification and fallback text.
  let blocks;
  if (req.blocks_b64 !== undefined) {
    let parsed;
    try {
      parsed = typeof req.blocks_b64 === "string" && /^[A-Za-z0-9+/=]+$/.test(req.blocks_b64)
        ? JSON.parse(Buffer.from(req.blocks_b64, "base64").toString("utf-8"))
        : null;
    } catch {
      parsed = null;
    }
    if (!Array.isArray(parsed) || parsed.length === 0 || parsed.length > 50) die(2, "post blocks_b64 must be a base64 JSON list of 1-50 blocks");
    blocks = JSON.stringify(parsed);
  }
  const data = await call("chat.postMessage", {
    channel: req.channel,
    text,
    blocks,
    thread_ts: req.thread,
    unfurl_links: false,
  });
  if (!validChannel(data.channel) || !validTs(data.ts)) throw new SlackError("chat.postMessage", "unexpected_response");
  process.stdout.write(`posted ${data.channel} ${data.ts}\n`);
}

async function actionFindReply(call, req) {
  const marker = typeof req.marker_b64 === "string" && /^[A-Za-z0-9+/=]+$/.test(req.marker_b64)
    ? Buffer.from(req.marker_b64, "base64").toString("utf-8")
    : "";
  const markerId = marker.startsWith("[fm-reply:") && marker.endsWith("]")
    ? marker.slice("[fm-reply:".length, -1)
    : "";
  if (!validChannel(req.channel)) die(2, "find-reply needs a channel id");
  if (req.thread !== "-" && !validTs(req.thread)) die(2, "find-reply needs a thread ts or '-'");
  if (!validTs(req.oldest)) die(2, "find-reply needs the incoming message ts");
  if (!/^[A-Za-z0-9._-]+$/.test(markerId)) die(2, "find-reply needs a reply marker");
  const auth = await call("auth.test", {});
  if (!validUser(auth.user_id)) throw new SlackError("auth.test", "unexpected_bot_user");
  const messages = req.thread === "-"
    ? await paged(call, "conversations.history", { channel: req.channel, oldest: req.oldest, inclusive: true }, "messages")
    : await paged(call, "conversations.replies", { channel: req.channel, ts: req.thread }, "messages");
  const found = messages.find((message) => message.user === auth.user_id && (message.bot_id || message.subtype === "bot_message") && String(message.text || "").includes(marker));
  if (found && validTs(found.ts)) process.stdout.write(`found ${req.channel} ${found.ts}\n`);
  else process.stdout.write("not-found\n");
}

async function actionRead(call, req) {
  const threads = Array.isArray(req.threads) ? req.threads : [];
  const history = Array.isArray(req.history) ? req.history : [];
  for (const t of threads) {
    if (!validChannel(t.channel) || !Array.isArray(t.parents) || !t.parents.every(validTs)) die(2, "invalid threads entry");
  }
  for (const h of history) {
    if (!validChannel(h.channel) || !validTs(h.oldest)) die(2, "invalid history entry");
  }
  const dm = req.dm;
  if (dm !== undefined && dm !== null && (!validUser(dm.user) || !validTs(dm.oldest))) die(2, "invalid dm entry");
  const mentions = req.mentions;
  if (mentions !== undefined && mentions !== null
    && (!Array.isArray(mentions.channels) || !mentions.channels.every(validChannel)
      || !validTs(mentions.oldest) || !validTs(mentions.since))) die(2, "invalid mentions entry");
  if (mentions) {
    const auth = await call("auth.test", {});
    if (!validUser(auth.user_id)) throw new SlackError("auth.test", "unexpected_bot_user");
    selfMention = new RegExp(`<@${auth.user_id}(?:\\|[^>]*)?>`, "g");
  }

  const out = [];
  for (const t of threads) {
    const wanted = new Set(t.parents);
    const oldest = t.parents.reduce((a, b) => (Number(a) <= Number(b) ? a : b));
    // One history read per channel finds which bridge posts have replies at all.
    const top = await paged(call, "conversations.history", { channel: t.channel, oldest, inclusive: true }, "messages");
    for (const parent of top) {
      if (!wanted.has(parent.ts) || !(parent.reply_count > 0)) continue;
      const all = await paged(call, "conversations.replies", { channel: t.channel, ts: parent.ts }, "messages");
      for (const m of all) {
        if (m.ts === parent.ts || !validTs(m.ts)) continue;
        out.push(record("reply", t.channel, parent.ts, m));
      }
    }
  }
  for (const h of history) {
    const top = await paged(call, "conversations.history", { channel: h.channel, oldest: h.oldest }, "messages");
    for (const m of top) {
      if (!validTs(m.ts) || Number(m.ts) <= Number(h.oldest)) continue;
      // Without users:read the bot cannot look up names; the bridge names the id.
      out.push(record("message", h.channel, "-", m, ["-"]));
    }
  }
  if (mentions) {
    const after = (ts) => validTs(ts) && Number(ts) > Number(mentions.oldest);
    let mark = null;
    const seen = (ts) => { if (after(ts) && (mark === null || Number(ts) > Number(mark))) mark = ts; };
    for (const channel of new Set(mentions.channels)) {
      const read = threads.find((t) => t.channel === channel);
      const watched = new Set(read ? read.parents : []);
      const top = await paged(call, "conversations.history", { channel, oldest: mentions.oldest }, "messages");
      for (const m of top) {
        if (!validTs(m.ts)) continue;
        seen(m.ts);
        // A reply also sent to the channel answers in its own thread.
        const thread = validTs(m.thread_ts) && m.thread_ts !== m.ts ? m.thread_ts : "-";
        if (after(m.ts) && mentionsSelf(m)) out.push(record("mention", channel, thread, m));
      }
      const discovery = await paged(call, "conversations.history", { channel, oldest: mentions.since }, "messages");
      for (const m of discovery) {
        if (!validTs(m.ts)) continue;
        seen(m.latest_reply);
        if (!(m.reply_count > 0) || !after(m.latest_reply) || watched.has(m.ts)) continue;
        const all = await paged(call, "conversations.replies", { channel, ts: m.ts }, "messages");
        for (const r of all) {
          if (r.ts === m.ts || !after(r.ts) || !mentionsSelf(r)) continue;
          out.push(record("mention", channel, m.ts, r));
        }
      }
    }
    if (mark !== null) out.push(`mark\t${mark}\n`);
  }
  if (dm) {
    const channel = await openDm(call, dm.user);
    const top = await paged(call, "conversations.history", { channel, oldest: dm.oldest }, "messages");
    for (const m of top) {
      if (!validTs(m.ts) || Number(m.ts) <= Number(dm.oldest)) continue;
      out.push(record("dm", channel, "-", m));
    }
  }
  process.stdout.write(out.join(""));
  process.stdout.write("done\n");
}

async function actionVerify(call, req) {
  if (!validUser(req.user)) die(2, "verify needs a user id");
  const auth = await call("auth.test", {});
  const botUser = validUser(auth.user_id) ? auth.user_id : "-";
  const team = typeof auth.team_id === "string" && /^[TE][A-Z0-9]{2,}$/.test(auth.team_id) ? auth.team_id : "-";
  const channel = await openDm(call, req.user);
  process.stdout.write(`bot\t${botUser}\t${team}\t${channel}\n`);
}

async function main() {
  const action = process.argv[2];
  if (!VALID_ACTIONS.has(action) || process.argv.length !== 3) die(2, "usage: fm-slack-bot.mjs post|find-reply|read|verify < request.json");
  let req;
  try {
    req = JSON.parse(readFileSync(0, "utf-8"));
  } catch {
    die(2, "expected a JSON request on stdin");
  }
  if (!req || typeof req !== "object") die(2, "expected a JSON request object on stdin");
  if (!validService(req.keychain)) die(2, "the request needs a Keychain service name");
  apiBase();
  const call = client(keychainToken(req.keychain));
  try {
    if (action === "post") await actionPost(call, req);
    else if (action === "find-reply") await actionFindReply(call, req);
    else if (action === "read") await actionRead(call, req);
    else await actionVerify(call, req);
  } catch (err) {
    if (err instanceof SlackError) die(1, `slack ${err.method} failed: ${err.slackCode}`);
    die(1, "slack call failed: unknown_error");
  }
}

main().catch(() => die(1, "slack call failed: unknown_error"));
