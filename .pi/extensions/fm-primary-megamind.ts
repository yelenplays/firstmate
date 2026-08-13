// Pi primary input adapter for the host-owned Megamind coordinator.
// Pi owns input interception and replay transport; the coordinator owns every
// semantic decision and the bounded reader.
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  WikiOfferDispositionPicker,
  WikiExistingPicker,
  type WikiOfferDisposition,
  type WikiExistingDisposition,
} from "./lib/fm-megamind-offer-picker.ts";

type Decision = {
  decision?: string;
  failure_code?: string | null;
  selection_id?: string | null;
  offers?: Array<{ wiki?: string }>;
  existing_selection_id?: string | null;
  existing_wikis?: Array<{ wiki?: string }>;
  existing_list?: {
    truncated?: boolean;
    shown?: number;
    total?: number;
    can_show_more?: boolean;
  } | null;
  context?: { text?: string } | null;
  replay_prompt?: string | null;
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

// Automatic primary mode is opt-in and the coordinator owns that eligibility.
// A session that never opted into it must not lose its prompt to a transport
// failure of this adapter's own, so the coordinator is asked by exit status
// alone before any failure is turned into a handled, unsent prompt. A
// coordinator that cannot even be spawned is by definition governing nothing.
function coordinatorGoverns(): Promise<boolean> {
  return new Promise((resolveResult) => {
    const child = spawn(coordinator, ["governed", "--harness", process.env.FM_PI_HARNESS === "pi-signed" ? "pi-signed" : "pi"], {
      cwd: root,
      env: { ...process.env, FM_ROOT_OVERRIDE: root },
      stdio: ["ignore", "ignore", "ignore"],
    });
    const timeout = setTimeout(() => {
      child.kill("SIGTERM");
      resolveResult(false);
    }, 10_000);
    child.on("error", () => {
      clearTimeout(timeout);
      resolveResult(false);
    });
    child.on("close", (code) => {
      clearTimeout(timeout);
      resolveResult(code === 0);
    });
  });
}

function sessionId(ctx: { sessionManager?: { getSessionId?: () => string } }): string {
  return ctx.sessionManager?.getSessionId?.() ?? "pi-session";
}

function failureText(result: Decision): string {
  return `Firstmate preflight stopped this request (${result.failure_code ?? "unknown"}); no provider turn was started.`;
}

function harnessName(): string {
  return process.env.FM_PI_HARNESS === "pi-signed" ? "pi-signed" : "pi";
}

type ExistingUiContext = {
  sessionManager?: { getSessionId?: () => string };
  hasUI?: boolean;
  mode?: string;
  ui: {
    custom<T>(factory: (tui: { requestRender: () => void }, theme: unknown, keybindings: unknown, done: (value: T) => void) => unknown): Promise<T>;
    notify: (message: string, type: "info" | "warning" | "error") => void;
  };
};

async function chooseExisting(
  ctx: ExistingUiContext,
  selection: string,
  initial: Decision,
): Promise<{ wiki: string; existingSelectionId: string } | null> {
  let result = initial;
  while (true) {
    const existingSelectionId = result.existing_selection_id;
    const names = (result.existing_wikis ?? [])
      .map((item) => item.wiki ?? "")
      .filter(Boolean);
    if (!existingSelectionId || result.decision !== "existing-list") {
      ctx.ui.notify(failureText({ failure_code: "existing_list_invalid" }), "error");
      return null;
    }
    if (names.length === 0) {
      ctx.ui.notify("Megamind returned no eligible existing wikis. The request was not sent.", "warning");
      return null;
    }
    if (!ctx.hasUI || ctx.mode !== "tui") {
      ctx.ui.notify("Megamind returned eligible existing wikis, but this interface cannot choose one. The request was not sent.", "warning");
      return null;
    }
    const list = result.existing_list;
    const disposition = await ctx.ui.custom<WikiExistingDisposition | null>((tui: { requestRender: () => void }, _theme: unknown, _keybindings: unknown, done: (value: WikiExistingDisposition | null) => void) => {
      const picker = new WikiExistingPicker(names, list?.can_show_more === true);
      picker.onSelect = done;
      picker.onCancel = () => done(null);
      return {
        render: (width: number) => picker.render(width),
        invalidate: () => picker.invalidate(),
        handleInput: (data: string) => {
          picker.handleInput(data);
          tui.requestRender();
        },
      };
    });
    if (!disposition) return null;
    if (disposition.kind === "existing") {
      return { wiki: disposition.wiki, existingSelectionId };
    }
    if (list?.can_show_more !== true) {
      ctx.ui.notify("Megamind did not offer a safe full eligible-wiki list. The request was not sent.", "error");
      return null;
    }
    result = await runCoordinator([
      "existing-list",
      "--harness", harnessName(),
      "--session-id", sessionId(ctx),
      "--selection-id", selection,
      "--full",
    ]);
    if (result.decision !== "existing-list") {
      ctx.ui.notify(failureText(result), "error");
      return null;
    }
  }
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
      ["process", "--harness", harnessName(), "--session-id", sessionId(ctx), "--submission-id", randomUUID()],
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
        if (!selection || offers.length === 0 || !ctx.hasUI || ctx.mode !== "tui") {
          ctx.ui.notify("Megamind found an ambiguous request. No wiki content was loaded, and this interface cannot choose a disposition.", "warning");
          return { action: "handled" as const };
        }
        const disposition = await ctx.ui.custom<WikiOfferDisposition | null>((tui, _theme, _keybindings, done) => {
          const picker = new WikiOfferDispositionPicker(offers);
          picker.onSelect = done;
          picker.onCancel = () => done(null);
          return {
            render: (width) => picker.render(width),
            invalidate: () => picker.invalidate(),
            handleInput: (data) => {
              picker.handleInput(data);
              tui.requestRender();
            },
          };
        });
        if (!disposition) {
          ctx.ui.notify("Wiki evidence selection was cancelled. The request was not sent.", "warning");
          return { action: "handled" as const };
        }
        if (disposition.kind === "different-existing") {
          const existing = await runCoordinator([
            "existing-list",
            "--harness", harnessName(),
            "--session-id", sessionId(ctx),
            "--selection-id", selection,
          ]);
          const choice = await chooseExisting(ctx, selection, existing);
          if (!choice) return { action: "handled" as const };
          const continued = await runCoordinator([
            "continue-existing",
            "--harness", harnessName(),
            "--session-id", sessionId(ctx),
            "--selection-id", selection,
            "--existing-selection-id", choice.existingSelectionId,
            "--wiki", choice.wiki,
            "--include-replay",
          ]);
          if (continued.decision !== "proceed-with-admission" || !continued.context?.text || !continued.replay_prompt) {
            ctx.ui.notify(failureText(continued), "error");
            return { action: "handled" as const };
          }
          enqueue(contextByPrompt, text, continued.context.text);
          enqueueReplay(continued.replay_prompt);
          await pi.sendUserMessage(continued.replay_prompt);
          return { action: "handled" as const };
        }
        if (disposition.kind === "unavailable") {
          const message = "New wiki proposals are not available yet because no proposal workflow exists. No wiki was created, and the request was not sent.";
          ctx.ui.notify(message, "warning");
          return { action: "handled" as const };
        }
        if (disposition.kind === "no-context") {
          const continued = await runCoordinator([
            "continue-no-context",
            "--harness", process.env.FM_PI_HARNESS === "pi-signed" ? "pi-signed" : "pi",
            "--session-id", sessionId(ctx),
            "--selection-id", selection,
            "--include-replay",
          ]);
          const replay = continued.replay_prompt;
          if (continued.decision !== "proceed-no-context" || !replay) {
            ctx.ui.notify(failureText(continued), "error");
            return { action: "handled" as const };
          }
          enqueueReplay(replay);
          await pi.sendUserMessage(replay);
          return { action: "handled" as const };
        }
        const continued = await runCoordinator(
          ["continue", "--harness", harnessName(), "--session-id", sessionId(ctx), "--selection-id", selection, "--offer", disposition.wiki],
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
      default: {
        if (!(await coordinatorGoverns())) return { action: "continue" as const };
        ctx.ui.notify(failureText(result), "error");
        return { action: "handled" as const };
      }
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
