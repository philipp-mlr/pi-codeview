export type ActivityKind = "prompt" | "text" | "tool" | "checkpoint" | "settled";
export type ActivityItem = { seq: number; kind: ActivityKind; text: string; tool?: string; target?: string; at: number };
export type CurrentTool = { tool?: string; target?: string };

const EXCERPT_CHARS = 300;
const TARGET_COMMAND_CHARS = 60;

/** In-memory ring of what the agent did, newest last. Never persisted. */
export class ActivityLog {
  private items: ActivityItem[] = [];
  private seq = 0;
  /** Tools started and not yet ended, oldest first. */
  private running: { id: string; tool: string; target: string }[] = [];

  constructor(private readonly cap = 200) {}

  add(item: Omit<ActivityItem, "seq" | "at">): ActivityItem {
    const added: ActivityItem = { ...item, seq: ++this.seq, at: Date.now() };
    this.items.push(added);
    if (this.items.length > this.cap) this.items.splice(0, this.items.length - this.cap);
    return added;
  }

  since(seq = 0): ActivityItem[] {
    return this.items.filter((i) => i.seq > seq);
  }

  lastSeq(): number {
    return this.seq;
  }

  startTool(id: string, tool: string, target: string): void {
    this.running.push({ id, tool, target });
  }

  endTool(id: string): void {
    this.running = this.running.filter((r) => r.id !== id);
  }

  clearTools(): void {
    this.running = [];
  }

  /** The most recently started tool still running, null when none. */
  current(): CurrentTool | null {
    const last = this.running.at(-1);
    if (!last) return null;
    return last.target === "" ? { tool: last.tool } : { tool: last.tool, target: last.target };
  }
}

/** First 300 chars of the message's text blocks, whitespace-collapsed; null when there is no text. */
export function excerpt(message: { content?: unknown }): string | null {
  const content = message.content;
  const parts: string[] = [];
  if (typeof content === "string") parts.push(content);
  else if (Array.isArray(content)) {
    for (const block of content as { type?: string; text?: unknown }[]) {
      if (block?.type === "text" && typeof block.text === "string") parts.push(block.text);
    }
  }
  const text = parts.join(" ").replace(/\s+/g, " ").trim();
  if (text === "") return null;
  return text.length > EXCERPT_CHARS ? text.slice(0, EXCERPT_CHARS) + "…" : text;
}

/** `path` argument if present, else the first 60 chars of `command`, else empty. */
export function toolLine(toolName: string, args: unknown): { tool: string; target: string } {
  const a = (args && typeof args === "object" ? args : {}) as { path?: unknown; command?: unknown };
  if (typeof a.path === "string" && a.path !== "") return { tool: toolName, target: a.path };
  if (typeof a.command === "string") return { tool: toolName, target: a.command.slice(0, TARGET_COMMAND_CHARS) };
  return { tool: toolName, target: "" };
}
