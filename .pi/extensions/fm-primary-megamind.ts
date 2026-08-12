// Pi primary input adapter for the host-owned Megamind coordinator.
// Pi owns input interception and replay transport; the coordinator owns every
// semantic decision and the bounded reader.
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type Decision = {
  decision?: string;
  failure_code?: string | null;
  selection_id?: string | null;
  offers?: Array<{ wiki?: string }>;
  context?: { text?: string } | null;
};

type ContextItem = { prompt: string; context: string };

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const coordinator = `${root}/bin/fm-megamind-primary.sh`;
const contextByPrompt = new Map<string, ContextItem[]>();
const replayByPrompt = new Map<string, string[]>();

function promptKey(prompt: string): string {
  return createHash("sha256").update(prompt).digest("hex");
}

function enqueue(map: Map<string, ContextItem[]>, prompt: string, context: string): void {
  const key = promptKey(prompt);
  const entries = map.get(key) ?? [];
  entries.push({ prompt, context });
  map.set(key, entries);
}

function dequeue(map: Map<string, ContextItem[]>, prompt: string): string | undefined {
  const key = promptKey(prompt);
  const entries = map.get(key);
  if (!entries) return undefined;
  const index = entries.findIndex((entry) => entry.prompt === prompt);
  if (index < 0) return undefined;
  const [entry] = entries.splice(index, 1);
  if (entries.length === 0) map.delete(key);
  return entry.context;
}

function enqueueReplay(prompt: string): void {
  const key = promptKey(prompt);
  const entries = replayByPrompt.get(key) ?? [];
  entries.push(prompt);
  replayByPrompt.set(key, entries);
}

function consumeReplay(prompt: string): boolean {
  const key = promptKey(prompt);
  const entries = replayByPrompt.get(key);
  if (!entries) return false;
  const index = entries.indexOf(prompt);
  if (index < 0) return false;
  entries.splice(index, 1);
  if (entries.length === 0) replayByPrompt.delete(key);
  return true;
}

function runCoordinator(args: string[], prompt = ""): Promise<Decision> {
  return new Promise((resolveResult) => {
    const child = spawn(coordinator, args, {
      cwd: root,
      env: { ...process.env, FM_ROOT_OVERRIDE: root },
      stdio: ["pipe", "pipe", "ignore"],
    });
    let stdout = "";
    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    const timeout = setTimeout(() => {
      child.kill("SIGTERM");
      resolveResult({ decision: "block", failure_code: "coordinator_timeout" });
    }, 120_000);
    child.on("error", () => {
      clearTimeout(timeout);
      resolveResult({ decision: "block", failure_code: "coordinator_unavailable" });
    });
    child.on("close", () => {
      clearTimeout(timeout);
      try {
        resolveResult(JSON.parse(stdout) as Decision);
      } catch {
        resolveResult({ decision: "block", failure_code: "coordinator_invalid" });
      }
    });
    child.stdin.end(prompt);
  });
}

function sessionId(ctx: { sessionManager?: { getSessionId?: () => string } }): string {
  return ctx.sessionManager?.getSessionId?.() ?? "pi-session";
}

function failureText(result: Decision): string {
  return `Firstmate preflight stopped this request (${result.failure_code ?? "unknown"}); no provider turn was started.`;
}

export default function (pi: ExtensionAPI) {
  pi.on?.("input", async (event, ctx) => {
    const text = String((event as { text?: unknown }).text ?? "");
    if (!text) return { action: "continue" as const };

    // The adapter's own replay is the only extension-originated prompt that is
    // allowed to bypass a second preflight. Watcher and session messages remain
    // ordinary extension input and take the mandatory path below, where the
    // coordinator's own classifier decides whether they bypass.
    if ((event as { source?: string }).source === "extension" && consumeReplay(text)) {
      return { action: "continue" as const };
    }

    const result = await runCoordinator(
      ["process", "--harness", process.env.FM_PI_HARNESS === "pi-signed" ? "pi-signed" : "pi", "--session-id", sessionId(ctx), "--submission-id", randomUUID()],
      text,
    );
    switch (result.decision) {
      case "bypass":
      case "proceed-no-context":
        return { action: "continue" as const };
      case "proceed-with-admission": {
        const context = result.context?.text;
        if (context) enqueue(contextByPrompt, text, context);
        return { action: "continue" as const };
      }
      case "offer": {
        const selection = result.selection_id;
        const offers = (result.offers ?? []).map((item) => item.wiki ?? "").filter(Boolean);
        if (!selection || offers.length === 0 || !ctx.hasUI) {
          ctx.ui.notify("Megamind found an ambiguous request. No wiki content was loaded.", "warning");
          return { action: "handled" as const };
        }
        const selected = await ctx.ui.select("Choose one exact wiki offer", offers);
        if (!selected) {
          ctx.ui.notify("No wiki offer selected. The request was not sent.", "warning");
          return { action: "handled" as const };
        }
        const continued = await runCoordinator(
          ["continue", "--harness", process.env.FM_PI_HARNESS === "pi-signed" ? "pi-signed" : "pi", "--session-id", sessionId(ctx), "--selection-id", selection, "--offer", selected],
        );
        if (continued.decision !== "proceed-with-admission" || !continued.context?.text) {
          ctx.ui.notify(failureText(continued), "error");
          return { action: "handled" as const };
        }
        enqueue(contextByPrompt, text, continued.context.text);
        enqueueReplay(text);
        await pi.sendUserMessage(text);
        return { action: "handled" as const };
      }
      default:
        ctx.ui.notify(failureText(result), "error");
        return { action: "handled" as const };
    }
  });

  pi.on?.("before_agent_start", async (event) => {
    const prompt = String((event as { prompt?: unknown }).prompt ?? "");
    const context = dequeue(contextByPrompt, prompt);
    if (!context) return;
    return {
      message: {
        customType: "firstmate-megamind-context",
        content: context,
        display: false,
      },
    };
  });

  pi.on?.("session_shutdown", () => {
    contextByPrompt.clear();
    replayByPrompt.clear();
  });
}
