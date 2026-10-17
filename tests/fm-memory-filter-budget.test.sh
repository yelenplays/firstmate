#!/usr/bin/env bash
# Regressions for short factual turns and the complete NOW output budget.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || fail 'node is required for memory regressions'
TMP_ROOT=$(fm_test_tmproot fm-memory-filter-budget)

short_facts() {
  node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { buildUnits } from './bin/fm-memory-capture.mjs';
const facts = ["I'm vegan.", 'Use tabs.', 'I moved.', 'No dairy.', 'Rust.'];
const turns = facts.map((captain, i) => ({ id: `fact-${i}`, captain, reply: 'Noted.' }));
const result = buildUnits(turns, new Set(['Captain, shipshape.']));
assert.deepEqual(result.units.map((unit) => unit.captain), facts,
  'short factual turns must remain eligible for extraction');
assert.equal(result.dropped, 0);
const acknowledgements = ['ok', 'Thanks!', 'yes', 'merge it', 'Captain, shipshape.'];
const filtered = buildUnits(acknowledgements.map((captain) => ({ captain })),
  new Set(['Captain, shipshape.']));
assert.equal(filtered.units.length, 0, 'recognized acknowledgements must still be dropped');
const reply = buildUnits([{ captain: "I'm vegan.", reply: 'Captain, shipshape.' }],
  new Set(['Captain, shipshape.']));
assert.equal(reply.units[0].reply, '', 'configured no-op replies must still be stripped');
JS
  pass 'short facts survive while recognized acknowledgements are dropped'
}

now_budget() {
  export FM_HOME="$TMP_ROOT/home" FM_MEMORY_DIR="$TMP_ROOT/memories"
  local mem="$ROOT/bin/fm-memory.sh" body i cap out
  body=$(printf '%585s' '' | tr ' ' x)
  for i in {1..11}; do
    "$mem" remember --category now "Entry $i" "$body" >/dev/null
  done
  out=$("$mem" now)
  printf '%s\n' "$out" > "$TMP_ROOT/now.txt"
  node --input-type=module - "$TMP_ROOT/now.txt" <<'JS'
import assert from 'node:assert/strict';
import fs from 'node:fs';
const text = fs.readFileSync(process.argv[2], 'utf8');
assert.ok(text.length <= 6000, `default NOW cap exceeded: ${text.length} characters`);
assert.match(text, /more now\/ entries omitted by the size cap/);
assert.match(text, /- Entry /, 'the block must retain entries that fit');
JS
  for cap in 0 1 20 45 60 620 1000; do
    "$mem" now --max-chars "$cap" > "$TMP_ROOT/now.txt"
    node --input-type=module - "$TMP_ROOT/now.txt" "$cap" <<'JS'
import assert from 'node:assert/strict';
import fs from 'node:fs';
const text = fs.readFileSync(process.argv[2], 'utf8');
const cap = Number(process.argv[3]);
assert.ok(text.length <= cap, `NOW cap ${cap} exceeded: ${text.length} characters`);
if (cap >= 60) assert.match(text, /more now\/ entries omitted by the size cap/);
JS
  done
  pass 'NOW entries and omission notice share the character budget'
}

case "${1:-all}" in
  short-facts) short_facts ;;
  now-budget) now_budget ;;
  all) short_facts; now_budget ;;
  *) fail 'expected short-facts, now-budget, or all' ;;
esac
