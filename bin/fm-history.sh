#!/usr/bin/env bash
# fm-history.sh - capture and retrieve the primary conversation journal.
#
# Usage:
#   fm-history.sh capture [--compaction] --transcript <path>
#   fm-history.sh wakes --rows-file <path> --ack-through <sequence> --actor <main|branch>
#   fm-history.sh wake-ack <sequence> <row-count> <main|branch>
#   fm-history.sh recent [--n <count>]
#   fm-history.sh find <query>
#   fm-history.sh task <id> [--completed]
#   fm-history.sh logbook [--date <YYYY-MM-DD>] [--rebuild]
#
# Capture reads Claude or Pi JSONL transcripts deterministically. Transcript
# capture journals only captain messages and final assistant replies; tool results,
# internal operational messages, and thinking blocks are not. The private pages live under
# $FM_HOME/data/history, with generated task cards, daily Logbooks, index.md,
# and a disposable BM25 cache. The byte cursor and capture lock live under
# $FM_HOME/state.
#
# `find` searches pages locally through fm-memory.sh. If Jev is configured, it
# receives the query and bounded page ids/titles only, never page contents.
# `days/<date>.md` stores transcript, wake-batch, compaction, and Logbook records;
# `tasks/<id>.md` is create-once and embeds `fm-history-task.v1` metadata:
# schema, id, title, project, home, kind, mode, completion, via, pr_url,
# report_path, local_note and digest-verified decisions. The daily JSON is
# `fm-logbook.v1` with schema, date, tz, closed, generated, landed, reports,
# decisions, and open. The generated `index.md` lists page paths/titles.
# `state/.history-cursor` is `fm-history-cursor.v1` with schema, transcript,
# dev, ino, offset, pending {id, day, time}, and last assistant token usage;
# `.history.lock` holds only the owner pid. `state/jev-history-find.jsonl`
# contains metadata-only Jev search records, with queries stored as SHA-256 digests.
# History directories are mode 0700 and generated files mode 0600; the BM25
# search cache is disposable. Older Logbooks are closed, never deleted; --rebuild
# is the explicit path that can replace a closed day's JSON and Markdown section.
#
# Environment: FM_HOME, FM_DATA_OVERRIDE, FM_STATE_OVERRIDE, FM_ROOT_OVERRIDE.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
HISTORY_DIR="$DATA_DIR/history"

# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  fm-history.sh capture [--compaction] --transcript <path>
  fm-history.sh wakes --rows-file <path> --ack-through <sequence> --actor <main|branch>
  fm-history.sh wake-ack <sequence> <row-count> <main|branch>
  fm-history.sh recent [--n <count>]
  fm-history.sh find <query>
  fm-history.sh task <id> [--completed]
  fm-history.sh logbook [--date <YYYY-MM-DD>] [--rebuild]
EOF
}

die() {
  printf 'fm-history: %s\n' "$1" >&2
  exit "${2:-2}"
}

# Capture and recent share the same small Node standard-library adapter so
# JSONL is parsed in one streaming pass and message text remains byte-faithful.
run_history_node() {
  command -v node >/dev/null 2>&1 || die 'node is required'
  node - "$@" <<'NODE'
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

function fail(message, code = 2) {
  process.stderr.write(`fm-history: ${message}\n`);
  process.exit(code);
}

function ensureDirectory(dir, mode = 0o700, tightenPermissions = true) {
  let created = false;
  try {
    const st = fs.lstatSync(dir);
    if (!st.isDirectory() || st.isSymbolicLink()) fail(`not a real directory: ${dir}`);
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
    fs.mkdirSync(dir, { recursive: true, mode });
    created = true;
  }
  if (tightenPermissions || created) fs.chmodSync(dir, mode);
}

function regularFile(file) {
  try {
    const st = fs.lstatSync(file);
    return st.isFile() && !st.isSymbolicLink();
  } catch (err) {
    if (err.code === 'ENOENT') return false;
    throw err;
  }
}

function assertRegularOrMissing(file, label = 'file') {
  try {
    const st = fs.lstatSync(file);
    if (!st.isFile() || st.isSymbolicLink()) fail(`not a regular ${label}: ${file}`);
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
  }
}

function writeAtomic(file, content, mode = 0o600, tightenParentPermissions = true) {
  const dir = path.dirname(file);
  ensureDirectory(dir, 0o700, tightenParentPermissions);
  assertRegularOrMissing(file, 'write target');
  const suffix = crypto.randomBytes(6).toString('hex');
  const tmp = path.join(dir, `.${path.basename(file)}.tmp.${process.pid}.${suffix}`);
  let fd;
  try {
    fd = fs.openSync(tmp, 'wx', mode);
    fs.writeFileSync(fd, content, 'utf8');
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = undefined;
    fs.renameSync(tmp, file);
    fs.chmodSync(file, mode);
  } catch (err) {
    if (fd !== undefined) {
      try { fs.closeSync(fd); } catch {}
    }
    try { fs.unlinkSync(tmp); } catch {}
    throw err;
  }
}

function safeId(value, fallback) {
  if (typeof value === 'string' && /^[A-Za-z0-9._:-]{1,200}$/.test(value)) return value;
  return fallback;
}

function acquireHistoryLock(stateDir, skipWhenBusy = false) {
  ensureDirectory(stateDir, 0o700, false);
  const lockDir = path.join(stateDir, '.history.lock');
  for (let attempt = 0; attempt < 20; attempt++) {
    try {
      fs.mkdirSync(lockDir, { mode: 0o700 });
      fs.writeFileSync(path.join(lockDir, 'pid'), `${process.pid}\n`, { mode: 0o600, flag: 'wx' });
      return lockDir;
    } catch (err) {
      if (err.code !== 'EEXIST') {
        try { fs.rmSync(lockDir, { recursive: true, force: true }); } catch {}
        throw err;
      }
      let owner = '';
      try { owner = fs.readFileSync(path.join(lockDir, 'pid'), 'utf8').trim(); } catch {}
      if (/^\d+$/.test(owner)) {
        let alive = true;
        try { process.kill(Number(owner), 0); } catch (checkErr) { if (checkErr.code === 'ESRCH') alive = false; }
        if (!alive) {
          try { fs.rmSync(lockDir, { recursive: true, force: true }); } catch {}
          continue;
        }
      }
      if (attempt < 19) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
    }
  }
  if (skipWhenBusy) return null;
  fail('another history operation is active', 1);
}

function releaseHistoryLock(lockDir) {
  if (!lockDir) return;
  try { fs.rmSync(lockDir, { recursive: true, force: true }); } catch {}
}

function withHistoryLock(stateDir, operation) {
  const lockDir = acquireHistoryLock(stateDir, false);
  try { return operation(); }
  finally { releaseHistoryLock(lockDir); }
}

const HOME_TIME_ZONE = Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
const localDateFormatter = new Intl.DateTimeFormat('en-CA', {
  timeZone: HOME_TIME_ZONE, year: 'numeric', month: '2-digit', day: '2-digit',
  hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
});

function localDateParts(date) {
  const parts = Object.fromEntries(localDateFormatter.formatToParts(date).map((part) => [part.type, part.value]));
  return { day: `${parts.year}-${parts.month}-${parts.day}`, time: `${parts.hour}:${parts.minute}` };
}

function currentLocalDate() {
  return localDateParts(new Date()).day;
}

function timestampParts(value) {
  if (typeof value !== 'string') return null;
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return null;
  return localDateParts(date);
}

function tokenCounts(record) {
  const usage = record?.message?.usage || record?.usage;
  if (!usage || typeof usage !== 'object' || Array.isArray(usage)) return null;
  const aliases = {
    input_tokens: ['input', 'input_tokens'],
    output_tokens: ['output', 'output_tokens'],
    cache_read_input_tokens: ['cacheRead', 'cache_read_input_tokens'],
    cache_creation_input_tokens: ['cacheWrite', 'cache_creation_input_tokens'],
    reasoning_tokens: ['reasoning', 'reasoning_tokens'],
    total_tokens: ['totalTokens', 'total_tokens'],
  };
  const counts = {};
  for (const [field, names] of Object.entries(aliases)) {
    const value = names.map((name) => usage[name]).find((item) => Number.isSafeInteger(item) && item >= 0);
    if (value !== undefined) counts[field] = value;
  }
  return Object.keys(counts).length ? counts : null;
}

function isInternalInput(text) {
  return text.startsWith('\u2063FIRSTMATE_OP: ') || text.startsWith('FM_INJECT_MARK');
}

function textOf(record) {
  const content = record && record.message ? record.message.content : undefined;
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  const pieces = [];
  for (const block of content) {
    if (block && block.type === 'text' && typeof block.text === 'string') pieces.push(block.text);
    else if (block && block.type === 'image') pieces.push('[image attached]');
  }
  return pieces.join('\n');
}

function maxBacktickRun(text) {
  let max = 0;
  for (const match of text.matchAll(/`+/g)) max = Math.max(max, match[0].length);
  return max;
}

function recordMarker(role, id, turnId, text) {
  const trailingNewline = text.endsWith('\n') ? 1 : 0;
  if (role === 'captain') {
    return `<!-- fm-history:captain id=${id} trailing-newline=${trailingNewline} -->`;
  }
  return `<!-- fm-history:firstmate id=${id} turn=${turnId} trailing-newline=${trailingNewline} -->`;
}

function outsideFenceLineIndexes(lines) {
  const indexes = new Set();
  let fenceChar = '';
  let fenceSize = 0;
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    if (fenceChar) {
      const close = new RegExp(`^ {0,3}${fenceChar}{${fenceSize},}[ \\t]*$`);
      if (close.test(line)) {
        fenceChar = '';
        fenceSize = 0;
      }
      continue;
    }
    indexes.add(index);
    const open = line.match(/^ {0,3}(`{3,}|~{3,})/);
    if (open) {
      fenceChar = open[1][0];
      fenceSize = open[1].length;
    }
  }
  return indexes;
}

function markerExists(content, wanted) {
  const lines = content.split('\n');
  const outside = outsideFenceLineIndexes(lines);
  return [...outside].some((index) => lines[index] === wanted);
}

function renderRecord(role, id, turnId, time, text) {
  const fence = '`'.repeat(Math.max(3, maxBacktickRun(text) + 1));
  const label = role === 'captain' ? 'captain' : 'firstmate';
  const marker = recordMarker(role, id, turnId, text);
  const separator = text.endsWith('\n') ? '' : '\n';
  return `${marker}\n### ${time} ${label}\n${fence}text\n${text}${separator}${fence}\n\n`;
}

function appendStructuredRecord(historyDir, day, id, time, heading, value) {
  const daysDir = path.join(historyDir, 'days');
  ensureDirectory(historyDir);
  ensureDirectory(daysDir);
  const file = path.join(daysDir, `${day}.md`);
  if (fs.existsSync(file) && !regularFile(file)) fail(`not a regular journal page: ${file}`);
  let content = regularFile(file) ? fs.readFileSync(file, 'utf8') : `# Conversation history - ${day}\n\n`;
  const marker = `<!-- fm-history:${id.type} id=${id.value} -->`;
  if (markerExists(content, marker)) return false;
  const body = JSON.stringify(value, null, 2);
  const fence = '`'.repeat(Math.max(3, maxBacktickRun(body) + 1));
  if (content && !content.endsWith('\n')) content += '\n';
  content += `${marker}\n### ${time} ${heading}\n${fence}json\n${body}\n${fence}\n\n`;
  writeAtomic(file, content);
  return true;
}

function appendRecord(historyDir, day, role, id, turnId, time, text) {
  const daysDir = path.join(historyDir, 'days');
  ensureDirectory(historyDir);
  ensureDirectory(daysDir);
  const file = path.join(daysDir, `${day}.md`);
  if (fs.existsSync(file) && !regularFile(file)) fail(`not a regular journal page: ${file}`);
  let content = regularFile(file) ? fs.readFileSync(file, 'utf8') : `# Conversation history - ${day}\n\n`;
  const marker = recordMarker(role, id, turnId, text);
  if (markerExists(content, marker)) return false;
  if (content && !content.endsWith('\n')) content += '\n';
  content += renderRecord(role, id, turnId, time, text);
  writeAtomic(file, content);
  return true;
}

function titleFromPage(file) {
  const text = fs.readFileSync(file, 'utf8');
  const title = text.split('\n').find((line) => /^#\s+/.test(line));
  return title ? title.replace(/^#\s+/, '').trim() : path.basename(file, '.md');
}

function pageRows(historyDir) {
  const rows = [];
  for (const kind of ['days', 'tasks']) {
    const dir = path.join(historyDir, kind);
    if (!fs.existsSync(dir)) continue;
    const walk = (current, prefix) => {
      for (const ent of fs.readdirSync(current, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
        const full = path.join(current, ent.name);
        const rel = path.posix.join(prefix, ent.name);
        if (ent.isSymbolicLink()) continue;
        if (ent.isDirectory()) walk(full, rel);
        else if (ent.isFile() && ent.name.endsWith('.md')) rows.push({ kind, rel, full, title: titleFromPage(full) });
      }
    };
    if (fs.lstatSync(dir).isDirectory() && !fs.lstatSync(dir).isSymbolicLink()) walk(dir, kind);
  }
  return rows.sort((a, b) => a.rel.localeCompare(b.rel));
}

function updateIndex(historyDir) {
  ensureDirectory(historyDir);
  const index = path.join(historyDir, 'index.md');
  if (fs.existsSync(index) && !regularFile(index)) fail(`not a regular history index: ${index}`);
  const rows = pageRows(historyDir);
  const lines = ['# History index', '', 'Generated register of dated history pages and task cards.', ''];
  for (const row of rows) {
    lines.push(`- ${row.rel} - ${row.kind === 'days' ? 'day' : 'task'} - ${row.title.replace(/[\r\n]+/g, ' ')}`);
  }
  writeAtomic(index, `${lines.join('\n')}\n`);
}

function capture(transcript, historyDir, stateDir, compaction) {
  if (!transcript || !historyDir || !stateDir) fail('capture requires transcript, history, and state paths');
  const transcriptPath = path.resolve(transcript);
  if (!regularFile(transcriptPath)) fail(`transcript is not a readable regular file: ${transcriptPath}`);
  fs.accessSync(transcriptPath, fs.constants.R_OK);
  const lockDir = acquireHistoryLock(stateDir, true);
  if (!lockDir) {
    process.stdout.write('capture skipped: another history operation is active\n');
    return;
  }

  try {
    const cursorFile = path.join(stateDir, '.history-cursor');
    let cursor = {};
    if (regularFile(cursorFile)) {
      try { cursor = JSON.parse(fs.readFileSync(cursorFile, 'utf8')); } catch { cursor = {}; }
    }
    const st = fs.statSync(transcriptPath);
    let offset = Number.isSafeInteger(cursor.offset) && cursor.offset >= 0 ? cursor.offset : 0;
    let pending = cursor.pending && typeof cursor.pending === 'object' ? cursor.pending : null;
    let lastUsage = cursor.last_usage && typeof cursor.last_usage === 'object' ? cursor.last_usage : null;
    if (cursor.transcript !== transcriptPath || cursor.dev !== st.dev || cursor.ino !== st.ino || st.size < offset) {
      offset = 0;
      pending = null;
      lastUsage = null;
    }
    const scanEnd = st.size;
    const fd = fs.openSync(transcriptPath, 'r');
    let readPosition = offset;
    let processedPosition = offset;
    let remainder = Buffer.alloc(0);
    let captainCount = 0;
    let replyCount = 0;
    let badLines = 0;
    try {
      while (readPosition < scanEnd) {
        const chunk = Buffer.allocUnsafe(Math.min(64 * 1024, scanEnd - readPosition));
        const read = fs.readSync(fd, chunk, 0, chunk.length, readPosition);
        if (read <= 0) break;
        readPosition += read;
        remainder = Buffer.concat([remainder, chunk.subarray(0, read)]);
        let newline;
        while ((newline = remainder.indexOf(0x0a)) !== -1) {
          const lineBytes = remainder.subarray(0, newline);
          remainder = remainder.subarray(newline + 1);
          processedPosition += lineBytes.length + 1;
          const line = lineBytes.toString('utf8').replace(/\r$/, '');
          if (!line) continue;
          let rec;
          try { rec = JSON.parse(line); } catch { badLines++; continue; }
          const type = rec && rec.type;
          const piRole = type === 'message' && rec.message && rec.message.role;
          const assistantRecord = type === 'assistant' || piRole === 'assistant';
          const sidechain = Boolean(rec && (rec.isSidechain || (rec.message && rec.message.isSidechain)));
          if (assistantRecord && !sidechain) lastUsage = tokenCounts(rec) || lastUsage;
          const fromTool = Boolean(rec && (rec.sourceToolAssistantUUID || rec.toolUseResult));
          if ((type === 'user' && !fromTool) || piRole === 'user') {
            if (type === 'user') {
              const origin = rec.origin || (rec.message && rec.message.origin) || '';
              if (origin !== 'human') {
                pending = null;
                continue;
              }
            }
            const text = textOf(rec);
            if (isInternalInput(text)) {
              pending = null;
              continue;
            }
            const parts = timestampParts(rec.timestamp || (rec.message && rec.message.timestamp));
            if (!text || !parts) {
              pending = null;
              continue;
            }
            const id = safeId(rec.uuid || rec.id, crypto.createHash('sha256').update(lineBytes).digest('hex').slice(0, 32));
            appendRecord(historyDir, parts.day, 'captain', id, '', parts.time, text);
            pending = { id, day: parts.day, time: parts.time };
            captainCount++;
            continue;
          }
          if (assistantRecord && pending && !sidechain) {
            const stopReason = rec.message && (rec.message.stop_reason || rec.message.stopReason);
            if (stopReason !== 'end_turn' && stopReason !== 'stop') continue;
            const text = textOf(rec);
            const parts = timestampParts(rec.timestamp || (rec.message && rec.message.timestamp));
            if (text && parts) {
              const id = safeId(rec.uuid || rec.id, crypto.createHash('sha256').update(lineBytes).digest('hex').slice(0, 32));
              appendRecord(historyDir, pending.day, 'firstmate', id, pending.id, parts.time, text);
              replyCount++;
            }
            pending = null;
          }
        }
      }
    } finally {
      fs.closeSync(fd);
    }
    const nextCursor = {
      schema: 'fm-history-cursor.v1',
      transcript: transcriptPath,
      dev: st.dev,
      ino: st.ino,
      offset: processedPosition,
      pending,
      last_usage: lastUsage,
    };
    if (compaction) {
      const observed = localDateParts(new Date());
      const identity = crypto.createHash('sha256')
        .update(`${transcriptPath}\u0000${st.dev}\u0000${st.ino}\u0000${scanEnd}`, 'utf8')
        .digest('hex').slice(0, 32);
      appendStructuredRecord(historyDir, observed.day, { type: 'compaction', value: identity }, observed.time,
        'last assistant token usage before compaction', { transcript_bytes: scanEnd,
          last_assistant_usage: lastUsage });
    }
    updateIndex(historyDir);
    writeAtomic(cursorFile, `${JSON.stringify(nextCursor)}\n`, 0o600, false);
    if (badLines) process.stderr.write(`fm-history: skipped ${badLines} malformed transcript line(s)\n`);
    process.stdout.write(`captured ${captainCount} captain message(s) and ${replyCount} final reply/replies\n`);
  } finally {
    releaseHistoryLock(lockDir);
  }
}

function readWakeRows(file) {
  if (!regularFile(file)) fail(`not a readable regular wake-row file: ${file}`);
  return fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean).map((line) => {
    const fields = line.split('\t');
    if (fields.length < 5 || !/^\d+$/.test(fields[0]) || !/^\d+$/.test(fields[1])) fail('invalid wake row');
    const epoch = Number(fields[0]);
    const sequence = Number(fields[1]);
    const date = new Date(epoch * 1000);
    if (!Number.isSafeInteger(epoch) || !Number.isSafeInteger(sequence) || sequence < 1
      || !Number.isFinite(date.getTime()) || !['signal', 'stale', 'check', 'heartbeat'].includes(fields[2])) fail('invalid wake row');
    return {
      occurred_at: date.toISOString(), sequence, kind: fields[2], key: fields[3],
      reason: fields.slice(4).join('\t'),
    };
  });
}

function wakeBatch(historyDir, stateDir, rowsFile, ackThrough, actor) {
  if (!/^\d+$/.test(String(ackThrough)) || !['main', 'branch'].includes(actor)) fail('invalid wake batch metadata');
  return withHistoryLock(stateDir, () => {
    const rows = readWakeRows(rowsFile);
    if (!rows.length) fail('wake batch has no rows');
    const acknowledgementNumber = Number(ackThrough);
    if (!Number.isSafeInteger(acknowledgementNumber) || acknowledgementNumber < Math.max(...rows.map((row) => row.sequence))) {
      fail('wake acknowledgement number precedes its rows');
    }
    const observed = localDateParts(new Date());
    const batchId = crypto.createHash('sha256')
      .update(JSON.stringify({ acknowledgementNumber, actor, rows }), 'utf8').digest('hex').slice(0, 32);
    appendStructuredRecord(historyDir, observed.day, { type: 'wake-batch', value: batchId }, observed.time,
      `wake batch (acknowledgement number ${acknowledgementNumber})`, {
        actor, acknowledgement_number: acknowledgementNumber, rows,
      });
    updateIndex(historyDir);
    process.stdout.write(`journaled wake batch ${batchId}\n`);
  });
}

function wakeAcknowledgement(historyDir, stateDir, sequence, rowCount, actor) {
  if (!/^\d+$/.test(String(sequence)) || !/^\d+$/.test(String(rowCount))
    || !['main', 'branch'].includes(actor)) fail('invalid wake acknowledgement');
  const acknowledgementNumber = Number(sequence);
  const rowsAcknowledged = Number(rowCount);
  if (!Number.isSafeInteger(acknowledgementNumber) || !Number.isSafeInteger(rowsAcknowledged)
    || acknowledgementNumber < 0 || rowsAcknowledged < 0) fail('invalid wake acknowledgement');
  return withHistoryLock(stateDir, () => {
    const observed = localDateParts(new Date());
    const identity = crypto.createHash('sha256')
      .update(`${acknowledgementNumber}\u0000${rowsAcknowledged}\u0000${actor}`, 'utf8').digest('hex').slice(0, 32);
    appendStructuredRecord(historyDir, observed.day, { type: 'wake-ack', value: identity }, observed.time,
      `wake acknowledgement ${acknowledgementNumber}`, {
        actor, acknowledgement_number: acknowledgementNumber, rows_acknowledged: rowsAcknowledged,
      });
    updateIndex(historyDir);
  });
}

function parsePageRecords(file, rel) {
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  const outside = outsideFenceLineIndexes(lines);
  const rows = [];
  const markerRe = /^<!-- fm-history:(captain|firstmate) id=([A-Za-z0-9._:-]+)(?: turn=([A-Za-z0-9._:-]+))? trailing-newline=([01]) -->$/;
  for (let i = 0; i < lines.length; i++) {
    if (!outside.has(i)) continue;
    const marker = lines[i].match(markerRe);
    if (!marker) continue;
    const heading = lines[i + 1] || '';
    const h = heading.match(/^### (\d{2}:\d{2}) (captain|firstmate)$/);
    const opening = (lines[i + 2] || '').match(/^(`{3,})text$/);
    if (!h || !opening || h[2] !== marker[1]) continue;
    const fence = opening[1];
    const body = [];
    let j = i + 3;
    while (j < lines.length && lines[j] !== fence) body.push(lines[j++]);
    if (j >= lines.length) continue;
    let text = body.join('\n');
    if (marker[4] === '1') text += '\n';
    rows.push({ role: marker[1], id: marker[2], turnId: marker[3] || '', time: h[1], text, page: rel });
    i = j;
  }
  return rows;
}

function historyPages(historyDir) {
  const pages = [];
  const dir = path.join(historyDir, 'days');
  if (!fs.existsSync(dir)) return pages;
  if (!fs.lstatSync(dir).isDirectory() || fs.lstatSync(dir).isSymbolicLink()) return pages;
  for (const ent of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (ent.isFile() && !ent.isSymbolicLink() && /^\d{4}-\d{2}-\d{2}\.md$/.test(ent.name)) {
      pages.push({ file: path.join(dir, ent.name), rel: `data/history/days/${ent.name}`, day: ent.name.slice(0, 10) });
    }
  }
  return pages;
}

function truncateText(text, limit, page) {
  if (Buffer.byteLength(text, 'utf8') <= limit) return text;
  let head = Math.floor(limit * 0.72);
  let tail = Math.floor(limit * 0.18);
  const suffix = `\n[... truncated; full text in ${page}]\n`;
  while (head + tail > 0) {
    const candidate = `${text.slice(0, head)}${suffix}${text.slice(-tail)}`;
    if (Buffer.byteLength(candidate, 'utf8') <= limit) return candidate;
    head = Math.floor(head * 0.9);
    tail = Math.floor(tail * 0.9);
  }
  return suffix.trim();
}

function renderRecent(groups, historyDir) {
  const blocks = [];
  for (const group of groups) {
    const page = `data/history/days/${group.day}.md`;
    let captain = group.captain.text;
    let reply = group.reply ? group.reply.text : '';
    const perTextLimit = Math.max(300, Math.floor(6800 / Math.max(1, groups.length * (group.reply ? 2 : 1))));
    captain = truncateText(captain, perTextLimit, page);
    if (group.reply) reply = truncateText(reply, perTextLimit, page);
    blocks.push(`${group.captain.time} captain (${page}):\n${captain}${captain.endsWith('\n') ? '' : '\n'}`);
    if (group.reply) blocks.push(`${group.reply.time} firstmate:\n${reply}${reply.endsWith('\n') ? '' : '\n'}`);
  }
  let output = blocks.join('\n');
  const maxBytes = 8000;
  while (Buffer.byteLength(output, 'utf8') > maxBytes && groups.length > 1) {
    groups.shift();
    return renderRecent(groups, historyDir);
  }
  if (Buffer.byteLength(output, 'utf8') > maxBytes && groups.length === 1) {
    const group = groups[0];
    const page = `data/history/days/${group.day}.md`;
    const captainLimit = group.reply ? 2600 : 7000;
    const captain = truncateText(group.captain.text, captainLimit, page);
    const reply = group.reply ? truncateText(group.reply.text, 2600, page) : '';
    output = `${group.captain.time} captain (${page}):\n${captain}\n`;
    if (group.reply) output += `${group.reply.time} firstmate:\n${reply}\n`;
    if (Buffer.byteLength(output, 'utf8') > maxBytes) output = output.slice(-maxBytes);
  }
  return `${output.trimEnd()}\njournal: ${historyDir}/days/\n`;
}

function recent(historyDir, n) {
  const pages = historyPages(historyDir).reverse();
  const groups = [];
  for (const page of pages) {
    const pageGroups = [];
    const byId = new Map();
    for (const row of parsePageRecords(page.file, page.rel)) {
      if (row.role === 'captain') {
        const group = { day: page.day, captain: row, reply: null };
        pageGroups.push(group);
        byId.set(row.id, group);
      } else {
        const group = byId.get(row.turnId);
        if (group && !group.reply) group.reply = row;
      }
    }
    groups.unshift(...pageGroups);
    if (groups.length >= n) break;
  }
  const selected = groups.slice(-n);
  if (!selected.length) {
    process.stdout.write(`(no captain conversations captured yet; journal: ${historyDir}/days/)\n`);
    return;
  }
  process.stdout.write(renderRecent(selected, historyDir));
}

function readJsonFile(file, label) {
  if (!regularFile(file)) fail(`not a readable regular ${label}: ${file}`);
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (err) { fail(`invalid ${label}: ${file}: ${err.message}`); }
}

function homeIdentity(homeDir) {
  const marker = path.join(homeDir, '.fm-secondmate-home');
  assertRegularOrMissing(marker, 'secondmate home marker');
  if (!regularFile(marker)) return 'main';
  const id = fs.readFileSync(marker, 'utf8').trim();
  if (!/^[A-Za-z0-9._:-]{1,200}$/.test(id)) fail(`invalid secondmate home identity: ${marker}`);
  return id;
}

function validDate(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T12:00:00.000Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

function repoFromUrl(value) {
  if (typeof value !== 'string') return null;
  const match = value.match(/^https?:\/\/github\.com\/[^/]+\/([^/]+)\/(?:pull|issues)\/\d+/i);
  return match ? match[1].replace(/\.git$/i, '') : null;
}

function cleanTaskTitle(value) {
  return String(value || '')
    .replace(/\s+-?\s*data\/[^\s)]+\/report\.md$/i, '')
    .replace(/\s+-?\s*local main$/i, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function resolutionSignatures(body, verifyDecisionWords = true) {
  if (typeof body !== 'string') return [];
  const marker = /^Resolution recorded by fm-(?:captain|decision)-hold\.$/gm;
  const signatures = [];
  let cursor = 0;
  while (cursor < body.length) {
    marker.lastIndex = cursor;
    const match = marker.exec(body);
    if (!match) break;
    const start = match.index;
    const tail = body.slice(start);
    const label = /^Captain decision:\n/m.exec(tail);
    if (!label) {
      cursor = start + match[0].length;
      continue;
    }
    const header = tail.slice(0, label.index);
    if (/^Resolution recorded by fm-(?:captain|decision)-hold\.$/m.test(header.slice(match[0].length))) {
      cursor = start + match[0].length;
      continue;
    }
    const mode = header.match(/^Resolution mode: ([a-z-]+)\s*$/m)?.[1];
    const at = header.match(/^Resolved: (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s*$/m)?.[1];
    const digest = header.match(/^Decision digest: ([a-f0-9]{64})\s*$/m)?.[1];
    if (!mode || !at || !digest) {
      cursor = start + match[0].length;
      continue;
    }
    let end = body.length;
    if (verifyDecisionWords) {
      const wordsStart = start + label.index + label[0].length;
      end = -1;
      for (let offset = wordsStart; offset <= body.length; offset++) {
        if (offset !== body.length && body[offset] !== '\n') continue;
        const words = body.slice(wordsStart, offset);
        const hash = crypto.createHash('sha256').update(words, 'utf8').digest('hex');
        if (hash === digest) { end = offset; break; }
      }
      if (end < 0) {
        cursor = start + match[0].length;
        continue;
      }
    }
    signatures.push({ mode, at, digest, block: body.slice(start, end) });
    cursor = verifyDecisionWords ? end + 1 : start + label.index + label[0].length;
  }
  return signatures;
}

function decisionRows(snapshotBody, body, id, project, title, home, targetDate) {
  const snapshot = new Set(resolutionSignatures(snapshotBody, false).map(({ mode, at, digest }) => `${mode}\u0000${at}\u0000${digest}`));
  const rows = [];
  for (const { mode, at, digest, block } of resolutionSignatures(body)) {
    if (!snapshot.has(`${mode}\u0000${at}\u0000${digest}`)
      || !['answered', 'released', 'repaired'].includes(mode)
      || (targetDate && timestampParts(at)?.day !== targetDate)) continue;
    const labelMatch = block.match(/^Captain decision:\n/m);
    if (!labelMatch) continue;
    const tail = block.slice(labelMatch.index + labelMatch[0].length);
    let words;
    for (let offset = 0; offset <= tail.length; offset++) {
      if (offset !== tail.length && tail[offset] !== '\n') continue;
      const candidate = tail.slice(0, offset);
      const hash = crypto.createHash('sha256').update(candidate, 'utf8').digest('hex');
      if (hash === digest) { words = candidate; break; }
    }
    if (words !== undefined) rows.push({ id, project, title, mode, at, digest, words, home });
  }
  return rows;
}

function readDecisionBodies(file) {
  if (!regularFile(file)) fail(`not a readable regular decision-record file: ${file}`);
  const bodies = {};
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    if (!line) continue;
    let row;
    try { row = JSON.parse(line); } catch { fail(`invalid decision record in ${file}`); }
    if (row && typeof row.id === 'string' && typeof row.body === 'string' && typeof row.snapshot_body === 'string') {
      bodies[row.id] = { body: row.body, snapshot_body: row.snapshot_body };
    }
  }
  return bodies;
}

function taskIdentityKey(home, id) {
  return `${home || 'main'}\u0000${id}`;
}

function decisionIdentityKey(row) {
  return `${taskIdentityKey(row.home, row.id)}\u0000${row.digest || row.at}`;
}

function taskModeFromMeta(stateDir, id) {
  const file = path.join(stateDir, `${id}.meta`);
  if (!regularFile(file)) return null;
  const fields = {};
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const match = line.match(/^([A-Za-z0-9_.-]+)=(.*)$/);
    if (match) fields[match[1]] = match[2];
  }
  return fields.delivery || fields.mode || null;
}

function taskCardMetadata(page) {
  const body = fs.readFileSync(page, 'utf8');
  const match = body.match(/^<!-- fm-history:task:v1 ([A-Za-z0-9+/=]+) -->$/m);
  if (!match) return null;
  try { return JSON.parse(Buffer.from(match[1], 'base64').toString('utf8')); }
  catch { return null; }
}

function taskCard(historyDir, stateDir, dataDir, homeDir, snapshotFile, decisionsFile, id, cleanupCompleted) {
  return withHistoryLock(stateDir, () => taskCardLocked(historyDir, stateDir, dataDir, homeDir, snapshotFile, decisionsFile, id, cleanupCompleted));
}

function taskCardLocked(historyDir, stateDir, dataDir, homeDir, snapshotFile, decisionsFile, id, cleanupCompleted) {
  if (!/^[A-Za-z0-9._:-]{1,200}$/.test(id)) fail('task id contains unsupported characters');
  const taskDir = path.join(historyDir, 'tasks');
  ensureDirectory(historyDir);
  ensureDirectory(taskDir);
  const file = path.join(taskDir, `${id}.md`);
  assertRegularOrMissing(file, 'task card');
  if (regularFile(file)) {
    updateIndex(historyDir);
    process.stdout.write(`task card already exists: data/history/tasks/${id}.md\n`);
    return;
  }
  const snapshot = readJsonFile(snapshotFile, 'backlog snapshot');
  const row = (snapshot.backlog?.records || snapshot.records || []).find((item) => item && item.id === id && item.structured) || null;
  const briefPath = path.join(dataDir, id, 'brief.md');
  let intent = 'No task instructions were preserved when this task was cleaned up.';
  if (regularFile(briefPath)) {
    const brief = fs.readFileSync(briefPath, 'utf8');
    const intentStart = brief.indexOf("## Captain's intent");
    if (intentStart >= 0) {
      const intentTail = brief.slice(intentStart).replace(/^## Captain's intent\s*\n/, '');
      const intentEnd = intentTail.search(/^#{1,2}\s/m);
      intent = (intentEnd < 0 ? intentTail : intentTail.slice(0, intentEnd)).trimEnd();
    }
  }
  const metaPath = path.join(stateDir, `${id}.meta`);
  const statusPath = path.join(stateDir, `${id}.status`);
  const meta = {};
  if (regularFile(metaPath)) {
    for (const line of fs.readFileSync(metaPath, 'utf8').split(/\r?\n/)) {
      const match = line.match(/^([A-Za-z0-9_.-]+)=(.*)$/);
      if (match) meta[match[1]] = match[2];
    }
  }
  const statusLines = regularFile(statusPath) ? fs.readFileSync(statusPath, 'utf8').split(/\r?\n/) : [];
  const events = statusLines.filter((line) => /^(?:done|needs-decision|resolved|blocked|paused):/.test(line) || /https?:\/\/\S+/.test(line));
  const home = homeIdentity(homeDir);
  const mode = meta.delivery || meta.mode || row?.delivery || '';
  const prUrl = meta.pr || row?.pr_url || null;
  const reportPath = row?.report_path || (regularFile(path.join(dataDir, id, 'report.md')) ? `data/${id}/report.md` : null);
  const localNote = mode === 'local-only' ? 'local main' : row?.local_note || null;
  const kind = row?.kind || meta.kind || null;
  const recordedVerb = row?.completion && row.completion.verb;
  const doneEvidence = cleanupCompleted
    || row?.state === 'done'
    || (row?.hold_kind !== 'captain' && events.some((line) => line.startsWith('done:')));
  if (!doneEvidence) {
    process.stdout.write(`task card skipped; no terminal completion evidence: ${id}\n`);
    return;
  }
  const verb = ['merged', 'landed', 'done', 'reported'].includes(recordedVerb)
    ? recordedVerb
    : kind === 'scout' && reportPath ? 'reported'
      : mode === 'local-only' ? 'done' : prUrl ? 'merged' : 'done';
  const completionDate = validDate(row?.completion && row.completion.date) ? row.completion.date : currentLocalDate();
  const project = row?.repo || repoFromUrl(prUrl) || (home !== 'main' ? home : null);
  const title = cleanTaskTitle(row?.title || meta.title || id) || id;
  const decisions = readDecisionBodies(decisionsFile);
  const decisionBody = decisions[id];
  const decisionRecords = decisionBody
    ? decisionRows(decisionBody.snapshot_body, decisionBody.body, id, project, title, home, null)
    : [];
  const metadata = {
    schema: 'fm-history-task.v1', id, title, project, home, kind, mode,
    completion: { verb, date: completionDate }, via: prUrl ? 'pull_request' : 'local',
    pr_url: prUrl, report_path: reportPath, local_note: localNote, decisions: decisionRecords,
  };
  const fence = '`'.repeat(Math.max(3, maxBacktickRun(intent) + 1));
  const outcome = events.filter((line) => line.startsWith('done:')).slice(-1)[0] || (reportPath ? `Report: ${reportPath}` : '');
  const lines = [
    `# ${title}`, '', `<!-- fm-history:task:v1 ${Buffer.from(JSON.stringify(metadata)).toString('base64')} -->`,
    `- Task: ${id}`, `- Project: ${project || 'unclassified'}`, `- Home: ${home}`,
    `- Delivery: ${mode || 'unspecified'}`, `- Completed: ${metadata.completion.date}`,
    '', "## Captain's intent", '', `${fence}text`, intent, fence, '',
    '## Status events', '', ...(events.length ? events.map((event) => `- ${event}`) : ['- (no terminal status event recorded)']),
    '', '## Final outcome', '', outcome || '(no final outcome recorded)',
  ];
  if (reportPath) lines.push('', `Report: ${reportPath}`);
  if (decisionRecords.length) {
    lines.push('', "## Captain's decisions", '');
    for (const decision of decisionRecords) {
      const decisionFence = '`'.repeat(Math.max(3, maxBacktickRun(decision.words) + 1));
      lines.push(`### ${decision.at} (${decision.mode})`, '', `${decisionFence}text`, decision.words, decisionFence, '');
    }
  }
  writeAtomic(file, `${lines.join('\n')}\n`);
  updateIndex(historyDir);
  process.stdout.write(`wrote data/history/tasks/${id}.md\n`);
}

function logbookEntries(snapshot, historyDir, decisionBodies, date, home, stateDir) {
  const main = (snapshot.backlog?.records || snapshot.records || []).filter((row) => row && row.structured);
  const secondmate = (snapshot.secondmate_landed?.records || []).filter((row) => row && row.id);
  const cardsDir = path.join(historyDir, 'tasks');
  const cards = [];
  if (fs.existsSync(cardsDir) && fs.lstatSync(cardsDir).isDirectory() && !fs.lstatSync(cardsDir).isSymbolicLink()) {
    for (const ent of fs.readdirSync(cardsDir, { withFileTypes: true })) {
      if (ent.isFile() && !ent.isSymbolicLink() && ent.name.endsWith('.md')) {
        const metadata = taskCardMetadata(path.join(cardsDir, ent.name));
        if (metadata?.schema === 'fm-history-task.v1') cards.push(metadata);
      }
    }
  }
  const cardByIdentity = new Map(cards.map((card) => [taskIdentityKey(card.home, card.id), card]));
  const taskRows = [
    ...main.map((row) => {
      const card = cardByIdentity.get(taskIdentityKey(home, row.id));
      return { ...row, home, mode: row.mode || taskModeFromMeta(stateDir, row.id) || card?.mode || null };
    }),
    ...secondmate.map((row) => ({ ...row, state: 'done', home: row.home_id || row.home || 'unknown', mode: row.mode || null })),
  ];
  const present = new Set(taskRows.map((row) => `${row.home}\u0000${row.id}`));
  for (const card of cards) if (!present.has(`${card.home || 'main'}\u0000${card.id}`)) {
    taskRows.push({
      id: card.id, title: card.title, repo: card.project, home: card.home || 'main',
      kind: card.kind, mode: card.mode || null, pr_url: card.pr_url, report_path: card.report_path,
      local_note: card.local_note, completion: card.completion, state: 'done', structured: true,
    });
  }

  const landedById = new Map();
  const reportsById = new Map();
  const decisionById = new Map();
  for (const row of taskRows) {
    const id = safeId(row.id, '');
    if (!id) continue;
    const completion = row.completion || {};
    const rowHome = row.home || 'main';
    const prUrl = typeof row.pr_url === 'string' && row.pr_url ? row.pr_url : null;
    const project = row.repo || repoFromUrl(prUrl) || (rowHome !== 'main' ? rowHome : null);
    const title = cleanTaskTitle(row.title || id);
    if (!title) continue;
    if (completion.date !== date) continue;
    const identity = taskIdentityKey(rowHome, id);
    if (completion.verb === 'reported' && row.report_path) {
      reportsById.set(identity, { id, project, title, kind: row.kind || null, mode: row.mode || row.delivery_mode || null, report_path: row.report_path, home: rowHome });
    } else if (['merged', 'landed', 'done'].includes(completion.verb)
      && row.state === 'done' && row.kind !== 'captain' && row.hold_kind !== 'captain') {
      const via = prUrl ? 'pull_request' : 'local';
      landedById.set(identity, { id, project, title, kind: row.kind || null, mode: row.mode || row.delivery_mode || null, via, pr_url: prUrl, home: rowHome, order: Number.isSafeInteger(row.order) ? row.order : Number.MAX_SAFE_INTEGER });
    }
    if (rowHome === home) {
      const decisionBody = decisionBodies[id];
      if (decisionBody) {
        for (const decision of decisionRows(decisionBody.snapshot_body, decisionBody.body, id, project, title, rowHome, date)) {
          decisionById.set(decisionIdentityKey(decision), decision);
        }
      }
    }
  }
  for (const card of cards) {
    for (const decision of card.decisions || []) {
      if (decision && decision.at && timestampParts(decision.at)?.day === date) {
        decisionById.set(decisionIdentityKey(decision), decision);
      }
    }
  }
  const landedIdentities = new Set([...landedById.values()].map((row) => taskIdentityKey(row.home, row.id)));
  for (const [identity, row] of reportsById) {
    if (landedIdentities.has(taskIdentityKey(row.home, row.id))) reportsById.delete(identity);
  }
  const orderedRows = (map) => [...map.values()].sort((a, b) =>
    (a.order ?? Number.MAX_SAFE_INTEGER) - (b.order ?? Number.MAX_SAFE_INTEGER) || a.id.localeCompare(b.id));
  const landed = orderedRows(landedById).map(({ order, prior, ...row }, index) => ({ ...row, order: index + 1 }));
  const reports = orderedRows(reportsById).map((row, index) => ({ ...row, order: index + 1 }));
  const decisions = [...decisionById.values()].sort((a, b) => a.at.localeCompare(b.at) || a.id.localeCompare(b.id))
    .map((row, index) => ({ ...row, order: index + 1 }));

  const openIds = new Map();
  const openOmitted = [];
  const addOpenId = (identityHome, id) => {
    const safe = safeId(id, '');
    if (!safe) return;
    const rowHome = identityHome || 'main';
    openIds.set(taskIdentityKey(rowHome, safe), `${rowHome}/${safe}`);
  };
  let running = 0;
  let waitingOnYou = 0;
  for (const row of main) {
    if (row.state !== 'done' && row.id) addOpenId(home, row.id);
    if (row.state === 'in_flight') running++;
    if (row.state !== 'done' && row.hold_kind === 'captain') waitingOnYou++;
  }
  for (const mate of snapshot.secondmate_current?.records || []) {
    const counts = mate.counts || {};
    const mateHome = mate.id || mate.home_id || 'unknown';
    running += Number.isInteger(counts.active_children) ? counts.active_children : 0;
    waitingOnYou += Number.isInteger(counts.decisions_open) ? counts.decisions_open : 0;
    for (const child of mate.active_children || []) addOpenId(mateHome, child.id);
    for (const decision of mate.decisions_open || []) addOpenId(mateHome, decision.id);
    for (const row of mate.queued || []) addOpenId(mateHome, row.id);
    for (const omitted of mate.omitted || []) {
      if (['active_children', 'decisions_open', 'queued'].includes(omitted.surface)
        && Number.isSafeInteger(omitted.count) && omitted.count > 0) {
        openOmitted.push({ home: mateHome, surface: omitted.surface, count: omitted.count });
      }
    }
  }
  const record = {
    schema: 'fm-logbook.v1', date, tz: HOME_TIME_ZONE, closed: date < currentLocalDate(),
    generated: new Date().toISOString(), landed, reports, decisions,
    open: {
      running, waiting_on_you: waitingOnYou,
      ids: [...openIds.values()].sort(),
      omitted: openOmitted.sort((a, b) => a.home.localeCompare(b.home) || a.surface.localeCompare(b.surface)),
    },
  };
  return record;
}

function renderLogbook(record) {
  const lines = ['## Logbook', '', `Local date: ${record.date} (${record.tz})`, ''];
  if (record.landed.length) {
    lines.push(`### Landed (${record.landed.length})`, '');
    for (const row of record.landed) lines.push(`- ${row.title} (${row.project || 'unclassified'}) - task ${row.id}, kind ${row.kind || 'unknown'}, mode ${row.mode || 'unspecified'}, home ${row.home}; ${row.via === 'pull_request' ? `pull request ${row.pr_url}` : 'local landing'}`);
    lines.push('');
  }
  if (record.reports.length) {
    lines.push(`### Reports (${record.reports.length})`, '');
    for (const row of record.reports) lines.push(`- ${row.title} (${row.project || 'unclassified'}) - task ${row.id}, kind ${row.kind || 'unknown'}, mode ${row.mode || 'unspecified'}, home ${row.home}; ${row.report_path}`);
    lines.push('');
  }
  if (record.decisions.length) {
    lines.push(`### Captain decisions (${record.decisions.length})`, '');
    for (const row of record.decisions) {
      const decisionFence = '`'.repeat(Math.max(3, maxBacktickRun(row.words) + 1));
      lines.push(`- ${row.title} (${row.project || 'unclassified'}) - task ${row.id}, ${row.mode}, ${row.at}`, '', `${decisionFence}text`, row.words, decisionFence, '');
    }
  }
  lines.push('### Still open', '', `- In flight: ${record.open.running}`, `- Waiting on you: ${record.open.waiting_on_you}`);
  if (record.open.ids.length) lines.push(`- Task ids: ${record.open.ids.join(', ')}`);
  for (const omitted of record.open.omitted || []) {
    lines.push(`- Not individually listed: ${omitted.count} ${omitted.surface} item(s) from ${omitted.home}`);
  }
  return lines.join('\n');
}

function upsertLogbookMarkdown(historyDir, date, record) {
  const daysDir = path.join(historyDir, 'days');
  ensureDirectory(historyDir);
  ensureDirectory(daysDir);
  const file = path.join(daysDir, `${date}.md`);
  assertRegularOrMissing(file, 'journal page');
  let content = regularFile(file) ? fs.readFileSync(file, 'utf8') : `# Conversation history - ${date}\n\n`;
  const startMarker = '<!-- fm-history:logbook:start -->';
  const endMarker = '<!-- fm-history:logbook:end -->';
  const section = `${startMarker}\n${renderLogbook(record)}\n${endMarker}\n`;
  const lines = content.split('\n');
  const outside = outsideFenceLineIndexes(lines);
  const startLine = [...outside].find((index) => lines[index] === startMarker) ?? -1;
  const endLine = startLine < 0 ? -1 : [...outside].find((index) => index > startLine && lines[index] === endMarker) ?? -1;
  const offsets = [];
  let position = 0;
  for (const line of lines) {
    offsets.push(position);
    position += line.length + 1;
  }
  const start = startLine < 0 ? -1 : offsets[startLine];
  const end = endLine < 0 ? -1 : offsets[endLine];
  if (start !== -1 && end >= start) content = `${content.slice(0, start)}${section}${content.slice(end + endMarker.length).replace(/^\n*/, '')}`;
  else {
    const header = `# Conversation history - ${date}\n`;
    if (!content.startsWith(header)) content = `${header}\n${content.replace(/^#.*\n(?:\n)?/, '')}`;
    content = `${content.replace(/\n*$/, '\n\n')}${section}`;
  }
  writeAtomic(file, content);
}

function mergeRows(newRows, oldRows, identity = (row) => taskIdentityKey(row.home, row.id)) {
  const merged = new Map((oldRows || []).map((row) => [identity(row), row]));
  for (const row of newRows || []) merged.set(identity(row), row);
  return [...merged.values()];
}

function logbookPrepare(historyDir, homeDir, snapshotFile, decisionsFile, date, stateDir, rebuild) {
  if (!validDate(date)) fail(`invalid Logbook date: ${date}`);
  if (date > currentLocalDate()) fail('Logbook date cannot be in the future');
  const snapshot = readJsonFile(snapshotFile, 'fleet snapshot');
  const decisionBodies = readDecisionBodies(decisionsFile);
  const target = path.join(historyDir, 'days', `${date}.logbook.json`);
  let previous = null;
  assertRegularOrMissing(target, 'Logbook file');
  if (regularFile(target)) previous = readJsonFile(target, 'existing Logbook');
  if (previous?.closed === true && !rebuild) {
    withHistoryLock(stateDir, () => {
      upsertLogbookMarkdown(historyDir, date, previous);
      updateIndex(historyDir);
    });
    process.stdout.write(JSON.stringify({ skip: 'closed', date, record: previous }));
    return;
  }
  const record = logbookEntries(snapshot, historyDir, decisionBodies, date, homeIdentity(homeDir), stateDir);
  if (previous) {
    record.landed = mergeRows(record.landed, previous.landed);
    record.reports = mergeRows(record.reports, previous.reports).filter((row) => !record.landed.some((landed) => taskIdentityKey(landed.home, landed.id) === taskIdentityKey(row.home, row.id)));
    record.decisions = mergeRows(record.decisions, previous.decisions, decisionIdentityKey);
    if (!record.open) record.open = previous.open;
  }
  process.stdout.write(JSON.stringify({ skip: null, date, rebuild, record }));
}

function closeOlderLogbooks(historyDir, exceptDate) {
  const daysDir = path.join(historyDir, 'days');
  if (!fs.existsSync(daysDir)) return;
  const dirStat = fs.lstatSync(daysDir);
  if (!dirStat.isDirectory() || dirStat.isSymbolicLink()) return;
  for (const ent of fs.readdirSync(daysDir, { withFileTypes: true })) {
    const match = ent.name.match(/^(\d{4}-\d{2}-\d{2})\.logbook\.json$/);
    if (!match || !ent.isFile() || ent.isSymbolicLink() || match[1] >= currentLocalDate() || match[1] === exceptDate) continue;
    const file = path.join(daysDir, ent.name);
    const older = readJsonFile(file, 'older Logbook');
    if (older.closed !== true) {
      older.closed = true;
      older.generated = new Date().toISOString();
      writeAtomic(file, `${JSON.stringify(older)}\n`);
    }
    upsertLogbookMarkdown(historyDir, older.date, older);
  }
}

function logbookFinalize(historyDir, stateDir, recordFile, rebuild) {
  return withHistoryLock(stateDir, () => logbookFinalizeLocked(historyDir, stateDir, recordFile, rebuild));
}

function logbookFinalizeLocked(historyDir, stateDir, recordFile, rebuild) {
  const record = readJsonFile(recordFile, 'logbook record');
  if (record.schema !== 'fm-logbook.v1' || !validDate(record.date)) fail('invalid Logbook record');
  const target = path.join(historyDir, 'days', `${record.date}.logbook.json`);
  ensureDirectory(historyDir);
  ensureDirectory(path.dirname(target));
  assertRegularOrMissing(target, 'Logbook file');
  let previous = null;
  if (regularFile(target)) previous = readJsonFile(target, 'existing Logbook');
  if (previous && previous.closed === true && !rebuild) {
    process.stdout.write(`Logbook is closed: ${record.date}; use --rebuild to replace it\n`);
    return;
  }
  const sameContent = (a, b) => {
    const left = { ...a }; const right = { ...b };
    delete left.generated; delete right.generated;
    return JSON.stringify(left) === JSON.stringify(right);
  };
  if (previous) {
    record.landed = mergeRows(record.landed, previous.landed);
    record.reports = mergeRows(record.reports, previous.reports).filter((row) => !record.landed.some((landed) => taskIdentityKey(landed.home, landed.id) === taskIdentityKey(row.home, row.id)));
    record.decisions = mergeRows(record.decisions, previous.decisions, decisionIdentityKey);
    record.open = record.open || previous.open;
  }
  record.closed = record.closed === true || record.date < currentLocalDate();
  if (previous && sameContent(previous, record)) record.generated = previous.generated;
  const serialized = `${JSON.stringify(record)}\n`;
  if (previous && fs.readFileSync(target, 'utf8') === serialized) {
    process.stdout.write(`Logbook unchanged: ${record.date}\n`);
  } else {
    writeAtomic(target, serialized);
    process.stdout.write(`wrote data/history/days/${record.date}.logbook.json\n`);
  }
  upsertLogbookMarkdown(historyDir, record.date, record);
  closeOlderLogbooks(historyDir, record.date);
  updateIndex(historyDir);
}

const [mode, ...args] = process.argv.slice(2);
try {
  if (mode === 'capture') capture(args[0], args[1], args[2], args[3] === '1');
  else if (mode === 'wakes') wakeBatch(args[0], args[1], args[2], args[3], args[4]);
  else if (mode === 'wake-ack') wakeAcknowledgement(args[0], args[1], args[2], args[3], args[4]);
  else if (mode === 'recent') {
    const n = Number.parseInt(args[1], 10);
    recent(args[0], Number.isInteger(n) && n > 0 ? n : 5);
  } else if (mode === 'task') taskCard(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7] === '1');
  else if (mode === 'logbook-prepare') logbookPrepare(args[0], args[1], args[2], args[3], args[4], args[5], args[6] === '1');
  else if (mode === 'logbook-finalize') logbookFinalize(args[0], args[1], args[2], args[3] === '1');
  else fail('unknown internal operation');
} catch (err) {
  fail(err && err.message ? err.message : String(err), 1);
}
NODE
}

cmd_capture() {
  local transcript='' compaction=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --transcript)
        [ "$#" -ge 2 ] || die '--transcript needs a path'
        transcript=$2
        shift 2
        ;;
      --compaction) compaction=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unexpected capture argument: $1" ;;
    esac
  done
  [ -n "$transcript" ] || die 'capture requires --transcript <path>'
  run_history_node capture "$transcript" "$HISTORY_DIR" "$STATE_DIR" "$compaction"
}

cmd_wakes() {
  [ "$#" -eq 6 ] && [ "$1" = --rows-file ] && [ "$3" = --ack-through ] && [ "$5" = --actor ] \
    || { usage; die 'wakes requires --rows-file, --ack-through, and --actor'; }
  case "$4" in ''|*[!0-9]*) die 'wake acknowledgement number must be a non-negative integer' ;; esac
  case "$6" in main|branch) : ;; *) die 'wake actor must be main or branch' ;; esac
  run_history_node wakes "$HISTORY_DIR" "$STATE_DIR" "$2" "$4" "$6"
}

cmd_wake_ack() {
  [ "$#" -eq 3 ] || { usage; die 'wake-ack requires a sequence, row count, and actor'; }
  case "$1" in ''|*[!0-9]*) die 'wake acknowledgement number must be a non-negative integer' ;; esac
  case "$2" in ''|*[!0-9]*) die 'wake acknowledgement row count must be a non-negative integer' ;; esac
  case "$3" in main|branch) : ;; *) die 'wake actor must be main or branch' ;; esac
  run_history_node wake-ack "$HISTORY_DIR" "$STATE_DIR" "$1" "$2" "$3"
}

HISTORY_TMP_DIR=
history_tmp_cleanup() {
  [ -n "$HISTORY_TMP_DIR" ] || return 0
  rm -rf -- "$HISTORY_TMP_DIR"
  HISTORY_TMP_DIR=
}

history_tmp_start() {
  [ ! -L "$STATE_DIR" ] || die "state directory is a symlink: $STATE_DIR"
  (umask 077; mkdir -p "$STATE_DIR") || die "cannot create state directory: $STATE_DIR"
  HISTORY_TMP_DIR=$(umask 077; mktemp -d "${STATE_DIR%/}/.history-operation.XXXXXX") \
    || die 'cannot create private temporary history directory'
  trap history_tmp_cleanup EXIT
  trap 'history_tmp_cleanup; exit 1' HUP INT TERM
}

history_snapshot() {
  local destination=$1
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$destination" \
    || die 'could not read the structured fleet snapshot'
}

history_decision_bodies() {
  local snapshot_file=$1 destination=$2 rows row id snapshot_body show encoded body
  rows=$(jq -c '
    def has_resolution_header($lines):
      ($lines // []) as $rows
      | any($rows | to_entries[];
          . as $entry
          | (
              (($entry.value // "") | test("^Resolution recorded by fm-(captain|decision)-hold\\.$"))
              and (($rows[$entry.key + 1] // "") | test("^Decision digest: [a-f0-9]{64}$"))
              and (($rows[$entry.key + 2] // "") | test("^Resolution mode: [a-z-]+$"))
              and (($rows[$entry.key + 3] // "") | test("^Resolved: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
              and ($rows[$entry.key + 4] == "Captain decision:")
            )
        );
    [((.backlog.records // .records) // [])[]?
      | select(.structured == true and has_resolution_header(.body_lines))
      | {id, snapshot_body:(.body_lines // [] | join("\n"))}][]?
  ' "$snapshot_file") || die 'could not find recorded captain answers'
  : > "$destination"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -r '.id') || die 'could not read a captain-answer task id'
    snapshot_body=$(printf '%s' "$row" | jq -r '.snapshot_body') || die "could not read the snapshot resolution for $id"
    show=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA_DIR" \
      "$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" --full 2>/dev/null) \
      || die "could not read the recorded captain answer for $id"
    encoded=$(printf '%s\n' "$show" | awk 'substr($0, 1, 8) == "  body: " { print substr($0, 9); found=1 } END { if (!found) exit 1 }') \
      || die "the backlog answer for $id has no full body"
    case "$encoded" in
      \"*) body=$(printf '%s' "$encoded" | jq -r '.') || die "could not decode the recorded answer for $id" ;;
      -) body= ;;
      *) body=$encoded ;;
    esac
    jq -nc --arg id "$id" --arg snapshot_body "$snapshot_body" --arg body "$body" \
      '{id:$id,snapshot_body:$snapshot_body,body:$body}' >> "$destination" \
      || die "could not stage the recorded answer for $id"
  done <<< "$rows"
}

cmd_task() {
  [ "$#" -ge 1 ] || { usage; die 'task requires one task id'; }
  local id=$1 cleanup_completed=0
  shift
  if [ "$#" -gt 0 ]; then
    [ "$#" -eq 1 ] && [ "$1" = --completed ] || { usage; die 'task accepts only the --completed cleanup flag'; }
    cleanup_completed=1
  fi
  case "$id" in ''|*[!A-Za-z0-9._:-]*) die 'task id contains unsupported characters' ;; esac
  history_tmp_start
  local snapshot_file="$HISTORY_TMP_DIR/backlog.json" decisions_file="$HISTORY_TMP_DIR/decisions.jsonl"
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --backlog-json > "$snapshot_file" \
    || die 'could not read the structured backlog snapshot'
  history_decision_bodies "$snapshot_file" "$decisions_file"
  run_history_node task "$HISTORY_DIR" "$STATE_DIR" "$DATA_DIR" "$FM_HOME" \
    "$snapshot_file" "$decisions_file" "$id" "$cleanup_completed"
}

cmd_logbook() {
  local date='' rebuild=0 snapshot_file decisions_file prepared skip record
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --date)
        [ "$#" -ge 2 ] || die '--date needs a YYYY-MM-DD value'
        date=$2
        shift 2
        ;;
      --date=*) date=${1#--date=}; shift ;;
      --rebuild) rebuild=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unexpected logbook argument: $1" ;;
    esac
  done
  if [ -n "$date" ]; then
    case "$date" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;; *) die '--date must be YYYY-MM-DD' ;; esac
  else
    date=$(date +%Y-%m-%d 2>/dev/null) || die 'could not determine the local date'
  fi
  command -v jq >/dev/null 2>&1 || die 'jq is required'
  history_tmp_start
  snapshot_file="$HISTORY_TMP_DIR/fleet.json"
  decisions_file="$HISTORY_TMP_DIR/decisions.jsonl"
  history_snapshot "$snapshot_file"
  history_decision_bodies "$snapshot_file" "$decisions_file"
  prepared=$(run_history_node logbook-prepare "$HISTORY_DIR" "$FM_HOME" "$snapshot_file" "$decisions_file" "$date" "$STATE_DIR" "$rebuild") \
    || die 'could not prepare the daily Logbook'
  skip=$(printf '%s' "$prepared" | jq -r '.skip // ""') || die 'could not inspect the daily Logbook'
  if [ "$skip" = closed ]; then
    printf 'Logbook is already closed; use --rebuild to replace it\n'
    return 0
  fi
  record=$(printf '%s' "$prepared" | jq -c '.record') || die 'could not read the prepared Logbook'
  printf '%s\n' "$record" > "$HISTORY_TMP_DIR/logbook.json"
  run_history_node logbook-finalize "$HISTORY_DIR" "$STATE_DIR" \
    "$HISTORY_TMP_DIR/logbook.json" "$rebuild"
}

cmd_recent() {
  local n=5
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --n)
        [ "$#" -ge 2 ] || die '--n needs a value'
        n=$2
        shift 2
        ;;
      --n=*) n=${1#--n=}; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  case "$n" in
    ''|*[!0-9]*|0) die '--n must be an integer from 1 to 50' ;;
  esac
  [ "$n" -le 50 ] || die '--n must be an integer from 1 to 50'
  run_history_node recent "$HISTORY_DIR" "$n"
}

hash_query() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  else
    cksum | awk '{ print $1 "-" $2 }'
  fi
}

log_jev_find() {
  local payload=$1
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  fm_jev_log_call "$payload" "$STATE_DIR/jev-history-find.jsonl" >/dev/null 2>&1 || true
}

cmd_find() {
  [ "$#" -eq 1 ] || { usage; die 'find requires one query argument'; }
  local query=$1 results candidates state questions response_file response code=0 choice confidence probs ranking=bm25 fallback=off ordered json now hash
  case "$query" in *$'\n'*|*$'\r'*) die 'query must be one line' ;; esac
  [ -n "${query//[[:space:]]/}" ] || die 'query is empty'
  [ "${#query}" -le 300 ] || die 'query must be at most 300 characters'
  [ -d "$HISTORY_DIR" ] || {
    printf 'history-find:\n  ranking: bm25\n  candidates: none\n  journal: %s\n' "$HISTORY_DIR"
    return 0
  }
  command -v jq >/dev/null 2>&1 || die 'jq is required'
  results=$(FM_MEMORY_DIR="$HISTORY_DIR" FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-memory.sh" recall --json --limit 100 "$query" 2>/dev/null) \
    || die 'local BM25 search failed'
  candidates=$(printf '%s' "$results" | jq -c '
    [.documents[]?
      | select(.path | startswith("days/") or startswith("tasks/"))
      | {path, score, title}
    ] | unique_by(.path) | .[:24]
  ' 2>/dev/null) || die 'could not read local BM25 results'
  [ -n "$candidates" ] || candidates='[]'
  local count
  count=$(printf '%s' "$candidates" | jq 'length') || die 'could not count history results'

  if [ "$count" -ge 2 ] && fm_jev_key_configured; then
    local offer
    offer=$(printf '%s' "$candidates" | jq -c '
      [.[] | . as $row | (.path | split("/")) as $parts
        | {id:($row.path | sub("\\.md$"; "")),
           date:(if $parts[0] == "days" then $parts[1] else null end),
           kind:(if $parts[0] == "days" then "day" else "task" end),
           title:($row.title | .[0:120])}]
    ') || offer='[]'
    state=$(jq -nc --argjson candidates "$offer" '{candidates: $candidates}') || state=
    if [ -n "$state" ] && state=$(fm_jev_compact_state "$state"); then
      questions=$(printf '%s' "$offer" | jq -c '
        {match: {
          type: "choice",
          instructions: "Choose from the locally BM25-ranked pages using only their page id, date, kind, and title. The original query and page contents are unavailable. Pick none? when metadata does not support a choice.",
          criteria: (reduce .[] as $row ({}; .[$row.id] = ([$row.kind, ($row.date // "undated"), $row.title] | join(" - "))) + {"none?": "No offered history page fits from its metadata."})
        }}
      ') || questions=
      response_file=$(mktemp "${TMPDIR:-/tmp}/fm-history-jev-response.XXXXXX" 2>/dev/null) || response_file=
      if [ -n "$questions" ] && [ -n "$response_file" ]; then
        fm_jev_decide "$state" "$questions" > "$response_file" || code=$?
        response=$(cat "$response_file" 2>/dev/null)
        rm -f "$response_file"
        fallback=error
        if [ "$code" -eq 0 ] && [ -n "$response" ]; then
          choice=$(printf '%s' "$response" | jq -r '.answers.match.choice // empty' 2>/dev/null)
          confidence=$(printf '%s' "$response" | jq -r '.answers.match.confidence | select(type == "number") // empty' 2>/dev/null)
          if [ "$choice" = 'none?' ]; then
            fallback=no-match
          elif printf '%s' "$offer" | jq -e --arg id "$choice" 'any(.[]; .id == $id)' >/dev/null 2>&1 \
            && fm_jev_choice_confidence_ok "$confidence"; then
            ranking=jev
            fallback=none
            probs=$(printf '%s' "$response" | jq -c '.answers.match.probabilities // empty' 2>/dev/null)
            if [ -n "$probs" ] && fm_jev_probabilities_sum_ok "$probs" \
              && jq -en --argjson p "$probs" --argjson o "$offer" \
                'all($p | keys[]; . as $key | $key == "none?" or any($o[]; .id == $key))' >/dev/null 2>&1; then
              ordered=$(printf '%s' "$candidates" | jq -c --argjson p "$probs" \
                'map(. + {confidence: ($p[(.path | sub("\\.md$"; ""))] // 0)})
                 | map(select(.confidence > 0)) | sort_by(-.confidence)') || ordered=
            else
              ordered=$(printf '%s' "$candidates" | jq -c --arg id "$choice" \
                'sort_by(if (.path | sub("\\.md$"; "")) == $id then 0 else 1 end)') || ordered=
            fi
            [ -n "$ordered" ] || { ranking=bm25; fallback=error; }
          else
            fallback=low-confidence
          fi
        fi
        now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)
        hash=$(printf '%s' "$query" | hash_query)
        json=$(jq -nc --arg ts "$now" --arg hash "$hash" --arg choice "${choice:-}" \
          --arg confidence "${confidence:-}" --arg ranking "$ranking" --arg fallback "$fallback" \
          --arg route "${FM_JEV_LAST_ROUTE:-}" --arg http "${FM_JEV_LAST_HTTP:-}" \
          --arg latency "${FM_JEV_LAST_LATENCY_MS:-}" --argjson candidates "$offer" \
          --argjson code "$code" '{purpose:"history-find", advisory:true,
            query_sha256:$hash, candidates:[$candidates[].id],
            choice:(if $choice == "" then null else $choice end),
            confidence:(try ($confidence|tonumber) catch null), ranking:$ranking,
            fallback:$fallback, route:$route, http:$http,
            latency_ms:(try ($latency|tonumber) catch null), decide_code:$code, ts:$ts}') || json=
        [ -z "$json" ] || log_jev_find "$json"
      else
        [ -z "$response_file" ] || rm -f "$response_file"
        fallback=error
      fi
    else
      fallback=error
    fi
  elif [ "$count" -eq 0 ]; then
    fallback=no-candidates
  elif [ "$count" -eq 1 ]; then
    fallback=single-candidate
  fi

  if [ "$ranking" != jev ] || [ -z "${ordered:-}" ]; then ordered=$candidates; fi
  printf 'history-find:\n  ranking: %s\n  fallback: %s\n' "$ranking" "$fallback"
  if [ "$count" -eq 0 ]; then
    printf '  candidates: none\n'
  else
    printf '  candidates:\n'
    printf '%s' "$ordered" | jq -r --argjson max 3 '
      .[:$max] | to_entries[]
      | "    \(.key + 1). data/history/\(.value.path) score=\(.value.score) title=\(.value.title)"
    '
  fi
  printf '  journal: %s\n' "$HISTORY_DIR"
}

cmd=${1:-}
case "$cmd" in
  ''|-h|--help) usage; [ -n "$cmd" ] || exit 2; exit 0 ;;
esac
shift
case "$cmd" in
  capture) cmd_capture "$@" ;;
  wakes) cmd_wakes "$@" ;;
  wake-ack) cmd_wake_ack "$@" ;;
  recent) cmd_recent "$@" ;;
  find) cmd_find "$@" ;;
  task) cmd_task "$@" ;;
  logbook) cmd_logbook "$@" ;;
  *) usage; die "unknown command: $cmd" ;;
esac
