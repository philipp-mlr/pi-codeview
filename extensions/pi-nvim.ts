import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { findRoot } from "./git.ts";
import { CHECKPOINT_TOOL, ReviewLoop, STATUS_KEY } from "./loop.ts";
import { CHECKPOINT_GUIDELINES } from "./render.ts";

export { isReadOnlyTool } from "./loop.ts";

const NOT_A_REPO = "pi: inactive, not a git repository";

function errorText(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

export default function piNvim(pi: ExtensionAPI): void {
  let loop: ReviewLoop | null = null;

  pi.registerTool({
    name: CHECKPOINT_TOOL,
    label: "Checkpoint",
    description: "Hand the changes since the last checkpoint to Philipp for review and wait for his review.",
    promptSnippet: "Submit the current step for Philipp's review and wait for it",
    promptGuidelines: CHECKPOINT_GUIDELINES,
    parameters: Type.Object({
      note: Type.String({ description: "What was done in this step and why" }),
      files: Type.Optional(
        Type.Array(Type.Object({ path: Type.String(), why: Type.String() }), {
          description: "One entry per changed file: repo-relative path and one short line on why it changed.",
        }),
      ),
    }),
    defaultActive: false,
    // A parallel sibling edit could land after the chunk snapshot and be hidden from review.
    executionMode: "sequential",
    async execute(_id, params, signal) {
      if (!loop) throw new Error(NOT_A_REPO);
      const text = await loop.checkpoint(params.note, signal, params.files);
      return { content: [{ type: "text", text }], details: undefined };
    },
  });

  pi.registerCommand("checkpoints", {
    description: "pi: checkpoint mode — show state, on|off, continue <note>, discard <note>",
    handler: async (args, ctx) => {
      const [sub = "", ...rest] = args.trim().split(/\s+/);
      const note = rest.join(" ").trim();
      if (!loop) return void ctx.ui.notify(NOT_A_REPO, "warning");
      try {
        if (sub === "") ctx.ui.notify(loop.describe(), "info");
        else if (sub === "on" || sub === "off") await loop.setMode(sub === "on" ? "checkpoints" : "off");
        else if (sub === "continue") await loop.continueWith(note);
        else if (sub === "discard") await loop.discard(note);
        else ctx.ui.notify(`pi: unknown subcommand ${sub}`, "error");
      } catch (e) {
        ctx.ui.notify(`pi: ${errorText(e)}`, "error");
      }
    },
  });

  pi.on("session_start", async (_event, ctx: ExtensionContext) => {
    await loop?.stop();
    loop = null;
    const root = await findRoot(ctx.cwd);
    if (!root) {
      if (ctx.hasUI) ctx.ui.setStatus(STATUS_KEY, undefined);
      return;
    }
    loop = await ReviewLoop.start(pi, ctx, root);
  });

  pi.on("session_shutdown", async () => {
    await loop?.stop();
    loop = null;
  });

  pi.on("tool_call", (event) => {
    const reason = loop?.capBlock(event.toolName);
    return reason ? { block: true, reason } : undefined;
  });

  pi.on("tool_result", async (event) => {
    await loop?.afterTool(event.toolName);
  });

  pi.on("tool_execution_start", (event) => {
    loop?.activityToolStart(event.toolCallId, event.toolName, event.args);
  });

  pi.on("tool_execution_end", (event) => {
    loop?.activityToolEnd(event.toolCallId, event.toolName);
  });

  pi.on("agent_start", () => {
    loop?.runStarted();
  });

  pi.on("turn_end", async (event) => {
    await loop?.turnEnd(event.turnIndex);
  });

  pi.on("agent_before_settle", async () => {
    await loop?.endOfRun();
  });

  pi.on("agent_settled", async (event) => {
    // An aborted run skips agent_before_settle; its changes still become a chunk.
    if (event.aborted) await loop?.endOfRun();
    loop?.settled(event.aborted);
  });

  pi.on("input", (event) => {
    if (event.source === "extension") return undefined;
    if (!loop?.queueIfOpen(event.text, (event.images?.length ?? 0) > 0)) return undefined;
    return { action: "handled" };
  });
}
