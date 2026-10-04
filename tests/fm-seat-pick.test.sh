#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/environment.sh"
fm_test_sanitize_environment
# tests/fm-seat-pick.test.sh - bin/fm-seat-pick.sh: the opt-in gate, the code-owned
# candidate rule, the Jev pick bands and lead-decides fallbacks, the outbound data
# boundary, and the deterministic reroute plan. A fake curl replays canned
# answers, so no case touches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEAT_PICK="$ROOT/bin/fm-seat-pick.sh"
TMP_ROOT=$(fm_test_tmproot fm-seat-pick)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'
RESPONSE="$TMP_ROOT/response.json"
SEATS="$TMP_ROOT/seats.json"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$LOG"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --max-time) shift 2 ;;
    *) shift ;;
  esac
done
cat > "$FAKE_CURL_LOG/body"
printf 'call\n' >> "$FAKE_CURL_LOG/calls"
[ "${FAKE_CURL_FAIL:-0}" = 1 ] && exit 7
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '200'
SH
chmod +x "$FAKEBIN/curl"

cat > "$SEATS" <<'JSON'
[{"seat":"b-claude-1","role":"builder","family":"claude","running":true,"idle":true,"open_work":0,"quality":0.8,"note":"finished a CSS slice"},
 {"seat":"b-codex-1","role":"builder","family":"codex","running":true,"idle":true,"open_work":0,"quality":0.9},
 {"seat":"b-codex-2","role":"builder","family":"codex","running":true,"idle":false,"open_work":0},
 {"seat":"b-codex-3","role":"builder","family":"codex","running":true,"idle":true,"open_work":1,"note":"one queued fix"},
 {"seat":"b-kimi-1","role":"builder","family":"kimi","running":false,"idle":true,"open_work":0},
 {"seat":"b-grok-1","role":"builder","family":"grok","running":true,"idle":true,"open_work":0,"available":false},
 {"seat":"b-grok-2","role":"builder","family":"grok","running":true,"idle":true,"open_work":0,"context":98},
 {"seat":"r-grok-3","role":"reviewer","family":"grok","running":true,"idle":true,"open_work":0}]
JSON

seat_response() {  # <choice> <confidence>
  cat > "$RESPONSE" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "seat": { "type": "choice", "choice": "$1", "confidence": $2 } } }
JSON
}

# run_seat <exit-var> <out-var> [env=value...] -- <args...>   (stdin from $SEAT_STDIN)
run_seat() {
  local __exit=$1 __out=$2 _out _code=0
  local -a envs=()
  shift 2
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  rm -f "$LOG/body" "$LOG/calls"
  _out=$(env PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" TYPESAFE_API_KEY="$TS_KEY" FAKE_CURL_LOG="$LOG" \
    FAKE_CURL_RESPONSE="$RESPONSE" ${envs[@]+"${envs[@]}"} \
    "$SEAT_PICK" "$@" < "${SEAT_STDIN:-$SEATS}" 2>/dev/null) || _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
}

test_off_by_default() {
  local code out
  rm -f "$HOME_DIR/config/seat-pick"
  run_seat code out -- candidates --role builder
  expect_code 3 "$code" "an unflagged home is off"
  assert_equals '' "$out" "off prints nothing on stdout"
  : > "$HOME_DIR/config/seat-pick"
  run_seat code out FM_SEAT_PICK=0 -- pick --role builder --task 'x'
  expect_code 3 "$code" "FM_SEAT_PICK=0 forces off over the flag"
  [ ! -e "$LOG/calls" ] || fail "an off pick reached the network"
  rm -f "$HOME_DIR/config/seat-pick"
  run_seat code out FM_SEAT_PICK=1 -- candidates --role builder
  expect_code 0 "$code" "FM_SEAT_PICK=1 turns it on without the flag"
  pass "seat picking stays off unless config/seat-pick or FM_SEAT_PICK=1 opts in"
}

test_candidates_are_code_owned() {
  local code out
  : > "$HOME_DIR/config/seat-pick"
  run_seat code out -- candidates --role builder
  expect_code 0 "$code" "candidates exits 0"
  assert_equals 'b-claude-1,b-codex-1,b-codex-3' "$(jq -r 'map(.id) | join(",")' <<<"$out")" \
    "running idle seats with or without open work are candidates"
  jq -e '.[0].text | contains("load note: finished a CSS slice") and contains("quality 0.8")' <<<"$out" >/dev/null \
    || fail "the candidate text lacks the load note or quality: $out"
  jq -e '.[] | select(.id == "b-codex-3") | .text | contains("1 open work") and contains("load note: one queued fix")' <<<"$out" >/dev/null \
    || fail "the idle seat's open work and load note were not represented: $out"
  run_seat code out -- candidates --role builder --exclude-family codex
  assert_equals 'b-claude-1' "$(jq -r 'map(.id) | join(",")' <<<"$out")" "an excluded family is filtered in code"
  run_seat code out FM_SEAT_CONTEXT_WALL=99 -- candidates --role builder
  jq -e 'map(.id) | index("b-grok-2") != null' <<<"$out" >/dev/null \
    || fail "FM_SEAT_CONTEXT_WALL did not move the context wall"
  pass "code builds candidates from capacity, availability, the context wall, and family exclusions"
}

test_pick_bands_and_fallbacks() {
  local code out body
  : > "$HOME_DIR/config/seat-pick"
  seat_response b-codex-1 0.8
  run_seat code out -- pick --role builder --task 'add a button'
  expect_code 0 "$code" "an act-band pick exits 0"
  jq -e '.action == "dispatch" and .seat == "b-codex-1" and .band == "act"' <<<"$out" >/dev/null \
    || fail "an act-band listed seat did not dispatch: $out"
  body=$(cat "$LOG/body")
  jq -e '.questions.seat.criteria | has("b-claude-1") and has("b-codex-1") and has("none_fit") and (has("b-codex-2") | not)' \
    <<<"$body" >/dev/null || fail "the question does not offer exactly the candidates plus none_fit: $body"

  seat_response b-claude-1 0.4
  run_seat code out -- pick --role builder --task 'add a button'
  jq -e '.action == "lead-decides" and .seat == "b-claude-1" and .band == "review"' <<<"$out" >/dev/null \
    || fail "a review-band pick did not hand the choice to the lead with a suggestion: $out"

  seat_response b-codex-2 0.9
  run_seat code out -- pick --role builder --task 'add a button'
  jq -e '.action == "lead-decides" and .seat == null' <<<"$out" >/dev/null \
    || fail "a pick of an unlisted seat dispatched: $out"

  seat_response none_fit 0.9
  run_seat code out -- pick --role builder --task 'add a button'
  jq -e '.action == "lead-decides" and .seat == null' <<<"$out" >/dev/null \
    || fail "none_fit dispatched: $out"

  run_seat code out FAKE_CURL_FAIL=1 -- pick --role builder --task 'add a button'
  expect_code 0 "$code" "a Jev error never blocks the caller"
  jq -e '.action == "lead-decides" and (.reason | contains("no answer"))' <<<"$out" >/dev/null \
    || fail "a Jev error did not fall back to the lead: $out"

  run_seat code out TYPESAFE_API_KEY= -- pick --role builder --task 'add a button'
  jq -e '.action == "lead-decides" and (.reason | contains("off"))' <<<"$out" >/dev/null \
    || fail "a keyless home did not fall back to the lead: $out"
  [ ! -e "$LOG/calls" ] || fail "a keyless pick reached the network"

  run_seat code out -- pick --role designer --task 'draw a logo'
  jq -e '.action == "lead-decides" and (.reason | contains("no eligible idle designer seat"))' <<<"$out" >/dev/null \
    || fail "no candidate did not fall back to the lead: $out"
  [ ! -e "$LOG/calls" ] || fail "a pick with no candidate reached the network"
  pass "act dispatches a listed seat; every other answer or failure hands the choice to the lead"
}

test_pick_data_boundary() {
  local code out task body
  : > "$HOME_DIR/config/seat-pick"
  rm -f "$HOME_DIR/state/jev-seat-pick.jsonl"
  seat_response b-codex-1 0.8
  task="TASKMARK fix login with api_key=sk-or-abcdefghijklmnop0123 $(printf '%400s' '' | tr ' ' 'z')"
  run_seat code out -- pick --role builder --task "$task"
  body=$(cat "$LOG/body")
  jq -e '.state.task | contains("TASKMARK") and (contains("sk-or-abcdefghijklmnop0123") | not) and (length <= 300)' \
    <<<"$body" >/dev/null || fail "the task text was not capped and scrubbed before sending: $body"
  jq -n --slurpfile seats "$SEATS" '$seats[0] | map(if .seat == "b-claude-1" then .note = "finished sk-or-abcdefghijklmnop0123" else . end)' > "$TMP_ROOT/secret-note-seats.json"
  SEAT_STDIN="$TMP_ROOT/secret-note-seats.json" run_seat code out -- pick --role builder --task 'TASKMARK ordinary task'
  body=$(cat "$LOG/body")
  jq -e '[.state.seats[].text, (.questions.seat.criteria[])] | all(contains("sk-or-abcdefghijklmnop0123") | not)' \
    <<<"$body" >/dev/null || fail "a candidate note escaped redaction in the Jev request: $body"
  local secret_role='builder api_key=sk-or-abcdefghijklmnop0123'
  jq --arg role "$secret_role" 'map(.role = $role)' "$SEATS" > "$TMP_ROOT/secret-role-seats.json"
  SEAT_STDIN="$TMP_ROOT/secret-role-seats.json" run_seat code out -- pick --role "$secret_role" --task 'ordinary task'
  body=$(cat "$LOG/body")
  jq -e '(.state.role | contains("sk-or-abcdefghijklmnop0123") | not) and
    ([.state, .questions] | tostring | contains("sk-or-abcdefghijklmnop0123") | not)' \
    <<<"$body" >/dev/null || fail "the role escaped redaction in the Jev request: $body"
  run_seat code out JEV_STATE_MAX_BYTES=1 -- pick --role builder --task 'ordinary task'
  jq -e '.action == "lead-decides" and (.reason | contains("safely compacted"))' <<<"$out" >/dev/null \
    || fail "a compacting failure did not fail closed: $out"
  [ ! -e "$LOG/calls" ] || fail "uncompacted Jev input reached the network"
  assert_present "$HOME_DIR/state/jev-seat-pick.jsonl" "every attempted pick appends an audit record"
  ! grep -F 'TASKMARK' "$HOME_DIR/state/jev-seat-pick.jsonl" >/dev/null \
    || fail "the audit record kept the task text"
  jq -se 'any(.[]; .purpose == "seat-pick" and .choice == "b-codex-1" and .band == "act" and .candidates >= 3)' \
    "$HOME_DIR/state/jev-seat-pick.jsonl" >/dev/null \
    || fail "the audit record lacks the decision fields: $(cat "$HOME_DIR/state/jev-seat-pick.jsonl")"
  pass "a pick sends a capped, scrubbed task summary and audits without the task text"
}

test_reroute_plan() {
  local code out plan
  : > "$HOME_DIR/config/seat-pick"
  plan="$TMP_ROOT/plan.json"
  jq -n --slurpfile s "$SEATS" '{
    seats: ($s[0] + [
      {seat: "b-dead", role: "builder", family: "claude", running: false},
      {seat: "b-cool", role: "builder", family: "claude", running: true, idle: true, available: false},
      {seat: "b-cool-soon", role: "builder", family: "claude", running: true, idle: true, available: false, back_at: 1000600},
      {seat: "b-busy-out", role: "builder", family: "claude", running: true, idle: false, available: false},
      {seat: "b-wall", role: "builder", family: "claude", running: true, idle: true, available: true, context: 98},
      {seat: "b-extra", role: "builder", family: "grok", running: true, idle: true, available: true, quality: 0.7},
      {seat: "b-final", role: "builder", family: "kimi", running: true, idle: true, available: true, quality: 0.6},
      {seat: "b-last", role: "builder", family: "llama", running: true, idle: true, available: true, quality: 0.5},
      {seat: "r-dead", role: "reviewer", family: "claude", running: false},
      {seat: "x-dead", family: "claude", running: false}]),
    rows: [
      {id: "q1", state: "pending", destination: "b-dead", updated: 0},
      {id: "q2", state: "in-progress", destination: "b-cool", updated: 999000},
      {id: "q3", state: "in-progress", destination: "b-dead", updated: 0},
      {id: "q4", state: "pending", destination: "human@team", updated: 0},
      {id: "q5", state: "pending", destination: "b-dead", updated: 0, tags: ["owner-decision"]},
      {id: "q6", state: "pending", destination: "b-dead", updated: 999990},
      {id: "q7", state: "pending", destination: "b-dead", updated: 0, exclude_families: ["claude", "codex", "grok", "kimi", "llama"]},
      {id: "q8", state: "pending", destination: "r-dead", updated: 0},
      {id: "q9", state: "pending", destination: "r-dead", updated: 0, author_family: "grok"},
      {id: "q10", state: "pending", destination: "x-dead", updated: 0},
      {id: "q11", state: "pending", destination: "b-dead", updated: 0, exclude_families: ["claude", "codex", "grok", "kimi", "llama"]},
      {id: "q12", state: "in-progress", destination: "b-busy-out", updated: 0},
      {id: "q13", state: "pending", destination: "b-cool-soon", updated: 999000},
      {id: "q14", state: "done", destination: "b-dead", updated: 0},
      {id: "q15", state: "pending", destination: "b-codex-1", updated: 0},
      {id: "q16", state: "pending", destination: "b-dead", updated: 0},
      {id: "q17", state: "in-progress", destination: "b-wall", updated: 0},
      {id: "q18", state: "in-progress", destination: "b-gone", role: "builder", updated: 0},
      {id: "q19", state: "pending", destination: "b-cool", updated: 999000}],
    moved: ["q16"]}' > "$plan"
  SEAT_STDIN=$plan run_seat code out -- reroute --now 1000000
  expect_code 0 "$code" "a reroute plan exits 0"
  jq -e '.moves | map(select(.id == "q1")) | .[0] | .to == "b-codex-1" and .why == "b-dead is not running"' <<<"$out" >/dev/null \
    || fail "a long-pending row on a dead seat did not move to the best free seat: $out"
  jq -e '.moves | map(select(.id == "q3")) | .[0] | .to == "b-claude-1" and (.why | contains("not running")) and (.note | contains("partial work"))' <<<"$out" >/dev/null \
    || fail "an aged in-progress row on a dead seat was not rerouted: $out"
  jq -e '.moves | map(select(.id == "q18")) | .[0] | .to == "b-extra" and (.why | contains("gone"))' <<<"$out" >/dev/null \
    || fail "an aged in-progress row on a gone seat was not rerouted by its recorded role: $out"
  jq -e '.moves | map(select(.id == "q19")) | .[0] | .to == "b-final" and .why == "b-cool cannot be served now"' <<<"$out" >/dev/null \
    || fail "a pending row on an unservable seat with no return time did not move after 5 minutes: $out"
  jq -e '[.moves[].id] | (index("q2") == null) and (index("q4") == null) and (index("q5") == null)
      and (index("q6") == null) and (index("q12") == null) and (index("q13") == null)
      and (index("q14") == null) and (index("q15") == null) and (index("q16") == null)
      and (index("q17") == null)' <<<"$out" >/dev/null \
    || fail "a protected or settled row was planned: $out"
  jq -e '.moves | map(select(.id == "q7")) | .[0] | .to == null and (.note | contains("outside claude, codex, grok, kimi, llama"))' <<<"$out" >/dev/null \
    || fail "an excluded-family row was not left for the lead: $out"
  jq -e '.moves | map(select(.id == "q8")) | .[0] | .to == null and (.note | contains("author family"))' <<<"$out" >/dev/null \
    || fail "a review row without its author family was moved: $out"
  jq -e '.moves | map(select(.id == "q9")) | .[0] | .to == null' <<<"$out" >/dev/null \
    || fail "a review row moved to its author family: $out"
  jq -e '.moves | map(select(.id == "q10")) | .[0] | .to == null and (.note | contains("no role"))' <<<"$out" >/dev/null \
    || fail "a row on a seat without a role was moved: $out"
  jq -e '.moves | map(select(.id == "q11")) | .[0] | .to == null' <<<"$out" >/dev/null \
    || fail "one free seat took two rows in one pass: $out"
  pass "reroute plans moves off dead or unservable seats, keeps in-progress rows on running seats, keeps constraints, and never moves human or settled rows"
}

test_usage_errors() {
  local code out
  : > "$HOME_DIR/config/seat-pick"
  run_seat code out -- reroute --minutes 3
  expect_code 2 "$code" "--minutes below 5 is a usage error"
  run_seat code out -- pick --role builder
  expect_code 2 "$code" "pick without --task is a usage error"
  run_seat code out -- bogus
  expect_code 2 "$code" "an unknown command is a usage error"
  SEAT_STDIN=/dev/null run_seat code out -- candidates --role builder
  expect_code 1 "$code" "unreadable seats fail"
  pass "usage errors and malformed input refuse"
}

test_off_by_default
test_candidates_are_code_owned
test_pick_bands_and_fallbacks
test_pick_data_boundary
test_reroute_plan
test_usage_errors
