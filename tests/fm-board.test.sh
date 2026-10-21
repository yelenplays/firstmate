#!/usr/bin/env bash
# Behavior tests for the attention board (bin/fm-board.sh, bin/fm-board-lib.sh).
# Covers: a ready PR whose done signal nobody relayed stays on the board as
# ready to approve on every read; open decisions, failures, and live captain
# holds group under needs you and leave it once resolved; queued work; the
# after-merge columns (merged not live yet, live confirmed) from post-merge
# watch records, including after teardown and ignoring an earlier
# incarnation's record; a main-sync conflict at the current head moving a
# ready PR to needs you while a stale one does not; secondmate homes' boards
# (published and legacy ledgers); the home summary publishing its board; the
# session-start digest printing it (tests/fm-session-start.test.sh); and no network call on any of those paths.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

BOARD="$ROOT/bin/fm-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-board)
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"
mkdir -p "$FM_ROOT_OVERRIDE"
export FM_ROOT_OVERRIDE
export FM_SNAPSHOT_NOW=2026-10-20T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1792497600

make_fakebin() {  # <dir> - gh, curl, and tmux record every call to $NET_LOG
  local fb
  fb=$(fm_fakebin "$1")
  for tool in gh gh-axi curl; do
    cat > "$fb/$tool" <<SH
#!/usr/bin/env bash
echo "$tool \$*" >> "\$NET_LOG"
exit 1
SH
    chmod +x "$fb/$tool"
  done
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

new_home() {  # <name> -> home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

write_ship() {  # <home> <id> [extra meta k=v...]
  local home=$1 id=$2
  shift 2
  mkdir -p "$home/projects/$id"
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$home/projects/$id" "project=firstmate" "harness=claude" \
    "kind=ship" "mode=no-mistakes" "spawn_gen=s1.$id" "$@"
}

board_json() {  # <home> <fakebin> [args...]
  local home=$1 fb=$2
  shift 2
  PATH="$fb:$PATH" NET_LOG="$home/net.log" FM_HOME="$home" "$BOARD" --json "$@"
}

group_of() {  # <board-json> <id>
  printf '%s' "$1" | jq -r --arg id "$2" '[.groups | to_entries[] | .key as $g | .value[] | select(.id == $id) | $g] | join(",")'
}

field_of() {  # <board-json> <id> <field>
  printf '%s' "$1" | jq -r --arg id "$2" --arg f "$3" '[.groups[][] | select(.id == $id) | .[$f]] | first // ""'
}

FB=$(make_fakebin "$TMP_ROOT/fakebin")

# --- 1. one home: every group derived from stored state ----------------------
H=$(new_home main)
cat > "$H/data/backlog.md" <<'EOF'
## In flight
- [ ] missed-ready - Ship whose ready line nobody relayed (repo: firstmate) (kind: ship) (since 2026-10-16)
- [ ] recorded-ready - Ship with a recorded PR (repo: firstmate) (kind: ship) (since 2026-10-18)
- [ ] asks - Ship with an open question (repo: firstmate) (kind: ship) (since 2026-10-19)
- [ ] answered - Ship whose question was answered (repo: firstmate) (kind: ship) (since 2026-10-19)
- [ ] broke - Ship that failed (repo: firstmate) (kind: ship) (since 2026-10-19)
- [ ] busy - Ship still building (repo: firstmate) (kind: ship) (since 2026-10-19)
- [ ] handoff - Ship that handed off to validation (repo: firstmate) (kind: ship) (since 2026-10-19)
- [ ] local-ready - Local-only ready branch (repo: firstmate) (kind: ship) (since 2026-10-19)
- [ ] watching - Merged ship under its post-merge watch (repo: site) (kind: ship) (since 2026-10-19)
- [ ] reverting - Merged ship found broken (repo: site) (kind: ship) (since 2026-10-19)
- [ ] reused - Reused id with an earlier incarnation's record (repo: firstmate) (kind: ship) (since 2026-10-19)

## Queued
- [ ] later - Plain queued work (repo: firstmate) (kind: ship)
- [ ] after-busy - Waits for busy blocked-by: busy (repo: firstmate) (kind: ship)
- [ ] pick-one - Choose a route (repo: firstmate) (kind: captain) (hold: captain choice pending) (hold-kind: captain)

## Done
- [x] went-live - Landed and confirmed live https://github.com/acme/site/pull/40 (repo: site) (kind: ship) (merged 2026-10-18)
- [x] landed-plain - Landed without a live target https://github.com/acme/repo/pull/41 (repo: firstmate) (kind: ship) (merged 2026-10-18)
EOF
write_ship "$H" missed-ready
printf 'working: building\ndone [at=1792190000]: PR https://github.com/acme/repo/pull/150 checks green\n' > "$H/state/missed-ready.status"
write_ship "$H" recorded-ready "pr=https://github.com/acme/repo/pull/175" "pr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
printf 'done [at=1792190500]: PR https://github.com/acme/repo/pull/175 checks green\n' > "$H/state/recorded-ready.status"
write_ship "$H" asks
printf 'working: building\nneeds-decision [key=api]: keep the old flag or drop it\n' > "$H/state/asks.status"
write_ship "$H" answered
printf 'needs-decision [key=api]: keep the old flag or drop it\nresolved [key=api]: drop it\nworking: dropping it\n' > "$H/state/answered.status"
write_ship "$H" broke
printf 'failed: the build cannot run on this host\n' > "$H/state/broke.status"
write_ship "$H" busy
printf 'working: writing the parser\n' > "$H/state/busy.status"
write_ship "$H" handoff
printf 'done: implementation committed on fm/handoff\n' > "$H/state/handoff.status"
write_ship "$H" local-ready "mode=local-only"
printf 'done: ready branch fm/local-ready\n' > "$H/state/local-ready.status"
write_ship "$H" watching "pr=https://github.com/acme/site/pull/42"
printf 'done: PR https://github.com/acme/site/pull/42 checks green\n' > "$H/state/watching.status"
write_ship "$H" reverting "pr=https://github.com/acme/site/pull/43"
write_ship "$H" reused "pr=https://github.com/acme/repo/pull/44"
printf 'done: PR https://github.com/acme/repo/pull/44 checks green\n' > "$H/state/reused.status"
write_pm() {  # <home> <id> <spawn_gen> <phase> [k=v...]
  local home=$1 id=$2 gen=$3 phase=$4
  shift 4
  { printf 'version=fm-post-merge-v1\ntask=%s\nspawn_gen=%s\nkind=pr\nphase=%s\n' "$id" "$gen" "$phase"
    for kv in "$@"; do printf '%s\n' "$kv"; done; } > "$home/state/$id.post-merge"
}
write_pm "$H" watching s1.watching witness "pr=https://github.com/acme/site/pull/42" "witness=https://site.example"
write_pm "$H" reverting s1.reverting reverting "pr=https://github.com/acme/site/pull/43"
write_pm "$H" reused s0.earlier clear "witness_verdict=pass"
write_pm "$H" went-live s9.gone clear "pr=https://github.com/acme/site/pull/40" "witness=https://site.example" "witness_verdict=pass"
write_pm "$H" landed-plain s9.gone2 clear "pr=https://github.com/acme/repo/pull/41" "no_witness_reason=no live target"

OUT=$(board_json "$H" "$FB" --home-only) || fail "board --json exits zero"
assert_equals ready "$(group_of "$OUT" missed-ready)" "a done line naming a PR with no relay and no pr= is ready to approve"
assert_equals https://github.com/acme/repo/pull/150 "$(field_of "$OUT" missed-ready url)" "the missed ready row carries the reported PR URL"
assert_equals ready "$(group_of "$OUT" recorded-ready)" "a recorded pr= ship is ready to approve"
assert_equals needs_you "$(group_of "$OUT" asks)" "an open needs-decision is needs you"
assert_equals needs-decision "$(field_of "$OUT" asks reason)" "the needs-you row names the open verb"
assert_equals working "$(group_of "$OUT" answered)" "a resolved decision leaves needs you"
assert_equals needs_you "$(group_of "$OUT" broke)" "a failed task is needs you"
assert_equals working "$(group_of "$OUT" busy)" "a working task is working"
assert_equals working "$(group_of "$OUT" handoff)" "a pipeline handoff without a PR is working, not ready"
assert_equals handoff "$(field_of "$OUT" handoff reason)" "the handoff row says the landing step has not started"
assert_equals ready "$(group_of "$OUT" local-ready)" "a local-only done branch is ready to approve"
assert_equals merged "$(group_of "$OUT" watching)" "a merge whose witness has not passed is merged, not live yet"
assert_contains "$(field_of "$OUT" watching detail)" "https://site.example" "the merged row names the live target still to confirm"
assert_equals needs_you "$(group_of "$OUT" reverting)" "a merge found broken is needs you"
assert_equals ready "$(group_of "$OUT" reused)" "a post-merge record from an earlier incarnation is ignored"
assert_equals live "$(group_of "$OUT" went-live)" "a torn-down task whose witness passed is live confirmed"
assert_equals "done" "$(group_of "$OUT" landed-plain)" "a clear watch with no live target is done, not live"
assert_equals queued "$(group_of "$OUT" later)" "plain queued work is queued"
assert_equals blocked-by "$(field_of "$OUT" after-busy reason)" "a blocked queued row says what it waits for"
assert_equals needs_you "$(group_of "$OUT" pick-one)" "a live captain hold is needs you"
assert_equals decision "$(field_of "$OUT" pick-one reason)" "a captain hold reads as a decision"
assert_equals 1 "$(printf '%s' "$OUT" | jq '.counts.live')" "the live column counts confirmed merges"
assert_equals false "$(printf '%s' "$OUT" | jq '.groups.needs_you[0].reason == "decision"')" \
  "task-raised needs-you rows sort ahead of captain holds"
assert_equals pick-one "$(printf '%s' "$OUT" | jq -r '.groups.needs_you[-1].id')" "captain holds follow the task-raised rows"

# The board is level-triggered: reading it again, with no new event, shows the same ready rows.
OUT2=$(board_json "$H" "$FB" --home-only)
assert_equals "$(printf '%s' "$OUT" | jq -c '[.groups.ready[].id]')" "$(printf '%s' "$OUT2" | jq -c '[.groups.ready[].id]')" \
  "a second read keeps every ready row without any new signal"

TEXT=$(PATH="$FB:$PATH" NET_LOG="$H/net.log" FM_HOME="$H" FM_BOARD_SHOW=1 "$BOARD" --home-only) || fail "board text exits zero"
SKIPPED=$(PATH="$FB:$PATH" NET_LOG="$H/net.log" FM_HOME="$H" "$BOARD" --home-only --skip-done)
assert_contains "$SKIPPED" "1 done" "--skip-done still counts done rows"
assert_not_contains "$SKIPPED" "landed-plain" "--skip-done leaves done rows out"
assert_contains "$TEXT" "4 need you · 4 ready to approve" "the header counts needs-you and ready rows"
assert_contains "$TEXT" "READY TO APPROVE (4)" "every ready row prints even under a small show bound"
assert_contains "$TEXT" "- missed-ready [approval] https://github.com/acme/repo/pull/150" "the missed ready PR prints with its URL"
assert_contains "$TEXT" "QUEUED (2, showing 1; fm-board.sh --all shows every row)" "bounded groups disclose what they left out"
assert_contains "$TEXT" "MERGED (NOT LIVE YET) (1)" "merged-but-not-live has its own column"
assert_contains "$TEXT" "LIVE CONFIRMED (1)" "live confirmed has its own column"
order=$(printf '%s\n' "$TEXT" | grep -E '^(NEEDS YOU|READY TO APPROVE|WORKING|QUEUED|MERGED|LIVE CONFIRMED|DONE)' | cut -c1-6 | tr '\n' ' ')
assert_equals "NEEDS  READY  WORKIN QUEUED MERGED LIVE C DONE ( " "$order" "groups print in the order they need the captain"

# --- 2. main-sync records ---------------------------------------------------
printf 'version=fm-main-sync-v1\ntask=recorded-ready\nhead=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nresult=conflict\ndetail=2 commits behind main\n' > "$H/state/recorded-ready.main-sync"
OUT=$(board_json "$H" "$FB" --home-only)
assert_equals needs_you "$(group_of "$OUT" recorded-ready)" "a conflict at the recorded head moves a ready PR to needs you"
assert_equals conflict "$(field_of "$OUT" recorded-ready reason)" "the row says it conflicts with main"
printf 'version=fm-main-sync-v1\ntask=recorded-ready\nhead=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nresult=conflict\n' > "$H/state/recorded-ready.main-sync"
OUT=$(board_json "$H" "$FB" --home-only)
assert_equals ready "$(group_of "$OUT" recorded-ready)" "a conflict recorded for an older head is stale"
printf 'version=fm-main-sync-v1\ntask=recorded-ready\nhead=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nresult=synced\n' > "$H/state/recorded-ready.main-sync"
OUT=$(board_json "$H" "$FB" --home-only)
assert_contains "$(field_of "$OUT" recorded-ready detail)" "kept current with main" "a synced ready row says it is kept current"

# A merge the poll recorded leaves ready even before any post-merge watch exists.
(
  . "$ROOT/bin/fm-pr-lib.sh"
  fm_pr_poll_merge_mark_notified "$H/state" missed-ready github github.com acme/repo 150
) || fail "merge marker fixture"
OUT=$(board_json "$H" "$FB" --home-only)
assert_equals merged "$(group_of "$OUT" missed-ready)" "a PR the merge poll saw merged is no longer waiting for approval"

# --- 3. secondmate homes ----------------------------------------------------
mate_home() {  # <parent> <id> -> registered local secondmate home
  local parent=$1 id=$2 mate="$TMP_ROOT/$2-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  printf -- '- %s - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-10-01)\n' \
    "$id" "$mate" >> "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/$id.meta" "$mate"
  printf '%s\n' "$mate"
}
summary_base() {  # <home>
  jq -n --arg home "$1" '{schema:"fm-secondmate-home-summary.v1",hold_classifier_schema:"fm-captain-hold-buckets.v1",
    generated:"2026-10-20T11:59:00Z",generated_epoch:1792497540,home:$home,valid:true,reason:null,
    invalidity:{kind:null,ids:[]},state:"active_child_work",active_children:[],decisions_open:[],holds:[],
    queued:[],landed:[],endpoints:[],counts:{},omitted:[]}'
}
P=$(new_home parent)
printf '## In flight\n\n## Queued\n\n## Done\n' > "$P/data/backlog.md"
M1=$(mate_home "$P" frontend)
summary_base "$M1" | jq '. + {board:{schema:"fm-board-home.v1",items:[
  {group:"ready",id:"site-fix",title:"Fix the site",kind:"ship",repo:"site",since:null,at:5,
   url:"https://github.com/acme/site/pull/9",reason:"approval",detail:"waiting for approval"}],
  omitted:{working:580}}}' > "$M1/state/home-summary.json"
M2=$(mate_home "$P" lay)
summary_base "$M2" | jq '.decisions_open = [{id:"tax-sign",key:"tax-sign",verb:"captain-hold",summary:"Sign the tax return",reason:"waiting for the accountant",source:"backlog"}]
  | .active_children = [{id:"mail-triage",kind:"ship",state:"working",repo:"vault",name:"Triage mail",doing:"reading the inbox"}]' > "$M2/state/home-summary.json"
OUT=$(board_json "$P" "$FB") || fail "parent board exits zero"
assert_equals ready "$(group_of "$OUT" frontend/site-fix)" "a secondmate's published ready row reaches the parent board"
assert_equals frontend "$(field_of "$OUT" frontend/site-fix home)" "a secondmate row names its home"
assert_equals 580 "$(printf '%s' "$OUT" | jq '.counts.working - ([.groups.working[]] | length)')" \
  "rows a secondmate left out of its bounded board still count"
assert_contains "$(PATH="$FB:$PATH" NET_LOG="$P/net.log" FM_HOME="$P" "$BOARD")" "PARTIAL: frontend published 580 fewer WORKING rows" \
  "the text board names a secondmate's left-out rows"
assert_equals needs_you "$(group_of "$OUT" lay/tax-sign)" "a legacy ledger's open decision is needs you"
assert_equals decision "$(field_of "$OUT" lay/tax-sign reason)" "a legacy captain hold reads as a decision"
assert_equals working "$(group_of "$OUT" lay/mail-triage)" "a legacy ledger's active child is working"
OUT_HOME=$(board_json "$P" "$FB" --home-only)
assert_equals "" "$(group_of "$OUT_HOME" frontend/site-fix)" "--home-only skips secondmate homes"
rm -f "$M2/state/home-summary.json"
OUT=$(board_json "$P" "$FB")
assert_equals lay "$(printf '%s' "$OUT" | jq -r '.unavailable[0].home')" "an unreadable secondmate ledger is disclosed, not hidden"

# The published home summary carries the home's own board for its parent.
SUMMARY=$(PATH="$FB:$PATH" NET_LOG="$H/net.log" FM_HOME="$H" FM_SNAPSHOT_CREW_STATE_TIMEOUT=5 \
  "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary) || fail "home summary exits zero"
assert_equals fm-board-home.v1 "$(printf '%s' "$SUMMARY" | jq -r '.board.schema')" "the home summary publishes its board"
assert_equals '{}' "$(printf '%s' "$SUMMARY" | jq -c '.board.omitted')" "a small home publishes its whole board"
assert_equals recorded-ready "$(printf '%s' "$SUMMARY" | jq -r '[.board.items[] | select(.group == "ready") | .id] | sort | join(",")' | grep -o recorded-ready)" \
  "the published board carries the home's ready rows"

# --- 4. no network on any board path ----------------------------------------
if [ -s "$H/net.log" ] || [ -s "$P/net.log" ]; then
  fail "board paths made no network call (log: $(cat "$H/net.log" "$P/net.log" 2>/dev/null | head -3))"
else
  pass "board paths made no network call"
fi

