#!/usr/bin/env bash
# Behavior tests for the opt-in wiki integration (bin/fm-wiki-lib.sh):
# the registry wiki token as read through bin/fm-project-mode.sh, and the
# "# Wiki context" and "# Wiki guide" sections bin/fm-brief.sh renders for ship
# and scout briefs. The teardown guide check is covered beside the scout report
# check in tests/fm-backlog-atomicity.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wiki-lib)
HOME_DIR="$TMP_ROOT/home"
WIKIS="$TMP_ROOT/wikis"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/config" "$WIKIS/routing/cards" "$WIKIS/ProjektWiki/wiki/app"
: > "$WIKIS/ProjektWiki/wiki/app/app.md"

cat > "$HOME_DIR/data/projects.md" <<'EOF'
# Projects
- app [direct-PR +yolo] [wiki: OpenWiki, Digest Wiki, PointerWiki, locked-wiki, Missing Wiki] - an app (added 2026-01-01)
- bare [wiki: open-wiki] - no mode bracket (added 2026-01-01)
- legacy - no brackets at all (added 2026-01-01)
- solo [local-only] - mode only (added 2026-01-01)
- ghost [wiki: Nowhere] - only unresolved names (added 2026-01-01)
EOF

cat > "$WIKIS/routing/estate.json" <<EOF
{"schema": 1, "vaults": [
  {"wiki": "OpenWiki", "id": "open-wiki", "path": "$WIKIS/OpenWiki", "digest": "$WIKIS/OpenWiki/digest.md", "einstieg": "index.md", "cloud": "ja", "modus": "voll", "budget_klasse": "normal"},
  {"wiki": "Digest Wiki", "id": "digest-wiki", "path": "$WIKIS/Digest Wiki", "digest": "$WIKIS/Digest Wiki/digest.md", "einstieg": "index.md", "cloud": "nur-digest", "modus": "voll", "budget_klasse": "klein"},
  {"wiki": "PointerWiki", "id": "pointer-wiki", "path": "$WIKIS/PointerWiki", "digest": null, "einstieg": "index.md", "cloud": "nein", "modus": "pointer", "budget_klasse": "klein"},
  {"wiki": "LockedWiki", "id": "locked-wiki", "path": "$WIKIS/LockedWiki", "digest": "$WIKIS/LockedWiki/digest.md", "einstieg": "index.md", "cloud": "ja", "modus": "pointer", "budget_klasse": "gross"}
]}
EOF

# assert_line <line> <file> <msg>: the file must hold exactly this line.
assert_line() {
  grep -Fx -- "$1" "$2" >/dev/null || fail "$3"
}

project_mode() {
  FM_ROOT_OVERRIDE='' FM_DATA_OVERRIDE='' FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" "$@"
}

brief() {  # <id> <repo> [flags...] ; env FM_WIKIS_ROOT selects configuration
  FM_ROOT_OVERRIDE='' FM_DATA_OVERRIDE='' FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$@" >/dev/null
}

test_registry_token_is_parsed_and_posture_is_unchanged() {
  local out
  out=$(project_mode --wikis app)
  assert_equals "$(printf '%s\n' OpenWiki 'Digest Wiki' PointerWiki locked-wiki 'Missing Wiki')" "$out" \
    "wiki token after a mode bracket did not parse, names with spaces included"
  assert_equals "direct-PR on" "$(project_mode app 2>&1)" "a wiki token changed the registered posture"
  assert_equals "open-wiki" "$(project_mode --wikis bare)" "wiki token directly after the name did not parse"
  assert_equals "no-mistakes off" "$(project_mode bare 2>&1)" \
    "a leading wiki token was mistaken for a mode bracket"
  assert_equals "" "$(project_mode --wikis legacy)" "a row with no token printed wiki names"
  assert_equals "" "$(project_mode --wikis solo)" "a mode-only row printed wiki names"
  assert_equals "" "$(project_mode --wikis absent)" "an unregistered project printed wiki names"
  assert_equals "local-only off" "$(project_mode solo 2>&1)" "a mode-only row regressed"
  pass "registry wiki token parses in both positions and leaves the posture alone"
}

test_unconfigured_briefs_carry_no_wiki_sections() {
  local b
  FM_WIKIS_ROOT='' brief u-ship app --mode no-mistakes
  FM_WIKIS_ROOT='' brief u-scout app --scout
  for b in u-ship u-scout; do
    assert_no_grep '# Wiki' "$HOME_DIR/data/$b/brief.md" "$b gained a wiki section while unconfigured"
  done
  # A configured path without routing/estate.json is not a wikis root.
  FM_WIKIS_ROOT="$TMP_ROOT" brief u-bad app --mode direct-PR
  assert_no_grep '# Wiki' "$HOME_DIR/data/u-bad/brief.md" "a root without estate.json enabled the wiki sections"
  pass "unconfigured or invalid wikis root leaves briefs unchanged"
}

test_configured_brief_renders_the_privacy_ladder() {
  local f
  FM_WIKIS_ROOT="$WIKIS" brief c-ship app --mode no-mistakes
  f="$HOME_DIR/data/c-ship/brief.md"
  assert_line '# Wiki context' "$f" "configured ship brief has no wiki context"
  assert_grep "Project page: \`$WIKIS/ProjektWiki/wiki/app/app.md\`" "$f" "existing project page was not named"
  assert_grep 'digest, then its entry page, then at most 3 further pages' "$f" "read ladder missing"
  assert_grep 'Skip any page with `private: true`' "$f" "private-page rule missing"
  assert_grep "- OpenWiki (card open-wiki, budget normal) at \`$WIKIS/OpenWiki\`: digest \`$WIKIS/OpenWiki/digest.md\`, entry page \`$WIKIS/OpenWiki/index.md\`." "$f" \
    "cloud=ja vault did not get the full ladder"
  assert_grep "- Digest Wiki (card digest-wiki, budget klein) at \`$WIKIS/Digest Wiki\`: read its digest \`$WIKIS/Digest Wiki/digest.md\` only" "$f" \
    "cloud=nur-digest vault was not limited to its digest"
  assert_grep '- PointerWiki (card pointer-wiki, budget klein): private pointer vault - name only, do not open' "$f" \
    "cloud=nein vault was not name-only"
  assert_grep '- LockedWiki (card locked-wiki, budget gross): private pointer vault' "$f" \
    "modus=pointer vault was not name-only despite cloud=ja"
  assert_no_grep "$WIKIS/PointerWiki" "$f" "a private pointer vault's path leaked into the brief"
  assert_no_grep "$WIKIS/LockedWiki" "$f" "a pointer-mode vault's path leaked into the brief"
  assert_grep 'Not in the wiki estate: Missing Wiki; pick guide targets by the routing cards' "$f" \
    "unresolved wiki name was not reported"
  assert_line '# Wiki guide' "$f" "configured ship brief has no guide step"
  assert_line 'Wiki guide contract: required' "$f" "guide marker missing"
  assert_grep "$HOME_DIR/data/c-ship/guide.md" "$f" "guide path missing"
  FM_WIKIS_ROOT="$WIKIS" brief c-scout app --scout
  f="$HOME_DIR/data/c-scout/brief.md"
  assert_line '# Wiki context' "$f" "configured scout brief has no wiki context"
  assert_line 'Wiki guide contract: required' "$f" "configured scout brief has no guide step"
  pass "configured briefs render each cloud flag, unresolved names, and the guide step"
}

test_config_file_and_missing_token_paths() {
  local f
  printf '# comment\n%s\n' "$WIKIS" > "$HOME_DIR/config/wikis-root"
  brief f-legacy legacy --mode local-only
  f="$HOME_DIR/data/f-legacy/brief.md"
  assert_grep 'The registry carries no wiki token for legacy; pick guide targets by the routing cards' "$f" \
    "config/wikis-root was not honored or the no-token line is missing"
  assert_no_grep 'Project page:' "$f" "a project page was named although none exists"
  brief f-ghost ghost --mode local-only
  f="$HOME_DIR/data/f-ghost/brief.md"
  assert_grep 'Not in the wiki estate: Nowhere' "$f" "all-unresolved token was not reported"
  assert_no_grep 'Read the backing wikis' "$f" "read ladder printed with no resolved vault"
  rm -f "$HOME_DIR/config/wikis-root"
  pass "config/wikis-root is honored and missing or unresolved tokens degrade to one line"
}

test_malformed_estate_never_fails_the_scaffold() {
  local bad="$TMP_ROOT/bad-wikis" f
  mkdir -p "$bad/routing"
  printf '{ not json' > "$bad/routing/estate.json"
  FM_WIKIS_ROOT="$bad" brief m-ship app --mode no-mistakes || fail "malformed estate failed the scaffold"
  f="$HOME_DIR/data/m-ship/brief.md"
  assert_grep "The wiki estate at \`$bad/routing/estate.json\` is unreadable" "$f" "malformed estate was not reported"
  assert_line 'Wiki guide contract: required' "$f" "malformed estate dropped the guide step"
  pass "malformed estate degrades to one line and keeps the guide step"
}

test_registry_token_is_parsed_and_posture_is_unchanged
test_unconfigured_briefs_carry_no_wiki_sections
test_configured_brief_renders_the_privacy_ladder
test_config_file_and_missing_token_paths
test_malformed_estate_never_fails_the_scaffold
