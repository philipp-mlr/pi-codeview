import type { Annotation, Diagnostic } from "./state.ts";

export const PROTOCOL_VERSION = 2;

// text: the selected text from Philipp's buffer; unsaved: the buffer differs from the file on disk.
export type PromptContext = {
  path: string;
  startLine?: number;
  endLine?: number;
  text?: string;
  unsaved?: boolean;
  diagnostics?: Diagnostic[];
};

export type Request =
  | { id: number; type: "hello"; version: number }
  | { id: number; type: "status" }
  | { id: number; type: "list_chunks" }
  | { id: number; type: "get_chunk"; n: number }
  | { id: number; type: "prompt"; text: string; context?: PromptContext }
  | { id: number; type: "send"; annotations: Annotation[]; note: string; viewed: boolean }
  | { id: number; type: "save_drafts"; annotations: Annotation[] }
  | { id: number; type: "human_write"; path: string }
  | { id: number; type: "cancel" }
  // "checkpoints" | "off", or the aliases "on" | "review" | "vibe"; validated by the server.
  | { id: number; type: "set_mode"; mode: string };

export type RequestType = Request["type"];

export type Response =
  | { id: number | null; ok: true; result: unknown }
  | { id: number | null; ok: false; error: string };

export type EventName = "chunk_ready" | "chunk_reviewed" | "mode_changed" | "run_settled" | "activity_current" | "outside_worktree";
export type Event = { event: EventName; data: unknown };

/** Serialises one message as an NDJSON line. */
export function encode(msg: object): string {
  return JSON.stringify(msg) + "\n";
}

/** Buffers partial input into complete lines and JSON-parses them. */
export class LineDecoder {
  private buffer = "";

  /** Returns complete non-empty raw lines, keeping any partial tail buffered. */
  pushLines(chunk: string): string[] {
    this.buffer += chunk;
    const lines = this.buffer.split("\n");
    this.buffer = lines.pop() ?? "";
    return lines.filter((l) => l.trim() !== "");
  }

  /** Parsed JSON of each complete line. Throws SyntaxError on a bad line. */
  push(chunk: string): unknown[] {
    return this.pushLines(chunk).map((l) => JSON.parse(l));
  }
}
