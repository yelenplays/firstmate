#!/usr/bin/env node
// fm-slack-render.mjs - the one owner of how a Slack bridge post looks.
//
// bin/fm-slack-bridge.sh `post` turns its flags into a JSON spec and runs this
// helper; the result goes to Slack through the bot (Block Kit blocks plus the
// plain-text fallback) or through slack-axi (the fallback text alone, which is
// itself Slack mrkdwn laid out the same way).
//
// Usage: fm-slack-render.mjs lines < spec.json
//   lines -> "text <base64>" and "blocks <base64 JSON array|->", one per line
// Exit codes: 0 ok, 2 invalid spec (one "fm-slack-render: <reason>" line).
//
// Spec, every free-text field UTF-8 and base64 so the shell never escapes JSON:
//   {"kind":"report|decision|ready|merged",
//    "text_b64":"..."?,                         free-text form (old callers)
//    "title_b64":"..."?,                        structured form: one line
//    "project_b64":"..."?, "context_b64":["..",".."]?,
//    "options":[{"key":"a","text_b64":".."}]?, "recommend":"a"?,
//    "url_b64":"..."?, "url_label_b64":"..."?}
// A spec has either text_b64 or title_b64, never both.
//
// Layouts (structured form): one item per message, scannable at a glance.
//   decision  🧭 Decision · <project>   header, the question in bold, at most two
//             context lines, the options with the recommended one marked ➡️,
//             the link, and a "Reply in thread: a / b" footer
//   ready     🔀 Ready for review · <project>, same shape as a decision
//   report    📋 Report · <project>, same shape as a decision
//   merged    ✅ Merged · <project>, one compact section
// A link is always a labelled <url|label> link, never a raw URL in prose; a
// GitHub pull request or issue URL is labelled "PR #<n>" or "Issue #<n>".
// The free-text form posts the text as written, with any link on its own line.
// There are no interactive buttons: the bot has no Socket Mode or request URL,
// so answers stay thread replies, DMs, and mentions.
import { readFileSync } from "node:fs";

const KINDS = {
  decision: { emoji: "🧭", label: "Decision" },
  ready: { emoji: "🔀", label: "Ready for review" },
  report: { emoji: "📋", label: "Report" },
  merged: { emoji: "✅", label: "Merged" },
};
const MAX_TITLE = 150;
const MAX_PROJECT = 40;
const MAX_CONTEXT = 2;
const MAX_CONTEXT_LEN = 300;
const MAX_OPTIONS = 9;
const MAX_OPTION_LEN = 200;
const MAX_TEXT = 3000;
const OPTION_KEY = /^[a-z0-9][a-z0-9-]{0,15}$/;

function die(message) {
  process.stderr.write(`fm-slack-render: ${message}\n`);
  process.exit(2);
}

function decode(value, name) {
  if (value === undefined || value === null) return "";
  if (typeof value !== "string" || !/^[A-Za-z0-9+/=]*$/.test(value)) die(`${name} must be base64`);
  return Buffer.from(value, "base64").toString("utf-8");
}

// One line: collapse every run of whitespace, so a field never breaks the layout.
const oneLine = (s) => s.replace(/\s+/g, " ").trim();

// Escape Slack entities and formatting markers before adding intentional mrkdwn.
const escape = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  .replace(/[*_~`]/g, (character) => `\\${character}`);

function linkLabel(url) {
  const m = /^https:\/\/github\.com\/[^/\s]+\/[^/\s]+\/(pull|issues)\/([0-9]+)(?:[/?#]\S*)?$/.exec(url);
  if (m) return `${m[1] === "pull" ? "PR" : "Issue"} #${m[2]}`;
  return "Open link";
}

function link(spec) {
  const url = decode(spec.url_b64, "url_b64");
  if (!url) return "";
  if (!/^https:\/\/[^\s<>|]+$/.test(url)) die("url must be one https:// URL without spaces, <, >, or |");
  const label = oneLine(decode(spec.url_label_b64, "url_label_b64")) || linkLabel(url);
  if (label.length > 60) die("url label must be at most 60 characters");
  return `<${url}|${escape(label).replace(/\|/g, "/")}>`;
}

function renderFreeText(spec, text) {
  const l = link(spec);
  const body = l ? `${text}\n🔗 ${l}` : text;
  return { text: body, blocks: null };
}

function validateMessageLength(out) {
  for (const block of out.blocks ?? []) {
    if (block.type === "section" && block.text.text.length > MAX_TEXT) {
      die(`section text must be at most ${MAX_TEXT} characters`);
    }
  }
  if (out.text.length > MAX_TEXT) die(`fallback text must be at most ${MAX_TEXT} characters`);
}

function renderStructured(spec, kind) {
  const title = oneLine(decode(spec.title_b64, "title_b64"));
  if (!title) die("title must not be empty");
  if (title.length > MAX_TITLE) die(`title must be one line of at most ${MAX_TITLE} characters`);
  const project = oneLine(decode(spec.project_b64, "project_b64"));
  if (project.length > MAX_PROJECT) die(`project must be at most ${MAX_PROJECT} characters`);
  const contextRaw = spec.context_b64 === undefined ? [] : spec.context_b64;
  if (!Array.isArray(contextRaw)) die("context_b64 must be a list");
  if (contextRaw.length > MAX_CONTEXT) die(`at most ${MAX_CONTEXT} context lines`);
  const context = contextRaw.map((c) => oneLine(decode(c, "context_b64"))).filter(Boolean);
  for (const c of context) if (c.length > MAX_CONTEXT_LEN) die(`a context line must be at most ${MAX_CONTEXT_LEN} characters`);
  const optionsRaw = spec.options === undefined ? [] : spec.options;
  if (!Array.isArray(optionsRaw)) die("options must be a list");
  if (optionsRaw.length > MAX_OPTIONS) die(`at most ${MAX_OPTIONS} options`);
  const options = optionsRaw.map((o) => {
    if (!o || typeof o.key !== "string" || !OPTION_KEY.test(o.key)) die("an option key must be 1-16 lowercase letters, digits, or dashes");
    const text = oneLine(decode(o.text_b64, "option text_b64"));
    if (!text) die(`option ${o.key} needs text`);
    if (text.length > MAX_OPTION_LEN) die(`option ${o.key} must be at most ${MAX_OPTION_LEN} characters`);
    return { key: o.key, text };
  });
  const keys = options.map((o) => o.key);
  if (new Set(keys).size !== keys.length) die("option keys must be unique");
  const recommend = spec.recommend === undefined || spec.recommend === null ? "" : spec.recommend;
  if (recommend && !keys.includes(recommend)) die("recommend must name one of the option keys");
  if (kind === "decision" && options.length && !recommend) die("a decision with options needs --recommend");
  if (kind === "merged" && options.length) die("a merged post takes no options");
  const l = link(spec);

  const { emoji, label } = KINDS[kind];
  const head = project ? `${emoji} ${label} · ${project}` : `${emoji} ${label}`;
  const optionLines = options.map((o) => (o.key === recommend
    ? `➡️ *${o.key}* · ${escape(o.text)}  _(recommended)_`
    : `◻️ *${o.key}* · ${escape(o.text)}`));
  const footer = options.length ? `Reply in thread: ${keys.join(" / ")}` : "";

  if (kind === "merged") {
    const lines = [`${emoji} *${escape(label)}*${project ? ` · ${escape(project)}` : ""}`, `*${escape(title)}*${l ? `  🔗 ${l}` : ""}`];
    for (const c of context) lines.push(escape(c));
    const text = lines.join("\n");
    return { text, blocks: [{ type: "section", text: { type: "mrkdwn", text } }] };
  }

  const summary = [`*${escape(title)}*`, ...context.map(escape)].join("\n");
  const blocks = [
    { type: "header", text: { type: "plain_text", text: head, emoji: true } },
    { type: "section", text: { type: "mrkdwn", text: summary } },
  ];
  if (optionLines.length) blocks.push({ type: "section", text: { type: "mrkdwn", text: optionLines.join("\n") } });
  if (l) blocks.push({ type: "section", text: { type: "mrkdwn", text: `🔗 ${l}` } });
  if (footer) blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: footer }] });

  const textLines = [`*${escape(head)}*`, summary];
  if (optionLines.length) textLines.push(optionLines.join("\n"));
  if (l) textLines.push(`🔗 ${l}`);
  if (footer) textLines.push(`_${footer}_`);
  return { text: textLines.join("\n"), blocks };
}

function render(spec) {
  if (!spec || typeof spec !== "object") die("expected a JSON spec object");
  const kind = spec.kind;
  if (!Object.hasOwn(KINDS, kind)) die("kind must be report, decision, ready, or merged");
  const hasText = spec.text_b64 !== undefined;
  const hasTitle = spec.title_b64 !== undefined;
  if (hasText === hasTitle) die("a spec needs exactly one of text_b64 or title_b64");
  let out;
  if (hasText) {
    if (kind === "ready" || kind === "merged") die(`a ${kind} post needs the structured form (a title)`);
    const text = decode(spec.text_b64, "text_b64");
    if (!text.trim()) die("text must not be empty");
    out = renderFreeText(spec, text);
  } else {
    out = renderStructured(spec, kind);
  }
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
}

main();
