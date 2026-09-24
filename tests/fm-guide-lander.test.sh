#!/usr/bin/env bash
# Behavior tests for bin/fm-guide-lander.sh: the guide draft header parse
# (bin/fm-wiki-lib.sh fm_wiki_guide_header) as seen through `pending`, lane
# assignment per estate cloud flag, secondmate home scanning, and mark-filed
# receipts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-guide-lander)
HOME_DIR="$TMP_ROOT/home"
MATE_DIR="$TMP_ROOT/mate"
WIKIS="$TMP_ROOT/wikis"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/config" "$MATE_DIR/data" "$WIKIS/routing"
HOME_DIR=$(cd "$HOME_DIR" && pwd -P)
MATE_DIR=$(cd "$MATE_DIR" && pwd -P)
TAB=$(printf '\t')

cat > "$WIKIS/routing/estate.json" <<EOF
{"schema": 1, "vaults": [
  {"wiki": "OpenWiki", "id": "open-wiki", "path": "$WIKIS/OpenWiki", "cloud": "ja", "modus": "voll"},
  {"wiki": "Digest Wiki", "id": "digest-wiki", "path": "$WIKIS/Digest Wiki", "cloud": "nur-digest", "modus": "voll"},
  {"wiki": "PointerWiki", "id": "pointer-wiki", "path": "$WIKIS/PointerWiki", "cloud": "nein", "modus": "pointer"},
  {"wiki": "LockedWiki", "id": "locked-wiki", "path": "$WIKIS/LockedWiki", "cloud": "ja", "modus": "pointer"},
  {"wiki": "OddWiki", "id": "odd-wiki", "path": "$WIKIS/OddWiki", "cloud": "vielleicht", "modus": "voll"}
]}
EOF

cat > "$HOME_DIR/data/secondmates.md" <<EOF
# Secondmates
- mate - local fixture (home: $MATE_DIR; scope: tests; projects: app; added 2026-01-01)
- far - remote fixture (host: example-host; root: /srv/fm; home: /srv/fm-home; scope: far; projects: app; added 2026-01-01)
- gone - missing fixture (home: $TMP_ROOT/missing; scope: gone; projects: app; added 2026-01-01)
EOF

draft() {  # <data-dir> <task-id> <content>
  mkdir -p "$1/$2"
  printf '%s' "$3" > "$1/$2/guide.md"
}

lander() {
  FM_ROOT_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$HOME_DIR" FM_WIKIS_ROOT="${LANDER_WIKIS-$WIKIS}" "$ROOT/bin/fm-guide-lander.sh" "$@"
}

draft "$HOME_DIR/data" a-open $'target: OpenWiki\ntopic: tmux-panes\naction: new\n\nbody\n'
draft "$HOME_DIR/data" b-digest $'\n  topic: cache-keys\r\naction: update guides/cache.md\ntarget: digest-wiki\n'
draft "$HOME_DIR/data" c-pointer $'target: pointer-wiki\ntopic: x\naction: new\n'
draft "$HOME_DIR/data" d-locked $'target: LockedWiki\ntopic: y\naction: new\n'
draft "$HOME_DIR/data" e-odd $'target: OddWiki\ntopic: z\naction: new\n'
draft "$HOME_DIR/data" f-nowhere $'target: Nowhere Wiki\ntopic: q\naction: new\n'
draft "$HOME_DIR/data" g-none $'no guide: config-only change\n'
draft "$HOME_DIR/data" g-empty-reason $'no guide:   \n'
draft "$HOME_DIR/data" g-missing-space $'no guide:reason\n'
draft "$HOME_DIR/data" h-filed $'target: OpenWiki\ntopic: done\naction: new\n'
printf 'commit: abcdef1\n' > "$HOME_DIR/data/h-filed/guide.filed"
draft "$HOME_DIR/data" i-badtopic $'target: OpenWiki\ntopic: Not A Slug\naction: new\n'
draft "$HOME_DIR/data" j-badaction $'target: OpenWiki\ntopic: ok\naction: rewrite\n'
draft "$HOME_DIR/data" k-legacy $'Target vault OpenWiki, topic foo, new, cloud ja\n'
draft "$HOME_DIR/data" l-repeat $'target: OpenWiki\ntarget: digest-wiki\ntopic: ok\n'
draft "$MATE_DIR/data" m-mate $'target: open-wiki\ntopic: mate-guide\naction: new\n'

test_pending_lists_each_lane_and_skips_filed_and_no_guide() {
  local out err expected
  out=$(lander pending 2>"$TMP_ROOT/pending.err") || fail "pending failed"
  err=$(cat "$TMP_ROOT/pending.err")
  expected=$(printf '%s\n' \
    "$HOME_DIR${TAB}a-open${TAB}OpenWiki${TAB}$WIKIS/OpenWiki${TAB}ja${TAB}bulk" \
    "$HOME_DIR${TAB}b-digest${TAB}digest-wiki${TAB}$WIKIS/Digest Wiki${TAB}nur-digest${TAB}private" \
    "$HOME_DIR${TAB}c-pointer${TAB}pointer-wiki${TAB}$WIKIS/PointerWiki${TAB}nein${TAB}private" \
    "$HOME_DIR${TAB}d-locked${TAB}LockedWiki${TAB}$WIKIS/LockedWiki${TAB}ja${TAB}private" \
    "$HOME_DIR${TAB}e-odd${TAB}OddWiki${TAB}$WIKIS/OddWiki${TAB}vielleicht${TAB}private" \
    "$HOME_DIR${TAB}f-nowhere${TAB}Nowhere Wiki${TAB}-${TAB}-${TAB}unresolved" \
    "$HOME_DIR${TAB}g-empty-reason${TAB}-${TAB}-${TAB}-${TAB}invalid" \
    "$HOME_DIR${TAB}g-missing-space${TAB}-${TAB}-${TAB}-${TAB}invalid" \
    "$HOME_DIR${TAB}i-badtopic${TAB}-${TAB}-${TAB}-${TAB}invalid" \
    "$HOME_DIR${TAB}j-badaction${TAB}-${TAB}-${TAB}-${TAB}invalid" \
    "$HOME_DIR${TAB}k-legacy${TAB}-${TAB}-${TAB}-${TAB}invalid" \
    "$HOME_DIR${TAB}l-repeat${TAB}-${TAB}-${TAB}-${TAB}invalid" \
    "$MATE_DIR${TAB}m-mate${TAB}open-wiki${TAB}$WIKIS/OpenWiki${TAB}ja${TAB}bulk" \
    | LC_ALL=C sort -t "$TAB" -k1,1 -k2,2)
  assert_equals "$expected" "$out" "pending rows differ"
  assert_contains "$err" "skipping remote secondmate far on example-host" "remote home was not skipped with a notice"
  assert_contains "$err" "skipping secondmate gone" "missing home was not skipped with a notice"
  assert_contains "$err" "topic is not a kebab-case slug" "bad topic reason missing"
  assert_contains "$err" "action is neither new nor update" "bad action reason missing"
  assert_contains "$err" "header repeats target" "repeated key reason missing"
  assert_contains "$err" "no-guide reason is empty" "empty no-guide reason was accepted"
  assert_contains "$err" "header line 1 is not target, topic, or action" "missing no-guide space was accepted"
  pass "pending lists every lane, skips filed and no-guide drafts, and flags bad headers"
}

test_unconfigured_is_inert() {
  local out err
  out=$(LANDER_WIKIS='' lander pending 2>"$TMP_ROOT/inert.err") || fail "unconfigured pending failed"
  err=$(cat "$TMP_ROOT/inert.err")
  assert_equals "" "$out" "unconfigured pending printed rows"
  assert_contains "$err" "no wikis root configured" "unconfigured notice missing"
  pass "an unconfigured home lists nothing"
}

test_mark_filed_is_idempotent() {
  local out first rc
  out=$(lander mark-filed "$MATE_DIR" m-mate 0123abc) || fail "mark-filed failed"
  assert_contains "$out" "filed $MATE_DIR/m-mate at 0123abc" "mark-filed did not confirm"
  first=$(cat "$MATE_DIR/data/m-mate/guide.filed")
  assert_contains "$first" "commit: 0123abc" "receipt lacks the commit"
  out=$(lander mark-filed "$MATE_DIR" m-mate fedcba9) || fail "second mark-filed failed"
  assert_contains "$out" "already filed" "second mark-filed did not report already filed"
  assert_equals "$first" "$(cat "$MATE_DIR/data/m-mate/guide.filed")" "second mark-filed changed the receipt"
  out=$(lander pending 2>/dev/null)
  assert_not_contains "$out" "m-mate" "a filed draft is still pending"

  lander mark-filed "$HOME_DIR" g-none 0123abc >/dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "a no-guide draft was marked filed"
  [ ! -e "$HOME_DIR/data/g-none/guide.filed" ] || fail "a no-guide draft gained a receipt"
  lander mark-filed "$HOME_DIR" g-empty-reason 0123abc >/dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "an empty no-guide reason was marked filed"
  [ ! -e "$HOME_DIR/data/g-empty-reason/guide.filed" ] || fail "an empty-reason draft gained a receipt"
  lander mark-filed "$HOME_DIR" a-open not-a-commit >/dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "a bad commit was accepted"
  lander mark-filed "$TMP_ROOT" a-open 0123abc >/dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "an unregistered home was accepted"
  lander mark-filed "$HOME_DIR" ../a-open 0123abc >/dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "a traversing task id was accepted"
  pass "mark-filed writes one receipt, keeps it on repeat, and refuses bad input"
}

test_symlinked_task_dir_or_draft_is_refused() {
  local out err rc outside="$TMP_ROOT/outside"
  draft "$TMP_ROOT" outside $'target: OpenWiki\ntopic: linked\naction: new\n'
  ln -s "$outside" "$HOME_DIR/data/n-linkdir"
  mkdir -p "$HOME_DIR/data/o-linkdraft"
  ln -s "$outside/guide.md" "$HOME_DIR/data/o-linkdraft/guide.md"
  out=$(lander pending 2>"$TMP_ROOT/link.err") || fail "pending failed with a symlink"
  err=$(cat "$TMP_ROOT/link.err")
  assert_not_contains "$out" "n-linkdir" "a symlinked task directory was listed"
  assert_not_contains "$out" "o-linkdraft" "a symlinked draft was listed"
  assert_contains "$err" "skipping $HOME_DIR/data/n-linkdir/guide.md: symlinked" "no notice for a symlinked task directory"
  assert_contains "$err" "skipping $HOME_DIR/data/o-linkdraft/guide.md: symlinked" "no notice for a symlinked draft"
  for id in n-linkdir o-linkdraft; do
    err=$(lander mark-filed "$HOME_DIR" "$id" 0123abc 2>&1 >/dev/null); rc=$?
    assert_equals 2 "$rc" "mark-filed accepted symlinked $id"
    assert_contains "$err" "symlinked task directory or draft" "mark-filed gave no clear refusal for $id"
  done
  [ ! -e "$outside/guide.filed" ] || fail "mark-filed wrote through a symlink"
  [ ! -e "$HOME_DIR/data/o-linkdraft/guide.filed" ] || fail "mark-filed wrote a receipt beside a symlinked draft"
  rm -f "$HOME_DIR/data/n-linkdir"; rm -rf "$HOME_DIR/data/o-linkdraft"
  pass "a symlinked task directory or draft is skipped by pending and refused by mark-filed"
}

test_pending_lists_each_lane_and_skips_filed_and_no_guide
test_symlinked_task_dir_or_draft_is_refused
test_unconfigured_is_inert
test_mark_filed_is_idempotent
