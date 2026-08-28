import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  DEFAULT_MAX_BYTES,
  DEFAULT_MAX_LINES,
  truncateHead,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "typebox";

const READ_OPERATIONS = [
  "health",
  "detailed_health",
  "capabilities",
  "models",
  "sessions",
  "session",
  "messages",
  "run_status",
  "run_events",
  "skills",
  "toolsets",
] as const;

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmRoot = resolve(process.env.FM_ROOT_OVERRIDE || root);
const fmHome = resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root);
const ownerScript = resolve(fmRoot, "bin/fm-hermes-agent.mjs");
const ownerOutputLimit = 1024 * 1024 + 128 * 1024;
const ownerErrorLimit = 16 * 1024;

const readParameters = Type.Object({
  operation: StringEnum(READ_OPERATIONS, {
    description: "Fixed read operation to perform against the pinned Hermes API Server",
  }),
  taskId: Type.String({
    description: "Firstmate task identity for the private audit record",
    minLength: 1,
    maxLength: 128,
    pattern: "^[A-Za-z0-9._:-]+$",
  }),
  sessionId: Type.Optional(Type.String({
    description: "Hermes session identifier, required only for session or messages",
    minLength: 1,
    maxLength: 256,
    pattern: "^[A-Za-z0-9._:-]+$",
  })),
  runId: Type.Optional(Type.String({
    description: "Hermes run identifier, required only for run_status or run_events",
    minLength: 1,
    maxLength: 256,
    pattern: "^[A-Za-z0-9._:-]+$",
  })),
  limit: Type.Optional(Type.Integer({
    description: "Bounded sessions or message page size",
    minimum: 1,
    maximum: 100,
  })),
  offset: Type.Optional(Type.Integer({
    description: "Bounded sessions or message page offset",
    minimum: 0,
    maximum: 1000000,
  })),
  privateContent: Type.Optional(Type.Boolean({
    description: "Must be exactly true for message-history access",
  })),
}, { additionalProperties: false });

const runParameters = Type.Object({
  taskId: Type.String({
    description: "Firstmate task identity used for Hermes session continuity and the private audit record",
    minLength: 1,
    maxLength: 128,
    pattern: "^[A-Za-z0-9._:-]+$",
  }),
  instruction: Type.String({
    description: "Authorized instruction for one Hermes run, limited to 16 KiB",
    minLength: 1,
    maxLength: 16384,
  }),
  authorizationBasis: StringEnum(["captain-approved", "operator-approved"], {
    description: "Required non-secret authorization category written to the private audit record",
  }),
}, { additionalProperties: false });

type OwnerEnvelope = {
  ok?: boolean;
  operation?: string;
  status?: number;
  responseBytes?: number;
  data?: unknown;
  error?: {
    code?: string;
    message?: string;
  };
};

function childEnvironment(): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {
    FM_HOME: fmHome,
    FM_ROOT_OVERRIDE: fmRoot,
  };
  for (const name of ["HOME", "TMPDIR", "TMP", "TEMP", "SystemRoot", "WINDIR"]) {
    const value = process.env[name];
    if (value) env[name] = value;
  }
  return env;
}

function invokeOwner(
  mode: "read" | "run",
  params: unknown,
  signal?: AbortSignal,
): Promise<OwnerEnvelope> {
  return new Promise((resolveResult, rejectResult) => {
    const child = spawn(process.execPath, [ownerScript, mode], {
      cwd: fmRoot,
      env: childEnvironment(),
      stdio: ["pipe", "pipe", "pipe"],
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let settled = false;
    const timeoutMs = mode === "run" ? 12000 : 47000;
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      settleError("Hermes access owner exceeded its bounded execution time.");
    }, timeoutMs);

    const onAbort = () => {
      child.kill("SIGTERM");
      settleError("Hermes access was cancelled.");
    };
    signal?.addEventListener("abort", onAbort, { once: true });

    function cleanup(): void {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
    }

    function settleError(message: string): void {
      if (settled) return;
      settled = true;
      cleanup();
      rejectResult(new Error(message));
    }

    child.stdout.on("data", (chunk: Buffer) => {
      stdoutBytes += chunk.length;
      if (stdoutBytes > ownerOutputLimit) {
        child.kill("SIGTERM");
        settleError("Hermes access owner returned an oversized result.");
        return;
      }
      stdout.push(chunk);
    });
    child.stderr.on("data", (chunk: Buffer) => {
      if (stderrBytes >= ownerErrorLimit) return;
      const remaining = ownerErrorLimit - stderrBytes;
      const retained = chunk.length <= remaining ? chunk : chunk.subarray(0, remaining);
      stderr.push(retained);
      stderrBytes += retained.length;
    });
    child.on("error", () => {
      settleError("Hermes access owner could not be started.");
    });
    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      cleanup();
      const text = Buffer.concat(stdout).toString("utf8").trim();
      let envelope: OwnerEnvelope;
      try {
        envelope = JSON.parse(text) as OwnerEnvelope;
      } catch {
        const diagnostic = Buffer.concat(stderr).toString("utf8").trim();
        rejectResult(new Error(
          diagnostic
            ? `Hermes access owner returned an invalid result: ${diagnostic}`
            : "Hermes access owner returned an invalid result.",
        ));
        return;
      }
      if (code !== 0 || envelope.ok !== true) {
        rejectResult(new Error(
          envelope.error?.message || "Hermes access stopped without a safe result.",
        ));
        return;
      }
      resolveResult(envelope);
    });
    child.stdin.on("error", () => {
      settleError("Hermes access owner could not receive its structured request.");
    });
    child.stdin.end(JSON.stringify(params));
  });
}

function renderOwnerResult(envelope: OwnerEnvelope): {
  content: Array<{ type: "text"; text: string }>;
  details: {
    operation: string;
    status: number;
    responseBytes: number;
    truncated: boolean;
  };
} {
  const output = typeof envelope.data === "string"
    ? envelope.data
    : JSON.stringify(envelope.data ?? null, null, 2);
  const truncation = truncateHead(output, {
    maxBytes: DEFAULT_MAX_BYTES,
    maxLines: DEFAULT_MAX_LINES,
  });
  const text = truncation.truncated
    ? `${truncation.content}\n\n[Hermes result truncated to ${DEFAULT_MAX_LINES} lines or ${DEFAULT_MAX_BYTES} bytes. The omitted private response was not written to disk.]`
    : truncation.content;
  return {
    content: [{ type: "text", text }],
    details: {
      operation: envelope.operation || "unknown",
      status: envelope.status || 0,
      responseBytes: envelope.responseBytes || 0,
      truncated: truncation.truncated,
    },
  };
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "hermes_read",
    label: "Read Hermes Agent",
    description: "Read one fixed, allowlisted Hermes Agent status or metadata surface through the operator-owned loopback connection. No arbitrary URL, method, path, or header is accepted. Message history requires privateContent=true. Tool output is truncated to 2000 lines or 50KB and omitted bytes are never written to disk.",
    promptSnippet: "Read allowlisted Hermes Agent status or metadata through the private loopback connection",
    promptGuidelines: [
      "Use hermes_read only when the current task needs Hermes status, capabilities, bounded session metadata, explicitly authorized private message history, or status for a named Hermes run.",
      "Set hermes_read privateContent=true only when the current task explicitly requires private Hermes message history, and never repeat private titles or content unnecessarily.",
    ],
    parameters: readParameters,
    async execute(_toolCallId, params, signal) {
      return renderOwnerResult(await invokeOwner("read", params, signal));
    },
  });

  pi.registerTool({
    name: "hermes_run",
    label: "Run Hermes Agent",
    description: "Create exactly one Hermes Agent run through POST /v1/runs. Actions are disabled by default in private configuration. Every call requires a Firstmate task identity and a fixed non-secret authorization category. The transport derives a deterministic idempotency key and never retries an action automatically. No stop, approval, session mutation, jobs, arbitrary endpoint, URL, method, path, or header is exposed.",
    promptSnippet: "Create one explicitly authorized Hermes Agent run with deterministic idempotency and no automatic retry",
    promptGuidelines: [
      "Call hermes_run only for a concrete Hermes action that current authority explicitly permits, because every prompt can invoke Hermes tools and cause external effects.",
      "Never use hermes_run for status or inspection when hermes_read can answer the request, and select the authorizationBasis category matching the granted authority.",
    ],
    parameters: runParameters,
    async execute(_toolCallId, params, signal) {
      return renderOwnerResult(await invokeOwner("run", params, signal));
    },
  });
}
