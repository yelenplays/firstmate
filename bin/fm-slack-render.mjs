#!/usr/bin/env node
// fm-slack-render.mjs - the one owner of how a Slack bridge post looks.
//
// bin/fm-slack-bridge.sh `post` turns its flags into a JSON spec and runs this
// helper; the result goes to Slack through the bot (Block Kit blocks plus the
// plain-text fallback) or through slack-axi (the fallback text alone, which is
// itself Slack mrkdwn laid out the same way).
//
// Usage: fm-slack-render.mjs lines < spec.json
//   lines -> "text <base64>" and "blocks <base64 JSON array|->", one per line,
//            plus "rewrote <term>,<term>" when internal terms were replaced
// Exit codes: 0 ok, 2 invalid spec (one "fm-slack-render: <reason>" line).
//
// Spec, every free-text field UTF-8 and base64 so the shell never escapes JSON:
//   {"kind":"report|decision|ready|merged|finished|live|stuck|digest",
//    "lang":"en|de"?,                           fixed words and rewrites; default en
//    "text_b64":"..."?,                         free-text form (old callers)
//    "title_b64":"..."?,                        structured form: the outcome
//    "project_b64":"..."?, "context_b64":["..",".."]?,
//    "options":[{"key":"a","text_b64":".."}]?, "recommend":"a"?,
//    "lines_b64":[".."]?,                       digest only: up to four more lines
//    "mirror":"<channel id or #name>"?,         the one-line #updates entry for a
//                                               post whose answer lives there
//    "url_b64":"..."?}
// A spec has either text_b64 or title_b64, never both.
//
// Every kind has the same short shape, built for a reader who scans:
//   line 1  <emoji> <project> · <outcome>          bold; project + outcome at most 90
//   line 2  what happens now or what to do         the context, at most 160
//   options a decision's or ready post's choices, the recommended one marked ➡️
//   link    one labelled link, never a raw URL
//   footer  "Reply in thread: a / b", only when there are options
// The emoji says the kind: 🙋 needs you (decision, ready), ✅ finished or merged,
// 🚀 live, ⚠️ stuck, 📋 report, ☀️ the morning digest (at most five lines).
// A mirror post is line 1, then "Reply there: <channel>", then the link.
// The free-text form becomes the same shape: its first line is line 1 and the
// rest is line 2.
// Overlong lines are cut with "…" rather than refused, so an outcome is never
// lost to its length; more than one question, more than five options, or more
// than two context lines are refused because the caller must split the post.
// Terms matched by JARGON below are rewritten to plain words in the post's
// language and named on the "rewrote" line; callers still follow AGENTS.md
// section 9 for terms outside that list.
// GitHub pull requests are labelled "PR #<n>"; other URLs use "Open link" in
// English or "Öffnen" in German.
// There are no interactive buttons: the bot has no Socket Mode or request URL,
// so answers stay thread replies, DMs, and mentions.
import { readFileSync } from "node:fs";

const KINDS = {
  decision: "🙋",
  ready: "🙋",
  report: "📋",
  merged: "✅",
  finished: "✅",
  live: "🚀",
  stuck: "⚠️",
  digest: "☀️",
};
const WORDS = {
  en: { recommended: "recommended", reply: "Reply in thread", there: "Reply there", open: "Open link" },
  de: { recommended: "empfohlen", reply: "Antworte im Thread", there: "Antworte dort", open: "Öffnen" },
};
// Longest phrases first, so "primary checkout" wins over "checkout".
const JARGON = [
  [/\bprimary checkouts?\b/gi, "local copy", "lokale Kopie"],
  [/\bworktrees?\b/gi, "local copy", "lokale Kopie"],
  [/\bcheckouts?\b/gi, "local copy", "lokale Kopie"],
  [/\bcrew ?mates?\b/gi, "worker", "Helfer"],
  [/\bteardown\b/gi, "cleanup", "Aufräumen"],
  [/\bheartbeats?\b/gi, "monitoring", "Überwachung"],
  [/\bwatchers?\b/gi, "monitoring", "Überwachung"],
  [/\bstatus (?:files?|lines?|logs?)\b/gi, "record", "Eintrag"],
  [/\bmetadata\b/gi, "record", "Eintrag"],
  [/\btask[ -]ids?\b/gi, "task", "Aufgabe"],
  [/\bneeds-decision\b/gi, "decision needed", "Entscheidung nötig"],
  [/\bask-user\b/gi, "your call", "deine Entscheidung"],
  [/\bchecks-passed\b/gi, "checks passed", "Prüfungen bestanden"],
  [/\bfix-review\b/gi, "review fix", "Prüfkorrektur"],
  [/\bfails? (?:closed|loudly)\b|\bfail-closed\b/gi, "stops safely", "stoppt sicher"],
  [/\bfails? open\b|\bfail-open\b|\bdegraded-open\b/gi, "continues without the check", "läuft ohne Prüfung weiter"],
  [/\bno-mistakes\b/gi, "checks", "Prüfung"],
  [/\bpipelines?\b/gi, "checks", "Prüfung"],
  [/\bharness(?:es)?\b/gi, "tool", "Werkzeug"],
  [/\bruntime backends?\b/gi, "tool", "Werkzeug"],
  [/\byolo\b/gi, "auto-merge", "automatisch übernehmen"],
  [/(?<![\w/])(?:~\/|\/Users\/|\/home\/|state\/|data\/|bin\/)[^\s)]+/g, "(local file)", "(lokale Datei)"],
];
const MAX_HEAD = 90;
const MAX_PROJECT = 40;
const MAX_NEXT = 160;
const MAX_CONTEXT = 2;
const MAX_OPTIONS = 5;
const MAX_OPTION_LEN = 80;
const MAX_DIGEST_LINES = 4;
const MAX_URL = 500;
const MAX_TEXT = 1500;
const OPTION_KEY = /^[a-z0-9][a-z0-9-]{0,15}$/;
const MIRROR = /^(?:[CG][A-Z0-9]{2,}|#[a-z0-9][a-z0-9._-]{0,79})$/;

function die(message) {
  process.stderr.write(`fm-slack-render: ${message}\n`);
  process.exit(2);
}

function decode(value, name) {
  if (value === undefined || value === null) return "";
  if (typeof value !== "string" || !/^[A-Za-z0-9+/=]*$/.test(value)) die(`${name} must be base64`);
  return Buffer.from(value, "base64").toString("utf-8");
}

const oneLine = (s) => s.replace(/\s+/g, " ").trim();

// Cut by characters, not UTF-16 units, so an emoji is never split.
function cut(s, max) {
  const chars = [...s];
  return chars.length <= max ? s : `${chars.slice(0, max - 1).join("").trimEnd()}…`;
}

const escape = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  .replace(/[*_~`]/g, (character) => `\\${character}`);

const rewritten = new Set();

function plain(s, lang) {
  let out = s;
  for (const [pattern, en, de] of JARGON) {
    out = out.replace(pattern, (match) => {
      rewritten.add(/^[A-Za-z -]+$/.test(match) ? match.toLowerCase() : "path");
      return lang === "de" ? de : en;
    });
  }
  return out;
}

function linkLabel(url, words) {
  const m = /^https:\/\/github\.com\/[^/\s]+\/[^/\s]+\/pull\/([0-9]+)(?:[/?#]\S*)?$/.exec(url);
  return m ? `PR #${m[1]}` : words.open;
}

function link(spec, words) {
  const url = decode(spec.url_b64, "url_b64");
  if (!url) return "";
  if (!/^https:\/\/[^\s<>|]+$/.test(url)) die("url must be one https:// URL without spaces, <, >, or |");
  if (url.length > MAX_URL) die(`url must be at most ${MAX_URL} characters`);
  return `<${url}|${linkLabel(url, words)}>`;
}

function validateMessageLength(out) {
  for (const block of out.blocks ?? []) {
    if (block.type === "section" && block.text.text.length > MAX_TEXT) {
      die(`section text must be at most ${MAX_TEXT} characters`);
    }
  }
  if (out.text.length > MAX_TEXT) die(`fallback text must be at most ${MAX_TEXT} characters`);
}

function countQuestions(...parts) {
  return parts.join(" ").split("?").length - 1;
}

// Gather the post's parts from either form into one shape.
function parts(spec, kind, lang) {
  const contextRaw = spec.context_b64 === undefined ? [] : spec.context_b64;
  if (!Array.isArray(contextRaw)) die("context_b64 must be a list");
  if (contextRaw.length > MAX_CONTEXT) die(`at most ${MAX_CONTEXT} context lines`);
  let title;
  let next = contextRaw.map((c) => oneLine(decode(c, "context_b64"))).filter(Boolean).join(" ");
  if (spec.text_b64 !== undefined) {
    const text = decode(spec.text_b64, "text_b64");
    if (!text.trim()) die("text must not be empty");
    const lines = text.split(/\r?\n/).map(oneLine).filter(Boolean);
    title = lines[0];
    next = lines.slice(1).join(" ");
  } else {
    title = oneLine(decode(spec.title_b64, "title_b64"));
    if (!title) die("title must not be empty");
  }
  const project = cut(oneLine(decode(spec.project_b64, "project_b64")), MAX_PROJECT);
  const optionsRaw = spec.options === undefined ? [] : spec.options;
  if (!Array.isArray(optionsRaw)) die("options must be a list");
  if (optionsRaw.length > MAX_OPTIONS) die(`at most ${MAX_OPTIONS} options`);
  const options = optionsRaw.map((o) => {
    if (!o || typeof o.key !== "string" || !OPTION_KEY.test(o.key)) die("an option key must be 1-16 lowercase letters, digits, or dashes");
    const text = oneLine(decode(o.text_b64, "option text_b64"));
    if (!text) die(`option ${o.key} needs text`);
    return { key: o.key, text: plain(text, lang) };
  });
  const keys = options.map((o) => o.key);
  if (new Set(keys).size !== keys.length) die("option keys must be unique");
  const recommend = spec.recommend === undefined || spec.recommend === null ? "" : spec.recommend;
  if (recommend && !keys.includes(recommend)) die("recommend must name one of the option keys");
  if (kind === "decision" && options.length && !recommend) die("a decision with options needs --recommend");
  if (options.length && !["decision", "ready", "report"].includes(kind)) die(`a ${kind} post takes no options`);
  const linesRaw = spec.lines_b64 === undefined ? [] : spec.lines_b64;
  if (!Array.isArray(linesRaw)) die("lines_b64 must be a list");
  if (linesRaw.length && kind !== "digest") die("only a digest takes extra lines");
  if (linesRaw.length > MAX_DIGEST_LINES) die(`a digest has at most ${MAX_DIGEST_LINES + 1} lines`);
  const extra = linesRaw.map((l) => oneLine(decode(l, "lines_b64"))).filter(Boolean);
  if (countQuestions(title, next, ...extra, ...options.map((o) => o.text)) > 1) die("a post asks at most one question; split it");
  title = plain(title, lang);
  next = plain(next, lang);
  const head = cut(project ? `${project} · ${title}` : title, MAX_HEAD);
  return {
    head,
    next: cut(next, MAX_NEXT),
    options: options.map((o) => ({ ...o, text: cut(o.text, MAX_OPTION_LEN) })),
    recommend,
    extra: extra.map((l) => cut(plain(l, lang), MAX_NEXT)),
  };
}

function render(spec) {
  if (!spec || typeof spec !== "object") die("expected a JSON spec object");
  const kind = spec.kind;
  if (!Object.hasOwn(KINDS, kind)) die("kind must be report, decision, ready, merged, finished, live, stuck, or digest");
  const lang = spec.lang === undefined || spec.lang === null ? "en" : spec.lang;
  if (!Object.hasOwn(WORDS, lang)) die("lang must be en or de");
  const words = WORDS[lang];
  const hasText = spec.text_b64 !== undefined;
  const hasTitle = spec.title_b64 !== undefined;
  if (hasText === hasTitle) die("a spec needs exactly one of text_b64 or title_b64");
  if (hasText && !["report", "decision"].includes(kind)) die(`a ${kind} post needs the structured form (a title)`);
  const mirror = spec.mirror === undefined || spec.mirror === null ? "" : spec.mirror;
  if (mirror && !MIRROR.test(mirror)) die("mirror must be a channel id or #name");
  const p = parts(spec, kind, lang);
  const l = link(spec, words);
  if (kind === "digest" && 1 + (p.next ? 1 : 0) + p.extra.length + (l ? 1 : 0) > MAX_DIGEST_LINES + 1) {
    die(`a digest has at most ${MAX_DIGEST_LINES + 1} lines, its link included`);
  }

  const lines = [`*${escape(`${KINDS[kind]} ${p.head}`)}*`];
  let footer = "";
  if (mirror) {
    lines.push(`${words.there}: ${mirror.startsWith("#") ? mirror : `<#${mirror}>`}`);
  } else {
    if (p.next) lines.push(escape(p.next));
    for (const e of p.extra) lines.push(escape(e));
    for (const o of p.options) {
      lines.push(o.key === p.recommend
        ? `➡️ *${o.key}* · ${escape(o.text)}  _(${words.recommended})_`
        : `◻️ *${o.key}* · ${escape(o.text)}`);
    }
    if (p.options.length) footer = `${words.reply}: ${p.options.map((o) => o.key).join(" / ")}`;
  }
  if (l) lines.push(`🔗 ${l}`);
  const body = lines.join("\n");
  const blocks = [{ type: "section", text: { type: "mrkdwn", text: body } }];
  if (footer) blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: footer }] });
  const out = { text: footer ? `${body}\n_${footer}_` : body, blocks };
  validateMessageLength(out);
  return out;
}

function main() {
  if (process.argv[2] !== "lines" || process.argv.length !== 3) die("usage: fm-slack-render.mjs lines < spec.json");
  let spec;
  try {
    spec = JSON.parse(readFileSync(0, "utf-8"));
  } catch {
    die("expected a JSON spec on stdin");
  }
  const out = render(spec);
  const b64 = (s) => Buffer.from(s, "utf-8").toString("base64");
  process.stdout.write(`text ${b64(out.text)}\n`);
  process.stdout.write(`blocks ${out.blocks ? b64(JSON.stringify(out.blocks)) : "-"}\n`);
  if (rewritten.size) process.stdout.write(`rewrote ${[...rewritten].join(",")}\n`);
}

main();
