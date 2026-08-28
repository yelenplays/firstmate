#!/usr/bin/env bash
# Offline behavior and security tests for the Hermes Agent connection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/fm-hermes-agent.mjs"
EXTENSION="$ROOT/.pi/extensions/fm-hermes-agent.ts"
TMP_ROOT=$(fm_test_tmproot fm-hermes-agent)
HOME_DIR="$TMP_ROOT/home"
CONTROL="$TMP_ROOT/control"
REQUEST_LOG="$TMP_ROOT/requests.jsonl"
READY="$TMP_ROOT/ready"
SERVER="$TMP_ROOT/fake-hermes.mjs"
TOKEN=TestBearerKey_123456
SERVER_PID=

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

mkdir -p "$HOME_DIR/config" "$HOME_DIR/state"
chmod 700 "$HOME_DIR/state"

cat > "$SERVER" <<'JS'
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import http from "node:http";

const [control, log, ready] = process.argv.slice(2);
let requestNumber = 0;
const server = http.createServer((request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    requestNumber += 1;
    const body = Buffer.concat(chunks).toString("utf8");
    appendFileSync(log, `${JSON.stringify({
      requestNumber,
      method: request.method,
      url: request.url,
      headers: request.headers,
      body,
    })}\n`);
    const mode = readFileSync(control, "utf8").trim() || "normal";
    if (mode === "drop-action" && request.method === "POST") {
      request.socket.destroy();
      return;
    }
    if (mode === "delay") {
      setTimeout(() => {
        response.writeHead(200, { "Content-Type": "application/json" });
        response.end('{"status":"late"}');
      }, 5500);
      return;
    }
    if (mode === "redirect") {
      response.writeHead(302, { Location: "https://example.invalid/escaped" });
      response.end();
      return;
    }
    if (mode === "redirect-loopback") {
      response.writeHead(302, { Location: "http://127.0.0.1:4861/health" });
      response.end();
      return;
    }
    if (mode === "oversize") {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ data: "x".repeat(1024 * 1024 + 1) }));
      return;
    }
    if (mode === "invalid-json") {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end("not-json");
      return;
    }
    if (mode === "http-error") {
      response.writeHead(401, { "Content-Type": "application/json" });
      response.end('{"detail":"PRIVATE_REMOTE_ERROR"}');
      return;
    }
    if (mode === "echo-secret") {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ echo: request.headers.authorization || "" }));
      return;
    }
    if (mode === "escaped-secret") {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end('{"nested":{"echo":"Bearer TestBearerKey_\\u0031\\u0032\\u0033\\u0034\\u0035\\u0036"}}');
      return;
    }
    if (mode === "double-escaped-secret") {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end('{"nested":{"echo":"Bearer TestBearerKey_\\\\u0031\\\\u0032\\\\u0033\\\\u0034\\\\u0035\\\\u0036"}}');
      return;
    }
    if (mode === "deep-percent-secret") {
      let encoded = "TestBearerKey_123456";
      for (let index = 0; index < 9; index += 1) {
        encoded = Array.from(encoded, (character) => `%${character.codePointAt(0).toString(16).padStart(2, "0")}`).join("");
      }
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ nested: { echo: encoded } }));
      return;
    }
    if (mode === "codepoint-secret") {
      const encoded = Array.from("TestBearerKey_123456", (character) => `\\u{${character.codePointAt(0).toString(16)}}`).join("");
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ nested: { echo: encoded } }));
      return;
    }
    if (mode === "octal-secret") {
      const encoded = Array.from("TestBearerKey_123456", (character) => `${String.fromCharCode(92)}${character.codePointAt(0).toString(8).padStart(3, "0")}`).join("");
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ nested: { echo: encoded } }));
      return;
    }
    if (mode === "split-secret") {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ first: "TestBearer", second: "Key_123456" }));
      return;
    }
    if (mode === "escaped-sse-secret") {
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.end('event: run.status\ndata: {"nested":{"echo":"Bearer TestBearerKey_\\u0031\\u0032\\u0033\\u0034\\u0035\\u0036"}}\n\n');
      return;
    }
    if (mode === "double-escaped-sse-secret") {
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.end('id: TestBearerKey_\\\\u0031\\\\u0032\\\\u0033\\\\u0034\\\\u0035\\\\u0036\nevent: TestBearerKey_\\\\u0031\\\\u0032\\\\u0033\\\\u0034\\\\u0035\\\\u0036\n: TestBearerKey_\\\\u0031\\\\u0032\\\\u0033\\\\u0034\\\\u0035\\\\u0036\ndata: {"nested":{"echo":"Bearer TestBearerKey_\\\\u0031\\\\u0032\\\\u0033\\\\u0034\\\\u0035\\\\u0036"}}\n\n');
      return;
    }
    if (mode === "no-data-sse-secret") {
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.end('id: TestBearerKey_\\\\u0031\\\\u0032\\\\u0033\\\\u0034\\\\u0035\\\\u0036\nevent: TestBearerKey_\\\\u0031\\\\u0032\\\\u0033\\\\u0034\\\\u0035\\\\u0036\n: TestBearerKey_\\\\u0031\\\\u0032\\\\u0033\\\\u0034\\\\u0035\\\\u0036\n\n');
      return;
    }
    if (mode === "codepoint-sse-secret") {
      const encoded = Array.from("TestBearerKey_123456", (character) => `\\u{${character.codePointAt(0).toString(16)}}`).join("");
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.end(`id: ${encoded}\nevent: ${encoded}\n: ${encoded}\n\n`);
      return;
    }
    if (mode === "octal-sse-secret") {
      const encoded = Array.from("TestBearerKey_123456", (character) => `${String.fromCharCode(92)}${character.codePointAt(0).toString(8).padStart(3, "0")}`).join("");
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.end(`id: ${encoded}\nevent: ${encoded}\n: ${encoded}\n\n`);
      return;
    }
    if (mode === "split-sse-secret") {
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.end('event: run.status\ndata: {"first":"TestBearer","second":"Key_123456"}\n\n');
      return;
    }
    if (mode === "escaped-nonjson-sse-secret") {
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.end('event: run.status\ndata: Bearer TestBearerKey_\\u0031\\u0032\\u0033\\u0034\\u0035\\u0036\n\n');
      return;
    }
    if (request.url?.endsWith("/events")) {
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.end('event: run.status\ndata: {"status":"running"}\n\n');
      return;
    }
    if (request.method === "POST" && request.url === "/v1/runs") {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ run_id: "run-created-private", status: "started" }));
      return;
    }
    response.writeHead(200, { "Content-Type": "application/json" });
    response.end(JSON.stringify({
      ok: true,
      method: request.method,
      path: request.url,
      session_title: "PRIVATE_SESSION_TITLE",
      message: "PRIVATE_MESSAGE_BODY",
    }));
  });
});
server.listen(4861, "127.0.0.1", () => writeFileSync(ready, "ready\n"));
JS

printf 'normal\n' > "$CONTROL"
: > "$REQUEST_LOG"
node "$SERVER" "$CONTROL" "$REQUEST_LOG" "$READY" &
SERVER_PID=$!
for _ in $(seq 1 100); do
  [ -f "$READY" ] && break
  kill -0 "$SERVER_PID" 2>/dev/null || fail "fake Hermes server could not bind pinned port 4861"
  sleep 0.02
done
[ -f "$READY" ] || fail "fake Hermes server did not become ready"

write_config() {
  local actions=${1:-true}
  cat > "$HOME_DIR/config/hermes-agent.env" <<EOF
HERMES_API_BASE_URL=http://127.0.0.1:4861
HERMES_API_SERVER_KEY=$TOKEN
HERMES_API_ACTIONS_ENABLED=$actions
EOF
  chmod 600 "$HOME_DIR/config/hermes-agent.env"
}

owner_call() {
  local mode=$1 payload=$2 output_file=$3
  printf '%s' "$payload" | FM_HOME="$HOME_DIR" node "$OWNER" "$mode" > "$output_file"
}

expect_owner_success() {
  local mode=$1 payload=$2 output_file=$3
  owner_call "$mode" "$payload" "$output_file"
  local rc=$?
  [ "$rc" -eq 0 ] || fail "Hermes owner call failed: $(cat "$output_file")"
  jq -e '.ok == true' "$output_file" >/dev/null || fail "Hermes owner call returned no success envelope: $(cat "$output_file")"
}

expect_owner_failure() {
  local mode=$1 payload=$2 code=$3 output_file=$4
  owner_call "$mode" "$payload" "$output_file"
  local rc=$?
  [ "$rc" -ne 0 ] || fail "Hermes owner call unexpectedly succeeded: $(cat "$output_file")"
  jq -e --arg code "$code" '.ok == false and .error.code == $code and (.error.message | type == "string")' "$output_file" >/dev/null \
    || fail "Hermes owner failure did not return code $code: $(cat "$output_file")"
}

request_count() {
  wc -l < "$REQUEST_LOG" | tr -d '[:space:]'
}

stat_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

test_unconfigured_state() {
  local out="$TMP_ROOT/unconfigured.json"
  rm -f "$HOME_DIR/config/hermes-agent.env"
  if printf '%s' '{"operation":"health","taskId":"task-unconfigured"}' \
    | FM_HOME="$HOME_DIR" HERMES_API_SERVER_KEY=IGNORED_ENV_SECRET node "$OWNER" read > "$out"; then
    fail "environment-only Hermes key unexpectedly configured access"
  fi
  jq -e '.ok == false and .error.code == "not-configured"' "$out" >/dev/null \
    || fail "environment-only Hermes key did not preserve the unconfigured refusal"
  assert_not_contains "$(cat "$out")" "IGNORED_ENV_SECRET" "unconfigured output leaked an environment key"
  assert_contains "$(jq -r '.error.message' "$out")" "Ask the operator to create" "unconfigured diagnostic must name the operator action"
  assert_contains "$(jq -r '.error.message' "$out")" "mode 0600" "unconfigured diagnostic must name the permission requirement"
  assert_contains "$(jq -r '.error.message' "$out")" "127.0.0.1:4861" "unconfigured diagnostic must name the pinned local seam"
  pass "Hermes owner reports one safe actionable unconfigured diagnostic"
}

test_config_refusals() {
  local out="$TMP_ROOT/config-failure.json" target="$TMP_ROOT/config-target"

  write_config true
  chmod 644 "$HOME_DIR/config/hermes-agent.env"
  expect_owner_failure read '{"operation":"health","taskId":"task-config"}' unsafe-config "$out"
  chmod 600 "$HOME_DIR/config/hermes-agent.env"

  write_config true
  printf 'UNKNOWN=value\n' >> "$HOME_DIR/config/hermes-agent.env"
  expect_owner_failure read '{"operation":"health","taskId":"task-config"}' unsafe-config "$out"

  write_config true
  printf 'HERMES_API_SERVER_KEY=duplicate\n' >> "$HOME_DIR/config/hermes-agent.env"
  expect_owner_failure read '{"operation":"health","taskId":"task-config"}' unsafe-config "$out"

  printf 'export HERMES_API_BASE_URL=http://127.0.0.1:4861\nHERMES_API_SERVER_KEY=%s\n' "$TOKEN" > "$HOME_DIR/config/hermes-agent.env"
  chmod 600 "$HOME_DIR/config/hermes-agent.env"
  expect_owner_failure read '{"operation":"health","taskId":"task-config"}' unsafe-config "$out"

  printf 'HERMES_API_BASE_URL=http://example.invalid:4861\nHERMES_API_SERVER_KEY=%s\n' "$TOKEN" > "$HOME_DIR/config/hermes-agent.env"
  chmod 600 "$HOME_DIR/config/hermes-agent.env"
  expect_owner_failure read '{"operation":"health","taskId":"task-config"}' unsafe-config "$out"

  printf 'HERMES_API_BASE_URL=http://127.0.0.1:4861\n' > "$HOME_DIR/config/hermes-agent.env"
  chmod 600 "$HOME_DIR/config/hermes-agent.env"
  expect_owner_failure read '{"operation":"health","taskId":"task-config"}' not-configured "$out"

  cat > "$HOME_DIR/config/hermes-agent.env" <<'EOF'
HERMES_API_BASE_URL=http://127.0.0.1:4861
HERMES_API_SERVER_KEY=$(id)
EOF
  chmod 600 "$HOME_DIR/config/hermes-agent.env"
  expect_owner_failure read '{"operation":"health","taskId":"task-config"}' unsafe-config "$out"

  write_config maybe
  expect_owner_failure read '{"operation":"health","taskId":"task-config"}' unsafe-config "$out"

  printf 'HERMES_API_BASE_URL=http://127.0.0.1:4861\nHERMES_API_SERVER_KEY=%09000d\n' 1 > "$HOME_DIR/config/hermes-agent.env"
  chmod 600 "$HOME_DIR/config/hermes-agent.env"
  expect_owner_failure read '{"operation":"health","taskId":"task-config"}' unsafe-config "$out"

  printf 'HERMES_API_BASE_URL=http://127.0.0.1:4861\nHERMES_API_SERVER_KEY=%s\n' "$TOKEN" > "$target"
  chmod 600 "$target"
  rm -f "$HOME_DIR/config/hermes-agent.env"
  ln -s "$target" "$HOME_DIR/config/hermes-agent.env"
  expect_owner_failure read '{"operation":"health","taskId":"task-config"}' unsafe-config "$out"
  rm -f "$HOME_DIR/config/hermes-agent.env"

  write_config true
  chmod 644 "$HOME_DIR/state/hermes-agent-audit.jsonl"
  expect_owner_failure read '{"operation":"health","taskId":"task-config"}' unsafe-audit "$out"
  chmod 600 "$HOME_DIR/state/hermes-agent-audit.jsonl"

  chmod 644 "$HOME_DIR/state/.hermes-agent-audit-salt"
  expect_owner_failure read '{"operation":"health","taskId":"task-config"}' unsafe-audit "$out"
  chmod 600 "$HOME_DIR/state/.hermes-agent-audit-salt"

  chmod 755 "$HOME_DIR/state"
  expect_owner_failure read '{"operation":"health","taskId":"task-config"}' unsafe-audit "$out"
  chmod 700 "$HOME_DIR/state"

  pass "Hermes owner rejects unsafe permissions, syntax, links, keys, values, and origins"
}

test_foreign_state_directory_refusal() {
  local out="$TMP_ROOT/foreign-state.json" hook="$TMP_ROOT/foreign-uid.cjs" foreign_uid
  write_config true
  foreign_uid=$(( $(id -u) + 1 ))
  printf 'process.getuid = () => %s;\n' "$foreign_uid" > "$hook"
  if printf '%s' '{"operation":"health","taskId":"task-foreign-state"}' \
    | NODE_OPTIONS="--require=$hook" FM_HOME="$HOME_DIR" node "$OWNER" read > "$out"
  then
    fail "foreign-owned Hermes audit state directory unexpectedly opened"
  fi
  jq -e '.ok == false and .error.code == "unsafe-audit"' "$out" >/dev/null \
    || fail "foreign-owned Hermes audit state directory did not return unsafe-audit"
  pass "Hermes owner rejects an audit state directory owned by another user"
}

test_read_allowlist() {
  local out="$TMP_ROOT/read.json" before after
  write_config true
  printf 'normal\n' > "$CONTROL"
  before=$(request_count)

  expect_owner_success read '{"operation":"health","taskId":"task-read"}' "$out"
  expect_owner_success read '{"operation":"detailed_health","taskId":"task-read"}' "$out"
  expect_owner_success read '{"operation":"capabilities","taskId":"task-read"}' "$out"
  expect_owner_success read '{"operation":"models","taskId":"task-read"}' "$out"
  expect_owner_success read '{"operation":"sessions","taskId":"task-read","limit":7,"offset":2}' "$out"
  expect_owner_success read '{"operation":"session","taskId":"task-read","sessionId":"sess-private-42"}' "$out"
  expect_owner_success read '{"operation":"messages","taskId":"task-read","sessionId":"sess-private-42","limit":9,"offset":3,"privateContent":true}' "$out"
  expect_owner_success read '{"operation":"run_status","taskId":"task-read","runId":"run-private-7"}' "$out"
  expect_owner_success read '{"operation":"run_events","taskId":"task-read","runId":"run-private-7"}' "$out"
  expect_owner_success read '{"operation":"skills","taskId":"task-read"}' "$out"
  expect_owner_success read '{"operation":"toolsets","taskId":"task-read"}' "$out"

  after=$(request_count)
  [ $((after - before)) -eq 11 ] || fail "read allowlist did not make exactly eleven requests"
  tail -n 11 "$REQUEST_LOG" > "$TMP_ROOT/read-requests.jsonl"
  sed -n '1p' "$TMP_ROOT/read-requests.jsonl" | jq -e '.method == "GET" and .url == "/health" and (.headers.authorization == null)' >/dev/null \
    || fail "public health request shape is wrong"
  sed -n '2p' "$TMP_ROOT/read-requests.jsonl" | jq -e --arg auth "Bearer $TOKEN" '.url == "/health/detailed" and .headers.authorization == $auth' >/dev/null \
    || fail "detailed health request shape is wrong"
  sed -n '3p' "$TMP_ROOT/read-requests.jsonl" | jq -e '.url == "/v1/capabilities"' >/dev/null || fail "capabilities path is wrong"
  sed -n '4p' "$TMP_ROOT/read-requests.jsonl" | jq -e '.url == "/v1/models"' >/dev/null || fail "models path is wrong"
  sed -n '5p' "$TMP_ROOT/read-requests.jsonl" | jq -e '.url == "/api/sessions?limit=7&offset=2"' >/dev/null || fail "sessions query is wrong"
  sed -n '6p' "$TMP_ROOT/read-requests.jsonl" | jq -e '.url == "/api/sessions/sess-private-42"' >/dev/null || fail "session path is wrong"
  sed -n '7p' "$TMP_ROOT/read-requests.jsonl" | jq -e '.url == "/api/sessions/sess-private-42/messages?limit=9&offset=3"' >/dev/null || fail "messages path is wrong"
  sed -n '8p' "$TMP_ROOT/read-requests.jsonl" | jq -e '.url == "/v1/runs/run-private-7"' >/dev/null || fail "run status path is wrong"
  sed -n '9p' "$TMP_ROOT/read-requests.jsonl" | jq -e '.url == "/v1/runs/run-private-7/events" and .headers.accept == "text/event-stream"' >/dev/null || fail "run events path is wrong"
  sed -n '10p' "$TMP_ROOT/read-requests.jsonl" | jq -e '.url == "/v1/skills"' >/dev/null || fail "skills path is wrong"
  sed -n '11p' "$TMP_ROOT/read-requests.jsonl" | jq -e '.url == "/v1/toolsets"' >/dev/null || fail "toolsets path is wrong"
  pass "Hermes owner exposes every approved read operation with fixed GET paths"
}

test_read_refusals_and_privacy_gate() {
  local out="$TMP_ROOT/read-refusal.json" before after payload
  write_config true
  before=$(request_count)
  for payload in \
    '{"operation":"sessions","taskId":"task-refuse","limit":101}' \
    '{"operation":"health","taskId":"task-refuse","method":"POST"}' \
    '{"operation":"health","taskId":"task-refuse","path":"/v1/runs"}' \
    '{"operation":"health","taskId":"task-refuse","url":"http://example.invalid"}' \
    '{"operation":"health","taskId":"task-refuse","headers":{"X-Test":"bad"}}' \
    '{"operation":"session","taskId":"task-refuse","sessionId":"../../escape"}' \
    '{"operation":"unknown","taskId":"task-refuse"}'
  do
    expect_owner_failure read "$payload" invalid-input "$out"
  done
  # The private-content refusal carries a more specific stable code.
  expect_owner_failure read '{"operation":"messages","taskId":"task-refuse","sessionId":"sess-private-42"}' private-content-required "$out"
  after=$(request_count)
  [ "$after" -eq "$before" ] || fail "refused read input reached the fake Hermes server"
  pass "Hermes owner refuses arbitrary surfaces, invalid IDs, oversized pages, and ungated message history"
}

test_action_gate_and_idempotency() {
  local out="$TMP_ROOT/run.json" before after key1 key2 key3 body oversized payload
  cat > "$HOME_DIR/config/hermes-agent.env" <<EOF
HERMES_API_BASE_URL=http://127.0.0.1:4861
HERMES_API_SERVER_KEY=$TOKEN
EOF
  chmod 600 "$HOME_DIR/config/hermes-agent.env"
  before=$(request_count)
  expect_owner_failure run '{"taskId":"task-run","instruction":"Return a test response.","authorizationBasis":"captain-approved"}' actions-disabled "$out"
  after=$(request_count)
  [ "$after" -eq "$before" ] || fail "disabled action reached the fake Hermes server"

  oversized=$(printf '%016385d' 0 | tr '0' 'x')
  payload=$(jq -cn --arg instruction "$oversized" '{taskId:"task-run", instruction:$instruction, authorizationBasis:"captain-approved"}')
  expect_owner_failure run "$payload" invalid-input "$out"
  [ "$(request_count)" -eq "$before" ] || fail "oversized action instruction reached the fake Hermes server"

  write_config true
  printf 'normal\n' > "$CONTROL"
  expect_owner_success run '{"taskId":"task-run","instruction":"Return a test response.\nUse no tools.","authorizationBasis":"captain-approved"}' "$out"
  expect_owner_success run '{"taskId":"task-run","instruction":"Return a test response.\nUse no tools.","authorizationBasis":"captain-approved"}' "$out"
  expect_owner_success run '{"taskId":"task-run","instruction":"Return a different test response.","authorizationBasis":"captain-approved"}' "$out"
  tail -n 3 "$REQUEST_LOG" > "$TMP_ROOT/run-requests.jsonl"
  key1=$(sed -n '1p' "$TMP_ROOT/run-requests.jsonl" | jq -r '.headers["idempotency-key"]')
  key2=$(sed -n '2p' "$TMP_ROOT/run-requests.jsonl" | jq -r '.headers["idempotency-key"]')
  key3=$(sed -n '3p' "$TMP_ROOT/run-requests.jsonl" | jq -r '.headers["idempotency-key"]')
  [ "$key1" = "$key2" ] || fail "identical authorized runs did not derive the same idempotency key"
  [ "$key1" != "$key3" ] || fail "different instructions derived the same idempotency key"
  case "$key1" in fm-[0-9a-f][0-9a-f]*) ;; *) fail "idempotency key has an unexpected shape" ;; esac
  body=$(sed -n '1p' "$TMP_ROOT/run-requests.jsonl" | jq -r '.body')
  printf '%s' "$body" | jq -e '.input == "Return a test response.\nUse no tools." and .session_id == "firstmate:task-run"' >/dev/null \
    || fail "run body did not bind the instruction to the Firstmate task identity"
  sed -n '1p' "$TMP_ROOT/run-requests.jsonl" | jq -e --arg auth "Bearer $TOKEN" '.method == "POST" and .url == "/v1/runs" and .headers.authorization == $auth' >/dev/null \
    || fail "run escaped the one approved action endpoint"
  pass "Hermes owner defaults actions off and derives deterministic idempotency for the one run endpoint"
}

test_authorization_basis_secrecy() {
  local out="$TMP_ROOT/authorization-basis.json" before after audit="$HOME_DIR/state/hermes-agent-audit.jsonl" audit_before audit_after
  write_config true
  printf 'normal\n' > "$CONTROL"
  before=$(request_count)
  audit_before=$(wc -l < "$audit" | tr -d '[:space:]')
  expect_owner_failure run '{"taskId":"task-basis","instruction":"Offline basis validation.","authorizationBasis":"TestBearerKey_123456"}' invalid-input "$out"
  after=$(request_count)
  audit_after=$(wc -l < "$audit" | tr -d '[:space:]')
  [ "$after" -eq "$before" ] || fail "free-form authorization basis reached the fake Hermes server"
  [ "$audit_after" -eq "$audit_before" ] || fail "free-form authorization basis reached the private audit log"
  assert_not_contains "$(cat "$out")" "$TOKEN" "rejected authorization basis leaked to tool output"
  pass "Hermes actions accept only fixed non-secret authorization categories"
}

test_no_action_retry() {
  local out="$TMP_ROOT/no-retry.json" before after
  write_config true
  printf 'drop-action\n' > "$CONTROL"
  before=$(request_count)
  expect_owner_failure run '{"taskId":"task-no-retry","instruction":"Offline connection drop.","authorizationBasis":"captain-approved"}' network-error "$out"
  after=$(request_count)
  [ $((after - before)) -eq 1 ] || fail "failed action was retried automatically"
  printf 'normal\n' > "$CONTROL"
  pass "Hermes owner never retries an action after an unknown connection outcome"
}

test_transport_bounds_and_redaction() {
  local out="$TMP_ROOT/transport.json" before after text
  write_config true

  printf 'redirect\n' > "$CONTROL"
  before=$(request_count)
  expect_owner_failure read '{"operation":"health","taskId":"task-transport"}' redirect-refused "$out"
  after=$(request_count)
  [ $((after - before)) -eq 1 ] || fail "external redirect caused another request"

  printf 'redirect-loopback\n' > "$CONTROL"
  expect_owner_failure read '{"operation":"health","taskId":"task-transport"}' redirect-refused "$out"

  printf 'oversize\n' > "$CONTROL"
  expect_owner_failure read '{"operation":"health","taskId":"task-transport"}' response-too-large "$out"

  printf 'invalid-json\n' > "$CONTROL"
  expect_owner_failure read '{"operation":"health","taskId":"task-transport"}' invalid-response "$out"

  printf 'http-error\n' > "$CONTROL"
  expect_owner_failure read '{"operation":"health","taskId":"task-transport"}' http-error "$out"
  assert_not_contains "$(cat "$out")" "PRIVATE_REMOTE_ERROR" "HTTP error body must not escape to tool output"

  printf 'echo-secret\n' > "$CONTROL"
  expect_owner_success read '{"operation":"capabilities","taskId":"task-transport"}' "$out"
  text=$(cat "$out")
  assert_not_contains "$text" "$TOKEN" "echoed bearer key must be redacted from output"
  assert_contains "$text" "[REDACTED]" "echoed bearer key must leave an explicit redaction marker"

  printf 'escaped-secret\n' > "$CONTROL"
  expect_owner_success read '{"operation":"capabilities","taskId":"task-transport"}' "$out"
  text=$(cat "$out")
  assert_not_contains "$text" "$TOKEN" "decoded JSON bearer key must be redacted from output"
  assert_contains "$text" "[REDACTED]" "decoded JSON bearer key must leave an explicit redaction marker"

  printf 'double-escaped-secret\n' > "$CONTROL"
  expect_owner_success read '{"operation":"capabilities","taskId":"task-transport"}' "$out"
  text=$(cat "$out")
  assert_not_contains "$text" "$TOKEN" "reversible JSON bearer key must be redacted from output"
  assert_not_contains "$text" 'TestBearerKey_\u0031' "reversible JSON bearer escape leaked to output"
  assert_contains "$text" "[REDACTED]" "reversible JSON bearer key must leave an explicit redaction marker"

  printf 'deep-percent-secret\n' > "$CONTROL"
  expect_owner_success read '{"operation":"capabilities","taskId":"task-transport"}' "$out"
  text=$(cat "$out")
  assert_not_contains "$text" "$TOKEN" "deep percent-escaped bearer key must be redacted from output"
  assert_not_contains "$text" '%54estBearerKey_123456' "deep percent-escaped bearer residue leaked to output"
  assert_contains "$text" "[REDACTED]" "deep percent-escaped bearer key must leave an explicit redaction marker"

  printf 'codepoint-secret\n' > "$CONTROL"
  expect_owner_success read '{"operation":"capabilities","taskId":"task-transport"}' "$out"
  text=$(cat "$out")
  assert_not_contains "$text" "$TOKEN" "code-point JSON bearer key must be redacted from output"
  assert_not_contains "$text" '\u{54}' "code-point JSON bearer escape leaked to output"
  assert_contains "$text" "[REDACTED]" "code-point JSON bearer key must leave an explicit redaction marker"

  printf 'octal-secret\n' > "$CONTROL"
  expect_owner_success read '{"operation":"capabilities","taskId":"task-transport"}' "$out"
  text=$(cat "$out")
  assert_not_contains "$text" "$TOKEN" "octal JSON bearer key must be redacted from output"
  assert_not_contains "$text" '\124' "octal JSON bearer escape leaked to output"
  assert_contains "$text" "[REDACTED]" "octal JSON bearer key must leave an explicit redaction marker"

  printf 'split-secret\n' > "$CONTROL"
  expect_owner_success read '{"operation":"capabilities","taskId":"task-transport"}' "$out"
  text=$(cat "$out")
  assert_not_contains "$text" "TestBearer" "split JSON bearer prefix leaked to output"
  assert_not_contains "$text" "Key_123456" "split JSON bearer suffix leaked to output"
  assert_contains "$text" "[REDACTED]" "split JSON bearer must leave an explicit redaction marker"

  printf 'escaped-sse-secret\n' > "$CONTROL"
  expect_owner_success read '{"operation":"run_events","taskId":"task-transport","runId":"run-private-7"}' "$out"
  text=$(cat "$out")
  assert_not_contains "$text" "$TOKEN" "decoded SSE bearer key must be redacted from output"
  assert_contains "$text" "[REDACTED]" "decoded SSE bearer key must leave an explicit redaction marker"

  printf 'double-escaped-sse-secret\n' > "$CONTROL"
  expect_owner_success read '{"operation":"run_events","taskId":"task-transport","runId":"run-private-7"}' "$out"
  text=$(cat "$out")
  assert_not_contains "$text" "$TOKEN" "reversible SSE bearer key must be redacted from output"
  assert_not_contains "$text" 'TestBearerKey_\u0031' "reversible SSE bearer escape leaked to output"
  assert_contains "$text" "[REDACTED]" "reversible SSE bearer key must leave an explicit redaction marker"

  printf 'no-data-sse-secret\n' > "$CONTROL"
  expect_owner_success read '{"operation":"run_events","taskId":"task-transport","runId":"run-private-7"}' "$out"
  text=$(cat "$out")
  assert_not_contains "$text" "$TOKEN" "no-data SSE bearer key must be redacted from output"
  assert_not_contains "$text" 'TestBearerKey_\u0031' "no-data SSE bearer escape leaked to output"
  assert_contains "$text" "[REDACTED]" "no-data SSE bearer key must leave an explicit redaction marker"

  printf 'codepoint-sse-secret\n' > "$CONTROL"
  expect_owner_success read '{"operation":"run_events","taskId":"task-transport","runId":"run-private-7"}' "$out"
  text=$(cat "$out")
  assert_not_contains "$text" "$TOKEN" "code-point SSE bearer key must be redacted from output"
  assert_not_contains "$text" '\u{54}' "code-point SSE bearer escape leaked to output"
  assert_contains "$text" "[REDACTED]" "code-point SSE bearer key must leave an explicit redaction marker"

  printf 'octal-sse-secret\n' > "$CONTROL"
  expect_owner_success read '{"operation":"run_events","taskId":"task-transport","runId":"run-private-7"}' "$out"
  text=$(cat "$out")
  assert_not_contains "$text" "$TOKEN" "octal SSE bearer key must be redacted from output"
  assert_not_contains "$text" '\124' "octal SSE bearer escape leaked to output"
  assert_contains "$text" "[REDACTED]" "octal SSE bearer key must leave an explicit redaction marker"

  printf 'split-sse-secret\n' > "$CONTROL"
  expect_owner_success read '{"operation":"run_events","taskId":"task-transport","runId":"run-private-7"}' "$out"
  text=$(cat "$out")
  assert_not_contains "$text" "TestBearer" "split SSE bearer prefix leaked to output"
  assert_not_contains "$text" "Key_123456" "split SSE bearer suffix leaked to output"
  assert_contains "$text" "[REDACTED]" "split SSE bearer must leave an explicit redaction marker"

  printf 'escaped-nonjson-sse-secret\n' > "$CONTROL"
  expect_owner_failure read '{"operation":"run_events","taskId":"task-transport","runId":"run-private-7"}' invalid-response "$out"
  text=$(cat "$out")
  assert_not_contains "$text" "$TOKEN" "rejected non-JSON SSE bearer key leaked to output"
  assert_not_contains "$text" 'TestBearerKey_\u0031' "rejected non-JSON SSE escape leaked to output"

  printf 'delay\n' > "$CONTROL"
  expect_owner_failure read '{"operation":"health","taskId":"task-transport"}' timeout "$out"
  assert_contains "$(jq -r '.error.message' "$out")" "5-second bound" "read timeout diagnostic must name its bound"
  printf 'normal\n' > "$CONTROL"
  pass "Hermes owner enforces response, redirect, error-body, redaction, and timeout bounds"
}

test_audit_secrecy() {
  local audit="$HOME_DIR/state/hermes-agent-audit.jsonl" salt="$HOME_DIR/state/.hermes-agent-audit-salt" content out="$TMP_ROOT/audit-secret.json" payload
  write_config true
  payload=$(jq -cn --arg task "$TOKEN" '{operation:"health", taskId:$task}')
  expect_owner_success read "$payload" "$out"
  content=$(cat "$audit")
  [ "$(stat_mode "$audit")" = 600 ] || fail "Hermes audit log is not mode 0600"
  [ "$(stat_mode "$salt")" = 600 ] || fail "Hermes audit salt is not mode 0600"
  assert_not_contains "$content" "$TOKEN" "audit leaked bearer token"
  assert_not_contains "$content" "PRIVATE_SESSION_TITLE" "audit leaked a session title"
  assert_not_contains "$content" "PRIVATE_MESSAGE_BODY" "audit leaked message content"
  assert_not_contains "$content" "sess-private-42" "audit leaked raw session id"
  assert_not_contains "$content" "run-private-7" "audit leaked raw run id"
  assert_not_contains "$content" "run-created-private" "audit leaked created run id"
  assert_not_contains "$content" "Return a test response." "audit leaked a run instruction"
  assert_contains "$content" '"authorizationBasis":"captain-approved"' "audit omitted the action authorization basis"
  jq -e -s 'all(.[]; (.authorizationBasis == null or .authorizationBasis == "captain-approved" or .authorizationBasis == "operator-approved"))' "$audit" >/dev/null \
    || fail "audit recorded an unsafe authorization basis"
  jq -e -s 'all(.[]; (.at | type == "string") and ((.task // "") | test("^[0-9a-f]{24}$")) and (.operation | type == "string") and (.endpoint | type == "string") and (.durationMs | type == "number") and (.responseBytes | type == "number") and (.privateContent | type == "boolean"))' "$audit" >/dev/null \
    || fail "audit record schema is incomplete"
  jq -e -s 'any(.[]; .operation == "messages" and .privateContent == true and ((.subjectHash // "") | test("^[0-9a-f]{24}$")))' "$audit" >/dev/null \
    || fail "private message audit lacks a salted subject hash"
  jq -e -s 'any(.[]; .operation == "create_run" and ((.subjectHash // "") | test("^[0-9a-f]{24}$")))' "$audit" >/dev/null \
    || fail "created run audit lacks a salted run hash"
  pass "Hermes audit is mode 0600, salted, bounded to safe metadata, and secret-free"
}

test_extension_contract_and_child_environment() {
  local fixture capture out status
  fixture="$TMP_ROOT/extension-fixture"
  capture="$fixture/child-env.json"
  mkdir -p \
    "$fixture/.pi/extensions" \
    "$fixture/bin" \
    "$fixture/node_modules/@earendil-works/pi-coding-agent" \
    "$fixture/node_modules/@earendil-works/pi-ai" \
    "$fixture/node_modules/typebox" \
    "$fixture/home"
  cp "$EXTENSION" "$fixture/.pi/extensions/fm-hermes-agent.ts"
  cp "$OWNER" "$fixture/bin/fm-hermes-agent.mjs"
  cat > "$fixture/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$fixture/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export const DEFAULT_MAX_BYTES = 51200;
export const DEFAULT_MAX_LINES = 2000;
export function truncateHead(text, options) {
  const bytes = Buffer.from(text);
  if (bytes.length <= options.maxBytes && text.split("\n").length <= options.maxLines) {
    return { content: text, truncated: false };
  }
  return { content: bytes.subarray(0, options.maxBytes).toString("utf8"), truncated: true };
}
JS
  cat > "$fixture/node_modules/@earendil-works/pi-ai/package.json" <<'JSON'
{"name":"@earendil-works/pi-ai","type":"module","exports":"./index.js"}
JSON
  cat > "$fixture/node_modules/@earendil-works/pi-ai/index.js" <<'JS'
export function StringEnum(values, options = {}) { return { type: "string", enum: [...values], ...options }; }
JS
  cat > "$fixture/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$fixture/node_modules/typebox/index.js" <<'JS'
const withOptions = (type, options = {}) => ({ type, ...options });
export const Type = {
  Object(properties) { return { type: "object", properties, additionalProperties: false }; },
  String(options) { return withOptions("string", options); },
  Integer(options) { return withOptions("integer", options); },
  Boolean(options) { return withOptions("boolean", options); },
  Optional(schema) { return schema; },
};
JS

  out=$(PLUGIN="$fixture/.pi/extensions/fm-hermes-agent.ts" FIXTURE="$fixture" CAPTURE="$capture" FM_ROOT_OVERRIDE="$fixture" FM_HOME="$fixture/home" HERMES_API_SERVER_KEY=SHOULD_NOT_REACH_CHILD node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const tools = new Map();
const pi = { registerTool(tool) { tools.set(tool.name, tool); } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const read = tools.get("hermes_read");
const run = tools.get("hermes_run");
if (!read || !run || tools.size !== 2) throw new Error(`unexpected tools: ${[...tools.keys()].join(",")}`);
const readKeys = Object.keys(read.parameters.properties).sort();
const runKeys = Object.keys(run.parameters.properties).sort();
if (readKeys.join(",") !== "limit,offset,operation,privateContent,runId,sessionId,taskId") throw new Error(`unexpected read schema: ${readKeys}`);
if (runKeys.join(",") !== "authorizationBasis,instruction,taskId") throw new Error(`unexpected run schema: ${runKeys}`);
for (const forbidden of ["url", "method", "path", "headers", "idempotencyKey", "token", "apiKey"]) {
  if (readKeys.includes(forbidden) || runKeys.includes(forbidden)) throw new Error(`forbidden field exposed: ${forbidden}`);
}
if (read.parameters.properties.operation.enum.join(",") !== "health,detailed_health,capabilities,models,sessions,session,messages,run_status,run_events,skills,toolsets") {
  throw new Error(`unexpected operation enum: ${read.parameters.properties.operation.enum}`);
}
if (run.parameters.properties.authorizationBasis.enum.join(",") !== "captain-approved,operator-approved") {
  throw new Error(`unexpected authorization basis enum: ${run.parameters.properties.authorizationBasis.enum}`);
}
let unconfigured = "";
try {
  await read.execute("call-unconfigured", { operation: "health", taskId: "task-extension" }, undefined);
} catch (error) {
  unconfigured = error.message;
}
if (!unconfigured.includes("Ask the operator to create") || !unconfigured.includes("mode 0600") || !unconfigured.includes("127.0.0.1:4861")) {
  throw new Error(`unsafe unconfigured result: ${unconfigured}`);
}

writeFileSync(`${process.env.FIXTURE}/bin/fm-hermes-agent.mjs`, `#!/usr/bin/env node
import { writeFileSync } from "node:fs";
const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
writeFileSync(new URL("../child-env.json", import.meta.url), JSON.stringify(process.env));
const data = input.taskId === "truncate" ? "x".repeat(60000) : { safe: true };
console.log(JSON.stringify({ ok: true, operation: "fixture", status: 200, responseBytes: 60000, data }));
`);
const readResult = await read.execute("call-read", { operation: "health", taskId: "task-extension" }, undefined);
const env = JSON.parse(await readFile(process.env.CAPTURE, "utf8"));
if (Object.hasOwn(env, "HERMES_API_SERVER_KEY")) throw new Error("bearer key reached child environment");
if (JSON.stringify(readResult).includes("SHOULD_NOT_REACH_CHILD")) throw new Error("bearer key reached tool output");
const truncated = await read.execute("call-truncate", { operation: "health", taskId: "truncate" }, undefined);
if (truncated.details?.truncated !== true || truncated.content[0]?.text.length > 52000) throw new Error("tool did not truncate model output");
const runResult = await run.execute("call-run", { taskId: "task-extension", instruction: "offline", authorizationBasis: "captain-approved" }, undefined);
if (runResult.details?.status !== 200) throw new Error("run wrapper did not return owner status");
EOF
  )
  status=$?
  [ "$status" -eq 0 ] || fail "Pi Hermes extension contract failed: $out"
  [ -z "$out" ] || fail "Pi Hermes extension test printed output: $out"
  pass "Pi registers only the two structured Hermes tools, truncates output, and strips the bearer from child environments"
}

test_unconfigured_state
test_config_refusals
test_foreign_state_directory_refusal
test_read_allowlist
test_read_refusals_and_privacy_gate
test_action_gate_and_idempotency
test_authorization_basis_secrecy
test_no_action_retry
test_transport_bounds_and_redaction
test_audit_secrecy
test_extension_contract_and_child_environment
