import type { Mode } from "./git.ts";

export type { Mode } from "./git.ts";

const WHY_MAX_CHARS = 200;

export type Author = "agent" | "human";
/**
 * One recorded change: `from` is the snapshot it starts at, `sha` the one it ends at.
 * `reported` marks human steps whose diff already reached the agent in a review.
 */
export type Step = { from: string; sha: string; author: Author; files: string[]; lines: number; reported?: boolean };
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
  /** Philipp's steps inside the chunk, so his diff can be shown without the agent's hunks. */
  humanSteps: Step[];
  annotations: Annotation[];
  reviewNote?: string;
  /** One short line per changed file, keyed by repo-relative path (agent-supplied at checkpoint). */
  why?: Record<string, string>;
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
    this.chunks = data.chunks.map((c) => ({ ...c, humanSteps: c.humanSteps ?? [] }));
    // Steps persisted before `from` existed start where the previous one ended.
    this.steps = data.steps.map((s, i) => ({ ...s, from: s.from ?? data.steps[i - 1]?.sha ?? data.baseline }));
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

  /** Philipp's steps not yet reported to the agent. */
  humanSteps(): Step[] {
    return this.steps.filter((s) => s.author === "human" && !s.reported);
  }

  /**
   * After a review: the steps recorded while the chunk was open move into the next chunk when the
   * agent changed files meanwhile (a parallel tool call), with Philipp's steps marked as reported.
   * Otherwise everything up to `sha` becomes the new baseline.
   */
  advanceAfterReview(sha: string): void {
    if (!this.steps.some((s) => s.author === "agent")) return this.setBaseline(sha);
    for (const s of this.steps) if (s.author === "human") s.reported = true;
  }

  openChunk(): Chunk | undefined {
    return this.chunks.find((c) => c.status === "open");
  }

  createChunk(
    note: string,
    toSha: string,
    status: "open" | "recorded" = "open",
    files: Array<{ path: string; why: string }> = [],
  ): Chunk {
    if (status === "open" && this.openChunk()) throw new Error("chunk already open");
    const chunk: Chunk = {
      n: this.chunks.length + 1,
      note,
      status,
      fromSha: this.baseline,
      toSha,
      agentFiles: this.agentFiles(),
      humanFiles: this.humanFiles(),
      humanSteps: this.humanSteps(),
      annotations: [],
    };
    const known = new Set([...chunk.agentFiles, ...chunk.humanFiles]);
    const why: Record<string, string> = {};
    for (const f of files) {
      const path = f.path.replace(/^\.\//, "");
      if (known.has(path)) why[path] = f.why.slice(0, WHY_MAX_CHARS);
    }
    if (Object.keys(why).length > 0) chunk.why = why;
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
    const steps = author === "human" ? this.humanSteps() : this.steps.filter((s) => s.author === author);
    return [...new Set(steps.flatMap((s) => s.files))];
  }
}
