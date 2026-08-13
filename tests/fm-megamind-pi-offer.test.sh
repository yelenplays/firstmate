#!/usr/bin/env bash
# Public-interface regressions for Pi's ambiguous-wiki disposition UI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v npm >/dev/null 2>&1 || { echo "skip: npm not found"; exit 0; }
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/package.json" ] || { echo "skip: installed Pi package not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-megamind-pi-offer)
PROJECT="$TMP_ROOT/project"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$PROJECT/.pi/extensions/lib" "$PROJECT/bin" "$PROJECT/node_modules/@earendil-works" "$HOME_DIR/state"
cp "$ROOT/.pi/extensions/fm-primary-megamind.ts" "$PROJECT/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-megamind-offer-picker.ts" "$PROJECT/.pi/extensions/lib/"
ln -s "$PI_PACKAGE_DIR" "$PROJECT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$PROJECT/node_modules/@earendil-works/pi-tui"
printf '%s\n' '{"type":"module"}' > "$PROJECT/package.json"
printf '%s\n' "$$" > "$HOME_DIR/state/.lock"

cat > "$PROJECT/bin/fm-megamind-primary.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_HOME:?}/state/coordinator-calls"
case "${1:-}" in
  process)
    prompt=$(cat)
    printf '%s' "$prompt" > "$FM_HOME/state/original-prompt"
    printf '%s\n' '{"decision":"offer","selection_id":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","offers":[{"wiki":"SyntheticWiki"}]}'
    ;;
  continue)
    printf '%s\n' '{"decision":"proceed-with-admission","context":{"text":"synthetic admitted wiki context"},"admitted_chars":31}'
    ;;
  continue-no-context)
    replay=$(cat "$FM_HOME/state/original-prompt")
    jq -cn --arg replay "$replay" '{decision:"proceed-no-context",replay_prompt:$replay,context:null,admitted_chars:0}'
    ;;
  governed) exit 0 ;;
  *) printf '%s\n' '{"decision":"block","failure_code":"unexpected_test_call"}' ;;
esac
SH
chmod 700 "$PROJECT/bin/fm-megamind-primary.sh"
: > "$HOME_DIR/state/coordinator-calls"

output="$TMP_ROOT/node-output"
(cd "$PROJECT" && EXT="$PROJECT/.pi/extensions/fm-primary-megamind.ts" FM_HOME="$HOME_DIR" \
  PI_PACKAGE_DIR="$PI_PACKAGE_DIR" node --input-type=module) >"$output" 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

const Key = { down: "\u001b[B", enter: "\r", escape: "\u001b" };
const handlers = new Map();
const sent = [];
const notifications = [];
let activeComponent;
let activeDone;
let inputHandler;

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

const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(text) {
    sent.push(text);
    const result = await inputHandler({ text, source: "extension" }, ctx);
    if (result.action !== "continue") throw new Error(`the exact replay was not consumed once: ${JSON.stringify(result)}`);
  },
};

const extension = await import(`${pathToFileURL(process.env.EXT).href}?test=${Date.now()}`);
extension.default(pi);
inputHandler = handlers.get("input");
if (!inputHandler) throw new Error("the Pi adapter did not register its input handler");

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
async function begin(text) {
  activeComponent = undefined;
  activeDone = undefined;
  const promise = inputHandler({ text, source: "user" }, ctx);
  for (let i = 0; i < 1000 && !activeComponent; i += 1) await new Promise((resolve) => setTimeout(resolve, 5));
  if (!activeComponent || !activeDone) throw new Error("the ambiguous result did not open the disposition UI");
  return { promise };
}
function press(key, count = 1) {
  for (let i = 0; i < count; i += 1) activeComponent.handleInput(key);
}

const offeredPrompt = "choose the offered wiki";
const { promise: offered } = await begin(offeredPrompt);
const initialLines = activeComponent.render(100);
const initial = initialLines.join("\n");
for (const expected of [
  "Nothing is loaded until you explicitly choose.",
  "SyntheticWiki (offered wiki)",
  "Different existing wiki… (not available yet)",
  "Continue with no wiki evidence",
  "Propose a new wiki… (not available yet)",
]) {
  if (!initial.includes(expected)) throw new Error(`one-offer UI omitted ${expected}:\n${initial}`);
}
if (initialLines.some((line) => line.startsWith("→ "))) {
  throw new Error(`a wiki or action was preselected:\n${initial}`);
}
let settled = false;
offered.then(() => { settled = true; });
press(Key.enter);
await tick();
if (settled) throw new Error("Enter before navigation chose a wiki or disposition");
press(Key.down);
if (!activeComponent.render(100).some((line) => line.startsWith("→ SyntheticWiki"))) {
  throw new Error("the first navigation did not make the offered row explicitly selected");
}
press(Key.enter);
await offered;
if (sent.length !== 1 || sent[0] !== offeredPrompt) {
  throw new Error(`the offered-wiki action did not deliver its prompt once: ${JSON.stringify(sent)}`);
}
const beforeStart = handlers.get("before_agent_start");
const admitted = await beforeStart({ prompt: offeredPrompt });
if (admitted?.message?.content !== "synthetic admitted wiki context") {
  throw new Error(`the offered-wiki action did not inject its admitted context: ${JSON.stringify(admitted)}`);
}

const exactPrompt = "first line\nsecond line remains exact";
const { promise: noWiki } = await begin(exactPrompt);
press(Key.down, 3);
press(Key.enter);
const noWikiResult = await noWiki;
if (noWikiResult.action !== "handled") throw new Error(`the no-wiki action did not handle the original event: ${JSON.stringify(noWikiResult)}`);
if (sent.length !== 2 || sent[1] !== exactPrompt) {
  throw new Error(`the no-wiki action did not deliver the exact original prompt once: ${JSON.stringify(sent)}`);
}

const { promise: cancel } = await begin("cancel this offered request");
press(Key.escape);
await cancel;
if (sent.length !== 2) throw new Error("Escape sent a prompt");
if (!notifications.some(({ message }) => message.includes("cancelled") && message.includes("not sent"))) {
  throw new Error(`Escape produced no truthful cancellation notice: ${JSON.stringify(notifications)}`);
}

const { promise: different } = await begin("different existing wiki action");
press(Key.down, 2);
press(Key.enter);
await different;
if (sent.length !== 2) throw new Error("the unavailable different-wiki action sent a prompt");
if (!notifications.some(({ message }) => message.includes("Different existing wiki") && message.includes("not available yet"))) {
  throw new Error(`the different-wiki action did not disclose unavailability: ${JSON.stringify(notifications)}`);
}

const { promise: proposal } = await begin("new wiki proposal action");
press(Key.down, 4);
press(Key.enter);
await proposal;
if (sent.length !== 2) throw new Error("the unavailable new-wiki action sent a prompt");
if (!notifications.some(({ message }) => message.includes("New wiki proposals") && message.includes("No wiki was created"))) {
  throw new Error(`the new-wiki action did not disclose proposal unavailability: ${JSON.stringify(notifications)}`);
}

const { promise: independent } = await begin(exactPrompt);
press(Key.escape);
await independent;
JS
status=$?
out=$(cat "$output")
[ "$status" -eq 0 ] || fail "Pi ambiguous-wiki public interface failed: $out"
[ -z "$out" ] || fail "Pi ambiguous-wiki public interface printed output: $out"

calls=$(cat "$HOME_DIR/state/coordinator-calls")
[ "$(printf '%s\n' "$calls" | grep -c '^continue-no-context ')" = 1 ] \
  || fail "the no-wiki action did not call its typed coordinator path exactly once: $calls"
assert_contains "$calls" 'continue-no-context --harness pi --session-id synthetic-session' \
  "the no-wiki action did not use the Pi session-bound coordinator path"
assert_contains "$calls" '--include-replay' "the no-wiki action did not request the exact private replay"
[ "$(printf '%s\n' "$calls" | grep -c '^process ')" = 6 ] \
  || fail "an extension replay was reprocessed or a future independent prompt was suppressed: $calls"
[ "$(printf '%s\n' "$calls" | grep -c '^continue ')" = 1 ] \
  || fail "an unavailable action or no-wiki action was passed through select-offer: $calls"
assert_contains "$calls" 'continue --harness pi --session-id synthetic-session' \
  "the offered wiki did not use the existing typed continuation"
assert_contains "$calls" '--offer SyntheticWiki' "the offered wiki name changed before continuation"
pass "Pi offer UI: explicit unselected dispositions, cancellation, exact-once no-wiki replay, and truthful unavailable actions"
