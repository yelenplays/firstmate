#!/usr/bin/env node
// fm-memory-capture.mjs - the extraction pass behind bin/fm-memory-capture.sh.
//
// docs/memory.md "Automatic capture" owns the operator contract;
// bin/fm-memory-capture.sh owns scope guards, flags, and state locations.
// This file implements one extraction run.
//
// Usage (normally through the shell wrapper):
//   node fm-memory-capture.mjs run --bin <dir> --state <dir> --config <dir>
//        --trigger <precompact|sessionend|manual> [--dry-run] [--after <day>/<id>]
//        [--until-day <YYYY-MM-DD>] [--no-watermark]
//
// Environment: FM_MEMORY_CAPTURE_MODEL (default claude-haiku-5-5; only
// claude-haiku-* and claude-sonnet-* are accepted), FM_CLAUDE_BIN (default
// claude), FM_MEMORY_CAPTURE_JEV (off disables the Jev pass),
// FM_MEMORY_CAPTURE_JEV_BIN (default bin/fm-jev.sh), and
// FM_MEMORY_DIR and the other variables fm-memory.sh and fm-history.sh read.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const DEFAULT_MODEL = 'claude-haiku-5-5';
const MODEL_RE = /^claude-(haiku|sonnet)-[a-z0-9-]+$/;
const JEV_REQUEST_BYTES = 3900;
const JEV_BATCH_UNITS = 5;
const JEV_UNIT_CHARS = 420;
const CAPTAIN_CHARS = 2400;
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

// A unit that mentions any of these stays away from Jev and goes to the
// Anthropic model only. The list is deliberately broad: a false hit costs a
// few model tokens, a miss would send personal words to a hosted classifier.
const PERSONAL_RE = new RegExp([
  'girl ?friend', 'boy ?friend', 'partner', 'relationship', 'break ?up', 'broke up', 'dating', 'divorce',
  'love', 'heart', 'feel', 'sad', 'depress', 'anxi', 'lonely', 'cry', 'tears', 'therap', 'doctor',
  'health', 'sick', 'ill\\b', 'hospital', 'medic', 'pill', 'diagnos', 'treatment', 'pain', 'sleep',
  'mood', 'mental', 'family', 'mother', '\\bmom\\b', '\\bmum\\b', 'father', '\\bdad\\b', 'sister',
  'brother', 'parent', 'friend', 'moved', 'move out', 'apartment', '\\bflat\\b', 'rent\\b', 'debt',
  'salary', 'birthday', 'wedding', 'pregnan', 'alcohol', 'drunk', 'drug', 'grief', 'funeral',
  'lecturer', 'professor', '\\buni\\b', 'university', 'exam', 'girl', 'her\\b', '\\bshe\\b', '\\bhim\\b',
  'freundin', 'freund', 'beziehung', 'schluss', 'getrennt', 'trennung', 'liebe', 'gefühl', 'gefuehl',
  'traurig', 'einsam', 'weinen', 'therapie', 'arzt', 'ärzt', 'krank', 'gesund', 'medikament',
  'tablette', 'diagnose', 'behandlung', 'schmerz', 'schlaf', 'stimmung', 'psych', 'familie', 'mutter',
  'mama', 'vater', 'papa', 'schwester', 'bruder', 'eltern', 'umzug', 'umgezogen', 'wohnung', 'miete',
  'schulden', 'gehalt', 'dozent', 'vorlesung', 'prüfung', 'pruefung', 'klausur', 'geburtstag',
  'hochzeit', 'schwanger', '\\bsie\\b', '\\bihr\\b',
].join('|'), 'i');

// A unit is Jev-eligible only when it also reads as fleet work.
const WORK_RE = /\b(pr|prs|repo|branch|merge|commit|crew|crewmate|secondmate|firstmate|scout|pipeline|no-mistakes|jev|haiku|sonnet|opus|model|config|script|hook|tests?|lint|ci|deploy|wiki|skill|backlog|tokens?|quota|prompt|agent|api|github|issue|bug|fix|build|release|server|daemon|herdr|pi|codex|claude|dispatch|worktree)\b|bin\/|\.sh\b|\.md\b|\.json\b/i;

const JEV_OPTS = [
  'none=nothing worth remembering next week',
  'preference=standing rule or working style',
  'entity=lasting project or tool fact',
  'event=dated decision worth keeping',
  'now=current perishable focus',
];

const SYSTEM_PROMPT = `You extract durable memories from a captain's conversation with their AI first mate.
Return only memories that would still matter in a future session and that a fresh session could not re-derive from code or git history:
facts about the captain's life and situation (relationships, health, living situation, study or work arrangements, people they rely on), stated preferences and working style, decisions with their reason, and corrections.
Skip task chatter, PR or build status, tool output, plans already carried out, and anything only relevant to the current turn.
Each memory: a short topic title (reuse an existing title from the provided list exactly when the fact updates that memory), a category (preferences, entities, or events), and a self-contained fact of one to three sentences that names the date it was said.
Write the fact in the language the captain used.
Set sensitivity to private for personal life, health, relationships, family, living situation, and money; otherwise normal.
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
          sensitivity: { type: 'string', enum: ['normal', 'private'] },
          now: { type: 'boolean' },
          now_summary: { type: 'string' },
          expires: { type: 'string' },
        },
        required: ['topic', 'category', 'fact', 'sensitivity', 'now'],
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
  if (mode !== 'run') fail('usage: fm-memory-capture.mjs run --bin <dir> --state <dir> --config <dir> ...');
  for (let i = 0; i < rest.length; i++) {
    const arg = rest[i];
    const next = () => {
      if (i + 1 >= rest.length) fail(`${arg} needs a value`);
      return rest[++i];
    };
    if (arg === '--bin') opts.bin = next();
    else if (arg === '--state') opts.state = next();
    else if (arg === '--config') opts.config = next();
    else if (arg === '--trigger') opts.trigger = next();
    else if (arg === '--after') opts.after = next();
    else if (arg === '--until-day') opts.untilDay = next();
    else if (arg === '--dry-run') opts.dryRun = true;
    else if (arg === '--no-watermark') opts.noWatermark = true;
    else fail(`unknown argument: ${arg}`);
  }
  if (!opts.bin || !opts.state || !opts.config) fail('--bin, --state, and --config are required');
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

function privateMarkers(configDir) {
  const file = path.join(configDir, 'private-markers');
  try {
    const st = fs.lstatSync(file);
    if (!st.isFile()) return [];
    return fs.readFileSync(file, 'utf8').split('\n')
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#'))
      .map((line) => line.toLowerCase().replace(/[\s_-]+/g, ' '));
  } catch {
    return [];
  }
}

function stripPasted(text) {
  return text.replace(/<pasted_content\b[^>]*>[\s\S]*?<\/pasted_content>/g, '[pasted content omitted]');
}

function clip(text, limit) {
  return text.length <= limit ? text : `${text.slice(0, limit)} [...]`;
}

// Deterministic pre-filter: drop plumbing and recognized acknowledgements,
// strip pasted material and the configured no-op reply, and clip what remains.
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
    units.push({
      day: turn.day,
      time: turn.time,
      id: turn.id,
      captain: clip(captain, CAPTAIN_CHARS),
      reply: clip(stripPasted(reply), REPLY_CHARS),
    });
  }
  return { units, dropped };
}

export function jevEligible(unit, markers) {
  const text = `${unit.captain}\n${unit.reply}`;
  const folded = text.toLowerCase().replace(/[\s_-]+/g, ' ');
  if (markers.some((marker) => folded.includes(marker))) return false;
  if (PERSONAL_RE.test(text)) return false;
  return WORK_RE.test(text);
}

function jevText(unit) {
  const reply = unit.reply ? ` | reply: ${unit.reply.slice(0, 120)}` : '';
  return `${unit.captain.slice(0, JEV_UNIT_CHARS - reply.length)}${reply}`.replace(/\s+/g, ' ');
}

// Keep each question tied to its unit id even when several share one state.
function jevRequest(units, batch) {
  return {
    state: `Lines from an operator chat with a coding fleet, one per id.${batch.map((idx) => ` U${idx}: ${jevText(units[idx])}`).join('')}`,
    questions: batch.map((idx) => ({
      id: `U${idx}`,
      type: 'pick',
      q: `Memory kind of U${idx}?`,
      opts: JEV_OPTS,
    })),
  };
}

// Packs eligible units into Jev batches under the request byte cap and
// returns {kinds: Map(unitIndex -> kind|null), calls, escalated}. A null kind
// means Jev could not decide; the caller sends that unit to the model.
function jevTriage(binDir, units, indexes) {
  const kinds = new Map();
  let calls = 0;
  let escalated = 0;
  let i = 0;
  while (i < indexes.length) {
    const batch = [indexes[i++]];
    while (i < indexes.length && batch.length < JEV_BATCH_UNITS
      && Buffer.byteLength(JSON.stringify(jevRequest(units, [...batch, indexes[i]]))) <= JEV_REQUEST_BYTES) {
      batch.push(indexes[i++]);
    }
    calls++;
    const jevBin = process.env.FM_MEMORY_CAPTURE_JEV_BIN || path.join(binDir, 'fm-jev.sh');
    const res = run(jevBin, ['batch'], JSON.stringify(jevRequest(units, batch)), {}, 60000);
    const answers = new Map();
    if (res.code === 0 || res.code === 2) {
      for (const line of res.stdout.split('\n')) {
        const m = line.match(/^U(\d+): (\S+)/);
        if (!m) continue;
        answers.set(Number(m[1]), m[2] === 'ESCALATE' ? null : m[2]);
      }
    }
    for (const idx of batch) {
      const kind = answers.has(idx) ? answers.get(idx) : null;
      if (kind === null) escalated++;
      kinds.set(idx, kind);
    }
  }
  return { kinds, calls, escalated };
}

function storeTopics(binDir) {
  const res = run(path.join(binDir, 'fm-memory.sh'), ['list'], '');
  if (res.code !== 0) return [];
  return res.stdout.split('\n').filter(Boolean).slice(0, 400);
}

function unitBlock(unit, hint) {
  const lines = [`[${unit.day} ${unit.time}]${hint ? ` (triage: ${hint})` : ''}`, `captain: ${unit.captain}`];
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
  const jevOn = !/^(off|0|false)$/i.test(process.env.FM_MEMORY_CAPTURE_JEV || '');
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
    jev_units: 0,
    jev_calls: 0,
    jev_none: 0,
    jev_escalated: 0,
    model_units: 0,
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
  const markers = privateMarkers(opts.config);
  const eligible = jevOn ? units.map((u, i) => (jevEligible(u, markers) ? i : -1)).filter((i) => i >= 0) : [];
  record.jev_units = eligible.length;
  const hints = new Map();
  const skip = new Set();
  if (eligible.length) {
    const triage = jevTriage(opts.bin, units, eligible);
    record.jev_calls = triage.calls;
    record.jev_escalated = triage.escalated;
    for (const [idx, kind] of triage.kinds) {
      if (kind === 'none') { skip.add(idx); record.jev_none++; } else if (kind) hints.set(idx, kind);
    }
  }
  const selected = units.map((u, i) => i).filter((i) => !skip.has(i));
  record.model_units = selected.length;
  if (!selected.length) finish(lastTurn);

  const topics = storeTopics(opts.bin);
  const header = `Existing memory titles (category/slug):\n${topics.join('\n') || '(none)'}\n\nConversation turns:\n`;
  const batches = [];
  let current = [];
  let size = 0;
  for (const idx of selected) {
    const block = unitBlock(units[idx], hints.get(idx));
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
    const sensitivity = mem.sensitivity === 'private' ? 'private' : '';
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
