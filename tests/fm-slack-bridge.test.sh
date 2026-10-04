#!/usr/bin/env bash
# Behavior tests for bin/fm-slack-bridge.sh and its id reader bin/fm-slack-read.mjs.
#
# slack-axi is replaced by a fake installed package: a CLI that answers
# `draft`, `draft send`, `draft discard`, and `channels`, plus the two internal
# modules the reader loads (session.js, slack/threads.js), which serve messages
# from a per-case JSON fixture. The cases pin the bridge contract end to end:
# a post is sent and recorded, the captain's thread reply reaches the captain
# inbox exactly once, nobody else's reply ever does, a handoff-channel message
# arrives as a marked request, an unverified slack-axi keeps inbound off, and
# the bridge is off without config.
#
# The bot transport (bin/fm-slack-bot.mjs) is driven against a loopback fake of
# the Slack Web API and a fake macOS `security` tool that holds a fake bot
# token. Those cases pin that a bot posts instead of slack-axi, that only the
# captain's DMs and thread replies are delivered (never another person or
# another bot), that a reply recorded with `fm-inbox.sh reply` goes back into
# the same DM or thread exactly once, and that the token never reaches a record,
# an output, or a non-loopback host. No case contacts Slack.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE="$ROOT/bin/fm-slack-bridge.sh"
TMP_ROOT=$(fm_test_tmproot fm-slack-bridge)
command -v node >/dev/null 2>&1 || fail "fm-slack-bridge tests need node"

CAPTAIN=U0CAPTAIN1
OTHER=U0MARCO001
FILER=U0FILER001
NOW=1791140100

# make_pkg <dir> <version>: a fake slack-axi install whose CLI is reachable
# through <dir>/fakebin/slack-axi, the way a global npm install links it.
make_pkg() {
  local dir=$1 version=$2 pkg="$1/pkg"
  mkdir -p "$pkg/dist/bin" "$pkg/dist/src/slack" "$dir/fakebin"
  printf '{"name":"slack-axi","version":"%s","type":"module"}\n' "$version" > "$pkg/package.json"
  cat > "$pkg/dist/bin/slack-axi.js" <<'JS'
#!/usr/bin/env node
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
const args = process.argv.slice(2);
const log = process.env.FM_TEST_SLACK_LOG;
if (log) appendFileSync(log, JSON.stringify(args) + "\n");
const ids = { "#fm-yelen": "C0REPORT01", "#entscheidungen": "C0DECIDE01", "#fm-handoff": "C0HANDOFF1" };
const counter = process.env.FM_TEST_SLACK_COUNTER;
if (args[0] === "draft" && args[1] === "send") {
  if (process.env.FM_TEST_SLACK_SEND_FAIL === "1") { console.log("error: channel_not_found"); process.exit(1); }
  let n = existsSync(counter) ? Number(readFileSync(counter, "utf-8")) : 0;
  n += 1;
  writeFileSync(counter, String(n));
  console.log(`sent: ${args[2]}\nchannel: "#fm-yelen (C0REPORT01)"\nts: "17911400000000${String(n).padStart(2, "0")}"`);
} else if (args[0] === "draft" && args[1] === "discard") {
  console.log(`discarded: ${args[2]}`);
} else if (args[0] === "draft") {
  const positional = args.slice(1).filter((a) => !a.startsWith("-"));
  const id = ids[positional[0]] || positional[0];
  console.log(`draft: d_test0001\nchannel: "${positional[0]} (${id})"\ntext: ${positional.slice(1).join(" ")}`);
} else if (args[0] === "channels") {
  console.log("workspace: Test (T0TEST)\nchannels[3]{id,name,type}:");
  for (const [name, id] of Object.entries(ids)) console.log(`  ${id},${name},public`);
} else {
  console.log("error: unsupported in fake");
  process.exit(2);
}
JS
  chmod +x "$pkg/dist/bin/slack-axi.js"
  cat > "$pkg/dist/src/session.js" <<'JS'
import { readFileSync } from "node:fs";
const fixture = () => JSON.parse(readFileSync(process.env.FM_TEST_SLACK_FIXTURE, "utf-8"));
export async function activeSession() {
  return {
    token: "xoxp-never-printed",
    client: { users: { info: async ({ user }) => ({ user: { profile: { display_name: (fixture().names || {})[user] || "" } } }) } },
  };
}
JS
  cat > "$pkg/dist/src/slack/threads.js" <<'JS'
import { readFileSync } from "node:fs";
const fixture = () => JSON.parse(readFileSync(process.env.FM_TEST_SLACK_FIXTURE, "utf-8"));
export async function fetchWindow(_session, channel, oldestMs) {
  return ((fixture().history || {})[channel] || []).filter((m) => Number(m.ts) * 1000 >= oldestMs);
}
export async function fetchThread(_session, channel, ts) {
  return ((fixture().threads || {})[`${channel}:${ts}`] || []);
}
JS
  ln -sf "$pkg/dist/bin/slack-axi.js" "$dir/fakebin/slack-axi"
}

# make_home <name> [version]: a scratch home with its own fake slack-axi.
make_home() {
  local name=$1 version=${2:-1.2.0} home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config"
  make_pkg "$home" "$version"
  printf '{}\n' > "$home/fixture.json"
  printf '%s\n' "$home"
}

write_config() {
  local home=$1
  printf '%s\n' \
    '# Slack bridge for this home' \
    'report-channel=#fm-yelen' \
    'decisions-channel=#entscheidungen' \
    'handoff-channel=#fm-handoff' \
    "captain-user=$CAPTAIN" > "$home/config/slack-bridge"
}

bridge() {  # <home> <args...>
  local home=$1
  shift
  env FM_HOME="$home" PATH="$home/fakebin:$PATH" \
    FM_TEST_SLACK_FIXTURE="$home/fixture.json" FM_TEST_SLACK_LOG="$home/slack.log" \
    FM_TEST_SLACK_COUNTER="$home/counter" FM_SLACK_BRIDGE_NOW="$NOW" FM_CHECK_TIMEOUT=30 \
    "$BRIDGE" "$@"
}

note_count() {  # <home> [source]
  local home=$1 source=${2:-} n=0 f
  for f in "$home/state/inbox"/*.note; do
    [ -e "$f" ] || continue
    if [ -z "$source" ] || grep -qx "source=$source" "$f"; then
      n=$((n + 1))
    fi
  done
  printf '%s\n' "$n"
}

wake_rows() {  # <home>
  local n=0
  [ -f "$1/state/.wake-queue" ] && n=$(grep -c $'\tcheck\tinbox:' "$1/state/.wake-queue")
  printf '%s\n' "$n"
}

test_bridge_is_off_without_config() {
  local home out rc=0
  home=$(make_home off)
  out=$(bridge "$home" post report "PR ready" 2>&1) || rc=$?
  expect_code 0 "$rc" "post without config exits 0"
  assert_contains "$out" "slack bridge off" "post without config says the bridge is off"
  assert_absent "$home/slack.log" "post without config never calls slack-axi"
  out=$(bridge "$home" check 2>&1) || fail "check without config must succeed: $out"
  assert_equals "" "$out" "check without config is silent"
  assert_absent "$home/state/slack-bridge" "an off bridge writes no state"
  rc=0
  out=$(bridge "$home" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm without config is refused"
  assert_absent "$home/state/slack-bridge.check.sh" "a refused arm leaves no shim"
  pass "fm-slack-bridge: off without config"
}

test_post_sends_and_records() {
  local home out
  home=$(make_home post)
  write_config "$home"
  out=$(bridge "$home" post report --url https://github.com/o/r/pull/7 "PR ready for review" 2>&1) \
    || fail "post must succeed: $out"
  assert_contains "$out" "posted report C0REPORT01 1791140000.000001" "post names the channel id and dotted ts"
  assert_grep $'v1\tC0REPORT01\t1791140000.000001\treport\t' "$home/state/slack-bridge/posts" "the post is recorded with its channel id and ts"
  assert_grep '"draft","#fm-yelen","PR ready for review\nhttps://github.com/o/r/pull/7"' "$home/slack.log" "the report goes to the report channel with its URL"
  assert_grep '["draft","send","d_test0001"]' "$home/slack.log" "the draft is sent"

  out=$(bridge "$home" post decision -- "-1 on option B; recommend A" 2>&1) || fail "decision post must succeed: $out"
  assert_contains "$out" "posted decision" "a decision post succeeds"
  assert_grep '"draft","#entscheidungen","'$'\xe2\x80\x8b''-1 on option B; recommend A"' "$home/slack.log" \
    "a decision goes to the decisions channel and a leading dash survives as text"

  FM_TEST_SLACK_SEND_FAIL=1 bridge "$home" post report "lost" >"$home/fail.out" 2>&1 \
    && fail "an unconfirmed send must fail"
  assert_grep "did not confirm" "$home/fail.out" "an unconfirmed send says so"
  assert_grep '["draft","discard","d_test0001"]' "$home/slack.log" "an unconfirmed draft is discarded"
  assert_equals 2 "$(grep -c '^v1' "$home/state/slack-bridge/posts")" "a failed post is not recorded"
  pass "fm-slack-bridge: post sends, records, and refuses an unconfirmed send"
}

# A posted report thread with replies from the captain and from someone else.
write_thread_fixture() {
  local home=$1
  cat > "$home/fixture.json" <<JSON
{
  "names": {"$OTHER": "Marco", "$FILER": "Nora"},
  "history": {
    "C0REPORT01": [{"ts": "1791140000.000001", "user": "$CAPTAIN", "text": "PR ready", "replyCount": 3}],
    "C0HANDOFF1": [
      {"ts": "1791140150.000001", "user": "$OTHER", "subtype": "channel_join", "text": "joined"},
      {"ts": "1791140160.000001", "user": "$OTHER", "text": "can you review lay#12?"},
      {"ts": "1791140165.000001", "user": "$FILER", "subtype": "file_share", "text": ""},
      {"ts": "1791140170.000001", "user": "$CAPTAIN", "text": "my own ask to Marco"}
    ]
  },
  "threads": {
    "C0REPORT01:1791140000.000001": [
      {"ts": "1791140000.000001", "user": "$CAPTAIN", "text": "PR ready", "replyCount": 3},
      {"ts": "1791140010.000001", "user": "$OTHER", "text": "merge"},
      {"ts": "1791140020.000001", "user": "$CAPTAIN", "text": "merge &amp; ship"},
      {"ts": "1791140030.000001", "user": "$CAPTAIN", "botId": "B01", "text": "bot echo"}
    ]
  }
}
JSON
}

test_captain_reply_delivered_once_and_others_ignored() {
  local home out note
  home=$(make_home inbound)
  write_config "$home"
  bridge "$home" arm >/dev/null 2>&1 || fail "arm must succeed"
  assert_present "$home/state/slack-bridge.check.sh" "arm writes the check shim"
  assert_present "$home/state/slack-bridge.check-trust" "arm binds the check shim"
  bridge "$home" post report "PR ready" >/dev/null 2>&1 || fail "post must succeed"
  write_thread_fixture "$home"

  out=$(bridge "$home" check 2>&1) || fail "check must succeed: $out"
  assert_contains "$out" "slack: delivered 1 captain reply(s) and 2 handoff request(s)" "check prints one wake line for what it delivered"
  assert_equals 1 "$(note_count "$home" slack-captain)" "exactly one captain note"
  note=$(grep -l '^source=slack-captain$' "$home/state/inbox"/*.note)
  assert_grep "merge & ship" "$note" "the captain's reply text arrives decoded"
  assert_grep "captain reply in thread of report: PR ready" "$note" "the note names the post it answers"
  assert_no_grep "bot echo" "$note" "a bot message is never captain input"
  if grep -rq -- $'^merge$' "$home/state/inbox"; then
    fail "the other person's 'merge' must never become a note"
  fi

  # A file-only message with empty text must not shift the reader's columns.
  note=$(grep -l "($FILER)" "$home/state/inbox"/*.note)
  assert_grep "request from Nora ($FILER) in handoff channel C0HANDOFF1, ts 1791140165.000001" "$note" "an empty field keeps every column in place"
  note=$(grep -l "($OTHER)" "$home/state/inbox"/*.note)
  assert_grep "request from Marco ($OTHER)" "$note" "a handoff message names its sender"
  assert_grep "not captain authority" "$note" "a handoff message is marked as a request, not authority"
  assert_grep "can you review lay#12?" "$note" "the handoff text arrives"
  assert_equals 3 "$(note_count "$home")" "joins and the captain's own handoff message are not delivered"
  assert_equals 3 "$(wake_rows "$home")" "each delivered note has its single wake"

  out=$(bridge "$home" check 2>&1) || fail "second check must succeed: $out"
  assert_equals "" "$out" "a repeat poll with nothing new is silent"
  assert_equals 3 "$(note_count "$home")" "a repeat poll delivers nothing again"
  assert_equals 3 "$(wake_rows "$home")" "a repeat poll adds no wake"

  # Losing the local delivered record (a crash right after delivery) must not
  # duplicate: the inbox request id replays the original note.
  rm -f "$home/state/slack-bridge/delivered"
  printf '%s.000000\n' 1791140000 > "$home/state/slack-bridge/handoff-cursor"
  bridge "$home" check >/dev/null 2>&1 || fail "recovery check must succeed"
  assert_equals 3 "$(note_count "$home")" "a replayed delivery creates no second note"
  assert_equals 3 "$(wake_rows "$home")" "a replayed delivery adds no second wake"
  if grep -rq 'xoxp-' "$home/state" "$home/config"; then
    fail "no token may reach the home's records"
  fi
  pass "fm-slack-bridge: captain reply delivered once, others ignored, handoff marked as request"
}

test_macOS_base64_fallback_decodes_inbound_fields() {
  local home real_base64 out note
  home=$(make_home darwin-base64)
  write_config "$home"
  bridge "$home" arm >/dev/null 2>&1 || fail "arm must succeed"
  bridge "$home" post report "PR ready" >/dev/null 2>&1 || fail "post must succeed"
  write_thread_fixture "$home"
  real_base64=$(command -v base64)
  mkdir -p "$home/macbin"
  cat > "$home/macbin/base64" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --decode) exit 1 ;;
  -D) shift; exec "$real_base64" --decode "\$@" ;;
  *) exec "$real_base64" "\$@" ;;
esac
SH
  chmod +x "$home/macbin/base64"
  out=$(env FM_HOME="$home" PATH="$home/macbin:$home/fakebin:$PATH" \
    FM_TEST_SLACK_FIXTURE="$home/fixture.json" FM_TEST_SLACK_LOG="$home/slack.log" \
    FM_TEST_SLACK_COUNTER="$home/counter" FM_SLACK_BRIDGE_NOW="$NOW" FM_CHECK_TIMEOUT=30 \
    "$BRIDGE" check 2>&1) || fail "check with macOS base64 must succeed: $out"
  assert_contains "$out" "delivered 1 captain reply(s) and 2 handoff request(s)" "the -D fallback delivers inbound messages"
  note=$(grep -l '^source=slack-captain$' "$home/state/inbox"/*.note)
  assert_grep "merge & ship" "$note" "captain reply text decodes with base64 -D"
  note=$(grep -l "($OTHER)" "$home/state/inbox"/*.note)
  assert_grep "request from Marco ($OTHER)" "$note" "handoff sender name decodes with base64 -D"
  pass "fm-slack-bridge: macOS base64 fallback decodes inbound fields"
}

test_unverified_slack_axi_keeps_inbound_off() {
  local home out
  home=$(make_home unverified 9.9.9)
  write_config "$home"
  bridge "$home" post report "PR ready" >/dev/null 2>&1 || fail "post must still work"
  write_thread_fixture "$home"
  out=$(bridge "$home" check 2>&1) || fail "check must succeed: $out"
  assert_contains "$out" "slack-axi 9.9.9 is not a verified version" "an unverified slack-axi is reported"
  assert_equals 0 "$(note_count "$home")" "an unverified slack-axi delivers nothing"
  out=$(bridge "$home" check 2>&1) || fail "repeat check must succeed: $out"
  assert_equals "" "$out" "the same diagnostic is reported only once"
  pass "fm-slack-bridge: unverified slack-axi keeps inbound off with one report"
}

test_poll_cadence_state_and_validation() {
  local home out rc value
  home=$(make_home poll-cadence)
  write_config "$home"
  printf 'poll-seconds=60\n' >> "$home/config/slack-bridge"
  bridge "$home" arm >/dev/null 2>&1 || fail "arm with poll-seconds must succeed"
  assert_equals "60" "$(cat "$home/state/slack-bridge.check-every")" "arm writes the Slack poll cadence"
  write_config "$home"
  bridge "$home" check >/dev/null 2>&1 || fail "check without poll-seconds must succeed"
  assert_absent "$home/state/slack-bridge.check-every" "check removes an unset Slack poll cadence"
  bridge "$home" disarm >/dev/null 2>&1 || fail "disarm must succeed"
  assert_absent "$home/state/slack-bridge.check-every" "disarm removes the Slack poll cadence"

  for value in 5 abc ' 60' '60 '; do
    write_config "$home"
    printf 'poll-seconds=%s\n' "$value" >> "$home/config/slack-bridge"
    rc=0
    out=$(bridge "$home" arm 2>&1) || rc=$?
    expect_code 1 "$rc" "invalid poll-seconds '$value' is refused"
    assert_contains "$out" "poll-seconds" "invalid poll-seconds '$value' reports its key"
  done
  write_config "$home"
  printf 'poll-seconds=60\npoll-seconds=60\n' >> "$home/config/slack-bridge"
  rc=0
  out=$(bridge "$home" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "duplicate poll-seconds lines are refused"
  assert_contains "$out" "poll-seconds" "duplicate poll-seconds reports its key"
  pass "fm-slack-bridge: poll cadence state and validation"
}

test_invalid_config_is_reported() {
  local home out rc=0
  home=$(make_home badconfig)
  printf 'report-channel=#fm-yelen\ndecisions-channel=#entscheidungen\ncaptain-user=Yelen\n' > "$home/config/slack-bridge"
  out=$(bridge "$home" post report "x" 2>&1) || rc=$?
  expect_code 1 "$rc" "post with a bad captain id is refused"
  assert_contains "$out" "captain-user as a Slack user id" "the refusal names the bad value"
  out=$(bridge "$home" check 2>&1) || fail "check must succeed: $out"
  assert_contains "$out" "captain-user" "check reports the bad config once"
  pass "fm-slack-bridge: invalid config is refused and reported"
}

# ------------------------------------------------------------ bot transport

BOT_TOKEN=xoxb-test-token-0001
BOT_SERVICE=firstmate-slack-bot
BOT_CONTROL="$TMP_ROOT/bot-control"
BOT_READY="$TMP_ROOT/bot-ready"
BOT_PID=

bot_cleanup() {
  if [ -n "$BOT_PID" ]; then
    kill "$BOT_PID" 2>/dev/null || true
    wait "$BOT_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap bot_cleanup EXIT
trap 'bot_cleanup; exit 130' INT
trap 'bot_cleanup; exit 143' TERM

# A fake Slack Web API. The control file names the current case's home, whose
# bot-fixture.json serves history and threads; every call is logged without its
# Authorization header to bot-requests.jsonl, and a wrong token is refused.
cat > "$TMP_ROOT/fake-slack-api.mjs" <<'JS'
import http from "node:http";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
const [control, ready, token] = process.argv.slice(2);
const counters = new Map();
const accepted = new Map();
const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const home = readFileSync(control, "utf-8").trim();
    const method = req.url.replace(/^\/+/, "");
    const params = Object.fromEntries(new URLSearchParams(Buffer.concat(chunks).toString("utf-8")));
    const authorized = req.headers.authorization === `Bearer ${token}`;
    appendFileSync(`${home}/bot-requests.jsonl`, JSON.stringify({ method, params, authorized }) + "\n");
    const fixturePath = `${home}/bot-fixture.json`;
    const fixture = existsSync(fixturePath) ? JSON.parse(readFileSync(fixturePath, "utf-8")) : {};
    const reply = (body) => { res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify(body)); };
    if (!authorized) return reply({ ok: false, error: "invalid_auth" });
    if (method === "auth.test") return reply({ ok: true, user_id: "U0BOTYELEN", user: "yelens_firstmate", team_id: "T0DINKLE01" });
    if (method === "conversations.open") return reply({ ok: true, channel: { id: params.users === "U0CAPTAIN1" ? "D0DMCAPT01" : "D0DMOTHER1" } });
    if (method === "chat.postMessage") {
      if ((fixture.notInChannel || []).includes(params.channel)) return reply({ ok: false, error: "not_in_channel" });
      const n = (counters.get(home) || 0) + 1;
      counters.set(home, n);
      const message = { ts: `1791140500.${String(n).padStart(6, "0")}`, user: "U0BOTYELEN", bot_id: "B0YELEN001", text: params.text, thread_ts: params.thread_ts };
      if (!accepted.has(home)) accepted.set(home, []);
      accepted.get(home).push({ channel: params.channel, message });
      if (fixture.losePostResponseOnce) {
        fixture.losePostResponseOnce = false;
        writeFileSync(fixturePath, JSON.stringify(fixture));
        req.socket.destroy();
        return;
      }
      if (fixture.delayPostMs) {
        return setTimeout(() => reply({ ok: true, channel: params.channel, ts: message.ts }), Number(fixture.delayPostMs));
      }
      return reply({ ok: true, channel: params.channel, ts: message.ts });
    }
    if (method === "conversations.history") {
      const all = [...((fixture.history || {})[params.channel] || []), ...(accepted.get(home) || []).filter((x) => x.channel === params.channel).map((x) => x.message)];
      const oldest = Number(params.oldest || 0);
      const keep = all.filter((m) => (params.inclusive === "true" ? Number(m.ts) >= oldest : Number(m.ts) > oldest));
      const offset = Number(params.cursor || 0);
      const messages = keep.slice(offset, offset + 200);
      return reply({ ok: true, messages, response_metadata: offset + 200 < keep.length ? { next_cursor: String(offset + 200) } : { next_cursor: "" } });
    }
    if (method === "conversations.replies") {
      const seeded = (fixture.threads || {})[`${params.channel}:${params.ts}`] || [];
      const posted = (accepted.get(home) || []).filter((x) => x.channel === params.channel && x.message.thread_ts === params.ts).map((x) => x.message);
      const all = [...seeded, ...posted];
      const offset = Number(params.cursor || 0);
      const messages = all.slice(offset, offset + 200);
      return reply({ ok: true, messages, response_metadata: offset + 200 < all.length ? { next_cursor: String(offset + 200) } : { next_cursor: "" } });
    }
    return reply({ ok: false, error: "unknown_method" });
  });
});
server.listen(0, "127.0.0.1", () => writeFileSync(ready, String(server.address().port)));
JS
printf '%s\n' "$TMP_ROOT" > "$BOT_CONTROL"
node "$TMP_ROOT/fake-slack-api.mjs" "$BOT_CONTROL" "$BOT_READY" "$BOT_TOKEN" &
BOT_PID=$!
for _i in $(seq 1 50); do
  [ -s "$BOT_READY" ] && break
  kill -0 "$BOT_PID" 2>/dev/null || fail "the fake Slack API exited before it was ready"
  sleep 0.1
done
[ -s "$BOT_READY" ] || fail "the fake Slack API did not become ready"
BOT_API="http://127.0.0.1:$(cat "$BOT_READY")/"

# make_bot_home <name>: a home whose fake `security` holds the bot token under
# $BOT_SERVICE, and whose slack-axi logs any call so a bot home can prove it
# never used it.
make_bot_home() {
  local home
  home=$(make_home "$1")
  cat > "$home/fakebin/security" <<SH
#!/usr/bin/env bash
[ "\$1" = find-generic-password ] && [ "\$2" = -s ] && [ "\$3" = "$BOT_SERVICE" ] && [ "\$4" = -w ] || exit 44
printf '%s\n' "$BOT_TOKEN"
SH
  chmod +x "$home/fakebin/security"
  printf '%s\n' "$home" > "$BOT_CONTROL"
  printf '%s\n' "$home"
}

write_bot_config() {
  local home=$1
  printf '%s\n' \
    'report-channel=C0REPORT01' \
    'decisions-channel=C0DECIDE01' \
    "captain-user=$CAPTAIN" \
    "bot-keychain-service=$BOT_SERVICE" > "$home/config/slack-bridge"
}

bot_bridge() {  # <home> <args...>
  local home=$1
  shift
  env FM_SLACK_BOT_API_BASE="$BOT_API" FM_HOME="$home" PATH="$home/fakebin:$PATH" \
    FM_TEST_SLACK_FIXTURE="$home/fixture.json" FM_TEST_SLACK_LOG="$home/slack.log" \
    FM_TEST_SLACK_COUNTER="$home/counter" FM_SLACK_BRIDGE_NOW="$NOW" FM_CHECK_TIMEOUT=30 \
    "$BRIDGE" "$@"
}

bot_inbox() {  # <home> <args...>
  local home=$1
  shift
  env FM_SLACK_BOT_API_BASE="$BOT_API" FM_HOME="$home" PATH="$home/fakebin:$PATH" \
    FM_TEST_SLACK_LOG="$home/slack.log" "$ROOT/bin/fm-inbox.sh" "$@"
}

posted_requests() {  # <home> -> one "channel thread text" line per chat.postMessage
  # shellcheck disable=SC2016 # the template literal is JavaScript, not shell
  node -e '
    const fs = require("fs");
    for (const line of fs.readFileSync(process.argv[1], "utf-8").split("\n").filter(Boolean)) {
      const r = JSON.parse(line);
      if (r.method === "chat.postMessage") console.log(`${r.params.channel} ${r.params.thread_ts || "-"} ${r.params.text}`);
    }' "$1/bot-requests.jsonl"
}

assert_no_token() {  # <home> <text>...
  local home=$1
  shift
  if grep -rqF -- "$BOT_TOKEN" "$home/state" "$home/config"; then
    fail "the bot token must never reach the home's records"
  fi
  case "$*" in *"$BOT_TOKEN"*) fail "the bot token must never reach an output" ;; esac
}

test_bot_posts_instead_of_slack_axi() {
  local home out
  home=$(make_bot_home bot-post)
  write_bot_config "$home"
  out=$(bot_bridge "$home" post report --url https://github.com/o/r/pull/7 "PR ready for review" 2>&1) \
    || fail "bot post must succeed: $out"
  assert_contains "$out" "posted report C0REPORT01 1791140500.000001" "the bot post names the channel id and ts"
  assert_grep $'v1\tC0REPORT01\t1791140500.000001\treport\t' "$home/state/slack-bridge/posts" "the bot post is recorded"
  assert_contains "$(posted_requests "$home")" "C0REPORT01 - PR ready for review"$'\n'"https://github.com/o/r/pull/7" \
    "the bot posts the text and URL top-level in the report channel"
  out=$(bot_bridge "$home" post decision -- "-1 on option B; recommend A" 2>&1) || fail "bot decision post must succeed: $out"
  assert_contains "$(posted_requests "$home")" "C0DECIDE01 - -1 on option B; recommend A" "a bot needs no leading-dash workaround"
  assert_absent "$home/slack.log" "a bot home never calls slack-axi"
  assert_no_token "$home" "$out"
  pass "fm-slack-bridge: a bot posts instead of slack-axi"
}

write_bot_fixture() {
  local home=$1
  cat > "$home/bot-fixture.json" <<JSON
{
  "history": {
    "C0REPORT01": [{"ts": "1791140500.000001", "user": "U0BOTYELEN", "bot_id": "B0YELEN001", "text": "PR ready", "reply_count": 4}],
    "D0DMCAPT01": [
      {"ts": "1791140050.000001", "user": "$CAPTAIN", "text": "an old DM before arming"},
      {"ts": "1791140200.000001", "user": "$CAPTAIN", "text": "status &amp; next?"},
      {"ts": "1791140210.000001", "user": "U0BOTYELEN", "bot_id": "B0YELEN001", "text": "bot echo in the DM"}
    ]
  },
  "threads": {
    "C0REPORT01:1791140500.000001": [
      {"ts": "1791140500.000001", "user": "U0BOTYELEN", "bot_id": "B0YELEN001", "text": "PR ready", "reply_count": 4},
      {"ts": "1791140510.000001", "user": "$OTHER", "text": "merge"},
      {"ts": "1791140515.000001", "user": "U0MARCOBOT", "bot_id": "B0MARCO001", "text": "merge"},
      {"ts": "1791140520.000001", "user": "$CAPTAIN", "text": "merge it"},
      {"ts": "1791140530.000001", "user": "U0BOTYELEN", "bot_id": "B0YELEN001", "text": "bot echo in the thread"}
    ]
  }
}
JSON
}

test_bot_delivers_only_the_captain_and_replies_back() {
  local home out dm_note thread_note dm_id thread_id
  home=$(make_bot_home bot-inbound)
  write_bot_config "$home"
  out=$(bot_bridge "$home" arm 2>&1) || fail "bot arm must succeed: $out"
  assert_equals "$NOW.000000" "$(cat "$home/state/slack-bridge/dm-cursor")" "arm starts the bot DM at now"
  bot_bridge "$home" post report "PR ready" >/dev/null 2>&1 || fail "bot post must succeed"
  write_bot_fixture "$home"

  out=$(bot_bridge "$home" check 2>&1) || fail "bot check must succeed: $out"
  assert_contains "$out" "slack: delivered 2 captain reply(s) and 0 handoff request(s)" "the captain's DM and thread reply are delivered"
  assert_equals 2 "$(note_count "$home" slack-captain)" "exactly two captain notes"
  assert_equals 2 "$(note_count "$home")" "nobody else's message becomes a note"
  dm_note=$(grep -l "captain DM to this home's bot" "$home/state/inbox"/*.note)
  assert_grep "status & next?" "$dm_note" "the DM text arrives decoded"
  thread_note=$(grep -l "captain reply in thread of report: PR ready" "$home/state/inbox"/*.note)
  assert_grep "merge it" "$thread_note" "the thread reply text arrives"
  if grep -rqx 'merge' "$home/state/inbox"; then
    fail "another person's or another bot's 'merge' must never become a note"
  fi
  if grep -rq -e "bot echo" -e "an old DM" "$home/state/inbox"; then
    fail "bot messages and DMs from before arming must never become notes"
  fi
  assert_equals "1791140210.000001" "$(cat "$home/state/slack-bridge/dm-cursor")" "the DM cursor moves past what was read"
  out=$(bot_bridge "$home" check 2>&1) || fail "repeat bot check must succeed: $out"
  assert_equals "" "$out" "a repeat bot poll with nothing new is silent"
  assert_equals 2 "$(note_count "$home")" "a repeat bot poll delivers nothing again"

  dm_id=$(sed -n 's/^id=//p' "$dm_note")
  thread_id=$(sed -n 's/^id=//p' "$thread_note")
  out=$(bot_inbox "$home" reply "$dm_id" "all green, two PRs waiting" 2>&1) || fail "replying to a DM note must succeed: $out"
  assert_contains "$out" "replied $dm_id" "the reply is recorded"
  assert_contains "$out" "slack: reply to $dm_id posted D0DMCAPT01" "the reply is posted to Slack"
  assert_contains "$(posted_requests "$home")" "D0DMCAPT01 - all green, two PRs waiting" "a DM note's reply goes back into the DM"
  out=$(bot_inbox "$home" reply "$thread_id" "merging now" 2>&1) || fail "replying to a thread note must succeed: $out"
  assert_contains "$(posted_requests "$home")" "C0REPORT01 1791140500.000001 merging now" "a thread note's reply goes into the same thread"
  out=$(bot_bridge "$home" send-reply "$thread_id" 2>&1) || fail "a repeated send-reply must succeed: $out"
  assert_contains "$out" "already posted" "a repeated send-reply does not post twice"
  assert_equals 3 "$(posted_requests "$home" | grep -c .)" "one post plus exactly one post per reply"
  assert_absent "$home/slack.log" "a bot home never calls slack-axi"
  assert_no_token "$home" "$out"
  pass "fm-slack-bridge: a bot delivers only the captain's DMs and thread replies, and replies go back once"
}

test_reply_without_bot_stays_local() {
  local home out note id calls
  home=$(make_home nobot-reply)
  write_config "$home"
  bridge "$home" arm >/dev/null 2>&1 || fail "arm must succeed"
  bridge "$home" post report "PR ready" >/dev/null 2>&1 || fail "post must succeed"
  write_thread_fixture "$home"
  bridge "$home" check >/dev/null 2>&1 || fail "check must succeed"
  note=$(grep -l '^source=slack-captain$' "$home/state/inbox"/*.note)
  id=$(sed -n 's/^id=//p' "$note")
  calls=$(grep -c . "$home/slack.log")
  out=$(env FM_HOME="$home" PATH="$home/fakebin:$PATH" FM_TEST_SLACK_LOG="$home/slack.log" \
    "$ROOT/bin/fm-inbox.sh" reply "$id" "merging" 2>&1) || fail "reply without a bot must succeed: $out"
  assert_equals "replied $id" "$out" "a reply without a bot prints exactly what it did before"
  assert_equals "$calls" "$(grep -c . "$home/slack.log")" "a reply without a bot never calls slack-axi"
  assert_absent "$home/state/slack-bridge/replied" "a reply without a bot records no Slack post"
  pass "fm-slack-bridge: without a bot a reply stays local"
}

test_bot_reads_past_ten_pages() {
  local home out count
  home=$(make_bot_home bot-pages)
  node -e 'const fs=require("fs"); const messages=Array.from({length:2201},(_,i)=>({ts:`179114${String(i).padStart(4,"0")}.000001`,user:"U0CAPTAIN1",text:`message-${i}`})); fs.writeFileSync(process.argv[1],JSON.stringify({history:{C0HANDOFF1:messages}}));' "$home/bot-fixture.json"
  out=$(printf '{"keychain":"%s","history":[{"channel":"C0HANDOFF1","oldest":"1791140000.000000"}]}\n' "$BOT_SERVICE" | \
    env FM_SLACK_BOT_API_BASE="$BOT_API" FM_HOME="$home" PATH="$home/fakebin:$PATH" \
    node "$ROOT/bin/fm-slack-bot.mjs" read 2>&1) || fail "a paged bot read must succeed: $out"
  count=$(printf '%s\n' "$out" | awk -F '\t' '$1 == "message" { n++ } END { print n+0 }')
  assert_equals 2201 "$count" "the read returns every page, not only the first ten"
  pass "fm-slack-bridge: bot reads continue until pagination is complete"
}

test_lost_reply_response_is_found_before_retry() {
  local home note id out rc
  home=$(make_bot_home bot-lost-reply)
  write_bot_config "$home"
  bot_bridge "$home" arm >/dev/null 2>&1 || fail "bot arm must succeed"
  write_bot_fixture "$home"
  bot_bridge "$home" check >/dev/null 2>&1 || fail "bot check must succeed"
  note=$(grep -l '^source=slack-captain$' "$home/state/inbox"/*.note | head -n 1)
  id=$(sed -n 's/^id=//p' "$note")
  printf '{"losePostResponseOnce":true}\n' > "$home/bot-fixture.json"
  rc=0
  bot_inbox "$home" reply "$id" "accepted but response lost" >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "the ambiguous initial post is reported as failed"
  rc=0
  out=$(bot_bridge "$home" send-reply "$id" 2>&1) || rc=$?
  expect_code 0 "$rc" "the retry recognizes Slack's accepted post"
  assert_contains "$out" "already posted" "the retry records the existing reply"
  assert_equals 1 "$(posted_requests "$home" | grep -c .)" "the retry does not post a duplicate"
  assert_grep $'v1\t'"$id"$'\tD0DMCAPT01\t1791140500.000001' "$home/state/slack-bridge/replied" "the accepted reply is durably marked"
  node -e '
    const fs=require("fs");
    const rows=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);
    if (!rows.some(r => r.method === "conversations.history" && r.params.channel === "D0DMCAPT01" && r.params.oldest === "1791140200.000001" && r.params.inclusive === "true")) process.exit(1);
  ' "$home/bot-requests.jsonl" || fail "DM duplicate lookup must start at the incoming DM timestamp"
  pass "fm-slack-bridge: an ambiguous post is found before retry"
}

test_concurrent_send_reply_is_serialized() {
  local home note id p1 p2 rc1 rc2
  home=$(make_bot_home bot-concurrent-reply)
  write_bot_config "$home"
  bot_bridge "$home" arm >/dev/null 2>&1 || fail "bot arm must succeed"
  write_bot_fixture "$home"
  bot_bridge "$home" check >/dev/null 2>&1 || fail "bot check must succeed"
  note=$(grep -l '^source=slack-captain$' "$home/state/inbox"/*.note | head -n 1)
  id=$(sed -n 's/^id=//p' "$note")
  mkdir -p "$home/state/inbox/.replies"
  printf 'id=%s\n--\nconcurrent answer\n' "$id" > "$home/state/inbox/.replies/$id"
  node -e 'const fs=require("fs");const p=process.argv[1];const f=JSON.parse(fs.readFileSync(p,"utf8"));f.delayPostMs=250;fs.writeFileSync(p,JSON.stringify(f));' "$home/bot-fixture.json"
  bot_bridge "$home" send-reply "$id" >"$home/reply-one.out" 2>&1 & p1=$!
  bot_bridge "$home" send-reply "$id" >"$home/reply-two.out" 2>&1 & p2=$!
  rc1=0; wait "$p1" || rc1=$?
  rc2=0; wait "$p2" || rc2=$?
  expect_code 0 "$rc1" "the first concurrent send succeeds"
  expect_code 0 "$rc2" "the waiting send sees the posted reply"
  assert_equals 1 "$(posted_requests "$home" | grep -c .)" "concurrent send-reply calls produce one Slack post"
  assert_contains "$(cat "$home/reply-one.out" "$home/reply-two.out")" "already posted" "the waiting caller observes the existing reply"
  pass "fm-slack-bridge: concurrent reply attempts serialize"
}

test_bot_failures_are_safe() {
  local home out rc
  home=$(make_bot_home bot-fail)
  write_bot_config "$home"
  printf 'report-channel=C0REPORT01\ndecisions-channel=C0DECIDE01\ncaptain-user=%s\nbot-keychain-service=missing-item\n' \
    "$CAPTAIN" > "$home/config/slack-bridge"
  rc=0
  out=$(bot_bridge "$home" post report "x" 2>&1) || rc=$?
  expect_code 1 "$rc" "a missing Keychain item refuses the post"
  assert_contains "$out" "no Keychain item with service missing-item" "the refusal names the Keychain service"
  write_bot_config "$home"
  rc=0
  out=$(env FM_SLACK_BOT_API_BASE=https://slack.example/api/ FM_HOME="$home" PATH="$home/fakebin:$PATH" \
    "$BRIDGE" post report "x" 2>&1) || rc=$?
  expect_code 1 "$rc" "a non-loopback API override is refused"
  assert_contains "$out" "loopback" "the refusal says why"
  printf 'report-channel=#fm-yelen\ndecisions-channel=C0DECIDE01\ncaptain-user=%s\nbot-keychain-service=%s\n' \
    "$CAPTAIN" "$BOT_SERVICE" > "$home/config/slack-bridge"
  rc=0
  out=$(bot_bridge "$home" post report "x" 2>&1) || rc=$?
  expect_code 1 "$rc" "a bot with a #name channel is refused"
  assert_contains "$out" "channel id" "the refusal asks for channel ids"
  printf 'report-channel=C0REPORT01\ndecisions-channel=C0DECIDE01\ncaptain-user=%s\nbot-keychain-service=bad service\n' \
    "$CAPTAIN" > "$home/config/slack-bridge"
  rc=0
  out=$(bot_bridge "$home" post report "x" 2>&1) || rc=$?
  expect_code 1 "$rc" "an invalid Keychain service name is refused"
  assert_no_token "$home" "$out"
  pass "fm-slack-bridge: bot failures refuse without leaking the token"
}

test_bot_verify_round_trip() {
  local home out rc
  home=$(make_bot_home bot-verify)
  write_bot_config "$home"
  out=$(bot_bridge "$home" verify 2>&1) || fail "verify must succeed: $out"
  assert_contains "$out" "bot: U0BOTYELEN in team T0DINKLE01" "verify names the bot and team"
  assert_contains "$out" "posted test C0REPORT01" "verify posts to the report channel"
  assert_contains "$out" "posted test C0DECIDE01" "verify posts to the decisions channel"
  assert_contains "$out" "posted dm D0DMCAPT01" "verify DMs the captain"
  assert_contains "$(posted_requests "$home")" "C0REPORT01 - Setup test from firstmate: bot channel check (one-time setup test; ignore or delete)." "the report post is labeled for setup"
  assert_contains "$(posted_requests "$home")" "C0DECIDE01 - Setup test from firstmate: bot channel check (one-time setup test; ignore or delete)." "the decisions post is labeled for setup"
  assert_contains "$(posted_requests "$home")" "D0DMCAPT01 - Setup test from firstmate: reply to this one-time setup test to confirm the DM round trip; ignore or delete afterward." "the DM is labeled for setup"
  assert_grep $'\tD0DMCAPT01\t1791140500.000003\tverify\t' "$home/state/slack-bridge/posts" "the greeting DM is watched for thread replies"
  printf '{"notInChannel":["C0DECIDE01"]}\n' > "$home/bot-fixture.json"
  rc=0
  out=$(bot_bridge "$home" verify 2>&1) || rc=$?
  expect_code 1 "$rc" "verify fails when the bot is not in a channel"
  assert_contains "$out" "not_in_channel" "the failure carries Slack's bare error code"
  assert_contains "$out" "invite the bot" "the failure says how to fix it"
  assert_no_token "$home" "$out"
  pass "fm-slack-bridge: verify proves the bot, both channels, and the DM"
}

assert_manifest_semantics() {  # <yaml> <expected-name> <private-channel-scope:0|1>
  ruby -e '
    require "yaml"
    manifest = YAML.safe_load(STDIN.read)
    name, private = ARGV
    expected_scopes = ["chat:write", "channels:history", "im:history", "im:write"]
    expected_scopes << "groups:history" if private == "1"
    abort "manifest name mismatch" unless manifest.dig("display_information", "name") == name
    abort "bot display name mismatch" unless manifest.dig("features", "bot_user", "display_name") == name
    abort "messages tab must be enabled" unless manifest.dig("features", "app_home", "messages_tab_enabled") == true
    scopes = manifest.dig("oauth_config", "scopes", "bot")
    abort "bot scopes mismatch" unless scopes.is_a?(Array) && scopes.sort == expected_scopes.sort && scopes.uniq == scopes
  ' "$2" "$3" <<< "$1"
}

test_manifest_has_name_and_minimal_scopes() {
  local out rc
  out=$("$BRIDGE" manifest --name "Yelen's Firstmate" 2>&1) || fail "manifest must succeed: $out"
  assert_manifest_semantics "$out" "Yelen's Firstmate" 0 || fail "the standard manifest has incorrect semantic fields"
  out=$("$BRIDGE" manifest --name "Marco's Firstmate" --private-channels 2>&1) || fail "private manifest must succeed: $out"
  assert_manifest_semantics "$out" "Marco's Firstmate" 1 || fail "the private manifest has incorrect semantic fields"
  rc=0
  "$BRIDGE" manifest --name "$(printf 'x%.0s' $(seq 1 36))" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a name longer than Slack allows is refused"
  pass "fm-slack-bridge: manifest names the bot and asks for minimal scopes"
}

test_bridge_is_off_without_config
test_post_sends_and_records
test_captain_reply_delivered_once_and_others_ignored
test_macOS_base64_fallback_decodes_inbound_fields
test_unverified_slack_axi_keeps_inbound_off
test_poll_cadence_state_and_validation
test_invalid_config_is_reported
test_bot_posts_instead_of_slack_axi
test_bot_delivers_only_the_captain_and_replies_back
test_reply_without_bot_stays_local
test_bot_reads_past_ten_pages
test_lost_reply_response_is_found_before_retry
test_concurrent_send_reply_is_serialized
test_bot_failures_are_safe
test_bot_verify_round_trip
test_manifest_has_name_and_minimal_scopes
