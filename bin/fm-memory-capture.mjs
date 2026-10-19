#!/usr/bin/env node
// fm-memory-capture.mjs - the extraction pass behind bin/fm-memory-capture.sh.
//
// docs/memory.md "Automatic capture" owns the operator contract;
// bin/fm-memory-capture.sh owns scope guards, flags, and state locations.
// This file implements one extraction run.
//
// Usage (normally through the shell wrapper):
//   node fm-memory-capture.mjs run --bin <dir> --state <dir>
//        --trigger <precompact|sessionend|manual> [--dry-run] [--after <day>/<id>]
//        [--until-day <YYYY-MM-DD>] [--no-watermark]
//
// Environment: FM_MEMORY_CAPTURE_MODEL (default claude-haiku-5-5; only
// claude-haiku-* and claude-sonnet-* are accepted), FM_CLAUDE_BIN (default
// claude), and FM_MEMORY_DIR and the other variables fm-memory.sh and
// fm-history.sh read.
//
// Captain words go to that Claude model and nowhere else: Jev and other hosted
// classifiers accept task facts only, and no word filter can prove a chat turn
// holds no personal data.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const DEFAULT_MODEL = 'claude-haiku-5-5';
const MODEL_RE = /^claude-(haiku|sonnet)-[a-z0-9-]+$/;
// A captain message longer than one chunk becomes several consecutive units
// so every character reaches the model; only the reply, which is context for
// the captain's words, is clipped.
const CAPTAIN_CHUNK_CHARS = 12000;
const REPLY_CHARS = 1200;
const HAIKU_BATCH_CHARS = 60000;
const NOW_DEFAULT_DAYS = 14;
const NOW_MAX_DAYS = 60;

// Wake, triage, and operational prompts that reach a primary as typed input.
// They are fleet plumbing, never captain facts.
const WAKE_PATTERNS = [
  /^\s*:?\s*Firstmate (instruction|operational input) waiting/i,
  /firstmate watcher wake/i,
  /SYSTEM NOTIFICATION/,
  /Stop hook/,
  /^⁣?FIRSTMATE_OP/,
  /^<command-(message|name)>/,
  /^<local-command-/,
  /^\s*<task-notification>/,
];

const SYSTEM_PROMPT = `You extract durable memories from a captain's conversation with their AI first mate.
Return only memories that would still matter in a future session and that a fresh session could not re-derive from code or git history:
facts about the captain's life and situation (relationships, health, living situation, study or work arrangements, people they rely on), stated preferences and working style, decisions with their reason, and corrections.
Skip task chatter, PR or build status, tool output, plans already carried out, and anything only relevant to the current turn.
Each memory: a short topic title (reuse an existing title from the provided list exactly when the fact updates that memory), a category (preferences, entities, or events), and a self-contained fact of one to three sentences that names the date it was said.
Write the fact in the language the captain used.
Set now to true when the fact describes a current, perishable state or focus that later messages may refer to without naming it (a relationship change, a health phase, a move, this week's focus); then give now_summary as one sentence a fresh session needs, and expires as the YYYY-MM-DD date after which it stops being current (usually two weeks after it was said).
Return an empty list when nothing qualifies. Never invent facts.`;

const OUTPUT_SCHEMA = {
  type: 'object',
  properties: {
    memories: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          topic: { type: 'string' },
          category: { type: 'string', enum: ['preferences', 'entities', 'events'] },
          fact: { type: 'string' },
          now: { type: 'boolean' },
          now_summary: { type: 'string' },
          expires: { type: 'string' },
        },
        required: ['topic', 'category', 'fact', 'now'],
      },
    },
  },
  required: ['memories'],
};

function fail(message) {
  process.stderr.write(`fm-memory-capture: ${message}\n`);
  process.exit(2);
}

function parseArgs(argv) {
  const opts = { dryRun: false, noWatermark: false, after: '', untilDay: '', trigger: 'manual' };
  const [mode, ...rest] = argv;
  if (mode !== 'run') fail('usage: fm-memory-capture.mjs run --bin <dir> --state <dir> ...');
  for (let i = 0; i < rest.length; i++) {
    const arg = rest[i];
    const next = () => {
      if (i + 1 >= rest.length) fail(`${arg} needs a value`);
      return rest[++i];
    };
    if (arg === '--bin') opts.bin = next();
    else if (arg === '--state') opts.state = next();
    else if (arg === '--trigger') opts.trigger = next();
    else if (arg === '--after') opts.after = next();
    else if (arg === '--until-day') opts.untilDay = next();
    else if (arg === '--dry-run') opts.dryRun = true;
    else if (arg === '--no-watermark') opts.noWatermark = true;
    else fail(`unknown argument: ${arg}`);
  }
  if (!opts.bin || !opts.state) fail('--bin and --state are required');
  return opts;
}

function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

function writeAtomic(file, content) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, content, { mode: 0o600 });
  fs.renameSync(tmp, file);
}

function run(cmd, args, input, extraEnv = {}, timeout = 120000) {
  const res = spawnSync(cmd, args, {
    input: input ?? '',
    encoding: 'utf8',
    env: { ...process.env, ...extraEnv },
    timeout,
    maxBuffer: 64 * 1024 * 1024,
  });
  return { code: res.status ?? (res.error ? 127 : 1), stdout: res.stdout || '', stderr: res.stderr || (res.error ? String(res.error) : '') };
}

function noopReplies(binDir) {
  const replies = new Set(['Captain, shipshape.']);
  const theme = run(path.join(binDir, 'fm-theme.sh'), ['digest'], '');
  const match = theme.stdout.match(/Exact no-op reply \(replaces "Captain, shipshape\."\): (.+)$/m);
  if (match) replies.add(match[1].trim());
  return replies;
}

function stripPasted(text) {
  return text.replace(/<pasted_content\b[^>]*>[\s\S]*?<\/pasted_content>/g, '[pasted content omitted]');
}

function clip(text, limit) {
  return text.length <= limit ? text : `${text.slice(0, limit)} [...]`;
}

// Splits text into consecutive pieces of at most `limit` characters, cutting
// at the last whitespace inside each window when there is one. Joining the
// pieces gives back the text exactly.
export function chunk(text, limit) {
  const pieces = [];
  let rest = text;
  while (rest.length > limit) {
    let cut = rest.lastIndexOf(' ', limit);
    const nl = rest.lastIndexOf('\n', limit);
    if (nl > cut) cut = nl;
    if (cut <= 0) cut = limit;
    pieces.push(rest.slice(0, cut));
    rest = rest.slice(cut);
  }
  pieces.push(rest);
  return pieces;
}

// Deterministic pre-filter: drop plumbing and recognized acknowledgements,
// strip pasted material and the configured no-op reply, split long captain
// messages into lossless chunks, and clip the paired reply.
export function buildUnits(turns, noop) {
  const units = [];
  let dropped = 0;
  for (const turn of turns) {
    const captainRaw = (turn.captain || '').trim();
    if (!captainRaw || WAKE_PATTERNS.some((re) => re.test(captainRaw))) { dropped++; continue; }
    const captain = stripPasted(captainRaw).trim();
    if (noop.has(captain) || /^(?:ok(?:ay)?|yes|no|thanks|thank you|got it|go ahead|do it|merge it|ship it)[.!?]*$/i.test(captain)) {
      dropped++; continue;
    }
    let reply = (turn.reply || '').trim();
    if (noop.has(reply)) reply = '';
    const parts = chunk(captain, CAPTAIN_CHUNK_CHARS);
    parts.forEach((part, k) => {
      units.push({
        day: turn.day,
        time: turn.time,
        id: turn.id,
        part: parts.length > 1 ? `${k + 1}/${parts.length}` : '',
        captain: part,
        reply: k === parts.length - 1 ? clip(stripPasted(reply), REPLY_CHARS) : '',
      });
    });
  }
  return { units, dropped };
}

function storeTopics(binDir) {
  const res = run(path.join(binDir, 'fm-memory.sh'), ['list'], '');
  if (res.code !== 0) return [];
  return res.stdout.split('\n').filter(Boolean).slice(0, 400);
}

function unitBlock(unit) {
  const lines = [`[${unit.day} ${unit.time}]${unit.part ? ` (message part ${unit.part})` : ''}`, `captain: ${unit.captain}`];
  if (unit.reply) lines.push(`first mate: ${unit.reply}`);
  return lines.join('\n');
}

function callModel(model, claudeBin, prompt) {
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'fm-memory-capture-'));
  try {
    const args = [
      '-p', '--model', model,
      '--setting-sources', '',
      '--strict-mcp-config',
      '--tools', '',
      '--disable-slash-commands',
      '--no-session-persistence',
      '--system-prompt', SYSTEM_PROMPT,
      '--output-format', 'json',
      '--json-schema', JSON.stringify(OUTPUT_SCHEMA),
    ];
    const res = spawnSync(claudeBin, args, {
      input: prompt,
      cwd,
      encoding: 'utf8',
      env: { ...process.env, FM_MEMORY_CAPTURE_CHILD: '1' },
      timeout: 300000,
      maxBuffer: 64 * 1024 * 1024,
    });
    if (res.error) return { ok: false, why: `model call failed: ${res.error.message}` };
    let out;
    try { out = JSON.parse(res.stdout); } catch { return { ok: false, why: `model returned non-JSON (exit ${res.status})` }; }
    if (out.is_error || !out.structured_output || !Array.isArray(out.structured_output.memories)) {
      return { ok: false, why: `model returned no structured memories (exit ${res.status})`, usage: out.usage, cost: out.total_cost_usd };
    }
    return { ok: true, memories: out.structured_output.memories, usage: out.usage || {}, cost: out.total_cost_usd || 0 };
  } finally {
    fs.rmSync(cwd, { recursive: true, force: true });
  }
}

function slugify(topic) {
  return topic.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').replace(/-{2,}/g, '-');
}

function addDays(day, n) {
  const d = new Date(`${day}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

function existingBody(file) {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return ''; }
  const lines = text.split('\n');
  let i = 0;
  if (lines[0] === '---') {
    i = 1;
    while (i < lines.length && !/^---\s*$/.test(lines[i])) i++;
    i++;
  }
  if (i < lines.length && /^# /.test(lines[i])) i++;
  return lines.slice(i).join('\n').trim();
}

// Writes one memory through fm-memory.sh and proves it: the file holds the
// fact and recall for the topic returns the file.
function writeVerified(binDir, store, { category, topic, body, expires, sensitivity, replace = false }) {
  const slug = slugify(topic);
  if (!slug) return { ok: false, why: `unusable topic: ${topic}` };
  const rel = `${category}/${slug}.md`;
  const file = path.join(store, rel);
  const old = existingBody(file);
  let next = body;
  if (old && !replace) next = old.includes(body) ? old : `${old}\n\n${body}`;
  const args = ['remember', '--category', category];
  if (expires) args.push('--expires', expires);
  if (sensitivity) args.push('--sensitivity', sensitivity);
  args.push(topic);
  const res = run(path.join(binDir, 'fm-memory.sh'), args, next);
  if (res.code !== 0) return { ok: false, why: `remember failed for ${rel}: ${res.stderr.trim()}` };
  let text = '';
  try { text = fs.readFileSync(file, 'utf8'); } catch { /* checked below */ }
  if (!text.includes(body)) return { ok: false, why: `written file does not hold the fact: ${rel}` };
  const recall = run(path.join(binDir, 'fm-memory.sh'), ['recall', '--json', '--limit', '50', topic], '');
  let found = false;
  try { found = JSON.parse(recall.stdout).documents.some((doc) => doc.path === rel); } catch { found = false; }
  if (!found) return { ok: false, why: `recall does not return ${rel}` };
  return { ok: true, rel };
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const model = process.env.FM_MEMORY_CAPTURE_MODEL || DEFAULT_MODEL;
  if (!MODEL_RE.test(model)) fail(`refusing model ${model}: captain words only go to an Anthropic Claude model`);
  const claudeBin = process.env.FM_CLAUDE_BIN || 'claude';
  const markFile = path.join(opts.state, 'watermark.json');
  const mark = readJson(markFile, {});
  const after = opts.after || (mark.day ? `${mark.day}/${mark.id || ''}` : '');

  const turnsRes = run(path.join(opts.bin, 'fm-history.sh'), after ? ['turns', '--after', after] : ['turns'], '');
  if (turnsRes.code !== 0) fail(`history turns failed: ${turnsRes.stderr.trim()}`);
  let turns = turnsRes.stdout.split('\n').filter(Boolean).map((line) => JSON.parse(line));
  if (opts.untilDay) turns = turns.filter((turn) => turn.day <= opts.untilDay);
  const record = {
    schema: 'fm-memory-capture-run.v1',
    at: new Date().toISOString(),
    trigger: opts.trigger,
    model,
    turns: turns.length,
    dropped: 0,
    units: 0,
    model_calls: 0,
    model_usage: { input: 0, cache_write: 0, cache_read: 0, output: 0 },
    model_cost_usd: 0,
    memories: 0,
    now_entries: 0,
    ok: true,
    why: '',
  };
  const finish = (lastTurn) => {
    if (!opts.dryRun && !opts.noWatermark && record.ok && lastTurn) {
      writeAtomic(markFile, `${JSON.stringify({ schema: 'fm-memory-capture-mark.v1', day: lastTurn.day, id: lastTurn.id, at: record.at })}\n`);
    }
    if (!opts.dryRun) fs.appendFileSync(path.join(opts.state, 'runs.jsonl'), `${JSON.stringify(record)}\n`, { mode: 0o600 });
    process.stdout.write(`${JSON.stringify(record)}\n`);
    process.exit(record.ok ? 0 : 1);
  };
  const lastTurn = turns[turns.length - 1];
  if (!turns.length) finish(null);

  const { units, dropped } = buildUnits(turns, noopReplies(opts.bin));
  record.dropped = dropped;
  record.units = units.length;
  if (!units.length) finish(lastTurn);

  const topics = storeTopics(opts.bin);
  const header = `Existing memory titles (category/slug):\n${topics.join('\n') || '(none)'}\n\nConversation turns:\n`;
  const batches = [];
  let current = [];
  let size = 0;
  for (const unit of units) {
    const block = unitBlock(unit);
    if (current.length && size + block.length > HAIKU_BATCH_CHARS) {
      batches.push(current);
      current = [];
      size = 0;
    }
    current.push(block);
    size += block.length + 2;
  }
  if (current.length) batches.push(current);

  const memories = [];
  for (const blocks of batches) {
    if (opts.dryRun) { record.model_calls++; continue; }
    const res = callModel(model, claudeBin, header + blocks.join('\n\n'));
    record.model_calls++;
    const usage = res.usage || {};
    record.model_usage.input += usage.input_tokens || 0;
    record.model_usage.cache_write += usage.cache_creation_input_tokens || 0;
    record.model_usage.cache_read += usage.cache_read_input_tokens || 0;
    record.model_usage.output += usage.output_tokens || 0;
    record.model_cost_usd += res.cost || 0;
    if (!res.ok) {
      record.ok = false;
      record.why = res.why;
      finish(lastTurn);
    }
    memories.push(...res.memories);
  }
  if (opts.dryRun) finish(lastTurn);

  const store = run(path.join(opts.bin, 'fm-memory.sh'), ['dir'], '').stdout.trim();
  const lastDay = lastTurn.day;
  for (const mem of memories) {
    const topic = String(mem.topic || '').trim();
    const fact = String(mem.fact || '').trim();
    if (!topic || !fact) continue;
    // All chat-derived memories are private, including work summaries: the
    // model can carry personal context into a fact it considers non-personal.
    // Only an explicit operator write may publish context to other harnesses.
    const sensitivity = 'private';
    const wrote = writeVerified(opts.bin, store, { category: mem.category, topic, body: fact, sensitivity });
    if (!wrote.ok) {
      record.ok = false;
      record.why = wrote.why;
      finish(lastTurn);
    }
    record.memories++;
    if (mem.now) {
      let expires = /^\d{4}-\d{2}-\d{2}$/.test(mem.expires || '') ? mem.expires : addDays(lastDay, NOW_DEFAULT_DAYS);
      const ceiling = addDays(lastDay, NOW_MAX_DAYS);
      if (expires > ceiling) expires = ceiling;
      const summary = String(mem.now_summary || '').trim() || fact;
      const nowWrite = writeVerified(opts.bin, store, { category: 'now', topic, body: summary, expires, sensitivity, replace: true });
      if (!nowWrite.ok) {
        record.ok = false;
        record.why = nowWrite.why;
        finish(lastTurn);
      }
      record.now_entries++;
    }
  }
  finish(lastTurn);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname)) main();
