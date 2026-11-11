import * as fs from "node:fs";
import * as net from "node:net";
import * as path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { ActivityLog, excerpt, shorten, toolLine } from "./activity.ts";
import { diffText, numstat, parseMode, pruneRefs, readConfig, repoHash, showFile, snapshot, writeMode } from "./git.ts";
import type { Mode } from "./git.ts";
import { LineDecoder, PROTOCOL_VERSION, encode } from "./protocol.ts";
import type { EventName, PromptContext, Request } from "./protocol.ts";
import { humanChangedSteer, renderAnnotationPrompt, renderPrompt, renderResume, renderReview } from "./render.ts";
import { socketPath, startServer } from "./server.ts";
import type { Server } from "./server.ts";
import { CodeviewState } from "./state.ts";
import type { Annotation, Author, Chunk, Serialized } from "./state.ts";

export const STATE_ENTRY = "pi-codeview-state";
export const STATUS_KEY = "codeview";
export const CHECKPOINT_TOOL = "checkpoint";
export const REVIEW_PENDING = "Review pending. Philipp will send it later.";
export const END_OF_RUN_NOTE = "end of run, no checkpoint";
export const SEND_REFUSED = "open at least one file of the chunk or add a note";
export const ONE_REVIEW_SESSION =
  "another pi session is in review mode for this worktree (one review-mode session per worktree)";

const READ_ONLY_TOOLS = new Set([
  "read",
  CHECKPOINT_TOOL,
  "module_report",
  "read_symbol",
  "read_enclosing",
  "symbol_search",
  "project_report",
  "effective_config",
  "ask_user_question",
  "todo",
]);

/** Tools that cannot change files. Every other tool counts as possibly mutating. */
export function isReadOnlyTool(name: string): boolean {
  return READ_ONLY_TOOLS.has(name) || name.startsWith("lens_");
}

/** What is stored in each `pi-codeview-state` entry: the state plus the next snapshot ref number. */
export type PersistedState = Serialized & { snapshotSeq: number };

export type SendInput = { annotations: Annotation[]; note: string; viewed: boolean };

type Waiter = { n: number; resolve(text: string): void };

function lastPersisted(ctx: ExtensionContext): PersistedState | undefined {
  const entries = ctx.sessionManager.getEntries() as { type: string; customType?: string; data?: unknown }[];
  const last = entries.filter((e) => e.type === "custom" && e.customType === STATE_ENTRY).at(-1);
  return last?.data as PersistedState | undefined;
}

function unique(items: string[]): string[] {
  return [...new Set(items)];
}

/** Asks a socket for its `status`; null when it is dead, refuses, or does not answer in time. */
function probeStatus(sockPath: string): Promise<{ root?: string; mode?: string } | null> {
  return new Promise((resolve) => {
    const sock = net.connect(sockPath);
    const decoder = new LineDecoder();
    let done = false;
    const finish = (value: { root?: string; mode?: string } | null) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      sock.destroy();
      resolve(value);
    };
    const timer = setTimeout(() => finish(null), 1000);
    sock.setEncoding("utf8");
    sock.on("connect", () => sock.write(encode({ id: 1, type: "hello", version: PROTOCOL_VERSION })));
    sock.on("error", () => finish(null));
    sock.on("data", (data: string) => {
      for (const line of decoder.pushLines(data)) {
        let msg: { id?: number; ok?: boolean; result?: unknown };
        try {
          msg = JSON.parse(line);
        } catch {
          continue;
        }
        if (msg.id === 1 && !msg.ok) finish(null);
        else if (msg.id === 1) sock.write(encode({ id: 2, type: "status" }));
        else if (msg.id === 2) finish(msg.ok ? (msg.result as { root?: string; mode?: string }) : null);
      }
    });
  });
}

/** The review loop for one pi session in one git worktree. */
export class ReviewLoop {
  readonly state: CodeviewState;
  private readonly activity = new ActivityLog();
  private snapshotSeq: number;
  /** Every checkpoint call waiting for the open chunk's review; parallel calls share one review. */
  private waiters: Waiter[] = [];
  private server: Server | null = null;
  private lock: Promise<unknown> = Promise.resolve();
  /** Whether a mutating tool ran or a human_write arrived since the last vibe turn_end snapshot. */
  private mayHaveChanged = false;
  /** `state.baseline` when the current or last agent run started (vibe-mode mark base); in memory only. */
  private runBaseline: string | null = null;

  private constructor(
    private readonly pi: ExtensionAPI,
    private readonly ctx: ExtensionContext,
    readonly root: string,
    readonly sessionId: string,
    readonly sockPath: string,
    private readonly cap: number,
    saved: PersistedState | undefined,
  ) {
    this.state = new CodeviewState(saved);
    this.snapshotSeq = saved?.snapshotSeq ?? 0;
  }

  static async start(pi: ExtensionAPI, ctx: ExtensionContext, root: string): Promise<ReviewLoop> {
    const config = await readConfig(root);
    await pruneRefs(root, config.retentionDays);
    const sessionId = ctx.sessionManager.getSessionId();
    const sockPath = socketPath(await repoHash(root), sessionId, process.env.XDG_RUNTIME_DIR);
    const saved = lastPersisted(ctx);
    const loop = new ReviewLoop(pi, ctx, root, sessionId, sockPath, config.cap, saved);
    loop.state.mode = config.mode;
    if (config.mode === "review" && (await loop.otherReviewSession())) {
      loop.state.mode = "vibe";
      loop.notify(`codeview: staying in vibe mode, ${ONE_REVIEW_SESSION}`, "warning");
    }
    // A restored session keeps its chunks and steps; changes made while pi was down land on the agent's side.
    if (saved) await loop.recordSince("agent");
    else loop.state.setBaseline(await loop.snapshot());
    loop.server = await startServer({ path: sockPath, handle: (req) => loop.handle(req) });
    loop.applyTools();
    loop.persist();
    return loop;
  }

  async stop(): Promise<void> {
    this.resolveWaiters(REVIEW_PENDING);
    // Let in-flight work (e.g. a human_write) finish and persist before the runtime goes away.
    await this.lock;
    const server = this.server;
    this.server = null;
    await server?.close();
  }

  // --- agent side ---------------------------------------------------------

  async checkpoint(note: string, signal?: AbortSignal, files?: Array<{ path: string; why: string }>): Promise<string> {
    const chunk = await this.serial(async () => {
      const open = this.state.openChunk();
      if (open) return open;
      const { sha } = await this.recordSince("agent");
      const created = this.state.createChunk(note, sha, "open", files);
      this.persist();
      this.broadcast("chunk_ready", { chunk: created });
      return created;
    });
    return this.waitForReview(chunk.n, signal);
  }

  /** Block reason for a tool call, or undefined when it may run. */
  capBlock(toolName: string): string | undefined {
    if (this.state.mode !== "review" || isReadOnlyTool(toolName)) return undefined;
    if (this.state.agentLines() <= this.cap) return undefined;
    return `Changed lines since the last checkpoint exceed ${this.cap}. Call checkpoint with a note first.`;
  }

  async afterTool(toolName: string): Promise<void> {
    if (isReadOnlyTool(toolName)) return;
    this.mayHaveChanged = true;
    // Vibe mode records at turn_end only, so mutating tools stay cheap.
    if (this.state.mode !== "review") return;
    await this.serial(async () => {
      if ((await this.recordSince("agent")).files.length > 0) this.persist();
    });
  }

  async endOfRun(): Promise<void> {
    if (this.state.mode !== "review") return;
    await this.serial(async () => {
      if (this.state.openChunk()) return;
      const { sha } = await this.recordSince("agent");
      if (!this.state.steps.some((s) => s.author === "agent")) return this.persist();
      const chunk = this.state.createChunk(END_OF_RUN_NOTE, sha);
      this.persist();
      this.broadcast("chunk_ready", { chunk });
    });
  }

  async turnEnd(turnIndex: number): Promise<void> {
    if (this.state.mode !== "vibe" || !this.mayHaveChanged) return;
    this.mayHaveChanged = false;
    await this.serial(async () => {
      const { sha } = await this.recordSince("agent");
      if (this.state.steps.length === 0) return;
      const chunk = this.state.createChunk(`turn ${turnIndex + 1}`, sha, "recorded");
      this.persist();
      this.broadcast("chunk_ready", { chunk });
    });
  }

  activityToolStart(toolCallId: string, toolName: string, args: unknown): void {
    const { tool, target } = toolLine(toolName, args);
    this.activity.startTool(toolCallId, tool, target);
    const note = (args as { note?: unknown } | null)?.note;
    if (toolName === CHECKPOINT_TOOL && typeof note === "string") {
      this.addActivity({ kind: "checkpoint", text: shorten(note) });
    } else {
      this.addActivity({ kind: "tool", text: target === "" ? tool : `${tool} ${target}`, tool, target });
    }
  }

  activityToolEnd(toolCallId: string, toolName: string): void {
    this.activity.endTool(toolCallId);
    this.broadcast("activity_current", { current: this.activity.current(), mutating: !isReadOnlyTool(toolName) });
  }

  /** Pins the vibe-mode mark base: turn chunks move the baseline, the marks stay against the run's start. */
  runStarted(): void {
    this.runBaseline = this.state.baseline;
  }

  /**
   * The snapshot nvim marks changed lines against: the open chunk's start, else in review mode the
   * baseline, in vibe mode the baseline when the current or last run started.
   */
  markBase(): string {
    const open = this.state.openChunk();
    if (open) return open.fromSha;
    if (this.state.mode === "review") return this.state.baseline;
    return this.runBaseline ?? this.state.baseline;
  }

  /** Adds a `text` item for an assistant message or a `prompt` item for a user message; other roles are ignored. */
  activityMessage(message: { role?: string; content?: unknown }): void {
    if (message.role !== "assistant" && message.role !== "user") return;
    const text = excerpt(message);
    if (text !== null) this.addActivity({ kind: message.role === "user" ? "prompt" : "text", text });
  }

  settled(aborted: boolean): void {
    this.activity.clearTools();
    this.addActivity({ kind: "settled", text: aborted ? "aborted" : "settled" });
    this.broadcast("run_settled", { aborted });
  }

  /**
   * Queues a prompt while a chunk is open. Returns false when nothing is open, or when the prompt has
   * images: the queue holds text only, so such a prompt passes through untouched and Philipp is told.
   */
  queueIfOpen(text: string, hasImages = false): boolean {
    const chunk = this.state.openChunk();
    if (!chunk) return false;
    if (hasImages) {
      this.notify(`Prompt with images not queued: review chunk ${chunk.n} first`, "warning");
      return false;
    }
    this.state.queuePrompt(text);
    this.persist();
    this.notify(`Prompt queued until chunk ${chunk.n} is reviewed`, "info");
    return true;
  }

  // --- Philipp's side -----------------------------------------------------

  async send(input: SendInput): Promise<{ chunk: Chunk | null }> {
    return this.serial(async () => {
      const chunk = this.state.openChunk();
      const { sha } = await this.recordSince(chunk ? "human" : "agent");
      const annotations = await this.quote(sha, input.annotations);
      if (!chunk) {
        if (annotations.length === 0 && input.note === "") throw new Error("nothing to send");
        this.pi.sendUserMessage(renderAnnotationPrompt(annotations, input.note || "Address these annotations."), this.delivery());
        this.state.setDrafts([]);
        this.persist();
        return { chunk: null };
      }
      const humanEdits = unique([...chunk.humanFiles, ...this.state.humanFiles()]).length;
      const sendable = { annotations: annotations.length, note: input.note, humanEdits, viewed: input.viewed };
      if (!this.state.canSend(sendable)) throw new Error(SEND_REFUSED);
      const humanDiff = await this.humanDiff(chunk);
      const review = renderReview({ chunk, annotations, note: input.note, humanDiff });
      const reviewNote = input.note === "" ? undefined : input.note;
      const closed = this.state.closeChunk(chunk.n, { status: "reviewed", annotations, reviewNote });
      this.state.advanceAfterReview(sha);
      this.state.setDrafts([]);
      if (this.resolveWaiters(review, closed.n)) {
        this.deliverQueued();
      } else {
        this.pi.sendUserMessage(renderResume(review, this.state.takeQueuedPrompts()), this.delivery());
      }
      this.persist();
      this.broadcast("chunk_reviewed", { chunk: closed });
      return { chunk: closed };
    });
  }

  async continueWith(note: string): Promise<void> {
    if (!note) throw new Error("continue needs a note: /codeview continue <note>");
    if (!this.state.openChunk()) throw new Error("no open chunk");
    await this.send({ annotations: this.state.drafts, note, viewed: true });
  }

  async discard(note: string): Promise<void> {
    if (!note) throw new Error("discard needs a note: /codeview discard <note>");
    await this.serial(async () => {
      const open = this.state.openChunk();
      if (!open) throw new Error("no open chunk");
      const chunk = this.state.closeChunk(open.n, { status: "discarded", annotations: [], reviewNote: note });
      this.resolveWaiters(`Philipp discarded chunk ${chunk.n}. His note:\n${note}`, chunk.n);
      this.deliverQueued();
      this.persist();
      this.broadcast("chunk_reviewed", { chunk });
    });
  }

  async humanWrite(file: string): Promise<{ files: string[] }> {
    this.mayHaveChanged = true;
    return this.serial(async () => {
      const { files } = await this.recordSince("human");
      if (files.length > 0) this.persist();
      if (this.state.agentFiles().includes(file)) {
        this.pi.sendMessage(
          { customType: "pi-codeview", content: humanChangedSteer(file), display: true },
          { deliverAs: "steer" },
        );
      }
      return { files };
    });
  }

  prompt(text: string, context?: PromptContext): { queued: boolean } {
    if (this.queueIfOpen(text)) return { queued: true };
    this.pi.sendUserMessage(renderPrompt(text, context), this.delivery());
    return { queued: false };
  }

  async setMode(mode: Mode): Promise<void> {
    const open = this.state.openChunk();
    if (mode === "vibe" && open) {
      throw new Error(`chunk ${open.n} is open — send a review or /codeview discard <note> first`);
    }
    if (mode === "review" && (await this.otherReviewSession())) throw new Error(ONE_REVIEW_SESSION);
    await writeMode(this.root, mode);
    await this.serial(async () => {
      if (mode === "review" && this.state.mode !== "review" && !this.state.openChunk()) {
        this.state.setBaseline(await this.snapshot());
      }
      if (this.state.mode !== mode) this.runBaseline = null;
      this.state.mode = mode;
      this.applyTools();
      this.persist();
      this.broadcast("mode_changed", { mode });
    });
  }

  describe(): string {
    const open = this.state.openChunk();
    const chunk = open ? `chunk ${open.n} open ("${open.note}")` : "no open chunk";
    return `codeview: mode ${this.state.mode}, ${chunk}, socket ${this.sockPath}`;
  }

  // --- socket requests ----------------------------------------------------

  async handle(req: Request): Promise<unknown> {
    switch (req.type) {
      case "status":
        return {
          mode: this.state.mode,
          root: this.root,
          sessionId: this.sessionId,
          name: this.ctx.sessionManager.getSessionName?.() ?? null,
          baseline: this.state.baseline,
          markBase: this.markBase(),
          openChunk: this.state.openChunk() ?? null,
          drafts: this.state.drafts,
          busy: !this.ctx.isIdle(),
          queued: this.state.queuedPrompts.length,
          activity: this.activity.current(),
          activitySeq: this.activity.lastSeq(),
        };
      case "get_activity":
        return this.activity.since(req.since);
      case "list_chunks":
        return this.state.chunks;
      case "get_chunk": {
        const chunk = this.state.chunks.find((c) => c.n === req.n);
        if (!chunk) throw new Error(`no chunk ${req.n}`);
        return { chunk, diff: await diffText(this.root, chunk.fromSha, chunk.toSha) };
      }
      case "prompt":
        return this.prompt(req.text, req.context);
      case "send":
        return this.send({ annotations: req.annotations ?? [], note: req.note ?? "", viewed: req.viewed === true });
      case "save_drafts":
        this.state.setDrafts(req.annotations ?? []);
        this.persist();
        return { saved: this.state.drafts.length };
      case "human_write":
        return this.humanWrite(req.path);
      case "set_mode": {
        const mode = parseMode(req.mode);
        if (!mode) throw new Error(`unknown mode "${req.mode}": use review or vibe (on/off)`);
        await this.setMode(mode);
        return { mode: this.state.mode };
      }
      default:
        throw new Error(`unknown request ${(req as { type?: string }).type}`);
    }
  }

  // --- internals ----------------------------------------------------------

  /** Runs snapshot-and-record work one at a time so steps stay in order. */
  private serial<T>(fn: () => Promise<T>): Promise<T> {
    const run = this.lock.then(fn, fn);
    this.lock = run.catch(() => undefined);
    return run;
  }

  private snapshot(): Promise<string> {
    const ref = `refs/pi-codeview/${this.sessionId}/${this.snapshotSeq++}`;
    return snapshot(this.root, ref, "pi-codeview snapshot");
  }

  /**
   * Snapshots and records a step for `author` when files changed since the last recorded snapshot.
   * An unchanged snapshot gives its ref number back and returns the previous sha, so every kept ref
   * number is covered by a persisted state and a restored session never reuses one.
   */
  private async recordSince(author: Author): Promise<{ sha: string; files: string[] }> {
    const previous = this.state.steps.at(-1)?.sha ?? this.state.baseline;
    const sha = await this.snapshot();
    const changed = await numstat(this.root, previous, sha);
    if (changed.length === 0) {
      this.snapshotSeq--;
      return { sha: previous, files: [] };
    }
    const files = changed.map((c) => c.path);
    this.state.recordStep({ from: previous, sha, author, files, lines: changed.reduce((sum, c) => sum + c.lines, 0) });
    return { sha, files };
  }

  /** Philipp's edits inside the chunk plus those made since it was opened, step by step so the agent's hunks stay out. */
  private async humanDiff(chunk: Chunk): Promise<string> {
    const steps = [...chunk.humanSteps, ...this.state.humanSteps()];
    const parts = await Promise.all(steps.map((s) => diffText(this.root, s.from, s.sha, s.files)));
    return parts.join("");
  }

  private async quote(sha: string, annotations: Annotation[]): Promise<Annotation[]> {
    return Promise.all(
      annotations.map(async (a) => {
        const text = await showFile(this.root, sha, a.path);
        if (text === null) return { ...a };
        return { ...a, quote: text.split("\n").slice(a.startLine - 1, a.endLine).join("\n") };
      }),
    );
  }

  private waitForReview(n: number, signal?: AbortSignal): Promise<string> {
    return new Promise((resolve) => {
      if (signal?.aborted) return resolve(REVIEW_PENDING);
      const waiter: Waiter = {
        n,
        resolve: (text) => {
          signal?.removeEventListener("abort", onAbort);
          resolve(text);
        },
      };
      const onAbort = () => {
        this.waiters = this.waiters.filter((w) => w !== waiter);
        resolve(REVIEW_PENDING);
      };
      signal?.addEventListener("abort", onAbort, { once: true });
      this.waiters.push(waiter);
    });
  }

  /** Resolves the waiters for chunk `n` (all waiters when `n` is omitted). Returns whether any were waiting. */
  private resolveWaiters(text: string, n?: number): boolean {
    const matched = this.waiters.filter((w) => n === undefined || w.n === n);
    this.waiters = this.waiters.filter((w) => !matched.includes(w));
    for (const w of matched) w.resolve(text);
    return matched.length > 0;
  }

  private deliverQueued(): void {
    const queued = this.state.takeQueuedPrompts();
    if (queued.length > 0) this.pi.sendUserMessage(queued.join("\n\n"), this.delivery());
  }

  private delivery(): { deliverAs: "followUp" } | undefined {
    return this.ctx.isIdle() ? undefined : { deliverAs: "followUp" };
  }

  private async otherReviewSession(): Promise<boolean> {
    const dir = path.dirname(this.sockPath);
    const others = fs.existsSync(dir)
      ? fs.readdirSync(dir).filter((f) => f.endsWith(".sock") && path.join(dir, f) !== this.sockPath)
      : [];
    for (const file of others) {
      const status = await probeStatus(path.join(dir, file));
      if (status?.root === this.root && status.mode === "review") return true;
    }
    return false;
  }

  private applyTools(): void {
    const others = this.pi.getActiveTools().filter((t) => t !== CHECKPOINT_TOOL);
    this.pi.setActiveTools(this.state.mode === "review" ? [...others, CHECKPOINT_TOOL] : others);
  }

  private persist(): void {
    const data: PersistedState = { ...this.state.serialize(), snapshotSeq: this.snapshotSeq };
    this.pi.appendEntry(STATE_ENTRY, data);
    const open = this.state.openChunk();
    const status = open
      ? `codeview: chunk ${open.n} waiting for review`
      : this.state.mode === "review"
        ? "codeview: review"
        : undefined;
    if (this.ctx.hasUI) this.ctx.ui.setStatus(STATUS_KEY, status);
  }

  private addActivity(item: Parameters<ActivityLog["add"]>[0]): void {
    const added = this.activity.add(item);
    this.broadcast("activity", { ...added, current: this.activity.current() });
  }

  private broadcast(event: EventName, data: unknown): void {
    this.server?.broadcast({ event, data });
  }

  private notify(message: string, level: "info" | "warning" | "error"): void {
    if (this.ctx.hasUI) this.ctx.ui.notify(message, level);
  }
}
