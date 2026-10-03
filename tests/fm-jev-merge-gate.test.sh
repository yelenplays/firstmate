#!/usr/bin/env bash
# Behavioral regression for the shadow Jev merge gate: exact-head evidence,
# the privacy filter, the moving-head refusal, bands and outcomes, the shadow
# streak, local-only landings, and the on-demand eval harness.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-merge-gate)
CODE="$TMP_ROOT/code"
HOME_DIR="$TMP_ROOT/home"
WIKI="$TMP_ROOT/wikis"
FAKE="$TMP_ROOT/fakebin"
mkdir -p "$CODE/bin" "$CODE/tests/fixtures" "$HOME_DIR/state" "$HOME_DIR/config" "$WIKI/routing/cards" "$FAKE" "$TMP_ROOT/pages"
# A code root that is this repo's bin plus a stand-in for the cross-family
# review tool, so review evidence can be driven without spawning reviewers.
for f in "$ROOT"/bin/*; do
  [ "$(basename "$f")" = fm-cross-review.sh ] || ln -s "$f" "$CODE/bin/$(basename "$f")"
done
ln -s "$ROOT/tests/fixtures/jev-merge-gate" "$CODE/tests/fixtures/jev-merge-gate"
TOOL="$CODE/bin/fm-jev-merge-gate.sh"
cat > "$CODE/bin/fm-cross-review.sh" <<'SH'
#!/usr/bin/env bash
# status <task> --head <sha> --json
[ -n "${TEST_XR:-}" ] || exit 1
printf '%s' "$TEST_XR" | jq -c --arg t "$2" --arg h "$4" '.task = $t | .head = $h'
SH
chmod +x "$CODE/bin/fm-cross-review.sh"

cat > "$WIKI/routing/cards/fehler-wiki.yaml" <<'CARD'
wiki: FehlerWiki
pfad: FehlerWiki
cloud: ja
modus: voll
repo: yelen-wikis/FehlerWiki
CARD
cat > "$WIKI/routing/cards/second-brain.yaml" <<'CARD'
wiki: SecondBrain
pfad: SecondBrain
cloud: nein
modus: pointer
repo: yelenplays/SecondBrain
CARD
cat > "$WIKI/routing/cards/fitness-brain.yaml" <<'CARD'
wiki: FitnessBrain
pfad: FitnessBrain
cloud: nur-digest
modus: voll
repo: yelenplays/FitnessBrain
CARD

H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
B1=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# gh stand-in. TEST_FILES is the changed-file list, TEST_CHECKS the required
# checks JSON (empty means none required), TEST_RUNS the check runs on the
# head, TEST_VAULT=1 adds vault scaffold markers, pages come from
# $TEST_PAGES/<sha>/<path>, and TEST_MOVE_AFTER=N moves the head after N views.
cat > "$FAKE/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_GH_LOG"
jqf=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) jqf=$2; shift 2 ;;
    -H) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
emit() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
case "$1 $2" in
  "pr view")
    n=$(cat "$TEST_TMP/views" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$TEST_TMP/views"
    head=$TEST_HEAD
    if [ -n "${TEST_MOVE_AFTER:-}" ] && [ "$n" -gt "$TEST_MOVE_AFTER" ]; then head=$TEST_MOVED_HEAD; fi
    jq -nc --arg h "$head" --arg b "$TEST_BASE" --arg m "${TEST_MERGEABLE:-MERGEABLE}" --arg body "${TEST_BODY:-Adds the thing.}" \
      '{number: 7, state: "OPEN", title: "feat: add the thing", body: $body, isDraft: false, mergeable: $m,
        mergeStateStatus: "CLEAN", headRefOid: $h, baseRefOid: $b, baseRefName: "main", headRefName: "fm/thing"}' | emit
    ;;
  "pr checks")
    if [ -z "${TEST_CHECKS:-}" ]; then
      echo "no required checks reported on the 'fm/thing' branch" >&2
      exit 1
    fi
    printf '%s\n' "$TEST_CHECKS"
    jq -e 'all(.[]; .bucket == "pass")' <<<"$TEST_CHECKS" >/dev/null || exit 1
    ;;
  "api "*)
    path=$2
    case "$path" in
      */pulls/7/files*) printf '[%s]\n' "$TEST_FILES" ;;
      */check-runs*) printf '[{"check_runs":%s}]\n' "${TEST_RUNS:-[]}" ;;
      */statuses*) printf '[[]]\n' ;;
      */contents/_meta\?ref=*)
        if [ "${TEST_VAULT:-0}" = 1 ]; then printf '[{"name":"einstieg.sh","type":"file"}]\n'
        else echo 'gh: Not Found (HTTP 404)' >&2; exit 1; fi ;;
      */contents/.github/workflows\?ref=*) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
      */contents/*)
        rel=${path#*/contents/}; ref=${rel##*\?ref=}; rel=${rel%%\?ref=*}
        if [ -f "$TEST_PAGES/$ref/$rel" ]; then cat "$TEST_PAGES/$ref/$rel"
        else echo 'gh: Not Found (HTTP 404)' >&2; exit 1; fi ;;
      *) echo "unexpected api $path" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
SH
cat > "$FAKE/curl" <<'SH'
#!/usr/bin/env bash
out=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac
done
cat >> "$TEST_JEV_REQUEST"
if [ -n "${TEST_JEV_RESPONSE:-}" ]; then
  printf '%s' "$TEST_JEV_RESPONSE" > "$out"
else
  printf '%s' '{"id":"req-1","model":"jev-1.13.0","answers":{"decision":{"type":"choice","choice":"merge","confidence":0.8,"probabilities":{"merge":0.8,"hold":0.2}}}}' > "$out"
fi
printf 200
SH
chmod +x "$FAKE/gh" "$FAKE/curl"

export FM_HOME="$HOME_DIR" FM_WIKIS_ROOT="$WIKI" TYPESAFE_API_KEY=testing-only
export TEST_GH_LOG="$TMP_ROOT/gh.log" TEST_JEV_REQUEST="$TMP_ROOT/request.json" TEST_TMP="$TMP_ROOT" TEST_PAGES="$TMP_ROOT/pages"
export TEST_HEAD=$H1 TEST_BASE=$B1 TEST_MOVED_HEAD=$H2 FM_MERGE_GATE_MERGEABLE_WAIT_SECS=0
GREEN='[{"name":"test","state":"SUCCESS","bucket":"pass"},{"name":"lint","state":"SUCCESS","bucket":"pass"}]'
FILES_CODE='{"filename":"src/app.ts","status":"modified","additions":10,"deletions":2},{"filename":"tests/app.test.ts","status":"added","additions":30,"deletions":0}'
XR_OK='{"mode":"no-mistakes","builder":{"family":"anthropic","source":"claude catalog"},"pipeline_review":{"run":"r1","agent":"pi","family":"openai","source":"pi catalog"},"independent_review":{"source":"pipeline","family":"openai","verdict":"completed","detail":"pipeline review by openai"},"confirm":"MISSING: no confirm is recorded"}'
LOG="$HOME_DIR/state/jev-merge.jsonl"
URL=https://github.com/acme/app/pull/7
reset_case() {
  rm -f "$TEST_JEV_REQUEST" "$TMP_ROOT/views" "$TEST_GH_LOG"
  unset TEST_MOVE_AFTER TEST_VAULT TEST_JEV_RESPONSE TEST_RUNS TEST_MERGEABLE TEST_BODY TEST_XR FM_MERGE_GATE_STUB
  export TEST_CHECKS="$GREEN" TEST_FILES="$FILES_CODE"
}
write_meta() {  # <task> <mode> [extra lines]
  local t=$1 m=$2
  shift 2
  { printf 'project=%s\nmode=%s\nkind=ship\n' "${META_PROJECT:-/nonexistent/app}" "$m"; printf '%s\n' "$@"; } > "$HOME_DIR/state/$t.meta"
}
gate() { PATH="$FAKE:$PATH" bash "$TOOL" "$@"; }

# 1. A PR with no task record: every evidence field is filled, MISSING or N/A,
# free text is redacted before it is sent, and the log keeps only a hash.
reset_case
export TEST_BODY='Adds the thing. Contact ops@example.com, token ghp_abcdefghijklmnopqrstuvwxyz0123456789.

## Details
Long details that must not be part of the change summary.'
rc=0; out=$(gate decide "$URL" 2>"$TMP_ROOT/err") || rc=$?
[ "$rc" = 1 ] || fail "unreviewed PR must hold (exit 1), got $rc: $(cat "$TMP_ROOT/err")"
printf '%s' "$out" | jq -e '
  (.input | keys) == ["base", "change", "ci", "head", "limits", "pr", "review"]
  and ([.evidence[] | type == "string" and length > 0] | all)
  and .evidence.head == "'"$H1"'" and .evidence.base == "'"$B1"'"
  and (.evidence.independent_review | startswith("MISSING:"))
  and (.evidence.qa | startswith("N/A:"))
  and (.evidence.deploy_effect | startswith("MISSING:"))
  and (.evidence.rollback | startswith("MISSING:"))
  and (.input.limits | test("rollback: MISSING: no rollback procedure supplied or configured"))
  and (.evidence.required_checks | test("test=pass"))
  and (.evidence.scope | startswith("scope (from the diff): code change"))
  and .decision.decided_by == "jev" and .decision.band == "act" and .outcome.decision == "hold"' >/dev/null ||
  fail "decide output incomplete: $out"
grep -q 'ops@example.com\|ghp_abcdefghij\|Long details' "$TEST_JEV_REQUEST" && fail 'free text reached Jev unredacted or beyond the first section'
grep -q '"jev-1.13.0"' "$TEST_JEV_REQUEST" || fail 'the Jev call did not use the pinned model'
jq -e 'select(.kind == "gate") | .mode == "shadow" and (.input_sha256 | length == 64) and .request_id == "req-1" and (has("input") | not)' "$LOG" >/dev/null ||
  fail 'gate record missing shadow mode, hash or request id'
grep -q 'Adds the thing' "$LOG" && fail 'raw evidence text reached the log'
pass 'decide prints {input, decision} with every field filled, MISSING or N/A, and logs only a hash'

# 2. Without a required check, what ran on the exact head is reported.
reset_case
export TEST_CHECKS='' TEST_RUNS='[{"id":1,"name":"build","status":"completed","conclusion":"success"}]'
out=$(gate evidence "$URL" 2>/dev/null) || fail 'evidence without required checks failed'
printf '%s' "$out" | jq -e '.evidence.required_checks | test("no required checks; observed on exact head '"$H1"': build=success; all pass")' >/dev/null ||
  fail "observed checks not reported: $(printf '%s' "$out" | jq -r .evidence.required_checks)"
[ ! -e "$TEST_JEV_REQUEST" ] || fail 'evidence must not call Jev'
export TEST_RUNS='[]'
out=$(gate evidence "$URL" 2>/dev/null)
printf '%s' "$out" | jq -e '.problems | any(test("no check ran"))' >/dev/null || fail 'no checks at all must be a gate problem'
pass 'checks fall back to the exact head and evidence never calls Jev'

# 3. Privacy: a cloud: nein or nur-digest card, a vault without a card, a
# private page, and unreadable cards all keep the merge away from Jev.
for target in https://github.com/yelenplays/SecondBrain/pull/7 https://github.com/YelenPlays/fitnessbrain/pull/7; do
  reset_case
  rc=0; out=$(gate decide "$target" 2>/dev/null) || rc=$?
  [ "$rc" = 5 ] || fail "private card $target must be kept out (exit 5), got $rc"
  [ ! -e "$TEST_JEV_REQUEST" ] || fail "private card $target reached Jev"
  printf '%s' "$out" | jq -e '.eligibility.eligible == false and (has("evidence") | not) and (has("input") | not)' >/dev/null || fail "kept-out output leaked evidence: $out"
  [ ! -s "$TEST_GH_LOG" ] || fail "a private card must keep $target out before anything is read from the forge"
done
reset_case
export TEST_VAULT=1
rc=0; gate decide https://github.com/someone/UncardedVault/pull/7 >/dev/null 2>&1 || rc=$?
[ "$rc" = 5 ] && [ ! -e "$TEST_JEV_REQUEST" ] || fail "an uncarded vault must be kept out, got $rc"
reset_case
export TEST_FILES='{"filename":"pages/secret.md","status":"modified","additions":1,"deletions":1}'
mkdir -p "$TEST_PAGES/$H1/pages" "$TEST_PAGES/$B1/pages"
printf -- '---\ntitle: x\nprivate: true\n---\nbody text\n' > "$TEST_PAGES/$H1/pages/secret.md"
printf -- '---\ntitle: x\n---\nbody text\n' > "$TEST_PAGES/$B1/pages/secret.md"
rc=0; out=$(gate decide https://github.com/yelen-wikis/FehlerWiki/pull/7 2>/dev/null) || rc=$?
[ "$rc" = 5 ] && [ ! -e "$TEST_JEV_REQUEST" ] || fail "a private page in a shareable vault must be kept out, got $rc"
printf '%s' "$out" | grep -q 'body text' && fail 'private page content was printed'
printf -- '---\ntitle: x\n---\nbody text\n' > "$TEST_PAGES/$H1/pages/secret.md"
reset_case
export TEST_FILES='{"filename":"pages/secret.md","status":"modified","additions":1,"deletions":1}'
rc=0; gate decide https://github.com/yelen-wikis/FehlerWiki/pull/7 >/dev/null 2>&1 || rc=$?
[ "$rc" != 5 ] && [ -s "$TEST_JEV_REQUEST" ] || fail "a shareable vault change with no private page must reach Jev, got $rc"
reset_case
rc=0; FM_WIKIS_ROOT="$TMP_ROOT/no-such-wikis" gate decide "$URL" >/dev/null 2>&1 || rc=$?
[ "$rc" = 5 ] && [ ! -e "$TEST_JEV_REQUEST" ] || fail "unreadable routing cards must keep everything out, got $rc"
jq -e 'select(.kind == "gate" and .decision == "kept-out") | .input_sha256 == null' "$LOG" >/dev/null || fail 'kept-out records must carry no input hash'
pass 'private cards, uncarded vaults, private pages and unreadable cards get no Jev call'

# 4. A head that moves during collection refuses before Jev is asked.
reset_case
export TEST_MOVE_AFTER=1
rc=0; gate decide "$URL" >/dev/null 2>"$TMP_ROOT/err" || rc=$?
[ "$rc" = 2 ] || fail "a moving head must refuse (exit 2), got $rc"
grep -q 'moved' "$TMP_ROOT/err" || fail 'the refusal must say the target moved'
[ ! -e "$TEST_JEV_REQUEST" ] || fail 'a moving head reached Jev'
tail -1 "$LOG" | jq -e '.decision == "refused" and .reason == "head-or-base-moved"' >/dev/null || fail 'the refusal was not logged'
pass 'a head that moves during collection refuses without a Jev call'

# 5. Bands and outcomes with full review evidence.
write_meta app-task no-mistakes "pr=$URL"
reset_case
export TEST_XR="$XR_OK"
rc=0; out=$(gate decide "$URL" 2>/dev/null) || rc=$?
[ "$rc" = 0 ] || fail "act-band merge with green gates must merge (exit 0), got $rc: $out"
printf '%s' "$out" | jq -e '.evidence.reviewer_family == "openai" and .evidence.builder_family == "anthropic" and (.evidence.pipeline | test("completed"))' >/dev/null ||
  fail 'review evidence not read from the cross-family review tool'
reset_case
TEST_XR="$(jq -c '.independent_review.family = .builder.family' <<<"$XR_OK")"
export TEST_XR
rc=0; out=$(gate decide "$URL" 2>/dev/null) || rc=$?
if [ "$rc" = 1 ]; then
  printf '%s' "$out" | jq -e '.problems | any(test("reviewer family is missing or matches"))' >/dev/null ||
    fail "same-family independent review must hold, got $rc: $out"
else
  fail "same-family independent review must hold, got $rc: $out"
fi
reset_case
export TEST_XR="$XR_OK" TEST_JEV_RESPONSE='{"id":"req-2","model":"jev-1.13.0","answers":{"decision":{"type":"choice","choice":"merge","confidence":0.5}}}'
rc=0; gate decide "$URL" >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] || fail "review-band merge without confirm must need a confirm (exit 3), got $rc"
TEST_XR=$(jq -c --arg h "$H1" '.confirm = {sha: "x", family: "openai", reviewer: "r"}' <<<"$XR_OK")
rc=0; gate decide "$URL" >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] || fail "a confirmation for another head must not merge, got $rc"
TEST_XR=$(jq -c --arg h "$H1" '.confirm = {sha: $h, family: "anthropic", reviewer: "r"}' <<<"$XR_OK")
rc=0; gate decide "$URL" >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] || fail "a same-family confirmation must not merge, got $rc"
TEST_XR=$(jq -c --arg h "$H1" '.confirm = {sha: $h, family: "openai", reviewer: "r"}' <<<"$XR_OK")
rc=0; gate decide "$URL" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "review-band merge with a cross-family exact-head confirm must merge, got $rc"
reset_case
TEST_XR="$(jq -c --arg secret 'ghp_abcdefghijklmnopqrstuvwxyz0123456789' '.pipeline_review.run = $secret' <<<"$XR_OK")"
export TEST_XR
mkdir -p "$HOME_DIR/data/app-task/proof"
printf '%s\n' '---' 'artifact_type: artifact ghp_abcdefghijklmnopqrstuvwxyz0123456789' 'verdict: PASS' "candidate_sha: $H1" '---' > "$HOME_DIR/data/app-task/proof/brb-$H1.md"
rc=0; out=$(gate decide "$URL" --team 2>/dev/null) || rc=$?
if [ "$rc" = 1 ]; then
  printf '%s' "$out" | jq -e '.problems | any(test("proof artifact is not a QA artifact"))' >/dev/null ||
    fail "a non-QA proof must not satisfy QA, got $rc: $out"
else
  fail "a non-QA proof must not satisfy QA, got $rc: $out"
fi
! grep -q 'ghp_abcdefghijklmnopqrstuvwxyz0123456789' "$TEST_JEV_REQUEST" || fail 'pipeline secret reached Jev'
printf '%s' "$out" | jq -e '(.input.review | contains("ghp_") | not) and (.evidence.qa | contains("artifact_type=artifact"))' >/dev/null ||
  fail 'redacted pipeline or QA evidence was not represented correctly'
printf '%s\n' '---' 'artifact_type: qa' 'verdict: PASS' "candidate_sha: $H1" '---' > "$HOME_DIR/data/app-task/proof/brb-$H1.md"
rc=0; out=$(gate decide "$URL" --team 2>/dev/null) || rc=$?
[ "$rc" = 0 ] || fail "a matching QA artifact must satisfy the QA gate, got $rc"
reset_case
export TEST_XR="$XR_OK" TEST_JEV_RESPONSE='{"model":"jev-1.13.0","answers":{"decision":{"type":"choice","choice":"merge"}}}'
rc=0; gate decide "$URL" >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] || fail "a merge without confidence is uncertain and needs a confirm, got $rc"
reset_case
export TEST_XR="$XR_OK" TEST_FILES='{"filename":"src/auth/session.ts","status":"modified","additions":3,"deletions":1}'
rc=0; gate decide "$URL" >/dev/null 2>&1 || rc=$?
[ "$rc" = 6 ] || fail "a security-sensitive change must escalate (exit 6), got $rc"
reset_case
export TEST_XR="$XR_OK" TEST_CHECKS='[{"name":"test","state":"FAILURE","bucket":"fail"}]'
rc=0; gate decide "$URL" >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "a red required check must hold, got $rc"
reset_case
export TEST_XR="$XR_OK" TEST_MERGEABLE=UNKNOWN
rc=0; gate decide "$URL" >/dev/null 2>&1 || rc=$?
[ "$rc" = 4 ] && [ ! -e "$TEST_JEV_REQUEST" ] || fail "mergeable UNKNOWN must not be decided, got $rc"
reset_case
export TEST_XR="$XR_OK" FM_MERGE_GATE_STUB="$TMP_ROOT/stub.json"
printf '%s' '{"model":"jev-1.13.0","answers":{"decision":{"type":"choice","choice":"merge","confidence":0.99}}}' > "$FM_MERGE_GATE_STUB"
rc=0; gate decide "$URL" >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] && [ ! -e "$TEST_JEV_REQUEST" ] || fail "a stubbed answer must never merge, got $rc"
reset_case
export TEST_XR="$XR_OK" TEST_JEV_RESPONSE='not json'
rc=0; gate decide "$URL" >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "an unusable Jev answer must hold, got $rc"
pass 'act merges, review band needs a cross-family confirm, escalations, red checks, stubs and errors hold'

# 6. Shadow comparison: agreement extends the streak, disagreement resets it
# and stores an eval case; stubbed records are not comparable.
rm -f "$LOG" "$HOME_DIR/state/jev-merge-cases.jsonl"
reset_case
export TEST_XR="$XR_OK"
gate decide "$URL" >/dev/null 2>&1
out=$(gate record "$URL" --head "$H1" --firstmate merge) || fail 'record failed'
printf '%s' "$out" | jq -e '.agreement == true and .streak == 1' >/dev/null || fail "agreement not counted: $out"
out=$(gate record "$URL" --head "$H1" --firstmate merge) || fail 'duplicate record failed'
printf '%s' "$out" | jq -e '.agreement == true and .streak == 1 and .duplicate == true' >/dev/null || fail "duplicate agreement counted again: $out"
[ "$(jq -s '[.[] | select(.kind == "comparison")] | length' "$LOG")" = 1 ] || fail 'a duplicate record appended another comparison'
reset_case
export TEST_XR="$XR_OK" TEST_JEV_RESPONSE='{"id":"req-3","model":"jev-1.13.0","answers":{"decision":{"type":"choice","choice":"hold","confidence":0.7}}}'
gate decide "$URL" >/dev/null 2>&1
out=$(gate record "$URL" --head "$H1" --firstmate merge)
printf '%s' "$out" | jq -e '.agreement == false and .streak == 0' >/dev/null || fail "disagreement did not reset the streak: $out"
jq -e '.expect == "merge" and .label_source == "firstmate" and (.set | IN("train", "heldout")) and (.input.head == "'"$H1"'")' "$HOME_DIR/state/jev-merge-cases.jsonl" >/dev/null ||
  fail 'disagreement did not become an eval case'
reset_case
export TEST_XR="$XR_OK" FM_MERGE_GATE_STUB="$TMP_ROOT/stub.json"
gate decide "$URL" >/dev/null 2>&1
out=$(gate record "$URL" --head "$H1" --firstmate merge)
printf '%s' "$out" | jq -e '.agreement == null and .streak == 0' >/dev/null || fail "a stubbed decision must not be comparable: $out"
reset_case
export TEST_XR="$XR_OK" TEST_JEV_RESPONSE='not json'
gate decide "$URL" >/dev/null 2>&1
out=$(gate record "$URL" --head "$H1" --firstmate merge)
printf '%s' "$out" | jq -e '.agreement == null and .streak == 0' >/dev/null || fail "an unavailable Jev must not be comparable: $out"
out=$(gate record "$URL" --head "$H2" --firstmate hold)
printf '%s' "$out" | jq -e '.agreement == null' >/dev/null || fail 'a head without a gate decision must not be comparable'
gate outcome "$URL" --head "$H1" reverted >/dev/null || fail 'outcome failed'
[ "$(grep -c '"source":"revert"' "$HOME_DIR/state/jev-merge-cases.jsonl")" = 1 ] || fail 'a revert did not become an eval case'
out=$(gate streak)
printf '%s' "$out" | jq -e '.mode == "shadow" and .streak == 0 and .agreements == 1 and .disagreements == 1 and .not_comparable == 3 and .live_ready == false' >/dev/null ||
  fail "streak summary wrong: $out"
jq -se 'map(select(.kind == "comparison")) | length == 5 and all(.[]; has("agreement") and has("streak"))' "$LOG" >/dev/null || fail 'comparisons not visible in the log'
pass 'shadow decisions and the streak are recorded, disagreements and reverts become eval cases'

# 7. A local-only landing uses branch evidence: the recorded test run and the
# cross-family review, no forge checks.
REPO="$TMP_ROOT/proj/app"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.invalid
git -C "$REPO" config user.name t
printf 'a\n' > "$REPO/app.sh"
git -C "$REPO" add app.sh && git -C "$REPO" commit -qm 'initial'
git -C "$REPO" checkout -q -b fm/local-task
printf 'b\n' >> "$REPO/app.sh"
git -C "$REPO" commit -qam 'fix: handle the empty case'
git -C "$REPO" checkout -q main
LH=$(git -C "$REPO" rev-parse fm/local-task)
META_PROJECT="$REPO" write_meta local-task local-only
reset_case
export TEST_XR='{"mode":"local-only","builder":{"family":"anthropic"},"pipeline_review":"N/A: local-only runs no pipeline","independent_review":{"source":"one-shot","family":"openai","verdict":"success","detail":"d"},"confirm":"MISSING: none"}'
rc=0; out=$(gate decide --task local-task 2>/dev/null) || rc=$?
[ "$rc" = 1 ] || fail "a local landing without a recorded test run must hold, got $rc"
printf '%s' "$out" | jq -e '(.evidence.tests | startswith("MISSING:")) and (.evidence.required_checks | startswith("N/A:")) and .evidence.head == "'"$LH"'"' >/dev/null ||
  fail "local evidence wrong: $out"
gate note local-task tests --head "$LH" --result passed --summary 'bash tests/app.test.sh: 12 passed' >/dev/null || fail 'note failed'
rc=0; out=$(gate decide --task local-task 2>/dev/null) || rc=$?
[ "$rc" = 0 ] || fail "a reviewed, tested fast-forward local landing must merge in the act band, got $rc: $out"
printf '%s' "$out" | jq -e '.evidence.tests | test("passed")' >/dev/null || fail 'recorded test run not reported'
[ ! -s "$TEST_GH_LOG" ] || fail 'a local landing must not call the forge'
gate note local-task review --head "$LH" >/dev/null 2>&1 && fail 'review notes belong to the cross-family review tool'
pass 'local-only landings use the recorded test run and the review, without forge checks'

# 8. The eval harness runs labelled cases on demand and reports per set.
cat > "$TMP_ROOT/cases.jsonl" <<JSON
{"id":"a","set":"train","expect":"merge","input":{"pr":"x"}}
{"id":"b","set":"heldout","expect":"hold","input":{"pr":"y"}}
JSON
reset_case
mkdir -p "$TMP_ROOT/eval-state"
out=$(FM_STATE_OVERRIDE="$TMP_ROOT/eval-state" gate eval --cases "$TMP_ROOT/cases.jsonl" 2>/dev/null) || fail 'eval failed'
printf '%s' "$out" | jq -e '.all.n == 2 and .all.accuracy_pct == 50 and .all.wrong_merges == 1 and .by_set.heldout.n == 1 and (.all.confidence_sweep | length == 5)' >/dev/null ||
  fail "eval report wrong: $out"
[ -s "$TMP_ROOT/eval-state/jev-merge-eval-report.json" ] || fail 'eval report not written'
out=$(FM_STATE_OVERRIDE="$TMP_ROOT/eval-state" gate eval --cases "$TMP_ROOT/cases.jsonl" --set heldout 2>/dev/null)
printf '%s' "$out" | jq -e '.all.n == 1' >/dev/null || fail 'held-out selection ignored'
jq -se 'length > 0 and all(.[]; (.expect | IN("merge", "hold")) and (.set | IN("train", "heldout")) and (.input | type == "object"))' "$ROOT/tests/fixtures/jev-merge-gate/cases.jsonl" >/dev/null ||
  fail 'tracked seed cases malformed'
pass 'eval runs labelled cases with a held-out set'
