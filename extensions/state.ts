import type { Mode } from "./git.ts";

export type { Mode } from "./git.ts";

export type Author = "agent" | "human";
export type Step = { sha: string; author: Author; files: string[]; lines: number };
export type Annotation = { path: string; startLine: number; endLine: number; note: string; quote?: string };
export type ChunkStatus = "open" | "reviewed" | "discarded" | "recorded";
export type Chunk = {
  n: number;
  note: string;
  status: ChunkStatus;
  fromSha: string;
  toSha: string;
  agentFiles: string[];
  humanFiles: string[];
  annotations: Annotation[];
  reviewNote?: string;
};

export type Serialized = {
  mode: Mode;
  baseline: string;
  chunks: Chunk[];
  steps: Step[];
  drafts: Annotation[];
  queuedPrompts: string[];
};

export class CodeviewState {
  mode: Mode;
  baseline: string;
  chunks: Chunk[];
  steps: Step[];
  drafts: Annotation[];
  queuedPrompts: string[];

  constructor(init?: Serialized) {
    const data: Serialized = structuredClone(
      init ?? { mode: "vibe", baseline: "", chunks: [], steps: [], drafts: [], queuedPrompts: [] },
    );
    this.mode = data.mode;
    this.baseline = data.baseline;
    this.chunks = data.chunks;
    this.steps = data.steps;
    this.drafts = data.drafts;
    this.queuedPrompts = data.queuedPrompts;
  }

  serialize(): Serialized {
    return structuredClone({
      mode: this.mode,
      baseline: this.baseline,
      chunks: this.chunks,
      steps: this.steps,
      drafts: this.drafts,
      queuedPrompts: this.queuedPrompts,
    });
  }

  setBaseline(sha: string): void {
    this.baseline = sha;
    this.steps = [];
  }

  recordStep(step: Step): void {
    this.steps.push(step);
  }

  agentLines(): number {
    return this.steps.reduce((sum, s) => (s.author === "agent" ? sum + s.lines : sum), 0);
  }

  agentFiles(): string[] {
    return this.filesBy("agent");
  }

  humanFiles(): string[] {
    return this.filesBy("human");
  }

  openChunk(): Chunk | undefined {
    return this.chunks.find((c) => c.status === "open");
  }

  createChunk(note: string, toSha: string, status: "open" | "recorded" = "open"): Chunk {
    if (status === "open" && this.openChunk()) throw new Error("chunk already open");
    const chunk: Chunk = {
      n: this.chunks.length + 1,
      note,
      status,
      fromSha: this.baseline,
      toSha,
      agentFiles: this.agentFiles(),
      humanFiles: this.humanFiles(),
      annotations: [],
    };
    this.chunks.push(chunk);
    this.setBaseline(toSha);
    return chunk;
  }

  closeChunk(
    n: number,
    outcome: { status: "reviewed" | "discarded"; annotations: Annotation[]; reviewNote?: string },
  ): Chunk {
    const chunk = this.chunks.find((c) => c.n === n && c.status === "open");
    if (!chunk) throw new Error(`no open chunk ${n}`);
    chunk.status = outcome.status;
    chunk.annotations = outcome.annotations;
    if (outcome.reviewNote !== undefined) chunk.reviewNote = outcome.reviewNote;
    return chunk;
  }

  canSend(input: { annotations: number; note: string; humanEdits: number; viewed: boolean }): boolean {
    return input.annotations > 0 || input.humanEdits > 0 || input.note.length > 0 || input.viewed;
  }

  queuePrompt(text: string): void {
    this.queuedPrompts.push(text);
  }

  takeQueuedPrompts(): string[] {
    const taken = this.queuedPrompts;
    this.queuedPrompts = [];
    return taken;
  }

  setDrafts(a: Annotation[]): void {
    this.drafts = a;
  }

  private filesBy(author: Step["author"]): string[] {
    return [...new Set(this.steps.filter((s) => s.author === author).flatMap((s) => s.files))];
  }
}
