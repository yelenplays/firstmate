#!/usr/bin/env bash
# fm-history.sh - capture and retrieve the primary conversation journal.
#
# Usage:
#   fm-history.sh capture --transcript <path>
#   fm-history.sh recent [--n <count>]
#   fm-history.sh find <query>
#   fm-history.sh task <id>
#   fm-history.sh logbook [--date <YYYY-MM-DD>] [--rebuild]
#
# Capture reads Claude or Pi JSONL transcripts deterministically. Only captain
# messages and final assistant replies are journaled; tool results, internal
# operational messages, and thinking blocks are not. The private pages live under
# $FM_HOME/data/history, with generated task cards, daily Logbooks, index.md,
# and a disposable BM25 cache. The byte cursor and capture lock live under
# $FM_HOME/state.
#
# `find` searches pages locally through fm-memory.sh. If Jev is configured, it
# receives the query and bounded page ids/titles only, never page contents.
# `logbook` offers only candidate ids, kinds and titles to Jev, never answers,
# URLs, report paths or page contents; a deterministic local rule remains the fallback.
# `days/<date>.md` stores transcript records and the generated daily Logbook
# section; `tasks/<id>.md` is create-once and embeds `fm-history-task.v1`
# metadata: schema, id, title, project, home, kind, mode, completion, via,
# pr_url, report_path, local_note and digest-verified decisions. The daily JSON is
# `fm-logbook.v1` with schema, date, tz, closed, generated, landed, reports,
# decisions, open and highlight. The generated `index.md` lists page paths/titles.
# `state/.history-cursor` is `fm-history-cursor.v1` with schema, transcript,
# dev, ino, offset and pending {id, day, time}; `.history.lock` holds only the owner pid.
# `state/jev-logbook-highlight.jsonl` and `state/jev-history-find.jsonl` contain
# metadata-only Jev records, with search queries stored only as SHA-256 digests.
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
  fm-history.sh capture --transcript <path>
  fm-history.sh recent [--n <count>]
  fm-history.sh find <query>
  fm-history.sh task <id>
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

function markerExists(content, wanted) {
  let fenceChar = '';
  let fenceSize = 0;
  for (const line of content.split('\n')) {
    if (fenceChar) {
      const close = new RegExp(`^${fenceChar}{${fenceSize},}\\s*$`);
      if (close.test(line)) {
        fenceChar = '';
        fenceSize = 0;
      }
      continue;
    }
    if (line === wanted) return true;
    const open = line.match(/^(`{3,}|~{3,})/);
    if (open) {
      fenceChar = open[1][0];
      fenceSize = open[1].length;
    }
  }
  return false;
}

function renderRecord(role, id, turnId, time, text) {
  const fence = '`'.repeat(Math.max(3, maxBacktickRun(text) + 1));
  const label = role === 'captain' ? 'captain' : 'firstmate';
  const marker = recordMarker(role, id, turnId, text);
  const separator = text.endsWith('\n') ? '' : '\n';
  return `${marker}\n### ${time} ${label}\n${fence}text\n${text}${separator}${fence}\n\n`;
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

function capture(transcript, historyDir, stateDir) {
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
    if (cursor.transcript !== transcriptPath || cursor.dev !== st.dev || cursor.ino !== st.ino || st.size < offset) {
      offset = 0;
      pending = null;
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
          if ((type === 'assistant' || piRole === 'assistant') && pending
            && !(rec && (rec.isSidechain || (rec.message && rec.message.isSidechain)))) {
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
    };
    updateIndex(historyDir);
    writeAtomic(cursorFile, `${JSON.stringify(nextCursor)}\n`, 0o600, false);
    if (badLines) process.stderr.write(`fm-history: skipped ${badLines} malformed transcript line(s)\n`);
    process.stdout.write(`captured ${captainCount} captain message(s) and ${replyCount} final reply/replies\n`);
  } finally {
    releaseHistoryLock(lockDir);
  }
}

function parsePageRecords(file, rel) {
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  const rows = [];
  const markerRe = /^<!-- fm-history:(captain|firstmate) id=([A-Za-z0-9._:-]+)(?: turn=([A-Za-z0-9._:-]+))? trailing-newline=([01]) -->$/;
  for (let i = 0; i < lines.length; i++) {
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

function resolutionSignatures(body) {
  if (typeof body !== 'string') return [];
  const marker = /(?:^|\n)Resolution recorded by fm-(?:captain|decision)-hold\./g;
  const starts = [];
  let match;
  while ((match = marker.exec(body)) !== null) starts.push(match.index + (match[0][0] === '\n' ? 1 : 0));
  const signatures = [];
  for (let index = 0; index < starts.length; index++) {
    const start = starts[index];
    const end = starts[index + 1] === undefined ? body.length : starts[index + 1];
    const block = body.slice(start, end);
    const mode = block.match(/^Resolution mode: ([a-z-]+)\s*$/m)?.[1];
    const at = block.match(/^Resolved: (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s*$/m)?.[1];
    const digest = block.match(/^Decision digest: ([a-f0-9]{64})\s*$/m)?.[1];
    if (mode && at && digest) signatures.push({ mode, at, digest, block });
  }
  return signatures;
}

function decisionRows(snapshotBody, body, id, project, title, home, targetDate) {
  const snapshot = new Set(resolutionSignatures(snapshotBody).map(({ mode, at, digest }) => `${mode}\u0000${at}\u0000${digest}`));
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

function logbookCandidateId(kind, row) {
  return row.id;
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

function taskCard(historyDir, stateDir, dataDir, homeDir, snapshotFile, decisionsFile, id) {
  return withHistoryLock(stateDir, () => taskCardLocked(historyDir, stateDir, dataDir, homeDir, snapshotFile, decisionsFile, id));
}

function taskCardLocked(historyDir, stateDir, dataDir, homeDir, snapshotFile, decisionsFile, id) {
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
  const doneEvidence = row ? row.state === 'done' : events.some((line) => line.startsWith('done:'));
  const verb = ['merged', 'landed', 'done', 'reported'].includes(recordedVerb)
    ? recordedVerb
    : row?.hold_kind === 'captain' ? 'retained'
      : !doneEvidence ? 'unknown'
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
    ...secondmate.map((row) => ({ ...row, home: row.home_id || row.home || 'unknown', mode: row.mode || null })),
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
    if (!project) continue;
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

  const openIds = new Set();
  let running = 0;
  let waitingOnYou = 0;
  for (const row of main) {
    if (row.state === 'in_flight') { running++; openIds.add(row.id); }
    if (row.state !== 'done' && row.hold_kind === 'captain') { waitingOnYou++; openIds.add(row.id); }
  }
  for (const mate of snapshot.secondmate_current?.records || []) {
    const counts = mate.counts || {};
    running += Number.isInteger(counts.active_children) ? counts.active_children : 0;
    waitingOnYou += Number.isInteger(counts.decisions_open) ? counts.decisions_open : 0;
    for (const child of mate.active_children || []) if (child.id) openIds.add(child.id);
    for (const decision of mate.decisions_open || []) if (decision.id) openIds.add(decision.id);
  }
  const record = {
    schema: 'fm-logbook.v1', date, tz: HOME_TIME_ZONE, closed: date < currentLocalDate(),
    generated: new Date().toISOString(), landed, reports, decisions,
    open: { running, waiting_on_you: waitingOnYou, ids: [...openIds].sort() },
    highlight: { id: null, by: 'rule', confidence: null },
  };
  const candidates = [];
  for (const [kind, entries] of [['landed', landed], ['report', reports], ['decision', decisions]]) {
    for (const entry of entries) {
      if (entry.home !== 'main') continue;
      const candidateId = logbookCandidateId(kind, entry);
      if (candidates.some((candidate) => candidate.id === candidateId)) continue;
      candidates.push({ id: candidateId, kind, title: entry.title });
    }
  }
  const fallback = landed.find((entry) => entry.via === 'pull_request') || landed[0] || reports[0] || decisions[0];
  if (fallback) {
    const kind = landed.includes(fallback) ? 'landed' : reports.includes(fallback) ? 'report' : 'decision';
    record.highlight.id = logbookCandidateId(kind, fallback);
  }
  return { record, candidates };
}

function renderLogbook(record) {
  const lines = ['## Logbook', '', `Local date: ${record.date} (${record.tz})`, ''];
  if (record.landed.length) {
    lines.push(`### Landed (${record.landed.length})`, '');
    for (const row of record.landed) lines.push(`- ${row.title} (${row.project}) - task ${row.id}, kind ${row.kind || 'unknown'}, mode ${row.mode || 'unspecified'}, home ${row.home}; ${row.via === 'pull_request' ? `pull request ${row.pr_url}` : 'local landing'}`);
    lines.push('');
  }
  if (record.reports.length) {
    lines.push(`### Reports (${record.reports.length})`, '');
    for (const row of record.reports) lines.push(`- ${row.title} (${row.project}) - task ${row.id}, kind ${row.kind || 'unknown'}, mode ${row.mode || 'unspecified'}, home ${row.home}; ${row.report_path}`);
    lines.push('');
  }
  if (record.decisions.length) {
    lines.push(`### Captain decisions (${record.decisions.length})`, '');
    for (const row of record.decisions) {
      const decisionFence = '`'.repeat(Math.max(3, maxBacktickRun(row.words) + 1));
      lines.push(`- ${row.title} (${row.project}) - task ${row.id}, ${row.mode}, ${row.at}`, '', `${decisionFence}text`, row.words, decisionFence, '');
    }
  }
  const highlight = record.highlight?.id && [
    ...record.landed.filter((row) => row.home === 'main').map((row) => ({ ...row, candidate_id: logbookCandidateId('landed', row) })),
    ...record.reports.filter((row) => row.home === 'main').map((row) => ({ ...row, candidate_id: logbookCandidateId('report', row) })),
    ...record.decisions.filter((row) => row.home === 'main').map((row) => ({ ...row, candidate_id: logbookCandidateId('decision', row) })),
  ].find((row) => row.candidate_id === record.highlight.id);
  if (highlight) lines.push('### Highlight', '', `- ${highlight.title} (${highlight.project}) - task ${highlight.id}`, '');
  lines.push('### Still open', '', `- In flight: ${record.open.running}`, `- Waiting on you: ${record.open.waiting_on_you}`);
  if (record.open.ids.length) lines.push(`- Task ids: ${record.open.ids.join(', ')}`);
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
  const start = content.indexOf(startMarker);
  const end = content.indexOf(endMarker);
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
    process.stdout.write(JSON.stringify({ skip: 'closed', date, record: previous, candidates: [] }));
    return;
  }
  const { record, candidates } = logbookEntries(snapshot, historyDir, decisionBodies, date, homeIdentity(homeDir), stateDir);
  if (previous) {
    record.landed = mergeRows(record.landed, previous.landed);
    record.reports = mergeRows(record.reports, previous.reports).filter((row) => !record.landed.some((landed) => taskIdentityKey(landed.home, landed.id) === taskIdentityKey(row.home, row.id)));
    record.decisions = mergeRows(record.decisions, previous.decisions, decisionIdentityKey);
    if (!record.open) record.open = previous.open;
  }
  const entries = [...record.landed, ...record.reports, ...record.decisions];
  if (!entries.length && !previous) {
    process.stdout.write(JSON.stringify({ skip: 'quiet', date, record, candidates: [] }));
    return;
  }
  const visibleIds = new Set(candidates.map((entry) => entry.id));
  for (const [kind, entries] of [['landed', record.landed], ['report', record.reports], ['decision', record.decisions]]) {
    for (const entry of entries) {
      const candidateId = logbookCandidateId(kind, entry);
      if (entry.home !== 'main' || visibleIds.has(candidateId)) continue;
      candidates.push({ id: candidateId, kind, title: entry.title });
      visibleIds.add(candidateId);
    }
  }
  const candidateSet = candidates.map(({ id, kind, title }) => ({ id, kind, title }))
    .sort((a, b) => a.id.localeCompare(b.id) || a.kind.localeCompare(b.kind) || a.title.localeCompare(b.title));
  const hash = crypto.createHash('sha256').update(JSON.stringify(candidateSet), 'utf8').digest('hex');
  process.stdout.write(JSON.stringify({ skip: null, date, rebuild, record, candidates, candidate_set_hash: hash }));
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
    if (older.closed === true) continue;
    older.closed = true;
    older.generated = new Date().toISOString();
    writeAtomic(file, `${JSON.stringify(older)}\n`);
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
  if (!record.landed.length && !record.reports.length && !record.decisions.length && !previous) {
    closeOlderLogbooks(historyDir, record.date);
    process.stdout.write(`quiet day; no Logbook written: ${record.date}\n`);
    return;
  }
  if (previous) {
    record.landed = mergeRows(record.landed, previous.landed);
    record.reports = mergeRows(record.reports, previous.reports).filter((row) => !record.landed.some((landed) => taskIdentityKey(landed.home, landed.id) === taskIdentityKey(row.home, row.id)));
    record.decisions = mergeRows(record.decisions, previous.decisions, decisionIdentityKey);
    record.open = record.open || previous.open;
    if (!record.highlight?.id && previous.highlight?.id) record.highlight = previous.highlight;
  }
  record.closed = record.closed === true || record.date < currentLocalDate();
  if (previous && sameContent(previous, record)) record.generated = previous.generated;
  const serialized = `${JSON.stringify(record)}\n`;
  if (previous && fs.readFileSync(target, 'utf8') === serialized) {
    process.stdout.write(`Logbook unchanged: ${record.date}\n`);
  } else {
    writeAtomic(target, serialized);
    upsertLogbookMarkdown(historyDir, record.date, record);
    process.stdout.write(`wrote data/history/days/${record.date}.logbook.json\n`);
  }
  closeOlderLogbooks(historyDir, record.date);
  updateIndex(historyDir);
}

const [mode, ...args] = process.argv.slice(2);
try {
  if (mode === 'capture') capture(args[0], args[1], args[2]);
  else if (mode === 'recent') {
    const n = Number.parseInt(args[1], 10);
    recent(args[0], Number.isInteger(n) && n > 0 ? n : 5);
  } else if (mode === 'task') taskCard(args[0], args[1], args[2], args[3], args[4], args[5], args[6]);
  else if (mode === 'logbook-prepare') logbookPrepare(args[0], args[1], args[2], args[3], args[4], args[5], args[6] === '1');
  else if (mode === 'logbook-finalize') logbookFinalize(args[0], args[1], args[2], args[3] === '1');
  else fail('unknown internal operation');
} catch (err) {
  fail(err && err.message ? err.message : String(err), 1);
}
NODE
}

cmd_capture() {
  [ "$#" -eq 2 ] && [ "$1" = --transcript ] || { usage; die 'capture requires --transcript <path>'; }
  [ -n "$2" ] || die 'transcript path is empty'
  run_history_node capture "$2" "$HISTORY_DIR" "$STATE_DIR"
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
    [((.backlog.records // .records) // [])[]?
      | select(.structured == true and
          any(.body_lines[]?; test("^Resolution recorded by fm-(captain|decision)-hold\\.$")))
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
  [ "$#" -eq 1 ] || { usage; die 'task requires one task id'; }
  case "$1" in ''|*[!A-Za-z0-9._:-]*) die 'task id contains unsupported characters' ;; esac
  history_tmp_start
  local snapshot_file="$HISTORY_TMP_DIR/backlog.json" decisions_file="$HISTORY_TMP_DIR/decisions.jsonl"
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --backlog-json > "$snapshot_file" \
    || die 'could not read the structured backlog snapshot'
  history_decision_bodies "$snapshot_file" "$decisions_file"
  run_history_node task "$HISTORY_DIR" "$STATE_DIR" "$DATA_DIR" "$FM_HOME" \
    "$snapshot_file" "$decisions_file" "$1"
}

cmd_logbook() {
  local date='' rebuild=0 snapshot_file decisions_file prepared skip record candidates candidate_hash
  local candidate_count fallback_id highlight_id highlight_by=rule highlight_confidence='' cached='' log_file
  local state questions response_file response choice confidence probabilities jev_rc=0 fallback=off payload
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
  candidates=$(printf '%s' "$prepared" | jq -c '.candidates // []') || candidates='[]'
  candidate_hash=$(printf '%s' "$prepared" | jq -r '.candidate_set_hash // ""') || candidate_hash=
  fallback_id=$(printf '%s' "$record" | jq -r '.highlight.id // ""') || fallback_id=
  highlight_id=$fallback_id
  candidate_count=$(printf '%s' "$candidates" | jq 'length') || candidate_count=0
  date=$(printf '%s' "$prepared" | jq -r '.date') || die 'prepared Logbook has no date'
  log_file="$STATE_DIR/jev-logbook-highlight.jsonl"
  [ ! -L "$log_file" ] || die "Jev highlight log is a symlink: $log_file"
  if [ -e "$log_file" ] && [ ! -f "$log_file" ]; then die "Jev highlight log is not a regular file: $log_file"; fi
  if [ -f "$log_file" ] && [ "$rebuild" -ne 1 ]; then
    cached=$(jq -sc --arg date "$date" --arg hash "$candidate_hash" '
      [.[] | select(.purpose == "history-logbook" and .date == $date and .candidate_set_hash == $hash)] | last // empty
    ' "$log_file" 2>/dev/null) || cached=
    if [ -n "$cached" ]; then
      highlight_id=$(printf '%s' "$cached" | jq -r '.choice // ""') || highlight_id=
      highlight_by=$(printf '%s' "$cached" | jq -r '.by // "rule"') || highlight_by=rule
      highlight_confidence=$(printf '%s' "$cached" | jq -r '.confidence // empty') || highlight_confidence=
      fallback=$(printf '%s' "$cached" | jq -r '.fallback // "cached"') || fallback=cached
    fi
  fi
  if [ -z "$cached" ] && [ "$candidate_count" -gt 1 ] && fm_jev_key_configured; then
    state=$(jq -nc --argjson candidates "$candidates" '{entries:$candidates}') \
      || state=
    if [ -n "$state" ] && state=$(fm_jev_compact_state "$state"); then
      questions=$(printf '%s' "$candidates" | jq -c '
        {highlight:{type:"choice",instructions:"Choose the one entry that best represents this day. Judge only the offered ids, kinds, and titles. Pick none? when no entry is a useful highlight.",criteria:(reduce .[] as $row ({}; .[$row.id]=$row.title) + {"none?":"No entry is a useful highlight."})}}
      ') || questions=
      response_file="$HISTORY_TMP_DIR/jev-response.json"
      if [ -n "$questions" ]; then
        fm_jev_decide "$state" "$questions" > "$response_file" || jev_rc=$?
        response=$(<"$response_file")
        choice=$(printf '%s' "$response" | jq -r '.answers.highlight.choice // empty' 2>/dev/null) || choice=
        confidence=$(printf '%s' "$response" | jq -r '.answers.highlight.confidence | select(type == "number") // empty' 2>/dev/null) || confidence=
        probabilities=$(printf '%s' "$response" | jq -c '.answers.highlight.probabilities // empty' 2>/dev/null) || probabilities=
        if [ "$jev_rc" -eq 0 ] && [ -n "$choice" ] && [ "$choice" != 'none?' ] \
          && printf '%s' "$candidates" | jq -e --arg id "$choice" 'any(.[]; .id == $id)' >/dev/null 2>&1 \
          && fm_jev_choice_confidence_ok "$confidence" \
          && [ -n "$probabilities" ] && fm_jev_probabilities_sum_ok "$probabilities" \
          && jq -en --argjson p "$probabilities" --argjson c "$candidates" \
            'all($p | keys[]; . as $id | $id == "none?" or any($c[]; .id == $id))' >/dev/null 2>&1; then
          highlight_id=$choice
          highlight_by=jev
          highlight_confidence=$confidence
          fallback=none
        else
          highlight_id=$fallback_id
          highlight_by=rule
          highlight_confidence=$confidence
          fallback=low-confidence-or-error
        fi
        payload=$(jq -nc --arg date "$date" --arg hash "$candidate_hash" \
          --arg choice "$highlight_id" --arg by "$highlight_by" \
          --arg confidence "$highlight_confidence" --arg fallback "$fallback" \
          --arg route "${FM_JEV_LAST_ROUTE:-}" --arg http "${FM_JEV_LAST_HTTP:-}" \
          --arg latency "${FM_JEV_LAST_LATENCY_MS:-}" --argjson candidates "$candidates" \
          '{purpose:"history-logbook",date:$date,candidate_set_hash:$hash,candidate_ids:[$candidates[].id],
            choice:(if $choice == "" then null else $choice end),by:$by,
            confidence:(try ($confidence|tonumber) catch null),fallback:$fallback,route:$route,http:$http,
            latency_ms:(try ($latency|tonumber) catch null)}') || payload=
        [ -z "$payload" ] || fm_jev_log_call "$payload" "$log_file" >/dev/null 2>&1 || true
      fi
    fi
  fi
  record=$(printf '%s' "$record" | jq -c --arg id "$highlight_id" --arg by "$highlight_by" \
    --arg confidence "$highlight_confidence" '
      .highlight={id:(if $id == "" then null else $id end),by:$by,
        confidence:(try ($confidence|tonumber) catch null)}
    ') || die 'could not finalize the daily highlight'
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
    offer=$(printf '%s' "$candidates" | jq -c '[.[] | {id: (.path | sub("\\.md$"; "")), title: (.title | .[0:120])}]') || offer='[]'
    state=$(jq -nc --arg query "$query" --argjson candidates "$offer" \
      '{query: $query, candidates: $candidates}') || state=
    if [ -n "$state" ] && state=$(fm_jev_compact_state "$state"); then
      questions=$(printf '%s' "$offer" | jq -c '
        {match: {
          type: "choice",
          instructions: "Choose the history page most likely to contain the captain conversation described by the query. Judge only the query and page id/date/title. Page contents are intentionally unavailable. Pick none? when no offered page fits.",
          criteria: (reduce .[] as $row ({}; .[$row.id] = $row.title) + {"none?": "No offered history page fits."})
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
  recent) cmd_recent "$@" ;;
  find) cmd_find "$@" ;;
  task) cmd_task "$@" ;;
  logbook) cmd_logbook "$@" ;;
  *) usage; die "unknown command: $cmd" ;;
esac
