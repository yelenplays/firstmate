#!/usr/bin/env bash
# Behavior tests for bin/fm-memory-migrate.sh.
#
# Builds a fixture OpenViking workspace (memories tree, sessions, internals)
# and drives migrate + verify end to end. No launchd, no network; the fixture
# lives entirely in the test temp root.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-memory-migrate)
HOME_DIR="$TMP_ROOT/home"
SRC="$TMP_ROOT/ov-data"
STORE="$HOME_DIR/data/memories"
ARCHIVE="$HOME_DIR/data/memory-archive"
mkdir -p "$HOME_DIR/config" \
  "$SRC/user/default/memories/preferences" \
  "$SRC/user/default/memories/entities" \
  "$SRC/user/default/sessions" \
  "$SRC/user/default/wiki-layer" \
  "$SRC/resources" \
  "$SRC/_system/queue" \
  "$SRC/vectordb/context/store" \
  "$SRC/logs"
export FM_HOME=$HOME_DIR
unset FM_MEMORY_DIR FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_OV_HOME

printf '# tea\nThe captain drinks green tea\n' > "$SRC/user/default/memories/preferences/tea.md"
printf '# soul\nvalues brevity\n' > "$SRC/user/default/memories/soul.md"
printf '# acme\nAcme Corp is a client\n' > "$SRC/user/default/memories/entities/acme.md"
printf 'session transcript one\n' > "$SRC/user/default/sessions/s1.md"
printf 'session transcript two\n' > "$SRC/user/default/sessions/s2.md"
printf 'wiki layer page\n' > "$SRC/user/default/wiki-layer/w1.md"
printf 'shared resource\n' > "$SRC/resources/r1.md"
printf 'queue row bytes\n' > "$SRC/_system/queue/q.md"
printf 'vector blob\n' > "$SRC/vectordb/context/store/v.md"
printf 'noise\n' > "$SRC/_system/queue/not-markdown.bin"
printf 'server stdout\n' > "$SRC/logs/server.log"

MIG="$ROOT/bin/fm-memory-migrate.sh"

# --- dry-run writes nothing ---------------------------------------------------

out=$("$MIG" migrate --source "$SRC" --dry-run)
assert_contains "$out" '3 files' 'dry-run counts three memories'
assert_not_contains "$out" 'migrated:' 'dry-run performs no migration'
assert_absent "$STORE/preferences/tea.md" 'dry-run wrote a file'

# --- migrate: memories land, other markdown archives, internals skipped -------

out=$("$MIG" migrate --source "$SRC")
assert_contains "$out" 'all hashes verified' 'migrate reports verification'
assert_present "$STORE/preferences/tea.md" 'memory migrated into category dir'
assert_present "$STORE/soul.md" 'root memory migrated'
assert_present "$STORE/entities/acme.md" 'entity migrated'
assert_present "$ARCHIVE/user/default/sessions/s1.md" 'session archived'
assert_present "$ARCHIVE/user/default/wiki-layer/w1.md" 'wiki-layer archived'
assert_present "$ARCHIVE/resources/r1.md" 'resource archived'
assert_absent "$ARCHIVE/_system/queue/q.md" '_system markdown skipped'
assert_absent "$ARCHIVE/vectordb/context/store/v.md" 'vectordb markdown skipped'
assert_absent "$ARCHIVE/logs/server.log" 'logs skipped (not markdown anyway)'

# source is untouched
assert_present "$SRC/user/default/memories/preferences/tea.md" 'source memory still present'
assert_present "$SRC/_system/queue/q.md" 'source internals untouched'

# dest content is byte-identical to source
src_sum=$(shasum -a 256 "$SRC/user/default/memories/preferences/tea.md" | awk '{print $1}')
dst_sum=$(shasum -a 256 "$STORE/preferences/tea.md" | awk '{print $1}')
assert_equals "$src_sum" "$dst_sum" 'migrated file hash matches source'

# manifest exists and verify passes standalone
manifest=$(find "$STORE/.migration" -name 'manifest-*.txt' | sort | tail -n1)
assert_present "$manifest" 'manifest written'
out=$("$MIG" verify)
assert_contains "$out" 'verified' 'standalone verify passes'
assert_contains "$out" '7/7' 'verify counts every exported file'

# migrated memories are searchable through fm-memory.sh
out=$("$ROOT/bin/fm-memory.sh" recall 'green tea')
assert_contains "$out" 'preferences/tea.md' 'migrated memory is recallable'

# --- verify detects loss ------------------------------------------------------

rm "$ARCHIVE/resources/r1.md"
rc=0; out=$("$MIG" verify 2>/dev/null) || rc=$?
expect_code 1 "$rc" 'verify fails when a file is missing'
assert_contains "$out" 'missing' 'verify reports the missing file'

# --- re-run is idempotent and heals -------------------------------------------

out=$("$MIG" migrate --source "$SRC")
assert_contains "$out" 'all hashes verified' 're-run re-verifies'
assert_present "$ARCHIVE/resources/r1.md" 're-run restores the missing file'

# --- error paths ----------------------------------------------------------------

rc=0; "$MIG" migrate --source "$TMP_ROOT/no-such" >/dev/null 2>&1 || rc=$?
expect_code 3 "$rc" 'missing source'

empty_src="$TMP_ROOT/empty-src"; mkdir -p "$empty_src"
rc=0; "$MIG" migrate --source "$empty_src" >/dev/null 2>&1 || rc=$?
expect_code 3 "$rc" 'no memories tree found'

rc=0; "$MIG" migrate --bogus >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" 'unknown option'

pass 'fm-memory-migrate behavior suite'
