#!/usr/bin/env node
// Firstmate's sole transport and security owner for Hermes Agent access.
//
// Usage:
//   printf '%s' '<json>' | bin/fm-hermes-agent.mjs read
//   printf '%s' '<json>' | bin/fm-hermes-agent.mjs run
//
// The two modes accept one bounded JSON object on stdin and emit one JSON
// object on stdout. Configuration is parsed as inert data from
// $FM_HOME/config/hermes-agent.env. No credential is accepted through argv,
// stdin, or the environment. HTTP paths, methods, headers, limits, and the
// loopback origin are fixed here. The Pi extension is only a typed wrapper.

import { createHash, randomBytes } from "node:crypto";
import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  writeSync,
} from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const EXPECTED_BASE_URL = "http://127.0.0.1:4861";
const CONFIG_MAX_BYTES = 8192;
const INPUT_MAX_BYTES = 65536;
const RESPONSE_MAX_BYTES = 1024 * 1024;
const CONNECT_TIMEOUT_MS = 2000;
const READ_TIMEOUT_MS = 5000;
const ACTION_TIMEOUT_MS = 10000;
const EVENT_TIMEOUT_MS = 45000;
const INSTRUCTION_MAX_BYTES = 16384;
const AUTHORIZATION_BASES = new Set(["captain-approved", "operator-approved"]);
const ID_PATTERN = /^[A-Za-z0-9._:-]+$/;
const TASK_ID_MAX_BYTES = 128;
const SUBJECT_ID_MAX_BYTES = 256;
const CONFIG_KEYS = new Set([
  "HERMES_API_BASE_URL",
  "HERMES_API_SERVER_KEY",
  "HERMES_API_ACTIONS_ENABLED",
]);
const NOFOLLOW = constants.O_NOFOLLOW ?? 0;

const READ_OPERATIONS = {
  health: {
    path: "/health",
    template: "/health",
    authenticated: false,
    response: "json",
  },
  detailed_health: {
    path: "/health/detailed",
    template: "/health/detailed",
    authenticated: true,
    response: "json",
  },
  capabilities: {
    path: "/v1/capabilities",
    template: "/v1/capabilities",
    authenticated: true,
    response: "json",
  },
  models: {
    path: "/v1/models",
    template: "/v1/models",
    authenticated: true,
    response: "json",
  },
  skills: {
    path: "/v1/skills",
    template: "/v1/skills",
    authenticated: true,
    response: "json",
  },
  toolsets: {
    path: "/v1/toolsets",
    template: "/v1/toolsets",
    authenticated: true,
    response: "json",
  },
};

class HermesAccessError extends Error {
  constructor(code, message, metadata = {}) {
    super(message);
    this.name = "HermesAccessError";
    this.code = code;
    this.metadata = metadata;
  }
}

function usage() {
  process.stderr.write("usage: fm-hermes-agent.mjs read|run < request.json\n");
  process.exit(2);
}

function help() {
  process.stdout.write(`fm-hermes-agent.mjs - allowlisted Hermes API transport\n\nUsage:\n  printf '%s' '<json>' | bin/fm-hermes-agent.mjs read\n  printf '%s' '<json>' | bin/fm-hermes-agent.mjs run\n\nread input:\n  operation, taskId, and only the operation-specific sessionId, runId, limit,\n  offset, or privateContent fields.\n\nrun input:\n  taskId, instruction, and authorizationBasis.\n\nConfiguration:\n  $FM_HOME/config/hermes-agent.env, regular mode-0600 data file.\n  The HTTP origin is fixed at http://127.0.0.1:4861.\n`);
}

function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function safeError(error) {
  if (error instanceof HermesAccessError) {
    return { code: error.code, message: error.message };
  }
  return {
    code: "internal-error",
    message: "Hermes access failed before a safe result was available.",
  };
}

function utf8Bytes(value) {
  return Buffer.byteLength(value, "utf8");
}

function assertPlainObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new HermesAccessError("invalid-input", `${label} must be a JSON object.`);
  }
}

function assertKnownKeys(value, allowed, label) {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) {
      throw new HermesAccessError("invalid-input", `${label} contains unsupported field '${key}'.`);
    }
  }
}

function assertBoundedString(value, label, maxBytes, pattern = null) {
  if (typeof value !== "string" || value.length === 0 || value.trim().length === 0) {
    throw new HermesAccessError("invalid-input", `${label} must be a non-empty string.`);
  }
  if (utf8Bytes(value) > maxBytes) {
    throw new HermesAccessError("invalid-input", `${label} exceeds the ${maxBytes}-byte limit.`);
  }
  if (/[\u0000-\u001f\u007f]/.test(value)) {
    throw new HermesAccessError("invalid-input", `${label} must not contain control characters.`);
  }
  if (pattern && !pattern.test(value)) {
    throw new HermesAccessError("invalid-input", `${label} contains unsupported characters.`);
  }
  return value;
}

function assertTaskId(value) {
  return assertBoundedString(value, "taskId", TASK_ID_MAX_BYTES, ID_PATTERN);
}

function assertInstruction(value) {
  if (typeof value !== "string" || value.length === 0 || value.trim().length === 0) {
    throw new HermesAccessError("invalid-input", "instruction must be a non-empty string.");
  }
  if (utf8Bytes(value) > INSTRUCTION_MAX_BYTES) {
    throw new HermesAccessError(
      "invalid-input",
      `instruction exceeds the ${INSTRUCTION_MAX_BYTES}-byte limit.`,
    );
  }
  if (/[\u0000\u000b\u000c\u000d\u000e-\u001f\u007f]/.test(value)) {
    throw new HermesAccessError(
      "invalid-input",
      "instruction may contain tabs and newlines but no other control characters.",
    );
  }
  return value;
}

function assertAuthorizationBasis(value) {
  if (typeof value !== "string" || !AUTHORIZATION_BASES.has(value)) {
    throw new HermesAccessError(
      "invalid-input",
      "authorizationBasis must be one of: captain-approved, operator-approved.",
    );
  }
  return value;
}

function assertSubjectId(value, label) {
  return assertBoundedString(value, label, SUBJECT_ID_MAX_BYTES, ID_PATTERN);
}

function boundedInteger(value, label, minimum, maximum, fallback) {
  if (value === undefined) return fallback;
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new HermesAccessError(
      "invalid-input",
      `${label} must be an integer from ${minimum} through ${maximum}.`,
    );
  }
  return value;
}

async function readBoundedStdin() {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of process.stdin) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    bytes += buffer.length;
    if (bytes > INPUT_MAX_BYTES) {
      throw new HermesAccessError(
        "invalid-input",
        `Hermes request input exceeds the ${INPUT_MAX_BYTES}-byte limit.`,
      );
    }
    chunks.push(buffer);
  }
  if (bytes === 0) {
    throw new HermesAccessError("invalid-input", "Hermes request input is required on stdin.");
  }
  let value;
  try {
    value = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new HermesAccessError("invalid-input", "Hermes request input must be valid JSON.");
  }
  assertPlainObject(value, "Hermes request input");
  return value;
}

function resolveHome() {
  const configured = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE;
  if (configured) return path.resolve(configured);
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
}

function fileMode(stat) {
  return stat.mode & 0o777;
}

function assertOwnedRegularFile(stat, file, label) {
  if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1) {
    throw new HermesAccessError("unsafe-config", `${label} must be a regular, single-linked file: ${file}`);
  }
  if (typeof process.getuid === "function" && stat.uid !== process.getuid()) {
    throw new HermesAccessError("unsafe-config", `${label} must be owned by the current user: ${file}`);
  }
}

function unconfigured(configFile) {
  return new HermesAccessError(
    "not-configured",
    `Hermes access is not configured. Ask the operator to create ${configFile} with mode 0600 after the local 127.0.0.1:4861 tunnel is ready.`,
  );
}

function parseConfig(home) {
  const configFile = path.join(home, "config", "hermes-agent.env");
  let fd;
  try {
    fd = openSync(configFile, constants.O_RDONLY | NOFOLLOW);
  } catch (error) {
    if (error?.code === "ENOENT") throw unconfigured(configFile);
    throw new HermesAccessError("unsafe-config", `Hermes configuration cannot be opened safely: ${configFile}`);
  }
  let raw;
  try {
    const stat = fstatSync(fd);
    assertOwnedRegularFile(stat, configFile, "Hermes configuration");
    if (fileMode(stat) !== 0o600) {
      throw new HermesAccessError("unsafe-config", `Hermes configuration must have mode 0600: ${configFile}`);
    }
    if (stat.size === 0) throw unconfigured(configFile);
    if (stat.size > CONFIG_MAX_BYTES) {
      throw new HermesAccessError(
        "unsafe-config",
        `Hermes configuration exceeds the ${CONFIG_MAX_BYTES}-byte limit: ${configFile}`,
      );
    }
    raw = readFileSync(fd, "utf8");
  } catch (error) {
    if (error instanceof HermesAccessError) throw error;
    throw new HermesAccessError("unsafe-config", `Hermes configuration cannot be read safely: ${configFile}`);
  } finally {
    closeSync(fd);
  }
  if (raw.includes("\r") || raw.includes("\u0000")) {
    throw new HermesAccessError("unsafe-config", "Hermes configuration contains unsupported control bytes.");
  }
  if (raw.endsWith("\n")) raw = raw.slice(0, -1);
  if (!raw) throw unconfigured(configFile);

  const parsed = new Map();
  for (const line of raw.split("\n")) {
    const match = /^([A-Z][A-Z0-9_]*)=([^\n]*)$/.exec(line);
    if (!match) {
      throw new HermesAccessError(
        "unsafe-config",
        "Hermes configuration accepts only KEY=value data lines and rejects shell syntax.",
      );
    }
    const [, key, value] = match;
    if (!CONFIG_KEYS.has(key)) {
      throw new HermesAccessError("unsafe-config", `Hermes configuration contains unknown key '${key}'.`);
    }
    if (parsed.has(key)) {
      throw new HermesAccessError("unsafe-config", `Hermes configuration contains duplicate key '${key}'.`);
    }
    parsed.set(key, value);
  }

  const baseUrl = parsed.get("HERMES_API_BASE_URL");
  const apiKey = parsed.get("HERMES_API_SERVER_KEY");
  const actionsRaw = parsed.get("HERMES_API_ACTIONS_ENABLED");
  if (!baseUrl || !apiKey) throw unconfigured(configFile);
  if (baseUrl !== EXPECTED_BASE_URL) {
    throw new HermesAccessError(
      "unsafe-config",
      `Hermes API base URL must be exactly ${EXPECTED_BASE_URL}.`,
    );
  }
  const apiKeyHasCommandSyntax =
    apiKey.includes("$(") ||
    apiKey.includes("${") ||
    apiKey.includes("`") ||
    /[;&|<>]/.test(apiKey);
  const apiKeyHasQuotes = apiKey.startsWith("\"") || apiKey.endsWith("\"") || apiKey.startsWith("'") || apiKey.endsWith("'");
  if (
    utf8Bytes(apiKey) > 4096 ||
    /\s|[\u0000-\u001f\u007f]/.test(apiKey) ||
    apiKeyHasCommandSyntax ||
    apiKeyHasQuotes
  ) {
    throw new HermesAccessError(
      "unsafe-config",
      "Hermes API key is empty, oversized, quoted, or contains unsupported command syntax.",
    );
  }
  if (actionsRaw !== undefined && actionsRaw !== "true" && actionsRaw !== "false") {
    throw new HermesAccessError(
      "unsafe-config",
      "HERMES_API_ACTIONS_ENABLED must be exactly true or false when present.",
    );
  }
  return {
    baseUrl,
    apiKey,
    actionsEnabled: actionsRaw === "true",
    configFile,
  };
}

function parseReadInput(input) {
  assertKnownKeys(
    input,
    new Set(["operation", "taskId", "sessionId", "runId", "limit", "offset", "privateContent"]),
    "hermes_read input",
  );
  const taskId = assertTaskId(input.taskId);
  if (typeof input.operation !== "string" || !input.operation) {
    throw new HermesAccessError("invalid-input", "operation is required.");
  }

  const base = READ_OPERATIONS[input.operation];
  if (base) {
    for (const key of ["sessionId", "runId", "limit", "offset", "privateContent"]) {
      if (input[key] !== undefined) {
        throw new HermesAccessError("invalid-input", `${key} is not accepted for operation '${input.operation}'.`);
      }
    }
    return {
      taskId,
      operation: input.operation,
      method: "GET",
      path: base.path,
      template: base.template,
      authenticated: base.authenticated,
      response: base.response,
      privateContent: false,
      subject: "",
      timeoutMs: READ_TIMEOUT_MS,
    };
  }

  if (input.operation === "sessions") {
    for (const key of ["sessionId", "runId", "privateContent"]) {
      if (input[key] !== undefined) {
        throw new HermesAccessError("invalid-input", `${key} is not accepted for operation 'sessions'.`);
      }
    }
    const limit = boundedInteger(input.limit, "limit", 1, 100, 20);
    const offset = boundedInteger(input.offset, "offset", 0, 1000000, 0);
    return {
      taskId,
      operation: input.operation,
      method: "GET",
      path: `/api/sessions?limit=${limit}&offset=${offset}`,
      template: "/api/sessions?limit={limit}&offset={offset}",
      authenticated: true,
      response: "json",
      privateContent: false,
      subject: "",
      timeoutMs: READ_TIMEOUT_MS,
    };
  }

  if (input.operation === "session") {
    for (const key of ["runId", "limit", "offset", "privateContent"]) {
      if (input[key] !== undefined) {
        throw new HermesAccessError("invalid-input", `${key} is not accepted for operation 'session'.`);
      }
    }
    const sessionId = assertSubjectId(input.sessionId, "sessionId");
    return {
      taskId,
      operation: input.operation,
      method: "GET",
      path: `/api/sessions/${encodeURIComponent(sessionId)}`,
      template: "/api/sessions/{session_id}",
      authenticated: true,
      response: "json",
      privateContent: false,
      subject: sessionId,
      timeoutMs: READ_TIMEOUT_MS,
    };
  }

  if (input.operation === "messages") {
    if (input.runId !== undefined) {
      throw new HermesAccessError("invalid-input", "runId is not accepted for operation 'messages'.");
    }
    if (input.privateContent !== true) {
      throw new HermesAccessError(
        "private-content-required",
        "Reading Hermes message history requires privateContent=true for this exact call.",
      );
    }
    const sessionId = assertSubjectId(input.sessionId, "sessionId");
    const limit = boundedInteger(input.limit, "limit", 1, 100, 50);
    const offset = boundedInteger(input.offset, "offset", 0, 1000000, 0);
    return {
      taskId,
      operation: input.operation,
      method: "GET",
      path: `/api/sessions/${encodeURIComponent(sessionId)}/messages?limit=${limit}&offset=${offset}`,
      template: "/api/sessions/{session_id}/messages?limit={limit}&offset={offset}",
      authenticated: true,
      response: "json",
      privateContent: true,
      subject: sessionId,
      timeoutMs: READ_TIMEOUT_MS,
    };
  }

  if (input.operation === "run_status" || input.operation === "run_events") {
    for (const key of ["sessionId", "limit", "offset", "privateContent"]) {
      if (input[key] !== undefined) {
        throw new HermesAccessError("invalid-input", `${key} is not accepted for operation '${input.operation}'.`);
      }
    }
    const runId = assertSubjectId(input.runId, "runId");
    const events = input.operation === "run_events";
    return {
      taskId,
      operation: input.operation,
      method: "GET",
      path: `/v1/runs/${encodeURIComponent(runId)}${events ? "/events" : ""}`,
      template: events ? "/v1/runs/{run_id}/events" : "/v1/runs/{run_id}",
      authenticated: true,
      response: events ? "sse" : "json",
      privateContent: false,
      subject: runId,
      timeoutMs: events ? EVENT_TIMEOUT_MS : READ_TIMEOUT_MS,
    };
  }

  throw new HermesAccessError("invalid-input", `Unsupported Hermes read operation '${input.operation}'.`);
}

function parseRunInput(input) {
  assertKnownKeys(
    input,
    new Set(["taskId", "instruction", "authorizationBasis"]),
    "hermes_run input",
  );
  const taskId = assertTaskId(input.taskId);
  const instruction = assertInstruction(input.instruction);
  const authorizationBasis = assertAuthorizationBasis(input.authorizationBasis);
  const sessionId = `firstmate:${taskId}`;
  const idempotencyKey = `fm-${createHash("sha256")
    .update("firstmate-hermes-run-v1\u0000")
    .update(taskId)
    .update("\u0000")
    .update(instruction)
    .digest("hex")}`;
  return {
    taskId,
    operation: "create_run",
    method: "POST",
    path: "/v1/runs",
    template: "/v1/runs",
    authenticated: true,
    response: "json",
    privateContent: false,
    subject: "",
    timeoutMs: ACTION_TIMEOUT_MS,
    authorizationBasis,
    idempotencyKey,
    body: Buffer.from(JSON.stringify({ input: instruction, session_id: sessionId }), "utf8"),
  };
}

function secureStateDir(home) {
  const stateDir = path.join(home, "state");
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });
  const stat = lstatSync(stateDir);
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new HermesAccessError("unsafe-audit", `Hermes audit state directory is unsafe: ${stateDir}`);
  }
  if (typeof process.getuid === "function" && stat.uid !== process.getuid()) {
    throw new HermesAccessError("unsafe-audit", `Hermes audit state directory must be owned by the current user: ${stateDir}`);
  }
  if (fileMode(stat) !== 0o700) {
    throw new HermesAccessError("unsafe-audit", `Hermes audit state directory must have mode 0700: ${stateDir}`);
  }
  return stateDir;
}

function secureOpenExisting(file, flags, label) {
  const fd = openSync(file, flags | NOFOLLOW);
  const stat = fstatSync(fd);
  try {
    assertOwnedRegularFile(stat, file, label);
    if (fileMode(stat) !== 0o600) {
      throw new HermesAccessError("unsafe-audit", `${label} must have mode 0600: ${file}`);
    }
    return fd;
  } catch (error) {
    closeSync(fd);
    throw error;
  }
}

function loadOrCreateAuditSalt(stateDir) {
  const saltFile = path.join(stateDir, ".hermes-agent-audit-salt");
  let fd;
  try {
    fd = secureOpenExisting(saltFile, constants.O_RDONLY, "Hermes audit salt");
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    try {
      fd = openSync(
        saltFile,
        constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | NOFOLLOW,
        0o600,
      );
      writeSync(fd, `${randomBytes(32).toString("hex")}\n`, null, "utf8");
      closeSync(fd);
      fd = secureOpenExisting(saltFile, constants.O_RDONLY, "Hermes audit salt");
    } catch (createError) {
      if (fd !== undefined) {
        try { closeSync(fd); } catch {}
      }
      throw new HermesAccessError("unsafe-audit", `Hermes audit salt cannot be created safely: ${saltFile}`);
    }
  }
  try {
    const stat = fstatSync(fd);
    if (stat.size !== 65) {
      throw new HermesAccessError("unsafe-audit", `Hermes audit salt has an invalid size: ${saltFile}`);
    }
    const value = readFileSync(fd, "utf8");
    if (!/^[0-9a-f]{64}\n$/.test(value)) {
      throw new HermesAccessError("unsafe-audit", `Hermes audit salt has an invalid format: ${saltFile}`);
    }
    return value.trim();
  } finally {
    closeSync(fd);
  }
}

function prepareAudit(home) {
  const stateDir = secureStateDir(home);
  const salt = loadOrCreateAuditSalt(stateDir);
  const auditFile = path.join(stateDir, "hermes-agent-audit.jsonl");
  let fd;
  try {
    fd = secureOpenExisting(
      auditFile,
      constants.O_WRONLY | constants.O_APPEND,
      "Hermes audit log",
    );
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    try {
      fd = openSync(
        auditFile,
        constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_APPEND | NOFOLLOW,
        0o600,
      );
    } catch {
      throw new HermesAccessError("unsafe-audit", `Hermes audit log cannot be created safely: ${auditFile}`);
    }
    const stat = fstatSync(fd);
    try {
      assertOwnedRegularFile(stat, auditFile, "Hermes audit log");
      if (fileMode(stat) !== 0o600) {
        throw new HermesAccessError("unsafe-audit", `Hermes audit log must have mode 0600: ${auditFile}`);
      }
    } catch (error) {
      closeSync(fd);
      throw error;
    }
  }
  closeSync(fd);
  return { auditFile, salt };
}

function subjectHash(salt, kind, identifier) {
  if (!identifier) return null;
  return createHash("sha256")
    .update(salt)
    .update("\u0000")
    .update(kind)
    .update("\u0000")
    .update(identifier)
    .digest("hex")
    .slice(0, 24);
}

function appendAudit(audit, record) {
  const fd = secureOpenExisting(
    audit.auditFile,
    constants.O_WRONLY | constants.O_APPEND,
    "Hermes audit log",
  );
  try {
    writeSync(fd, `${JSON.stringify(record)}\n`, null, "utf8");
  } finally {
    closeSync(fd);
  }
}

function makeAuditRecord(request, audit, result) {
  const createdRun = result.runId || "";
  const subject = createdRun || request.subject || "";
  const subjectKind = createdRun || request.operation.startsWith("run_")
    ? "run"
    : request.subject
      ? "session"
      : "";
  return {
    at: new Date().toISOString(),
    task: subjectHash(audit.salt, "task", request.taskId),
    operation: request.operation,
    endpoint: request.template,
    httpStatus: result.status ?? null,
    durationMs: result.durationMs ?? 0,
    responseBytes: result.responseBytes ?? 0,
    subjectHash: subjectHash(audit.salt, subjectKind, subject),
    privateContent: request.privateContent === true,
    authorizationBasis: request.authorizationBasis || null,
  };
}

function requestHttp(config, request) {
  return new Promise((resolve, reject) => {
    const url = new URL(request.path, config.baseUrl);
    if (url.origin !== EXPECTED_BASE_URL || url.hostname !== "127.0.0.1" || url.port !== "4861") {
      reject(new HermesAccessError("unsafe-request", "Hermes request escaped the pinned loopback origin."));
      return;
    }

    const headers = {
      Accept: request.response === "sse" ? "text/event-stream" : "application/json",
      Connection: "close",
      "User-Agent": "firstmate-hermes-access/1",
    };
    if (request.authenticated) headers.Authorization = `Bearer ${config.apiKey}`;
    if (request.body) {
      headers["Content-Type"] = "application/json";
      headers["Content-Length"] = String(request.body.length);
      headers["Idempotency-Key"] = request.idempotencyKey;
    }

    const started = performance.now();
    let finished = false;
    let connectTimer = null;
    let overallTimer = null;
    let idleTimer = null;
    let status = null;
    let responseBytes = 0;

    const finish = (error, value) => {
      if (finished) return;
      finished = true;
      if (connectTimer) clearTimeout(connectTimer);
      if (overallTimer) clearTimeout(overallTimer);
      if (idleTimer) clearTimeout(idleTimer);
      if (error) {
        if (error instanceof HermesAccessError) {
          error.metadata = {
            ...error.metadata,
            status,
            responseBytes,
            durationMs: Math.max(0, Math.round(performance.now() - started)),
          };
        }
        reject(error);
      } else {
        resolve(value);
      }
    };

    const clientRequest = http.request(
      {
        protocol: "http:",
        hostname: "127.0.0.1",
        port: 4861,
        method: request.method,
        path: `${url.pathname}${url.search}`,
        headers,
        agent: false,
      },
      (response) => {
        status = response.statusCode ?? null;
        const chunks = [];
        const armIdleTimeout = () => {
          if (request.response !== "sse") return;
          if (idleTimer) clearTimeout(idleTimer);
          idleTimer = setTimeout(() => {
            response.destroy();
            finish(new HermesAccessError("timeout", "Hermes event stream exceeded the 45-second idle bound."));
          }, EVENT_TIMEOUT_MS);
        };
        armIdleTimeout();
        response.on("data", (chunk) => {
          armIdleTimeout();
          const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
          responseBytes += buffer.length;
          if (responseBytes > RESPONSE_MAX_BYTES) {
            response.destroy();
            finish(
              new HermesAccessError(
                "response-too-large",
                `Hermes response exceeded the ${RESPONSE_MAX_BYTES}-byte limit.`,
              ),
            );
            return;
          }
          chunks.push(buffer);
        });
        response.on("error", (error) => {
          finish(new HermesAccessError("network-error", `Hermes response failed: ${error.message}`));
        });
        response.on("end", () => {
          const durationMs = Math.max(0, Math.round(performance.now() - started));
          const body = Buffer.concat(chunks);
          if (status >= 300 && status < 400) {
            finish(
              new HermesAccessError(
                "redirect-refused",
                "Hermes returned a redirect. Firstmate never follows redirects from the pinned loopback service.",
              ),
            );
            return;
          }
          if (status < 200 || status >= 300) {
            finish(
              new HermesAccessError(
                "http-error",
                `Hermes API returned HTTP ${status ?? "unknown"}.`,
              ),
            );
            return;
          }
          finish(null, { status, body, responseBytes, durationMs });
        });
      },
    );

    overallTimer = setTimeout(() => {
      clientRequest.destroy();
      finish(
        new HermesAccessError(
          "timeout",
          request.response === "sse"
            ? "Hermes event stream exceeded the 45-second bound."
            : `Hermes request exceeded the ${request.timeoutMs / 1000}-second bound.`,
        ),
      );
    }, request.timeoutMs);

    clientRequest.on("socket", (socket) => {
      if (!socket.connecting) return;
      connectTimer = setTimeout(() => {
        clientRequest.destroy();
        finish(new HermesAccessError("connect-timeout", "Hermes loopback connection exceeded the 2-second bound."));
      }, CONNECT_TIMEOUT_MS);
      socket.once("connect", () => {
        if (connectTimer) clearTimeout(connectTimer);
        connectTimer = null;
      });
    });
    clientRequest.on("error", (error) => {
      finish(new HermesAccessError("network-error", `Hermes loopback request failed: ${error.message}`));
    });
    if (request.body) clientRequest.write(request.body);
    clientRequest.end();
  });
}

function decodeReversibleEscapes(value) {
  let decoded = value;
  for (let index = 0; index < 8; index += 1) {
    let next = decoded.replace(/\\\\/g, "\\");
    next = next.replace(/\\u([0-9a-fA-F]{4})/g, (_match, hex) => String.fromCharCode(Number.parseInt(hex, 16)));
    next = next.replace(/\\x([0-9a-fA-F]{2})/g, (_match, hex) => String.fromCharCode(Number.parseInt(hex, 16)));
    try {
      next = decodeURIComponent(next);
    } catch {}
    if (next === decoded) break;
    decoded = next;
  }
  return decoded;
}

function redactText(value, apiKey) {
  if (value.includes(apiKey)) return value.split(apiKey).join("[REDACTED]");
  if (decodeReversibleEscapes(value).includes(apiKey)) return "[REDACTED]";
  return value;
}

function redactDecodedValue(value, apiKey) {
  if (typeof value === "string") return redactText(value, apiKey);
  if (Array.isArray(value)) return value.map((entry) => redactDecodedValue(entry, apiKey));
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, entry]) => [
        redactText(key, apiKey),
        redactDecodedValue(entry, apiKey),
      ]),
    );
  }
  return value;
}

function invalidResponse(response, message) {
  return new HermesAccessError(
    "invalid-response",
    message,
    {
      status: response.status,
      responseBytes: response.responseBytes,
      durationMs: response.durationMs,
    },
  );
}

function redactSse(text, apiKey, response) {
  return text.split(/(\r\n\r\n|\n\n|\r\r)/).map((frame) => {
    const lines = frame.split(/\r\n|\r|\n/);
    const dataIndexes = [];
    const data = [];
    for (let index = 0; index < lines.length; index += 1) {
      const match = /^data:(?: ?)(.*)$/.exec(lines[index]);
      if (match) {
        dataIndexes.push(index);
        data.push(match[1]);
      }
    }
    if (dataIndexes.length === 0) return redactText(frame, apiKey);
    let decoded;
    try {
      decoded = JSON.parse(data.join("\n"));
    } catch {
      throw invalidResponse(response, "Hermes returned non-JSON data in an event stream.");
    }
    const payload = JSON.stringify(redactDecodedValue(decoded, apiKey));
    return lines.map((line, index) => {
      if (index === dataIndexes[0]) return `data: ${payload}`;
      if (dataIndexes.includes(index)) return "";
      return redactText(line, apiKey);
    }).join("\n");
  }).join("");
}

function decodeResponse(response, request, apiKey) {
  const text = response.body.toString("utf8");
  if (request.response === "sse") return redactSse(text, apiKey, response);
  if (!text) return null;
  try {
    return redactDecodedValue(JSON.parse(text), apiKey);
  } catch {
    throw invalidResponse(response, "Hermes returned a non-JSON response for a JSON operation.");
  }
}

async function main() {
  const mode = process.argv[2];
  if (mode === "--help" && process.argv.length === 3) {
    help();
    return;
  }
  if ((mode !== "read" && mode !== "run") || process.argv.length !== 3) usage();

  let request;
  let audit;
  let auditWritten = false;
  try {
    const input = await readBoundedStdin();
    request = mode === "read" ? parseReadInput(input) : parseRunInput(input);
    const home = resolveHome();
    audit = prepareAudit(home);
    const config = parseConfig(home);
    if (mode === "run" && !config.actionsEnabled) {
      throw new HermesAccessError(
        "actions-disabled",
        "Hermes actions are disabled. The operator must set HERMES_API_ACTIONS_ENABLED=true in the private mode-0600 configuration before an authorized run can start.",
      );
    }

    let response;
    try {
      response = await requestHttp(config, request);
    } catch (error) {
      const metadata = error instanceof HermesAccessError ? error.metadata : {};
      appendAudit(audit, makeAuditRecord(request, audit, metadata));
      auditWritten = true;
      throw error;
    }

    let data;
    try {
      data = decodeResponse(response, request, config.apiKey);
    } catch (error) {
      const metadata = error instanceof HermesAccessError ? error.metadata : response;
      appendAudit(audit, makeAuditRecord(request, audit, metadata));
      auditWritten = true;
      throw error;
    }
    const runId = mode === "run" && data && typeof data.run_id === "string" ? data.run_id : "";
    appendAudit(audit, makeAuditRecord(request, audit, { ...response, runId }));
    auditWritten = true;
    emit({
      ok: true,
      operation: request.operation,
      status: response.status,
      responseBytes: response.responseBytes,
      data,
    });
  } catch (error) {
    if (request && audit && !auditWritten) {
      try {
        const metadata = error instanceof HermesAccessError ? error.metadata : {};
        appendAudit(audit, makeAuditRecord(request, audit, metadata));
      } catch {
        error = new HermesAccessError(
          "unsafe-audit",
          "Hermes access stopped because the private audit record could not be written safely.",
        );
      }
    }
    emit({ ok: false, error: safeError(error) });
    process.exitCode = 1;
  }
}

await main();
