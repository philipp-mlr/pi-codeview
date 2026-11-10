import { afterEach, beforeEach, describe, expect, it } from "vitest";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import codeview, { isReadOnlyTool } from "../extensions/codeview.ts";
import { repoHash } from "../extensions/git.ts";
import { LineDecoder, encode } from "../extensions/protocol.ts";
import { renderResume, humanChangedSteer } from "../extensions/render.ts";
import { socketPath } from "../extensions/server.ts";
import { makeFakePi, type FakeEntry, type FakePi } from "./helpers/fake-pi.ts";
import { makeRepo, type TestRepo } from "./helpers/repo.ts";

type Client = {
  request(type: string, payload?: object): Promise<{ ok: boolean; result?: any; error?: string }>;
  events: { event: string; data: any }[];
  close(): void;
};

let runtimeDir: string;
const cleanups: Array<() => Promise<void> | void> = [];

beforeEach(() => {
  runtimeDir = fs.mkdtempSync(path.join(os.tmpdir(), "cv-"));
  process.env.XDG_RUNTIME_DIR = runtimeDir;
});

afterEach(async () => {
  for (const c of cleanups.splice(0).reverse()) await c();
  delete process.env.XDG_RUNTIME_DIR;
  fs.rmSync(runtimeDir, { recursive: true, force: true });
});

async function start(
  repo: TestRepo | string,
  opts: { mode?: "review" | "vibe"; sessionId?: string; entries?: FakeEntry[] } = {},
): Promise<FakePi> {
  const cwd = typeof repo === "string" ? repo : repo.root;
  if (opts.mode && typeof repo !== "string") await repo.git("config", "pi-codeview.mode", opts.mode);
  const fake = makeFakePi(cwd, { sessionId: opts.sessionId, entries: opts.entries });
  codeview(fake.pi);
  await fake.fire("session_start", { reason: "startup" });
  cleanups.push(() => fake.fire("session_shutdown", { reason: "quit" }).then(() => {}));
  return fake;
}

async function connect(repo: TestRepo, sessionId = "test-session"): Promise<Client> {
  const sock = net.connect(socketPath(await repoHash(repo.root), sessionId));
  await new Promise<void>((res, rej) => {
    sock.once("connect", res);
    sock.once("error", rej);
  });
  const decoder = new LineDecoder();
  const pending = new Map<number, (m: any) => void>();
  const events: { event: string; data: any }[] = [];
  let nextId = 1;
  sock.setEncoding("utf8");
  sock.on("data", (data: string) => {
    for (const m of decoder.push(data) as any[]) {
      if (m.event) events.push(m);
      else pending.get(m.id)?.(m);
    }
  });
  const client: Client = {
    events,
    request(type, payload = {}) {
      const id = nextId++;
      return new Promise((res) => {
        pending.set(id, res);
        sock.write(encode({ id, type, ...payload }));
      });
    },
    close: () => sock.destroy(),
  };
  cleanups.push(() => client.close());
  const hello = await client.request("hello", { version: 1 });
  expect(hello.ok).toBe(true);
  return client;
}

async function until<T>(fn: () => Promise<T | undefined | null | false> | T | undefined | null | false): Promise<T> {
  for (let i = 0; i < 200; i++) {
    const v = await fn();
    if (v) return v;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error("timed out");
}

async function settled<T>(p: Promise<T>, ms = 100): Promise<boolean> {
  let done = false;
  void p.then(() => (done = true));
  await new Promise((r) => setTimeout(r, ms));
  return done;
}

function lines(n: number, prefix = "line"): string {
  return Array.from({ length: n }, (_, i) => `${prefix} ${i}`).join("\n") + "\n";
}

async function agentWrite(fake: FakePi, repo: TestRepo, file: string, text: string): Promise<void> {
  repo.write(file, text);
  await fake.fire("tool_result", { toolName: "write", input: { path: file }, content: [], isError: false });
}

function text(result: any): string {
  return result.content.map((c: { text: string }) => c.text).join("");
}

describe("isReadOnlyTool", () => {
  it("treats read-only tools as read-only and everything else as mutating", () => {
    for (const name of ["read", "checkpoint", "lens_diagnostics", "module_report", "read_symbol", "read_enclosing",
      "symbol_search", "project_report", "effective_config", "ask_user_question", "todo"]) {
      expect(isReadOnlyTool(name)).toBe(true);
    }
    for (const name of ["write", "edit", "bash", "some_custom_tool"]) expect(isReadOnlyTool(name)).toBe(false);
  });
});

describe("codeview extension", () => {
  it("inactive outside a git repo", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cv-nogit-"));
    cleanups.push(() => fs.rmSync(dir, { recursive: true, force: true }));
    const fake = await start(dir);
    expect(fs.existsSync(path.join(runtimeDir, "pi-codeview"))).toBe(false);
    expect(fake.entries).toEqual([]);
    expect(await fake.fire("tool_call", { toolName: "write", input: {} })).toEqual([undefined]);
    await fake.runCommand("codeview", "");
    expect(fake.notifications.at(-1)?.message).toContain("not a git repository");
  });

  it("vibe mode: checkpoint tool inactive, turn_end records a chunk", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    expect(fake.pi.getActiveTools()).not.toContain("checkpoint");
    await agentWrite(fake, repo, "a.txt", "a\n");
    await fake.fire("turn_end", { turnIndex: 0 });
    const client = await connect(repo);
    const chunks = (await client.request("list_chunks")).result;
    expect(chunks).toHaveLength(1);
    expect(chunks[0]).toMatchObject({ n: 1, status: "recorded", agentFiles: ["a.txt"] });
    await fake.fire("turn_end", { turnIndex: 1 });
    expect((await client.request("list_chunks")).result).toHaveLength(1);
  });

  it("checkpoint blocks until send, returns the rendered review", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    expect(fake.pi.getActiveTools()).toContain("checkpoint");
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    const pending = fake.callTool("checkpoint", { note: "add a" });
    await until(() => client.events.find((e) => e.event === "chunk_ready"));
    expect(fake.statuses.get("codeview")).toBe("codeview: chunk 1 waiting for review");
    expect(await settled(pending)).toBe(false);
    const status = (await client.request("status")).result;
    expect(status).toMatchObject({ mode: "review", root: repo.root, sessionId: "test-session", queued: 0 });
    expect(status.openChunk).toMatchObject({ n: 1, note: "add a", agentFiles: ["a.txt"] });
    const get = (await client.request("get_chunk", { n: 1 })).result;
    expect(get.chunk.n).toBe(1);
    expect(get.diff).toContain("+a");

    const sent = await client.request("send", { annotations: [], note: "looks fine", viewed: true });
    expect(sent.ok).toBe(true);
    const out = text(await pending);
    expect(out).toContain('Review of chunk 1 ("add a")');
    expect(out).toContain("looks fine");
    expect(fake.statuses.get("codeview")).toBe("codeview: review");
    await until(() => client.events.find((e) => e.event === "chunk_reviewed"));
    expect((await client.request("list_chunks")).result[0].status).toBe("reviewed");
  });

  it("abort while waiting leaves the chunk open and persisted; send later resumes via sendUserMessage with renderResume", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "alpha\n");
    const abort = new AbortController();
    const pending = fake.callTool("checkpoint", { note: "add a" }, abort.signal);
    await until(async () => (await client.request("status")).result.openChunk);
    const drafts = [{ path: "a.txt", startLine: 1, endLine: 1, note: "why alpha?" }];
    expect((await client.request("save_drafts", { annotations: drafts })).ok).toBe(true);
    abort.abort();
    expect(text(await pending)).toBe("Review pending. Philipp will send it later.");
    expect((await client.request("status")).result.openChunk.n).toBe(1);

    await fake.fire("session_shutdown", { reason: "quit" });
    const fake2 = await start(repo, { entries: fake.entries });
    const client2 = await connect(repo);
    const status = (await client2.request("status")).result;
    expect(status.openChunk).toMatchObject({ n: 1, status: "open" });
    expect(status.drafts).toEqual(drafts);

    const res = await client2.request("send", { annotations: status.drafts, note: "", viewed: false });
    expect(res.ok).toBe(true);
    const resume = fake2.sent.find((s) => s.kind === "user");
    expect(resume).toBeDefined();
    const content = String(resume!.kind === "user" && resume!.content);
    expect(content).toContain("Continue the task that was interrupted");
    expect(content).toContain("why alpha?");
    expect(content).toContain("```\nalpha\n```");
    expect((await client2.request("status")).result).toMatchObject({ openChunk: null, drafts: [] });
  });

  it("parallel checkpoint calls share the open chunk and all resolve with the review", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    const first = fake.callTool("checkpoint", { note: "add a" });
    const second = fake.callTool("checkpoint", { note: "add a again" });
    await until(() => client.events.find((e) => e.event === "chunk_ready"));
    expect(await settled(Promise.race([first, second]))).toBe(false);
    expect((await client.request("send", { annotations: [], note: "ok", viewed: true })).ok).toBe(true);
    const [a, b] = await Promise.all([first, second]);
    expect(text(a)).toContain('Review of chunk 1 ("add a")');
    expect(text(b)).toBe(text(a));
    expect(fake.sent.filter((s) => s.kind === "user")).toEqual([]);
    expect(client.events.filter((e) => e.event === "chunk_ready")).toHaveLength(1);
  });

  it("aborting one of two checkpoint calls keeps the other waiting for the review", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    const abort = new AbortController();
    const first = fake.callTool("checkpoint", { note: "add a" }, abort.signal);
    const second = fake.callTool("checkpoint", { note: "add a" });
    await until(() => client.events.find((e) => e.event === "chunk_ready"));
    abort.abort();
    expect(text(await first)).toBe("Review pending. Philipp will send it later.");
    expect(await settled(second)).toBe(false);
    expect((await client.request("send", { annotations: [], note: "ok", viewed: true })).ok).toBe(true);
    expect(text(await second)).toContain('Review of chunk 1 ("add a")');
    expect(fake.sent.filter((s) => s.kind === "user")).toEqual([]);
  });

  it("vibe mode: mutating tools take no snapshots, turn_end records one chunk", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    const refs = async () => (await repo.git("for-each-ref", "refs/pi-codeview/")).split("\n").filter(Boolean).length;
    const entriesBefore = fake.entries.length;
    const refsBefore = await refs();
    await agentWrite(fake, repo, "a.txt", "a\n");
    await agentWrite(fake, repo, "b.txt", "b\n");
    await agentWrite(fake, repo, "c.txt", "c\n");
    expect(fake.entries.length).toBe(entriesBefore);
    expect(await refs()).toBe(refsBefore);
    await fake.fire("turn_end", { turnIndex: 0 });
    expect(fake.entries.length).toBe(entriesBefore + 1);
    expect(await refs()).toBe(refsBefore + 1);
    const client = await connect(repo);
    const chunks = (await client.request("list_chunks")).result;
    expect(chunks).toHaveLength(1);
    expect(chunks[0]).toMatchObject({ n: 1, status: "recorded", agentFiles: ["a.txt", "b.txt", "c.txt"] });
  });

  it("vibe mode: turn_end takes no snapshot when no mutating tool ran and no human_write arrived", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    const refs = async () => (await repo.git("for-each-ref", "refs/pi-codeview/")).split("\n").filter(Boolean).length;
    const refsBefore = await refs();
    repo.write("a.txt", "a\n");
    await fake.fire("tool_result", { toolName: "read", input: {}, content: [], isError: false });
    await fake.fire("turn_end", { turnIndex: 0 });
    expect(await refs()).toBe(refsBefore);
    const client = await connect(repo);
    expect((await client.request("list_chunks")).result).toEqual([]);
    await client.request("human_write", { path: "a.txt" });
    await fake.fire("turn_end", { turnIndex: 1 });
    expect((await client.request("list_chunks")).result).toHaveLength(1);
    const after = await refs();
    await fake.fire("turn_end", { turnIndex: 2 });
    expect(await refs()).toBe(after);
  });

  it("prompt typed while a chunk is open is queued and delivered after the review", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    await fake.fire("agent_before_settle", { entries: [], continue: false });
    const status = (await client.request("status")).result;
    expect(status.openChunk).toMatchObject({ n: 1, note: "end of run, no checkpoint" });
    expect(fake.statuses.get("codeview")).toBe("codeview: chunk 1 waiting for review");

    expect(await fake.fire("input", { text: "next do b", source: "interactive" })).toEqual([{ action: "handled" }]);
    expect(fake.notifications.at(-1)?.message).toBe("Prompt queued until chunk 1 is reviewed");
    expect(await fake.fire("input", { text: "from extension", source: "extension" })).toEqual([undefined]);
    expect((await client.request("prompt", { text: "and c" })).ok).toBe(true);
    expect((await client.request("status")).result.queued).toBe(2);
    expect(fake.sent).toEqual([]);

    fake.setIdle(false);
    expect((await client.request("send", { annotations: [], note: "", viewed: true })).ok).toBe(true);
    expect(fake.sent).toHaveLength(1);
    const call = fake.sent[0]!;
    expect(call.kind).toBe("user");
    const review = 'Review of chunk 1 ("end of run, no checkpoint"):\n\nPhilipp reviewed this chunk and has no remarks. Continue.';
    expect(call.kind === "user" && call.content).toBe(renderResume(review, ["next do b", "and c"]));
    expect(call.options).toEqual({ deliverAs: "followUp" });
  });

  it("prompt from nvim without an open chunk is sent with its context", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    const client = await connect(repo);
    await client.request("prompt", { text: "explain", context: { path: "README.md", startLine: 1, endLine: 1 } });
    expect(fake.sent).toEqual([{ kind: "user", content: "explain\n\nContext: README.md:1-1", options: undefined }]);
    fake.setIdle(false);
    await client.request("prompt", { text: "more" });
    expect(fake.sent[1]).toEqual({ kind: "user", content: "more", options: { deliverAs: "followUp" } });
  });

  it("cap blocks the next edit after 150 agent lines, not counting human lines", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    const client = await connect(repo);
    repo.write("human.txt", lines(300));
    expect((await client.request("human_write", { path: "human.txt" })).ok).toBe(true);
    expect(await fake.fire("tool_call", { toolName: "edit", input: {} })).toEqual([undefined]);

    await agentWrite(fake, repo, "a.txt", lines(150));
    expect(await fake.fire("tool_call", { toolName: "edit", input: {} })).toEqual([undefined]);
    await agentWrite(fake, repo, "b.txt", "one more\n");
    expect(await fake.fire("tool_call", { toolName: "edit", input: {} })).toEqual([
      { block: true, reason: "Changed lines since the last checkpoint exceed 150. Call checkpoint with a note first." },
    ]);
    expect(await fake.fire("tool_call", { toolName: "read", input: {} })).toEqual([undefined]);
    expect(await fake.fire("tool_call", { toolName: "checkpoint", input: {} })).toEqual([undefined]);
  });

  it("human_write on an agent-touched file steers the agent", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    repo.write("b.txt", "b\n");
    await client.request("human_write", { path: "b.txt" });
    expect(fake.sent).toEqual([]);
    repo.write("a.txt", "a changed by Philipp\n");
    await client.request("human_write", { path: "a.txt" });
    expect(fake.sent).toEqual([
      {
        kind: "message",
        message: { customType: "pi-codeview", content: humanChangedSteer("a.txt"), display: true },
        options: { deliverAs: "steer" },
      },
    ]);
  });

  it("send refuses an empty unviewed review", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    const pending = fake.callTool("checkpoint", { note: "add a" });
    await until(async () => (await client.request("status")).result.openChunk);
    const res = await client.request("send", { annotations: [], note: "", viewed: false });
    expect(res).toMatchObject({ ok: false, error: "open at least one file of the chunk or add a note" });
    expect(await settled(pending)).toBe(false);
    await client.request("send", { annotations: [], note: "", viewed: true });
    await pending;
  });

  it("annotations quote code from the send-time snapshot", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "one\ntwo\nthree\n");
    const pending = fake.callTool("checkpoint", { note: "add a" });
    await until(async () => (await client.request("status")).result.openChunk);
    repo.write("a.txt", "one\nTWO\nthree\n");
    await client.request("human_write", { path: "a.txt" });
    const annotations = [{ path: "a.txt", startLine: 2, endLine: 3, note: "rename" }];
    expect((await client.request("send", { annotations, note: "", viewed: false })).ok).toBe(true);
    const out = text(await pending);
    expect(out).toContain("a.txt:2-3\n```\nTWO\nthree\n```\nNote: rename");
    expect(out).toContain("Philipp changed these files himself");
    expect(out).toContain("-two\n+TWO");
    expect(out).not.toContain("+one");
    const chunk = (await client.request("list_chunks")).result[0];
    expect(chunk.annotations[0].quote).toBe("TWO\nthree");
  });

  it("checkpoint runs sequentially, never in parallel with sibling tool calls", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    expect(fake.tools.get("checkpoint")?.executionMode).toBe("sequential");
  });

  it("an agent edit recorded while a checkpoint waits is carried into the next chunk and counts toward the cap", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    const pending = fake.callTool("checkpoint", { note: "add a" });
    await until(async () => (await client.request("status")).result.openChunk);
    await agentWrite(fake, repo, "b.txt", lines(160));
    repo.write("h.txt", "human\n");
    await client.request("human_write", { path: "h.txt" });
    expect((await client.request("send", { annotations: [], note: "", viewed: true })).ok).toBe(true);
    expect(text(await pending)).toContain("+human");
    expect(await fake.fire("tool_call", { toolName: "edit", input: {} })).toEqual([
      { block: true, reason: "Changed lines since the last checkpoint exceed 150. Call checkpoint with a note first." },
    ]);
    const next = fake.callTool("checkpoint", { note: "add b" });
    await until(async () => (await client.request("status")).result.openChunk);
    const chunk = (await client.request("status")).result.openChunk;
    expect(chunk).toMatchObject({ n: 2, agentFiles: ["b.txt"] });
    expect((await client.request("get_chunk", { n: 2 })).result.diff).toContain("+line 159");
    expect((await client.request("send", { annotations: [], note: "", viewed: true })).ok).toBe(true);
    // Philipp's edit already reached the agent with chunk 1's review.
    expect(text(await next)).not.toContain("+human");
  });

  it("the human-edit diff holds only Philipp's hunks when he and the agent changed the same file", async () => {
    const repo = await makeRepo();
    repo.write("a.txt", lines(12));
    const fake = await start(repo, { mode: "review" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", lines(12).replace("line 0", "AGENT 0"));
    repo.write("a.txt", lines(12).replace("line 0", "AGENT 0").replace("line 9", "HUMAN 9"));
    await client.request("human_write", { path: "a.txt" });
    const pending = fake.callTool("checkpoint", { note: "edit a" });
    await until(async () => (await client.request("status")).result.openChunk);
    expect((await client.request("send", { annotations: [], note: "", viewed: true })).ok).toBe(true);
    const out = text(await pending);
    const human = out.slice(out.indexOf("Philipp changed these files himself"));
    expect(human).toContain("-line 9\n+HUMAN 9");
    expect(human).not.toContain("AGENT 0");
  });

  it("an aborted run creates the end-of-run chunk in review mode only", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    await fake.fire("agent_settled", { aborted: true });
    expect((await client.request("status")).result.openChunk).toMatchObject({ n: 1, note: "end of run, no checkpoint" });
    await until(() => client.events.find((e) => e.event === "run_settled" && e.data.aborted === true));

    const vibeRepo = await makeRepo();
    const vibe = await start(vibeRepo, { sessionId: "vibe" });
    vibeRepo.write("b.txt", "b\n");
    await vibe.fire("agent_settled", { aborted: true });
    const vibeClient = await connect(vibeRepo, "vibe");
    expect((await vibeClient.request("list_chunks")).result).toEqual([]);
  });

  it("a prompt with images is not queued while a chunk is open", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    await agentWrite(fake, repo, "a.txt", "a\n");
    await fake.fire("agent_before_settle", { entries: [], continue: false });
    const images = [{ type: "image", data: "AAAA", mimeType: "image/png" }];
    expect(await fake.fire("input", { text: "look at this", images, source: "interactive" })).toEqual([undefined]);
    expect(fake.notifications.at(-1)?.message).toBe("Prompt with images not queued: review chunk 1 first");
    const client = await connect(repo);
    expect((await client.request("status")).result.queued).toBe(0);
  });

  it("/codeview off refuses while a chunk is open", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    await agentWrite(fake, repo, "a.txt", "a\n");
    await fake.fire("agent_before_settle", { entries: [], continue: false });
    await fake.runCommand("codeview", "off");
    expect(fake.notifications.at(-1)).toMatchObject({
      level: "error",
      message: "codeview: chunk 1 is open — send a review or /codeview discard <note> first",
    });
    expect(fake.pi.getActiveTools()).toContain("checkpoint");
    expect((await repo.git("config", "pi-codeview.mode")).trim()).toBe("review");
  });

  it("session_shutdown waits for in-flight snapshot work, nothing is persisted after it", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    repo.write("a.txt", "a\n");
    const inFlight = fake.fire("tool_result", { toolName: "write", input: {}, content: [], isError: false });
    await fake.fire("session_shutdown", { reason: "quit" });
    const count = fake.entries.length;
    await inFlight;
    await new Promise((r) => setTimeout(r, 100));
    expect(fake.entries.length).toBe(count);
    expect((fake.entries.at(-1)!.data as any).steps).toHaveLength(1);
  });

  it("session restore after restart keeps the open chunk", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    await agentWrite(fake, repo, "a.txt", "a\n");
    await fake.fire("agent_before_settle", { entries: [], continue: false });
    await fake.fire("session_shutdown", { reason: "quit" });

    const fake2 = await start(repo, { entries: fake.entries });
    const client = await connect(repo);
    const status = (await client.request("status")).result;
    expect(status.openChunk).toMatchObject({ n: 1, note: "end of run, no checkpoint", agentFiles: ["a.txt"] });
    expect(fake2.statuses.get("codeview")).toBe("codeview: chunk 1 waiting for review");
    // New snapshots after the restore must not overwrite refs the restored state points at.
    await agentWrite(fake2, repo, "b.txt", "b\n");
    await agentWrite(fake2, repo, "c.txt", "c\n");
    const saved = fake2.entries.at(-1)!.data as any;
    const referenced = [saved.baseline, ...saved.steps.map((s: any) => s.sha),
      ...saved.chunks.flatMap((c: any) => [c.fromSha, c.toSha])];
    const refShas = (await repo.git("for-each-ref", "--format=%(objectname)", "refs/pi-codeview/test-session/")).split("\n");
    expect(saved.steps).toHaveLength(2);
    for (const sha of referenced) expect(refShas).toContain(sha);
  });

  it("/codeview continue and discard require a note", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "review" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    const pending = fake.callTool("checkpoint", { note: "add a" });
    await until(async () => (await client.request("status")).result.openChunk);

    await fake.runCommand("codeview", "continue");
    expect(fake.notifications.at(-1)).toMatchObject({ level: "error" });
    expect(fake.notifications.at(-1)?.message).toContain("note");
    await fake.runCommand("codeview", "discard   ");
    expect(fake.notifications.at(-1)).toMatchObject({ level: "error" });
    expect(await settled(pending)).toBe(false);

    await fake.runCommand("codeview", "continue go on with tests");
    expect(text(await pending)).toContain("go on with tests");

    await agentWrite(fake, repo, "b.txt", "b\n");
    await fake.fire("agent_before_settle", { entries: [], continue: false });
    await fake.runCommand("codeview", "discard throwing this away");
    const chunks = (await client.request("list_chunks")).result;
    expect(chunks[1]).toMatchObject({ n: 2, status: "discarded", reviewNote: "throwing this away" });
    expect((await client.request("status")).result.openChunk).toBeNull();
  });

  it("/codeview on and off switch mode and tools", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    const client = await connect(repo);
    await fake.runCommand("codeview", "on");
    expect(fake.pi.getActiveTools()).toContain("checkpoint");
    expect((await repo.git("config", "pi-codeview.mode")).trim()).toBe("review");
    await until(() => client.events.find((e) => e.event === "mode_changed" && e.data.mode === "review"));
    await fake.runCommand("codeview", "off");
    expect(fake.pi.getActiveTools()).not.toContain("checkpoint");
    expect((await repo.git("config", "pi-codeview.mode")).trim()).toBe("vibe");
    await fake.runCommand("codeview", "");
    expect(fake.notifications.at(-1)?.message).toContain("mode vibe");
  });

  it("second session in the same worktree cannot enter review mode", async () => {
    const repo = await makeRepo();
    await start(repo, { mode: "review" });
    const other = await start(repo, { sessionId: "other" });
    expect(other.notifications.at(-1)?.message).toContain("one review-mode session per worktree");
    expect(other.pi.getActiveTools()).not.toContain("checkpoint");
    await other.runCommand("codeview", "on");
    expect(other.notifications.at(-1)?.message).toContain("one review-mode session per worktree");
    const client = await connect(repo, "other");
    expect((await client.request("status")).result.mode).toBe("vibe");
  });
});
