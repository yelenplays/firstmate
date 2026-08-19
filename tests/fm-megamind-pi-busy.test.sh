#!/usr/bin/env bash
# Busy-agent (streaming) regressions for Pi's Megamind primary adapter.
#
# The offer suite drives an idle agent, where replay delivery and context
# injection both ride Pi's non-streaming prompt path. A busy agent is a
# different transport: Pi queues input as steer/followUp, sendUserMessage
# without deliverAs throws "Agent is already processing", and
# before_agent_start never fires for a queued message. Part A pins those
# facts by driving the installed Pi package's own AgentSession and
# ExtensionRunner, so the fake pi in Part B can only be as strict as the
# real transport actually is and cannot drift into confirming its own
# assumptions. Part B then drives the adapter through busy submissions,
# the picker dispositions, and the idle-at-pick/busy-at-replay race.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v npm >/dev/null 2>&1 || { echo "skip: npm not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/package.json" ] || { echo "skip: installed Pi package not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-megamind-pi-busy)
PROJECT="$TMP_ROOT/project"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$PROJECT/.pi/extensions/lib" "$PROJECT/bin" "$PROJECT/node_modules/@earendil-works" "$HOME_DIR/state"
cp "$ROOT/.pi/extensions/fm-primary-megamind.ts" "$PROJECT/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-megamind-offer-picker.ts" "$PROJECT/.pi/extensions/lib/"
ln -s "$PI_PACKAGE_DIR" "$PROJECT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$PROJECT/node_modules/@earendil-works/pi-tui"
printf '%s\n' '{"type":"module"}' > "$PROJECT/package.json"
printf '%s\n' "$$" > "$HOME_DIR/state/.lock"

# Prompts prefixed "admit: " take the direct-admission path; everything else
# is an ambiguous offer, and the continuations embed the original prompt in
# the context text so each scenario can assert exactly which context landed.
cat > "$PROJECT/bin/fm-megamind-primary.sh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  process)
    prompt=$(cat)
    printf '%s' "$prompt" > "${FM_HOME:?}/state/original-prompt"
    case "$prompt" in
      "admit: "*)
        jq -cn --arg p "$prompt" '{decision:"proceed-with-admission",context:{text:("direct ctx: "+$p)},admitted_chars:0}'
        ;;
      *)
        printf '%s\n' '{"decision":"offer","selection_id":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","offers":[{"wiki":"SyntheticWiki"}]}'
        ;;
    esac
    ;;
  continue)
    orig=$(cat "${FM_HOME:?}/state/original-prompt")
    jq -cn --arg p "$orig" '{decision:"proceed-with-admission",context:{text:("offer ctx: "+$p)},admitted_chars:0}'
    ;;
  continue-no-context)
    orig=$(cat "${FM_HOME:?}/state/original-prompt")
    jq -cn --arg p "$orig" '{decision:"proceed-no-context",replay_prompt:$p,context:null,admitted_chars:0}'
    ;;
  governed) exit 0 ;;
  *) printf '%s\n' '{"decision":"block","failure_code":"unexpected_test_call"}' ;;
esac
SH
chmod 700 "$PROJECT/bin/fm-megamind-primary.sh"

output="$TMP_ROOT/node-output"
(cd "$PROJECT" && EXT="$PROJECT/.pi/extensions/fm-primary-megamind.ts" FM_HOME="$HOME_DIR" \
  PI_PACKAGE_DIR="$PI_PACKAGE_DIR" node --input-type=module) >"$output" 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

// --- Part A: pin the installed Pi package's busy transport -----------------

const pkgUrl = (rel) => `${pathToFileURL(process.env.PI_PACKAGE_DIR).href}/${rel}`;
const { AgentSession } = await import(pkgUrl("dist/core/agent-session.js"));
const { ExtensionRunner } = await import(pkgUrl("dist/core/extensions/runner.js"));

const realQueued = [];
const streamingHost = {
  // sendUserMessage delegates to this.prompt, so bind the real method and let
  // it run against a minimal streaming session shape.
  prompt: AgentSession.prototype.prompt,
  isStreaming: true,
  _compactionAbortController: undefined,
  _extensionRunner: { hasHandlers: () => false },
  async _queueFollowUp(text) { realQueued.push({ mode: "followUp", text }); },
  async _queueSteer(text) { realQueued.push({ mode: "steer", text }); },
};

let busyError = "";
try {
  await AgentSession.prototype.sendUserMessage.call(streamingHost, "busy without deliverAs");
} catch (error) {
  busyError = error instanceof Error ? error.message : String(error);
}
if (!busyError.includes("Agent is already processing")) {
  throw new Error(`Pi no longer refuses a busy sendUserMessage without deliverAs: ${JSON.stringify(busyError)}`);
}
if (realQueued.length !== 0) throw new Error("the refused busy send still queued something");

await AgentSession.prototype.sendUserMessage.call(streamingHost, "busy follow-up", { deliverAs: "followUp" });
await AgentSession.prototype.sendUserMessage.call(streamingHost, "busy steer", { deliverAs: "steer" });
if (JSON.stringify(realQueued) !== JSON.stringify([
  { mode: "followUp", text: "busy follow-up" },
  { mode: "steer", text: "busy steer" },
])) {
  throw new Error(`deliverAs no longer queues on the real busy path: ${JSON.stringify(realQueued)}`);
}

const realCustomQueued = [];
const customHost = {
  isStreaming: true,
  agent: {
    followUp: (message) => realCustomQueued.push({ mode: "followUp", message }),
    steer: (message) => realCustomQueued.push({ mode: "steer", message }),
  },
};
await AgentSession.prototype.sendCustomMessage.call(
  customHost,
  { customType: "firstmate-megamind-context", content: "pinned ctx", display: false },
  { deliverAs: "followUp" },
);
if (realCustomQueued.length !== 1
  || realCustomQueued[0].mode !== "followUp"
  || realCustomQueued[0].message.customType !== "firstmate-megamind-context"
  || realCustomQueued[0].message.content !== "pinned ctx") {
  throw new Error(`a custom message no longer queues on the real busy path: ${JSON.stringify(realCustomQueued)}`);
}

const idleAppended = [];
const idleHost = {
  isStreaming: false,
  agent: { state: { messages: idleAppended } },
  sessionManager: { appendCustomMessageEntry: () => {} },
  _emit: () => {},
};
await AgentSession.prototype.sendCustomMessage.call(
  idleHost,
  { customType: "firstmate-megamind-context", content: "idle ctx", display: false },
  { deliverAs: "followUp" },
);
if (idleAppended.length !== 1 || idleAppended[0].content !== "idle ctx") {
  throw new Error(`an idle custom send without triggerTurn no longer appends quietly: ${JSON.stringify(idleAppended)}`);
}

const pinnedEvents = [];
const pinRunner = new ExtensionRunner(
  [{
    path: "busy-pin",
    handlers: new Map([["input", [async (event) => { pinnedEvents.push(event); return { action: "continue" }; }]]]),
  }],
  {}, "/", {}, {},
);
const pinResult = await pinRunner.emitInput("pinned text", undefined, "extension", "followUp");
if (pinResult.action !== "continue" || pinnedEvents.length !== 1
  || pinnedEvents[0].streamingBehavior !== "followUp" || pinnedEvents[0].source !== "extension") {
  throw new Error(`the real runner no longer forwards streamingBehavior into input events: ${JSON.stringify(pinnedEvents)}`);
}

// --- Part B: drive the adapter through the pinned busy transport -----------

const handlers = new Map();
const notifications = [];
const runtimeErrors = [];
const queue = [];
const turns = [];
let streaming = true;
let activeComponent;
let activeDone;
let inputHandler;
let beforeStart;

const ctx = {
  hasUI: true,
  mode: "tui",
  sessionManager: { getSessionId: () => "synthetic-session" },
  ui: {
    custom(factory) {
      return new Promise((resolve) => {
        activeDone = resolve;
        activeComponent = factory({ requestRender() {} }, {}, {}, resolve);
      });
    },
    notify(message, type) {
      notifications.push({ message, type });
    },
  },
};

// Mirrors the real idle prompt path: a fresh turn starts and
// before_agent_start is the only injection point.
async function startTurn(text) {
  const injection = await beforeStart({ prompt: text });
  turns.push({ text, injected: injection?.message?.content });
}

// Mirrors the real AgentSession.prompt() transport pinned in Part A: the
// input event fires first (carrying streamingBehavior only while
// streaming), then a busy agent queues with deliverAs or refuses with the
// exact real error, and an idle agent starts a turn.
async function deliverUserMessage(text, options) {
  const result = await inputHandler(
    { text, source: "extension", streamingBehavior: streaming ? options?.deliverAs : undefined },
    ctx,
  );
  if (result.action !== "continue") return;
  if (streaming) {
    if (!options?.deliverAs) throw new Error(busyError);
    queue.push({ kind: "user", text, mode: options.deliverAs });
    return;
  }
  await startTurn(text);
}

const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  sendUserMessage(content, options) {
    // Mirrors Pi's fire-and-forget core binding: a rejection surfaces as an
    // Extension "<runtime>" error, never as a throw at the call site.
    void deliverUserMessage(content, options).catch((error) => {
      runtimeErrors.push(error instanceof Error ? error.message : String(error));
    });
  },
  sendMessage(message, options) {
    if (streaming && options?.triggerTurn !== false) {
      queue.push({ kind: "context", content: message.content, mode: options?.deliverAs ?? "steer" });
      return;
    }
    if (options?.triggerTurn) {
      runtimeErrors.push("a context message started its own turn");
      return;
    }
    turns.push({ text: null, injected: message.content });
  },
};

const extension = await import(`${pathToFileURL(process.env.EXT).href}?test=${Date.now()}`);
extension.default(pi);
inputHandler = handlers.get("input");
beforeStart = handlers.get("before_agent_start");
if (!inputHandler || !beforeStart) throw new Error("the Pi adapter did not register its handlers");

const Key = { down: String.fromCharCode(27) + "[B", enter: "\r" };
async function waitFor(cond, what) {
  for (let i = 0; i < 1000; i += 1) {
    if (cond()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error(`timed out waiting for ${what}`);
}
function press(key, count = 1) {
  for (let i = 0; i < count; i += 1) activeComponent.handleInput(key);
}
// The pending handler promise is wrapped so the top-level await does not
// adopt it before the picker keys below can settle it.
async function beginPicker(text, streamingBehavior) {
  activeComponent = undefined;
  activeDone = undefined;
  const promise = inputHandler({ text, source: "interactive", streamingBehavior }, ctx);
  await waitFor(() => activeComponent && activeDone, `the disposition picker for ${JSON.stringify(text)}`);
  return { promise };
}
function assertQueued(label, expected) {
  const got = queue.map(({ kind, text, content, mode }) => ({ kind, value: kind === "user" ? text : content, mode }));
  if (JSON.stringify(got) !== JSON.stringify(expected)) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(got)}`);
  }
}
function assertClean(label) {
  if (runtimeErrors.length) throw new Error(`${label} raised a runtime extension error: ${runtimeErrors.join("; ")}`);
}
async function assertNoStaleContext(label, prompt) {
  const stale = await beforeStart({ prompt });
  if (stale?.message) throw new Error(`${label} left stale context for before_agent_start: ${JSON.stringify(stale)}`);
}
function reset() {
  queue.length = 0;
  turns.length = 0;
  runtimeErrors.length = 0;
  notifications.length = 0;
}

// Busy offered-wiki disposition: the replay and its admitted context must
// both queue as the captain's chosen followUp instead of crashing.
reset();
streaming = true;
const busyOffered = "busy offered prompt";
const { promise: busyOfferedPromise } = await beginPicker(busyOffered, "followUp");
press(Key.down);
press(Key.enter);
const busyOfferedResult = await busyOfferedPromise;
if (busyOfferedResult.action !== "handled") {
  throw new Error(`the busy offered flow did not handle the original event: ${JSON.stringify(busyOfferedResult)}`);
}
await waitFor(() => queue.length >= 2 || runtimeErrors.length > 0, "the busy offered replay delivery");
assertClean("the busy offered replay");
assertQueued("the busy offered replay", [
  { kind: "context", value: `offer ctx: ${busyOffered}`, mode: "followUp" },
  { kind: "user", value: busyOffered, mode: "followUp" },
]);
await assertNoStaleContext("the busy offered replay", busyOffered);

// Busy direct admission: the context must ride the queue ahead of the text
// that Pi will queue right after the input handler returns.
reset();
const busyDirect = "admit: busy direct prompt";
const busyDirectResult = await inputHandler({ text: busyDirect, source: "interactive", streamingBehavior: "followUp" }, ctx);
if (busyDirectResult.action !== "continue") {
  throw new Error(`the busy direct admission did not continue: ${JSON.stringify(busyDirectResult)}`);
}
queue.push({ kind: "user", text: busyDirect, mode: "followUp" });
assertClean("the busy direct admission");
assertQueued("the busy direct admission", [
  { kind: "context", value: `direct ctx: ${busyDirect}`, mode: "followUp" },
  { kind: "user", value: busyDirect, mode: "followUp" },
]);
await assertNoStaleContext("the busy direct admission", busyDirect);

// A steered submission keeps its steer delivery for the context too.
reset();
const busySteer = "admit: busy steer prompt";
const busySteerResult = await inputHandler({ text: busySteer, source: "interactive", streamingBehavior: "steer" }, ctx);
if (busySteerResult.action !== "continue") {
  throw new Error(`the busy steer admission did not continue: ${JSON.stringify(busySteerResult)}`);
}
queue.push({ kind: "user", text: busySteer, mode: "steer" });
assertQueued("the busy steer admission", [
  { kind: "context", value: `direct ctx: ${busySteer}`, mode: "steer" },
  { kind: "user", value: busySteer, mode: "steer" },
]);

// Busy no-context disposition: the replay queues and nothing injects.
reset();
const busyNoContext = "busy no wiki prompt";
const { promise: busyNoContextPromise } = await beginPicker(busyNoContext, "followUp");
press(Key.down, 3);
press(Key.enter);
await busyNoContextPromise;
await waitFor(() => queue.length >= 1 || runtimeErrors.length > 0, "the busy no-context replay delivery");
assertClean("the busy no-context replay");
assertQueued("the busy no-context replay", [
  { kind: "user", value: busyNoContext, mode: "followUp" },
]);
await assertNoStaleContext("the busy no-context replay", busyNoContext);

// Idle-at-pick, busy-at-replay race: a watcher wake can start a turn while
// the captain is choosing, so a replay must always name a delivery mode.
reset();
streaming = false;
const raceOffered = "race offered prompt";
const { promise: raceOfferedPromise } = await beginPicker(raceOffered, undefined);
streaming = true;
press(Key.down);
press(Key.enter);
await raceOfferedPromise;
await waitFor(() => queue.length >= 2 || runtimeErrors.length > 0, "the raced replay delivery");
assertClean("the raced replay");
assertQueued("the raced replay", [
  { kind: "context", value: `offer ctx: ${raceOffered}`, mode: "followUp" },
  { kind: "user", value: raceOffered, mode: "followUp" },
]);
await assertNoStaleContext("the raced replay", raceOffered);

// Idle offered-wiki regression: with no queue in play the replay must still
// start a turn whose before_agent_start injection carries the context.
reset();
streaming = false;
const idleOffered = "idle offered prompt";
const { promise: idleOfferedPromise } = await beginPicker(idleOffered, undefined);
press(Key.down);
press(Key.enter);
await idleOfferedPromise;
await waitFor(() => turns.length >= 1 || runtimeErrors.length > 0, "the idle replay turn");
assertClean("the idle replay");
if (queue.length !== 0) throw new Error(`the idle replay queued instead of starting a turn: ${JSON.stringify(queue)}`);
if (turns.length !== 1 || turns[0].text !== idleOffered || turns[0].injected !== `offer ctx: ${idleOffered}`) {
  throw new Error(`the idle replay lost its before_agent_start context: ${JSON.stringify(turns)}`);
}
JS
status=$?
out=$(cat "$output")
[ "$status" -eq 0 ] || fail "Pi busy-agent Megamind transport failed: $out"
[ -z "$out" ] || fail "Pi busy-agent Megamind transport printed output: $out"
pass "Pi busy-agent Megamind transport: pinned real busy contract, queued replays with context, steer fidelity, race safety, and idle injection"
