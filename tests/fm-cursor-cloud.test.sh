#!/usr/bin/env bash
# Behavior tests for fm-cursor-cloud.sh: the github.com-only boundary refuses
# before any request, a dry run sends nothing, a live dispatch records the agent
# and registers its watcher check without the key on curl's argv, poll wakes once
# per new outcome, cleanup refuses unlanded work, and fm-spawn refuses the id.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLOUD="$ROOT/bin/fm-cursor-cloud.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-cloud)
KEY=test-key-not-real-0123

AGENT=bc-11111111-2222-3333-4444-555555555555
RUN=run-11111111-2222-3333-4444-555555555555
PR=https://github.com/octo/demo/pull/7

# make_home <name> <registry-row> [origin]: a home with one clone projects/demo.
make_home() {
  local name=$1 row=$2 origin=${3:-https://github.com/octo/demo.git} home fakebin
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$home/cursor"
  printf '# Fleet projects\n\n%s\n' "$row" > "$home/data/projects.md"
  fm_git_init_commit "$home/projects/demo" >/dev/null
  git -C "$home/projects/demo" remote add origin "$origin"
  git -C "$home/projects/demo" update-ref refs/remotes/origin/main HEAD
  git -C "$home/projects/demo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  printf 'Add a line to README.md.\n' > "$home/prompt.txt"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/"*) [ -n "${FAKE_GH_VISIBILITY:-}" ] || exit 1; printf '%s\n' "$FAKE_GH_VISIBILITY" ;;
  "pr view") printf '%s\n' "${FAKE_GH_PR_STATE:-OPEN}" ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
out='' method=GET url=''
printf '%s\n' "$*" >> "$FAKE_CURSOR_DIR/argv.log"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -X) method=$2; shift 2 ;;
    -w|-m|-H|--data-binary) shift 2 ;;
    --config) cat > "$FAKE_CURSOR_DIR/config.last"; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
path=${url#*://*/}
key="$method ${path}"
printf '%s\n' "$key" >> "$FAKE_CURSOR_DIR/calls.log"
file="$FAKE_CURSOR_DIR/$(printf '%s' "$key" | tr ' /' '__')"
if [ -f "$file.json" ]; then cat "$file.json" > "$out"; else printf '{}' > "$out"; fi
if [ -f "$file.code" ]; then cat "$file.code"; else printf 200; fi
SH
  chmod +x "$fakebin/gh" "$fakebin/curl"
  printf '%s\n' "$home"
}

row_ok='- demo [no-mistakes +yolo] - public test repo (added 2026-09-24)'

# run_cloud <home> <args...>: sets RC OUT ERR.
run_cloud() {
  local home=$1
  shift
  RC=0
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_CURSOR_DIR="$home/cursor" \
    FM_CURSOR_API_BASE=https://api.example.invalid \
    FAKE_GH_VISIBILITY="${VIS-public}" FAKE_GH_PR_STATE="${PRSTATE:-OPEN}" \
    CURSOR_API_KEY="${KEYVAL-$KEY}" FM_WIKIS_ROOT="${WIKIS-}" \
    "$CLOUD" "$@" >"$home/out" 2>"$home/err" || RC=$?
  OUT=$(cat "$home/out")
  ERR=$(cat "$home/err")
}

fake_response() {  # <home> <METHOD path> <json> [code]
  local file
  file="$1/cursor/$(printf '%s' "$2" | tr ' /' '__')"
  printf '%s' "$3" > "$file.json"
  if [ -n "${4:-}" ]; then printf '%s' "$4" > "$file.code"; else rm -f "$file.code"; fi
}

test_boundary_refusals() {
  local home estate_root
  home=$(make_home unregistered '- other [no-mistakes] - x (added 2026-09-24)')
  run_cloud "$home" dispatch elig demo --prompt-file "$home/prompt.txt" --dry-run
  expect_code 3 "$RC" "unregistered project"
  assert_contains "$ERR" "not registered" "unregistered refusal reason"

  home=$(make_home localonly '- demo [local-only +yolo] - x (added 2026-09-24)')
  run_cloud "$home" dispatch elig demo --prompt-file "$home/prompt.txt" --dry-run
  expect_code 3 "$RC" "local-only project"
  assert_contains "$ERR" "local-only" "local-only refusal reason"

  home=$(make_home gitlab "$row_ok" https://gitlab.com/octo/demo.git)
  run_cloud "$home" dispatch elig demo --prompt-file "$home/prompt.txt" --dry-run
  expect_code 3 "$RC" "non-github origin"
  assert_contains "$ERR" "not a github.com repository" "non-github refusal reason"

  home=$(make_home lookalike "$row_ok" https://github.com.evil.example/octo/demo.git)
  run_cloud "$home" dispatch elig demo --prompt-file "$home/prompt.txt" --dry-run
  expect_code 3 "$RC" "github lookalike host"

  home=$(make_home scaffold "$row_ok")
  mkdir -p "$home/projects/demo/_meta"
  : > "$home/projects/demo/_meta/pruefe.sh"
  run_cloud "$home" dispatch elig demo --prompt-file "$home/prompt.txt" --dry-run
  expect_code 3 "$RC" "vault scaffold"
  assert_contains "$ERR" "wiki vault" "vault scaffold refusal reason"

  home=$(make_home estate "$row_ok")
  estate_root="$home/wikis"
  mkdir -p "$estate_root/routing"
  printf '{"vaults":[{"wiki":"Other","repo":"Octo/Demo","path":"~/nowhere","cloud":"nein"}]}\n' \
    > "$estate_root/routing/estate.json"
  WIKIS=$estate_root run_cloud "$home" dispatch elig demo --prompt-file "$home/prompt.txt" --dry-run
  expect_code 3 "$RC" "repo listed as a vault"
  assert_contains "$ERR" "wiki vault listed" "estate refusal reason"

  home=$(make_home associated-private '- demo [no-mistakes] [wiki: PrivateWiki] - public test repo (added 2026-09-24)')
  estate_root="$home/wikis"
  mkdir -p "$estate_root/routing"
  printf '{"vaults":[{"wiki":"PrivateWiki","repo":"other/private","path":"~/private","cloud":"nein"}]}\n' \
    > "$estate_root/routing/estate.json"
  WIKIS=$estate_root run_cloud "$home" dispatch t-private demo --prompt-file "$home/prompt.txt" --dry-run
  expect_code 3 "$RC" "associated cloud:no wiki"
  assert_contains "$ERR" "associated with cloud: nein vault 'PrivateWiki'" "associated private vault refusal"
  assert_absent "$home/cursor/calls.log" "private associated vault reached Cursor API"

  home=$(make_home noestate "$row_ok")
  printf '%s\n' "$home/missing-wikis" > "$home/config/wikis-root"
  run_cloud "$home" dispatch elig demo --prompt-file "$home/prompt.txt" --dry-run
  expect_code 3 "$RC" "configured wikis root without estate"
  assert_contains "$ERR" "cannot be proven" "unreadable estate refusal reason"

  home=$(make_home private "$row_ok")
  VIS=private run_cloud "$home" dispatch elig demo --prompt-file "$home/prompt.txt" --dry-run
  expect_code 3 "$RC" "private repository"
  assert_contains "$ERR" "not public" "private refusal reason"
  VIS='' run_cloud "$home" dispatch elig demo --prompt-file "$home/prompt.txt" --dry-run
  expect_code 3 "$RC" "unreadable visibility"

  home=$(make_home okay "$row_ok" git@github.com:octo/demo.git)
  run_cloud "$home" dispatch elig demo --prompt-file "$home/prompt.txt" --dry-run
  expect_code 0 "$RC" "public github project"
  assert_contains "$OUT" '"url": "https://github.com/octo/demo"' "eligible dispatch dry-run output"
  assert_absent "$home/cursor/calls.log" "eligibility check called the Cursor API"
  pass "boundary refuses every ineligible project before any request"
}

test_dry_run_and_credential() {
  local home
  home=$(make_home dry "$row_ok")
  KEYVAL='' run_cloud "$home" dispatch t1 demo --prompt-file "$home/prompt.txt" --dry-run
  expect_code 0 "$RC" "dry run"
  assert_contains "$OUT" '"url": "https://github.com/octo/demo"' "dry run repo url"
  assert_contains "$OUT" '"startingRef": "main"' "dry run default ref"
  assert_contains "$OUT" '"autoCreatePR": true' "dry run opens a PR"
  assert_contains "$OUT" "Add a line to README.md." "dry run carries the task"
  assert_absent "$home/cursor/calls.log" "dry run called the Cursor API"
  assert_absent "$home/state/t1.cloud" "dry run wrote a record"

  KEYVAL='' run_cloud "$home" dispatch t1 demo --prompt-file "$home/prompt.txt"
  expect_code 4 "$RC" "live dispatch without a key"
  assert_contains "$ERR" "https://cursor.com/dashboard/api" "missing key names the captain step"
  assert_absent "$home/cursor/calls.log" "keyless dispatch called the Cursor API"

  printf 'Read %s/data/notes.md first.\n' "$home" > "$home/leaky.txt"
  run_cloud "$home" dispatch t1 demo --prompt-file "$home/leaky.txt" --dry-run
  expect_code 3 "$RC" "prompt naming the home path"
  pass "dry run sends nothing and a missing key stops with the captain's step"
}

test_dispatch_poll_cleanup() {
  local home check
  home=$(make_home live "$row_ok")
  fake_response "$home" "POST v1/agents" \
    "{\"agent\":{\"id\":\"$AGENT\",\"url\":\"https://cursor.com/agents/$AGENT\",\"createdAt\":\"2026-09-24T00:00:00Z\",\"latestRunId\":\"$RUN\"},\"run\":{\"id\":\"$RUN\",\"status\":\"CREATING\"}}"
  run_cloud "$home" dispatch t2 demo --prompt-file "$home/prompt.txt"
  expect_code 0 "$RC" "live dispatch: $ERR"
  assert_grep "agent_id=$AGENT" "$home/state/t2.cloud"
  assert_present "$home/state/t2.check-trust" "watcher check was not registered"
  assert_no_grep "$KEY" "$home/cursor/argv.log"
  assert_grep "$KEY" "$home/cursor/config.last"
  check="$home/state/t2.check.sh"
  assert_present "$check" "watcher check missing"

  run_cloud "$home" dispatch t2 demo --prompt-file "$home/prompt.txt"
  expect_code 3 "$RC" "second dispatch of the same id"

  fake_response "$home" "GET v1/agents/$AGENT" "{\"id\":\"$AGENT\",\"status\":\"ACTIVE\",\"latestRunId\":\"$RUN\"}"
  fake_response "$home" "GET v1/agents/$AGENT/runs/$RUN" "{\"id\":\"$RUN\",\"status\":\"RUNNING\"}"
  run_cloud "$home" poll t2
  expect_code 0 "$RC" "poll while running"
  assert_equals "" "$OUT" "poll woke while nothing changed"

  run_cloud "$home" cleanup t2
  expect_code 3 "$RC" "cleanup of a running agent"

  fake_response "$home" "GET v1/agents/$AGENT/runs/$RUN" \
    "{\"id\":\"$RUN\",\"status\":\"FINISHED\",\"result\":\"done\",\"git\":{\"branches\":[{\"repoUrl\":\"github.com/octo/demo\",\"branch\":\"cursor/x\",\"prUrl\":\"$PR\"}]}}"
  fake_response "$home" "GET v1/agents/$AGENT" "{\"id\":\"$AGENT\",\"status\":\"IDLE\",\"latestRunId\":\"$RUN\"}"
  run_cloud "$home" poll t2
  assert_equals "cursor-cloud t2 run=$RUN FINISHED pr=$PR" "$OUT" "poll outcome line"
  run_cloud "$home" poll t2
  assert_equals "" "$OUT" "poll repeated an outcome it already reported"

  local run2=run-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
  fake_response "$home" "GET v1/agents/$AGENT" "{\"id\":\"$AGENT\",\"status\":\"IDLE\",\"latestRunId\":\"$run2\"}"
  fake_response "$home" "GET v1/agents/$AGENT/runs/$run2" \
    "{\"id\":\"$run2\",\"status\":\"FINISHED\",\"result\":\"done\",\"git\":{\"branches\":[{\"branch\":\"cursor/x\",\"prUrl\":\"$PR\"}]}}"
  run_cloud "$home" poll t2
  assert_equals "cursor-cloud t2 run=$run2 FINISHED pr=$PR" "$OUT" "new run has distinct terminal identity"

  local run3=run-bbbbbbbb-cccc-dddd-eeee-ffffffffffff
  fake_response "$home" "GET v1/agents/$AGENT" "{\"id\":\"$AGENT\",\"status\":\"ACTIVE\",\"latestRunId\":\"$run3\"}"
  fake_response "$home" "GET v1/agents/$AGENT/runs/$run3" \
    "{\"id\":\"$run3\",\"status\":\"RUNNING\",\"git\":{\"branches\":[{\"branch\":\"cursor/x\",\"prUrl\":\"$PR\"}]}}"
  run_cloud "$home" poll t2
  assert_equals "cursor-cloud t2 run=$run3 pr-opened pr=$PR" "$OUT" "new run has distinct PR-opened identity"
  fake_response "$home" "GET v1/agents/$AGENT" "{\"id\":\"$AGENT\",\"status\":\"IDLE\",\"latestRunId\":\"$RUN\"}"

  run_cloud "$home" pr t2
  assert_equals "$PR" "$OUT" "pr subcommand"

  PRSTATE=OPEN run_cloud "$home" cleanup t2
  expect_code 3 "$RC" "cleanup with an unmerged PR"
  assert_present "$home/state/t2.cloud" "refused cleanup removed the record"

  PRSTATE=MERGED run_cloud "$home" cleanup t2
  expect_code 0 "$RC" "cleanup after merge: $ERR"
  assert_grep "POST v1/agents/$AGENT/archive" "$home/cursor/calls.log"
  assert_absent "$home/state/t2.cloud" "cleanup left the record"
  assert_absent "$home/state/t2.check.sh" "cleanup left the watcher check"
  pass "dispatch records and registers, poll wakes once, cleanup refuses unlanded work"
}

test_cancel() {
  local home
  home=$(make_home cancel "$row_ok")
  printf 'agent_id=%s\nrun_id=%s\nrepo=https://github.com/octo/demo\n' "$AGENT" "$RUN" > "$home/state/t3.cloud"
  fake_response "$home" "GET v1/agents/$AGENT" "{\"id\":\"$AGENT\",\"status\":\"ACTIVE\",\"latestRunId\":\"$RUN\"}"
  fake_response "$home" "GET v1/agents/$AGENT/runs/$RUN" "{\"id\":\"$RUN\",\"status\":\"RUNNING\"}"
  run_cloud "$home" cancel t3
  expect_code 0 "$RC" "cancel: $ERR"
  assert_grep "POST v1/agents/$AGENT/runs/$RUN/cancel" "$home/cursor/calls.log"

  fake_response "$home" "GET v1/agents/$AGENT" '{"error":{"message":"bad key"}}' 401
  run_cloud "$home" status t3
  expect_code 4 "$RC" "rejected key"
  assert_contains "$ERR" "was rejected" "rejected key names the captain step"

  fake_response "$home" "GET v1/agents/$AGENT" '{"status":"ACTIVE"}'
  run_cloud "$home" status t3
  expect_code 1 "$RC" "agent response missing latestRunId"
  assert_contains "$ERR" "invalid-response" "malformed agent response is rejected"

  fake_response "$home" "GET v1/agents/$AGENT" "{\"id\":\"$AGENT\",\"status\":\"ACTIVE\",\"latestRunId\":\"$RUN\"}"
  fake_response "$home" "GET v1/agents/$AGENT/runs/$RUN" '{"status":"RUNNING","git":{"branches":[{"branch":4}]}}'
  run_cloud "$home" status t3
  expect_code 1 "$RC" "run response with wrong-typed branch"
  assert_contains "$ERR" "invalid-response" "malformed run response is rejected"
  pass "cancel posts to the active run and malformed reads are rejected"
}

test_spawn_refuses_cloud_id() {
  local home rc=0 err
  home=$(make_home spawn "$row_ok")
  printf 'agent_id=%s\n' "$AGENT" > "$home/state/t4.cloud"
  err=$(FM_HOME="$home" "$ROOT/bin/fm-spawn.sh" t4 "$home/projects/demo" --mode no-mistakes --yolo off 2>&1 >/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-spawn accepted a cloud task id"
  assert_contains "$err" "Cursor cloud agent" "fm-spawn refusal names the cloud record"
  pass "fm-spawn refuses a task id owned by a cloud record"
}

test_boundary_refusals
test_dry_run_and_credential
test_dispatch_poll_cleanup
test_cancel
test_spawn_refuses_cloud_id
