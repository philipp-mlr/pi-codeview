export type CurrentTool = { tool?: string; target?: string };

const TARGET_COMMAND_CHARS = 60;

/** The tools the agent has started and not yet ended. Never persisted. */
export class ActivityLog {
  /** Tools started and not yet ended, oldest first. */
  private running: { id: string; tool: string; target: string }[] = [];

  startTool(id: string, tool: string, target: string): void {
    this.running.push({ id, tool, target });
  }

  endTool(id: string): void {
    this.running = this.running.filter((r) => r.id !== id);
  }

  clearTools(): void {
    this.running = [];
  }

  /** Tools still running other than `id`, oldest first. */
  runningExcept(id: string | undefined): { id: string; tool: string }[] {
    return this.running.filter((r) => r.id !== id);
  }

  /** The most recently started tool still running, null when none. */
  current(): CurrentTool | null {
    const last = this.running.at(-1);
    if (!last) return null;
    return last.target === "" ? { tool: last.tool } : { tool: last.tool, target: last.target };
  }
}

function collapse(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

/** `path` argument if present, else the first 60 chars of the whitespace-collapsed `command`, else empty. */
export function toolLine(toolName: string, args: unknown): { tool: string; target: string } {
  const a = (args && typeof args === "object" ? args : {}) as { path?: unknown; command?: unknown };
  if (typeof a.path === "string" && a.path !== "") return { tool: toolName, target: a.path };
  if (typeof a.command === "string") return { tool: toolName, target: collapse(a.command).slice(0, TARGET_COMMAND_CHARS) };
  return { tool: toolName, target: "" };
}
