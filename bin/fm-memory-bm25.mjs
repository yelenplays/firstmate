#!/usr/bin/env node
// fm-memory-bm25.mjs - length-normalized BM25 index and query engine for the
// plain-markdown memory store.
//
// Usage:
//   fm-memory-bm25.mjs build --dir <store> [--index <file>]
//   fm-memory-bm25.mjs query --dir <store> --query <text> [--index <file>]
//                            [--limit <n>] [--json]
//   fm-memory-bm25.mjs stale --dir <store> [--index <file>]
//
// This file is the single owner of the index format, the tokenizer, the BM25
// scoring constants, and the staleness rule. docs/memory.md owns the operator
// contract; bin/fm-memory.sh owns the command surface that calls this engine.
//
// Documents are every *.md file beneath the store directory, excluding
// dotfiles, dot-directories, and the .migration/ directory. The index is a
// disposable cache at <store>/.index.json: `query` and bin/fm-memory.sh rebuild
// it whenever the stored file manifest (path -> mtime+size) no longer matches
// the tree, so a stale index can never answer from removed or edited content.
//
// `build` prints "indexed <n> documents" and exits 0. `query` prints ranked
// hits as "score\t<relpath>\t<title>" plus an indented snippet, or a JSON
// envelope with --json; it exits 0 with zero hits and 2 on usage errors.
// `stale` exits 0 when the index is missing or behind the tree, 1 when fresh;
// it exists so callers can rebuild lazily without parsing the index.

import fs from 'node:fs';
import path from 'node:path';

const INDEX_VERSION = 1;
const K1 = 1.2;
const B = 0.75;
const DEFAULT_LIMIT = 10;
const SNIPPET_RADIUS = 80;

function die(msg) {
  process.stderr.write(`bm25: ${msg}\n`);
  process.exit(2);
}

function tokenize(text) {
  return (text.toLowerCase().match(/[\p{L}\p{N}]+/gu) || []);
}

function isIndexable(rel) {
  if (!rel.toLowerCase().endsWith('.md')) return false;
  const parts = rel.split('/');
  for (const part of parts) {
    if (part.startsWith('.')) return false;
  }
  return true;
}

function walk(dir, prefix, out) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  entries.sort((a, b) => a.name.localeCompare(b.name));
  for (const entry of entries) {
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!entry.name.startsWith('.')) walk(full, rel, out);
    } else if (entry.isFile() && isIndexable(rel)) {
      out.push(rel);
    }
  }
}

function manifestOf(dir) {
  const files = [];
  walk(dir, '', files);
  const manifest = {};
  for (const rel of files) {
    const st = fs.statSync(path.join(dir, rel));
    manifest[rel] = { m: st.mtimeMs, s: st.size };
  }
  return manifest;
}

function buildIndex(dir) {
  const manifest = manifestOf(dir);
  const docs = [];
  const df = new Map();
  let totalLen = 0;
  for (const rel of Object.keys(manifest)) {
    let text = '';
    try {
      text = fs.readFileSync(path.join(dir, rel), 'utf8');
    } catch {
      continue;
    }
    const tokens = tokenize(text);
    const tf = new Map();
    for (const tok of tokens) tf.set(tok, (tf.get(tok) || 0) + 1);
    for (const tok of tf.keys()) df.set(tok, (df.get(tok) || 0) + 1);
    docs.push({ path: rel, len: tokens.length, tf: Object.fromEntries(tf) });
    totalLen += tokens.length;
  }
  return {
    version: INDEX_VERSION,
    built: new Date().toISOString(),
    manifest,
    avgLen: docs.length ? totalLen / docs.length : 0,
    docs,
    df: Object.fromEntries(df),
  };
}

function isStale(index, dir) {
  if (!index || index.version !== INDEX_VERSION) return true;
  const fresh = manifestOf(dir);
  const old = index.manifest || {};
  const newKeys = Object.keys(fresh);
  const oldKeys = Object.keys(old);
  if (newKeys.length !== oldKeys.length) return true;
  for (const rel of newKeys) {
    const o = old[rel];
    const n = fresh[rel];
    if (!o || o.m !== n.m || o.s !== n.s) return true;
  }
  return false;
}

function loadIndex(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function writeIndex(file, index) {
  const tmp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(index));
  fs.renameSync(tmp, file);
}

function bodyText(text) {
  const m = text.match(/^---\n[\s\S]*?\n---\n?/);
  return m ? text.slice(m[0].length) : text;
}

function titleOf(text, rel) {
  for (const line of bodyText(text).split('\n')) {
    const t = line.trim();
    if (!t || t === '---') continue;
    return t.replace(/^#+\s*/, '').slice(0, 120);
  }
  return rel;
}

function snippetOf(text, queryTerms) {
  text = bodyText(text);
  const lower = text.toLowerCase();
  let pos = -1;
  for (const term of queryTerms) {
    const at = lower.indexOf(term);
    if (at !== -1 && (pos === -1 || at < pos)) pos = at;
  }
  if (pos === -1) {
    const t = text.trim().replace(/\s+/g, ' ');
    return t.slice(0, SNIPPET_RADIUS * 2);
  }
  const start = Math.max(0, pos - SNIPPET_RADIUS);
  const end = Math.min(text.length, pos + SNIPPET_RADIUS);
  const prefix = start > 0 ? '...' : '';
  const suffix = end < text.length ? '...' : '';
  return (prefix + text.slice(start, end) + suffix).replace(/\s+/g, ' ');
}

function scoreDoc(doc, terms, dfMap, nDocs, avgLen) {
  let score = 0;
  for (const term of terms) {
    const tf = doc.tf[term];
    if (!tf) continue;
    const n = dfMap[term] || 0;
    const idf = Math.log(1 + (nDocs - n + 0.5) / (n + 0.5));
    const denom = tf + K1 * (1 - B + (B * doc.len) / (avgLen || 1));
    score += idf * ((tf * (K1 + 1)) / denom);
  }
  return score;
}

function parseArgs(argv) {
  const args = { limit: DEFAULT_LIMIT, json: false };
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '--dir': args.dir = argv[++i]; break;
      case '--index': args.index = argv[++i]; break;
      case '--query': args.query = argv[++i]; break;
      case '--limit': args.limit = Number.parseInt(argv[++i], 10); break;
      case '--json': args.json = true; break;
      default:
        if (a.startsWith('--')) die(`unknown option: ${a}`);
        positional.push(a);
    }
  }
  return { args, positional };
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  if (!cmd || cmd === '-h' || cmd === '--help') {
    process.stderr.write('Usage: fm-memory-bm25.mjs build|query|stale --dir <store> [--index <file>] [--query <text>] [--limit <n>] [--json]\n');
    process.exit(cmd ? 0 : 2);
  }
  const { args } = parseArgs(rest);
  if (!args.dir) die('--dir is required');
  const dir = args.dir;
  const indexFile = args.index || path.join(dir, '.index.json');

  if (cmd === 'build') {
    if (!fs.existsSync(dir)) die(`store directory not found: ${dir}`);
    const index = buildIndex(dir);
    writeIndex(indexFile, index);
    process.stdout.write(`indexed ${index.docs.length} documents\n`);
    return;
  }

  if (cmd === 'stale') {
    process.exit(isStale(loadIndex(indexFile), dir) ? 0 : 1);
  }

  if (cmd === 'query') {
    if (args.query === undefined) die('--query is required');
    if (!fs.existsSync(dir)) die(`store directory not found: ${dir}`);
    let index = loadIndex(indexFile);
    if (isStale(index, dir)) {
      index = buildIndex(dir);
      writeIndex(indexFile, index);
    }
    const terms = [...new Set(tokenize(args.query))];
    const nDocs = index.docs.length;
    const hits = [];
    if (terms.length && nDocs) {
      for (const doc of index.docs) {
        const score = scoreDoc(doc, terms, index.df, nDocs, index.avgLen);
        if (score > 0) hits.push({ doc, score });
      }
      hits.sort((a, b) => b.score - a.score || a.doc.path.localeCompare(b.doc.path));
    }
    const limit = Number.isFinite(args.limit) && args.limit > 0 ? args.limit : DEFAULT_LIMIT;
    const top = hits.slice(0, limit).map(({ doc, score }) => {
      let text = '';
      try {
        text = fs.readFileSync(path.join(dir, doc.path), 'utf8');
      } catch {
        text = '';
      }
      return {
        path: doc.path,
        score: Math.round(score * 1000) / 1000,
        title: titleOf(text, doc.path),
        snippet: snippetOf(text, terms),
      };
    });
    if (args.json) {
      process.stdout.write(`${JSON.stringify({ version: INDEX_VERSION, dir, count: top.length, documents: top })}\n`);
    } else {
      for (const hit of top) {
        process.stdout.write(`${hit.score}\t${hit.path}\t${hit.title}\n    ${hit.snippet}\n`);
      }
    }
    return;
  }

  die(`unknown command: ${cmd}`);
}

main();
