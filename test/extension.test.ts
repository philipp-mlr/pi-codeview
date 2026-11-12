import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NO_REVIEW, ReviewLoop } from "../extensions/loop.ts";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import piNvim, { isReadOnlyTool } from "../extensions/pi-nvim.ts";
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
  opts: {
    mode?: "checkpoints" | "off";
    sessionId?: string;
    entries?: FakeEntry[];
    hasUI?: boolean;
    allowedTools?: string[];
  } = {},
): Promise<FakePi> {
  const cwd = typeof repo === "string" ? repo : repo.root;
  if (opts.mode && typeof repo !== "string") await repo.git("config", "pi-nvim.checkpoints", String(opts.mode === "checkpoints"));
  const fake = makeFakePi(cwd, {
    sessionId: opts.sessionId,
    entries: opts.entries,
    hasUI: opts.hasUI,
    allowedTools: opts.allowedTools,
  });
  piNvim(fake.pi);
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
  const hello = await client.request("hello", { version: 2 });
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
      "symbol_search", "project_report", "effective_config", "ask_user_question", "todo", "grep", "find", "ls"]) {
      expect(isReadOnlyTool(name)).toBe(true);
    }
    for (const name of ["write", "edit", "bash", "some_custom_tool"]) expect(isReadOnlyTool(name)).toBe(false);
  });
});

describe("pi-nvim extension", () => {
  it("inactive outside a git repo", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cv-nogit-"));
    cleanups.push(() => fs.rmSync(dir, { recursive: true, force: true }));
    const fake = await start(dir);
    expect(fs.existsSync(path.join(runtimeDir, "pi-nvim"))).toBe(false);
    expect(fake.entries).toEqual([]);
    expect(await fake.fire("tool_call", { toolName: "write", input: {} })).toEqual([undefined]);
    await fake.runCommand("checkpoints", "");
    expect(fake.notifications.at(-1)?.message).toContain("not a git repository");
  });

  it("checkpoints off: checkpoint tool inactive, turn_end records a chunk", async () => {
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

  it("checkpoint files store why on the chunk", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    void fake.callTool("checkpoint", { note: "add a", files: [{ path: "./a.txt", why: "new file" }, { path: "x", why: "?" }] });
    await until(() => client.events.find((e) => e.event === "chunk_ready"));
    expect((await client.request("status")).result.openChunk.why).toEqual({ "a.txt": "new file" });
    expect((await client.request("list_chunks")).result[0].why).toEqual({ "a.txt": "new file" });
    expect((await client.request("get_chunk", { n: 1 })).result.chunk.why).toEqual({ "a.txt": "new file" });
  });

  it("checkpoint stores the title and get_chunk reports per-file line counts", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\nb\nc\n");
    await agentWrite(fake, repo, "bin.dat", "x\0y\0");
    void fake.callTool("checkpoint", { note: "add a", title: "  Add   a  " });
    await until(() => client.events.find((e) => e.event === "chunk_ready"));
    const got = (await client.request("get_chunk", { n: 1 })).result;
    expect(got.chunk.title).toBe("Add a");
    expect(got.stats).toEqual(
      expect.arrayContaining([
        { path: "a.txt", added: 3, removed: 0 },
        { path: "bin.dat", added: 0, removed: 0 },
      ]),
    );
    expect(got.stats).toHaveLength(2);
  });

  it("an exception in toolCall never rejects the agent's tool call", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    const spy = vi.spyOn(ReviewLoop.prototype, "toolCall").mockImplementation(() => {
      throw new Error("boom");
    });
    try {
      await expect(fake.fire("tool_call", { toolName: "write", input: { path: "a.txt" } })).resolves.not.toThrow();
    } finally {
      spy.mockRestore();
    }
  });

  it("checkpoint blocks until send, returns the rendered review", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    expect(fake.pi.getActiveTools()).toContain("checkpoint");
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    const pending = fake.callTool("checkpoint", { note: "add a" });
    await until(() => client.events.find((e) => e.event === "chunk_ready"));
    expect(fake.statuses.get("pi-nvim")).toBe("pi: checkpoint 1 waiting for review");
    expect(await settled(pending)).toBe(false);
    const status = (await client.request("status")).result;
    expect(status).toMatchObject({ mode: "checkpoints", root: repo.root, sessionId: "test-session", queued: 0 });
    expect(status.baseline).toMatch(/^[0-9a-f]{40}$/);
    expect(status.openChunk).toMatchObject({ n: 1, note: "add a", agentFiles: ["a.txt"] });
    const get = (await client.request("get_chunk", { n: 1 })).result;
    expect(get.chunk.n).toBe(1);
    expect(get.diff).toContain("+a");

    const sent = await client.request("send", { annotations: [], note: "looks fine", viewed: true });
    expect(sent.ok).toBe(true);
    const out = text(await pending);
    expect(out).toContain('Review of chunk 1 ("add a")');
    expect(out).toContain("looks fine");
    expect(fake.statuses.get("pi-nvim")).toBe("pi: checkpoints");
    await until(() => client.events.find((e) => e.event === "chunk_reviewed"));
    expect((await client.request("list_chunks")).result[0].status).toBe("reviewed");
  });

  it("markBase: checkpoint mode marks against the open chunk's start, then the baseline after send", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    const client = await connect(repo);
    const before = (await client.request("status")).result;
    expect(before.markBase).toBe(before.baseline);
    await agentWrite(fake, repo, "a.txt", "a\n");
    void fake.callTool("checkpoint", { note: "add a" });
    await until(() => client.events.find((e) => e.event === "chunk_ready"));
    const open = (await client.request("status")).result;
    expect(open.markBase).toBe(open.openChunk.fromSha);
    expect(open.markBase).toBe(before.baseline);
    expect(open.baseline).not.toBe(open.markBase);
    expect((await client.request("send", { annotations: [], note: "ok", viewed: true })).ok).toBe(true);
    const after = (await client.request("status")).result;
    expect(after.markBase).toBe(after.baseline);
    expect(after.markBase).toBe(open.openChunk.toSha);
  });

  it("markBase: checkpoints off keeps the run-start baseline across turn chunks, moves on the next agent_start", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    const client = await connect(repo);
    const start0 = (await client.request("status")).result.baseline;
    await fake.fire("agent_start", {});
    await agentWrite(fake, repo, "a.txt", "a\n");
    await fake.fire("turn_end", { turnIndex: 0 });
    await agentWrite(fake, repo, "b.txt", "b\n");
    await fake.fire("turn_end", { turnIndex: 1 });
    const status = (await client.request("status")).result;
    expect((await client.request("list_chunks")).result).toHaveLength(2);
    expect(status.baseline).not.toBe(start0);
    expect(status.markBase).toBe(start0);
    await fake.fire("agent_start", {});
    const next = (await client.request("status")).result;
    expect(next.markBase).toBe(status.baseline);
  });

  it("abort while waiting leaves the chunk open and persisted; send later resumes via sendUserMessage with renderResume", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
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
    const fake = await start(repo, { mode: "checkpoints" });
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
    const fake = await start(repo, { mode: "checkpoints" });
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

  it("checkpoints off: mutating tools take no snapshots, turn_end records one chunk", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    const refs = async () => (await repo.git("for-each-ref", "refs/pi-nvim/")).split("\n").filter(Boolean).length;
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

  it("checkpoints off: turn_end takes no snapshot when no mutating tool ran and no human_write arrived", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    const refs = async () => (await repo.git("for-each-ref", "refs/pi-nvim/")).split("\n").filter(Boolean).length;
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
    const fake = await start(repo, { mode: "checkpoints" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    await fake.fire("agent_before_settle", { entries: [], continue: false });
    const status = (await client.request("status")).result;
    expect(status.openChunk).toMatchObject({ n: 1, note: "end of run, no checkpoint" });
    expect(fake.statuses.get("pi-nvim")).toBe("pi: checkpoint 1 waiting for review");

    expect(await fake.fire("input", { text: "next do b", source: "interactive" })).toEqual([{ action: "handled" }]);
    expect(fake.notifications.at(-1)?.message).toBe("Prompt queued until checkpoint 1 is reviewed");
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
    const fake = await start(repo, { mode: "checkpoints" });
    const client = await connect(repo);
    await client.request("prompt", { text: "explain", context: { path: "README.md", startLine: 1, endLine: 1 } });
    expect(fake.sent).toEqual([{ kind: "user", content: "explain\n\nContext: README.md:1", options: undefined }]);
    fake.setIdle(false);
    await client.request("prompt", { text: "more" });
    expect(fake.sent[1]).toEqual({ kind: "user", content: "more", options: { deliverAs: "followUp" } });
  });

  it("cap blocks the next edit after 150 agent lines, not counting human lines", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
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
    const fake = await start(repo, { mode: "checkpoints" });
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
        message: { customType: "pi-nvim", content: humanChangedSteer("a.txt"), display: true },
        options: { deliverAs: "steer" },
      },
    ]);
  });

  it("send accepts an empty review of the open chunk and resumes the checkpoint", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    const pending = fake.callTool("checkpoint", { note: "add a" });
    await until(async () => (await client.request("status")).result.openChunk);
    const res = await client.request("send", { annotations: [], note: "", viewed: false });
    expect(res.ok).toBe(true);
    expect(text(await pending)).toContain("has no remarks");
    expect((await client.request("list_chunks")).result[0].status).toBe("reviewed");
  });

  it("send outside checkpoint mode with nothing to send is still refused", async () => {
    const repo = await makeRepo();
    await start(repo, { mode: "off" });
    const client = await connect(repo);
    const res = await client.request("send", { annotations: [], note: "", viewed: true });
    expect(res).toMatchObject({ ok: false, error: "nothing to send" });
  });

  it("run_settled counts the distinct files the agent changed in the run", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "off" });
    const client = await connect(repo);
    await fake.fire("agent_start", {});
    await agentWrite(fake, repo, "a.txt", "a1\n");
    await fake.fire("turn_end", { turnIndex: 0 });
    await agentWrite(fake, repo, "a.txt", "a2\n");
    await agentWrite(fake, repo, "b.txt", "b\n");
    await fake.fire("turn_end", { turnIndex: 1 });
    await fake.fire("agent_settled", { aborted: false });
    const first = await until(() => client.events.find((e) => e.event === "run_settled"));
    expect(first.data).toEqual({ aborted: false, files: 2 });

    await fake.fire("agent_start", {});
    repo.write("a.txt", "human\n");
    await client.request("human_write", { path: "a.txt" });
    await fake.fire("agent_settled", { aborted: false });
    await until(() => client.events.filter((e) => e.event === "run_settled").length === 2);
    expect(client.events.filter((e) => e.event === "run_settled")[1].data).toEqual({ aborted: false, files: 0 });
  });

  it("annotations quote code from the send-time snapshot", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
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
    const fake = await start(repo, { mode: "checkpoints" });
    expect(fake.tools.get("checkpoint")?.executionMode).toBe("sequential");
  });

  it("an agent edit recorded while a checkpoint waits is carried into the next chunk and counts toward the cap", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
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
    const fake = await start(repo, { mode: "checkpoints" });
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

  it("an aborted run creates the end-of-run chunk in checkpoint mode only", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    await fake.fire("agent_settled", { aborted: true });
    expect((await client.request("status")).result.openChunk).toMatchObject({ n: 1, note: "end of run, no checkpoint" });
    await until(() => client.events.find((e) => e.event === "run_settled" && e.data.aborted === true));

    const offRepo = await makeRepo();
    const off = await start(offRepo, { sessionId: "off" });
    offRepo.write("b.txt", "b\n");
    await off.fire("agent_settled", { aborted: true });
    const offClient = await connect(offRepo, "off");
    expect((await offClient.request("list_chunks")).result).toEqual([]);
  });

  it("checkpoint with nothing changed returns at once: no checkpoint, no event, drafts kept", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    const client = await connect(repo);
    const drafts = [{ path: "README.md", startLine: 1, endLine: 1, text: "keep" }];
    expect((await client.request("save_drafts", { annotations: drafts })).ok).toBe(true);
    const out = await fake.callTool("checkpoint", { note: "nothing" });
    expect(text(out)).toBe("Nothing changed since the last checkpoint; no review needed. Continue.");
    expect((await client.request("list_chunks")).result).toEqual([]);
    expect(client.events.filter((e) => e.event === "chunk_ready")).toEqual([]);
    expect((await client.request("status")).result.drafts).toEqual(drafts);
  });

  it("checkpoint after only a human change still opens", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    const client = await connect(repo);
    repo.write("human.txt", "h\n");
    expect((await client.request("human_write", { path: "human.txt" })).ok).toBe(true);
    const pending = fake.callTool("checkpoint", { note: "human only" });
    expect(await until(async () => (await client.request("status")).result.openChunk)).toMatchObject({ n: 1 });
    await fake.runCommand("checkpoints", "discard done");
    await pending;
  });

  it("checkpoint after an edit and its revert returns the empty text and opens no chunk", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    fs.rmSync(path.join(repo.root, "a.txt"));
    await fake.fire("tool_result", { toolName: "bash", input: {}, content: [], isError: false });
    const out = await fake.callTool("checkpoint", { note: "reverted" });
    expect(text(out)).toBe("Nothing changed since the last checkpoint; no review needed. Continue.");
    expect((await client.request("list_chunks")).result).toEqual([]);
    expect(client.events.filter((e) => e.event === "chunk_ready")).toEqual([]);
    // A real net change still opens one.
    await agentWrite(fake, repo, "b.txt", "b\n");
    const pending = fake.callTool("checkpoint", { note: "real" });
    expect(await until(async () => (await client.request("status")).result.openChunk)).toMatchObject({ n: 1, agentFiles: ["b.txt"] });
    await fake.runCommand("checkpoints", "discard done");
    await pending;
  });

  it("end of run after an edit and its revert creates no chunk", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    fs.rmSync(path.join(repo.root, "a.txt"));
    await fake.fire("tool_result", { toolName: "bash", input: {}, content: [], isError: false });
    await fake.fire("agent_before_settle", { entries: [], continue: false });
    expect((await client.request("list_chunks")).result).toEqual([]);
    expect((await client.request("status")).result.openChunk).toBeNull();
  });

  describe("outside-worktree warning", () => {
    it("search tools and ~/ paths", async () => {
      const repo = await makeRepo();
      const other = await makeRepo();
      const fake = await start(repo, { mode: "checkpoints" });
      const client = await connect(repo);
      for (const toolName of ["grep", "find", "ls"]) {
        await fake.fire("tool_call", { toolName, input: { path: other.root } });
      }
      expect(fake.notifications.filter((n) => n.level === "warning")).toEqual([]);
      expect(client.events.filter((e) => e.event === "outside_worktree")).toEqual([]);
      await fake.fire("tool_call", { toolName: "write", input: { path: "~/pi-nvim-outside-test/x.txt" } });
      await until(() => client.events.some((e) => e.event === "outside_worktree"));
      expect(client.events.find((e) => e.event === "outside_worktree")?.data.path).toBe(
        path.join(os.homedir(), "pi-nvim-outside-test/x.txt"),
      );
    });

    const warning = (root: string) =>
      `pi: the agent is editing outside ${path.basename(root)} — start pi in that worktree to review it`;

    it("warns once per run for absolute and relative paths, resets on agent_start", async () => {
      const repo = await makeRepo();
      const other = await makeRepo();
      const fake = await start(repo, { mode: "checkpoints" });
      const client = await connect(repo);
      const warnings = () => fake.notifications.filter((n) => n.level === "warning");
      await fake.fire("tool_call", { toolName: "write", input: { path: path.join(other.root, "x.al") } });
      await fake.fire("tool_call", { toolName: "edit", input: { path: "../" + path.basename(other.root) + "/x.al" } });
      expect(warnings().map((n) => n.message)).toEqual([warning(repo.root)]);
      await until(() => client.events.some((e) => e.event === "outside_worktree"));
      expect(client.events.filter((e) => e.event === "outside_worktree")).toHaveLength(1);
      expect(client.events.filter((e) => e.event === "outside_worktree")).toEqual([
        { event: "outside_worktree", data: { path: path.join(other.root, "x.al") } },
      ]);
      await fake.fire("agent_start", {});
      await fake.fire("tool_call", { toolName: "edit", input: { path: "../" + path.basename(other.root) + "/x.al" } });
      expect(warnings()).toHaveLength(2);
      await until(() => client.events.filter((e) => e.event === "outside_worktree").length >= 2);
      expect(client.events.filter((e) => e.event === "outside_worktree")).toHaveLength(2);
    });

    it("stays quiet for paths inside the root, new files, and read-only tools", async () => {
      const repo = await makeRepo();
      const other = await makeRepo();
      const fake = await start(repo, { mode: "checkpoints" });
      await fake.fire("tool_call", { toolName: "write", input: { path: "a.txt" } });
      await fake.fire("tool_call", { toolName: "write", input: { path: path.join(repo.root, "new/dir/b.txt") } });
      await fake.fire("tool_call", { toolName: "read", input: { path: path.join(other.root, "x.al") } });
      expect(fake.notifications.filter((n) => n.level === "warning")).toEqual([]);
    });
  });

  it("a prompt with images is not queued while a chunk is open", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    await agentWrite(fake, repo, "a.txt", "a\n");
    await fake.fire("agent_before_settle", { entries: [], continue: false });
    const images = [{ type: "image", data: "AAAA", mimeType: "image/png" }];
    expect(await fake.fire("input", { text: "look at this", images, source: "interactive" })).toEqual([undefined]);
    expect(fake.notifications.at(-1)?.message).toBe("Prompt with images not queued: review checkpoint 1 first");
    const client = await connect(repo);
    expect((await client.request("status")).result.queued).toBe(0);
  });

  it("/checkpoints off refuses while a chunk is open", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    await agentWrite(fake, repo, "a.txt", "a\n");
    await fake.fire("agent_before_settle", { entries: [], continue: false });
    await fake.runCommand("checkpoints", "off");
    expect(fake.notifications.at(-1)).toMatchObject({
      level: "error",
      message: "pi: checkpoint 1 is open — continue (<leader>pc) or /checkpoints discard <note> first",
    });
    expect(fake.pi.getActiveTools()).toContain("checkpoint");
    expect((await repo.git("config", "pi-nvim.checkpoints")).trim()).toBe("true");
  });

  it("session_shutdown waits for in-flight snapshot work, nothing is persisted after it", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
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
    const fake = await start(repo, { mode: "checkpoints" });
    await agentWrite(fake, repo, "a.txt", "a\n");
    await fake.fire("agent_before_settle", { entries: [], continue: false });
    await fake.fire("session_shutdown", { reason: "quit" });

    const fake2 = await start(repo, { entries: fake.entries });
    const client = await connect(repo);
    const status = (await client.request("status")).result;
    expect(status.openChunk).toMatchObject({ n: 1, note: "end of run, no checkpoint", agentFiles: ["a.txt"] });
    expect(fake2.statuses.get("pi-nvim")).toBe("pi: checkpoint 1 waiting for review");
    // New snapshots after the restore must not overwrite refs the restored state points at.
    await agentWrite(fake2, repo, "b.txt", "b\n");
    await agentWrite(fake2, repo, "c.txt", "c\n");
    const saved = fake2.entries.at(-1)!.data as any;
    const referenced = [saved.baseline, ...saved.steps.map((s: any) => s.sha),
      ...saved.chunks.flatMap((c: any) => [c.fromSha, c.toSha])];
    const refShas = (await repo.git("for-each-ref", "--format=%(objectname)", "refs/pi-nvim/test-session/")).split("\n");
    expect(saved.steps).toHaveLength(2);
    for (const sha of referenced) expect(refShas).toContain(sha);
  });

  it("/checkpoints continue and discard require a note", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "a\n");
    const pending = fake.callTool("checkpoint", { note: "add a" });
    await until(async () => (await client.request("status")).result.openChunk);

    await fake.runCommand("checkpoints", "continue");
    expect(fake.notifications.at(-1)).toMatchObject({ level: "error" });
    expect(fake.notifications.at(-1)?.message).toContain("note");
    await fake.runCommand("checkpoints", "discard   ");
    expect(fake.notifications.at(-1)).toMatchObject({ level: "error" });
    expect(await settled(pending)).toBe(false);

    await fake.runCommand("checkpoints", "continue go on with tests");
    expect(text(await pending)).toContain("go on with tests");

    await agentWrite(fake, repo, "b.txt", "b\n");
    await fake.fire("agent_before_settle", { entries: [], continue: false });
    await fake.runCommand("checkpoints", "discard throwing this away");
    const chunks = (await client.request("list_chunks")).result;
    expect(chunks[1]).toMatchObject({ n: 2, status: "discarded", reviewNote: "throwing this away" });
    expect((await client.request("status")).result.openChunk).toBeNull();
  });

  it("/checkpoints on and off switch mode and tools", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    const client = await connect(repo);
    await fake.runCommand("checkpoints", "on");
    expect(fake.pi.getActiveTools()).toContain("checkpoint");
    expect((await repo.git("config", "pi-nvim.checkpoints")).trim()).toBe("true");
    await until(() => client.events.find((e) => e.event === "mode_changed" && e.data.mode === "checkpoints"));
    await fake.runCommand("checkpoints", "off");
    expect(fake.pi.getActiveTools()).not.toContain("checkpoint");
    expect((await repo.git("config", "pi-nvim.checkpoints")).trim()).toBe("false");
    await fake.runCommand("checkpoints", "");
    expect(fake.notifications.at(-1)?.message).toContain("checkpoint mode off");
  });

  it("set_mode accepts on/off and the old review/vibe names and refuses unknown modes", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    const client = await connect(repo);
    expect((await client.request("set_mode", { mode: "on" })).result).toEqual({ mode: "checkpoints" });
    expect(fake.pi.getActiveTools()).toContain("checkpoint");
    expect((await repo.git("config", "pi-nvim.checkpoints")).trim()).toBe("true");
    expect((await client.request("set_mode", { mode: "off" })).result).toEqual({ mode: "off" });
    expect((await client.request("set_mode", { mode: "review" })).result).toEqual({ mode: "checkpoints" });
    expect((await client.request("set_mode", { mode: "vibe" })).result).toEqual({ mode: "off" });
    expect((await client.request("set_mode", { mode: "checkpoints" })).result).toEqual({ mode: "checkpoints" });
    expect((await client.request("set_mode", { mode: "off" })).result).toEqual({ mode: "off" });
    const bad = await client.request("set_mode", { mode: "banana" });
    expect(bad.ok).toBe(false);
    expect(bad.error).toContain("checkpoints or off");
    expect((await repo.git("config", "pi-nvim.checkpoints")).trim()).toBe("false");
    expect((await client.request("status")).result.mode).toBe("off");
  });

  it("second session in the same worktree cannot enter checkpoint mode", async () => {
    const repo = await makeRepo();
    await start(repo, { mode: "checkpoints" });
    const other = await start(repo, { sessionId: "other" });
    expect(other.notifications.at(-1)?.message).toContain("one checkpoint-mode session per worktree");
    expect(other.pi.getActiveTools()).not.toContain("checkpoint");
    await other.runCommand("checkpoints", "on");
    expect(other.notifications.at(-1)?.message).toContain("one checkpoint-mode session per worktree");
    const client = await connect(repo, "other");
    expect((await client.request("status")).result.mode).toBe("off");
  });
});

describe("pi-nvim migration from pi-codeview", () => {
  it("pi-codeview.mode=review starts in checkpoint mode; pi-codeview.mode=vibe starts with checkpoints off", async () => {
    const repo = await makeRepo();
    await repo.git("config", "pi-codeview.mode", "review");
    const fake = await start(repo);
    expect(fake.pi.getActiveTools()).toContain("checkpoint");
    expect((await (await connect(repo)).request("status")).result.mode).toBe("checkpoints");

    const offRepo = await makeRepo();
    await offRepo.git("config", "pi-codeview.mode", "vibe");
    const off = await start(offRepo, { sessionId: "off" });
    expect(off.pi.getActiveTools()).not.toContain("checkpoint");
    expect((await (await connect(offRepo, "off")).request("status")).result.mode).toBe("off");
  });

  it("toggling writes pi-nvim.checkpoints and leaves pi-codeview.mode untouched", async () => {
    const repo = await makeRepo();
    await repo.git("config", "pi-codeview.mode", "on");
    const fake = await start(repo);
    await fake.runCommand("checkpoints", "off");
    expect((await repo.git("config", "pi-nvim.checkpoints")).trim()).toBe("false");
    expect((await repo.git("config", "pi-codeview.mode")).trim()).toBe("on");
    await fake.fire("session_shutdown", { reason: "quit" });
    const again = await start(repo, { sessionId: "again" });
    expect(again.pi.getActiveTools()).not.toContain("checkpoint");
  });

  it("restores from the last pi-codeview-state entry and maps its old mode names", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    await agentWrite(fake, repo, "a.txt", "a\n");
    await fake.fire("agent_before_settle", { entries: [], continue: false });
    await fake.fire("session_shutdown", { reason: "quit" });
    const last = fake.entries.filter((e) => e.customType === "pi-nvim-state").at(-1)!;
    const old: FakeEntry[] = [{ type: "custom", customType: "pi-codeview-state", data: { ...(last.data as object), mode: "review" } }];

    const fake2 = await start(repo, { entries: old });
    const status = (await (await connect(repo)).request("status")).result;
    expect(status.openChunk).toMatchObject({ n: 1, note: "end of run, no checkpoint", agentFiles: ["a.txt"] });
    expect(status.mode).toBe("checkpoints");
    expect(fake2.entries.at(-1)!.customType).toBe("pi-nvim-state");
    expect((fake2.entries.at(-1)!.data as { mode: string }).mode).toBe("checkpoints");
  });

  it("a pi-nvim-state entry wins over an older pi-codeview-state entry", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    await agentWrite(fake, repo, "a.txt", "a\n");
    await fake.fire("agent_before_settle", { entries: [], continue: false });
    await fake.fire("session_shutdown", { reason: "quit" });
    const last = fake.entries.filter((e) => e.customType === "pi-nvim-state").at(-1)!;
    const stale = { ...(last.data as object), chunks: [], mode: "vibe" };
    const entries: FakeEntry[] = [
      { type: "custom", customType: "pi-nvim-state", data: last.data },
      { type: "custom", customType: "pi-codeview-state", data: stale },
    ];
    await start(repo, { entries });
    expect((await (await connect(repo)).request("status")).result.openChunk).toMatchObject({ n: 1 });
  });
});

describe("pi-nvim lastActive", () => {
  const lastActive = async (client: Client): Promise<number> => (await client.request("status")).result.lastActive;
  const pause = () => new Promise((r) => setTimeout(r, 15));

  it("starts at session start and moves on run, tool, prompt and send activity", async () => {
    const repo = await makeRepo();
    const before = Date.now();
    const fake = await start(repo);
    const client = await connect(repo);
    let last = await lastActive(client);
    expect(last).toBeGreaterThanOrEqual(before);
    expect(last).toBeLessThanOrEqual(Date.now());

    const steps: Array<() => Promise<unknown>> = [
      () => fake.fire("agent_start", {}),
      () => fake.fire("tool_call", { toolName: "read", input: { path: "a.txt" } }),
      () => fake.fire("tool_result", { toolName: "read", input: {}, content: [], isError: false }),
      () => client.request("prompt", { text: "hi" }),
      () => client.request("send", { annotations: [], note: "go" }),
      () => fake.fire("agent_settled", { aborted: false }),
    ];
    for (const step of steps) {
      await pause();
      await step();
      const now = await lastActive(client);
      expect(now).toBeGreaterThan(last);
      last = now;
    }
  });

  it("a status request alone does not count as activity", async () => {
    const repo = await makeRepo();
    await start(repo);
    const client = await connect(repo);
    const first = await lastActive(client);
    await pause();
    expect(await lastActive(client)).toBe(first);
  });
});

describe("pi-nvim activity", () => {
  const currents = (client: { events: { event: string; data: any }[] }) => client.events.filter((e) => e.event === "activity_current");

  it("reports the running tool in status and activity_current, busy until settled", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    const client = await connect(repo);
    expect((await client.request("status")).result).toMatchObject({ activity: null });
    expect((await client.request("status")).result).not.toHaveProperty("activitySeq");

    await fake.fire("agent_start", {});
    await until(() => currents(client).length === 1);
    expect(currents(client)[0].data).toEqual({ current: null, busy: true });

    await fake.fire("tool_execution_start", { toolCallId: "t1", toolName: "edit", args: { path: "a.ts" } });
    await until(() => currents(client).length === 2);
    expect(currents(client)[1].data).toEqual({ current: { tool: "edit", target: "a.ts" }, busy: true });
    expect((await client.request("status")).result).toMatchObject({ activity: { tool: "edit", target: "a.ts" } });

    await fake.fire("tool_execution_end", { toolCallId: "t1", toolName: "edit", result: {}, isError: false });
    await until(() => currents(client).length === 3);
    expect(currents(client)[2].data).toEqual({ current: null, mutating: true, busy: true });

    await fake.fire("tool_execution_start", { toolCallId: "t2", toolName: "bash", args: { command: "ls" } });
    await fake.fire("agent_settled", { aborted: false });
    await until(() => currents(client).length === 5);
    expect(currents(client)[4].data).toEqual({ current: null, busy: false });
    expect((await client.request("status")).result.activity).toBeNull();
  });

  it("no longer serves get_activity or sends activity events", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    const client = await connect(repo);
    await fake.fire("tool_execution_start", { toolCallId: "t1", toolName: "edit", args: { path: "a.ts" } });
    await fake.fire("message_end", { message: { role: "assistant", content: [{ type: "text", text: "hi" }] } });
    await fake.fire("agent_settled", { aborted: false });
    expect((await client.request("get_activity")).ok).toBe(false);
    expect(client.events.some((e) => e.event === "activity")).toBe(false);
  });

  it("a parallel tool stays current when another ends", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    const client = await connect(repo);
    await fake.fire("tool_execution_start", { toolCallId: "a", toolName: "read", args: { path: "a.ts" } });
    await fake.fire("tool_execution_start", { toolCallId: "b", toolName: "read", args: { path: "b.ts" } });
    await fake.fire("tool_execution_end", { toolCallId: "b", toolName: "read", result: {}, isError: false });
    await until(() => currents(client).length === 3);
    expect(currents(client)[2].data).toEqual({ current: { tool: "read", target: "a.ts" }, mutating: false, busy: true });
    await fake.fire("tool_execution_end", { toolCallId: "a", toolName: "read", result: {}, isError: false });
    await until(() => currents(client).length === 4);
    expect(currents(client)[3].data).toEqual({ current: null, mutating: false, busy: true });
  });

  it("activity_current says whether the ended tool may have changed files", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    const client = await connect(repo);
    await fake.fire("tool_execution_start", { toolCallId: "w", toolName: "write", args: { path: "a.ts" } });
    await fake.fire("tool_execution_end", { toolCallId: "w", toolName: "write", result: {}, isError: false });
    await fake.fire("tool_execution_start", { toolCallId: "l", toolName: "lens_diagnostics", args: {} });
    await fake.fire("tool_execution_end", { toolCallId: "l", toolName: "lens_diagnostics", result: {}, isError: false });
    await until(() => currents(client).length === 4);
    expect(currents(client).map((e) => e.data.mutating)).toEqual([undefined, true, undefined, false]);
  });

  it("cancel while idle replies false and does not abort", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    const client = await connect(repo);
    expect((await client.request("cancel")).result).toEqual({ cancelled: false });
    expect(fake.abortCalls).toEqual([]);
  });

  it("cancel while busy aborts the run and replies true", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    const client = await connect(repo);
    fake.setIdle(false);
    expect((await client.request("cancel")).result).toEqual({ cancelled: true });
    expect(fake.abortCalls).toHaveLength(1);
  });

  it("cancel while a checkpoint waits returns Review pending, keeps the chunk open, and a later send resumes", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    const client = await connect(repo);
    await agentWrite(fake, repo, "a.txt", "alpha\n");
    fake.setIdle(false);
    const pending = fake.callTool("checkpoint", { note: "add a" });
    await until(async () => (await client.request("status")).result.openChunk);
    expect((await client.request("cancel")).result).toEqual({ cancelled: true });
    expect(text(await pending)).toBe("Review pending. Philipp will send it later.");
    expect((await client.request("status")).result.openChunk).toMatchObject({ n: 1, status: "open" });
    fake.setIdle(true);
    expect((await client.request("send", { annotations: [], note: "ok", viewed: true })).ok).toBe(true);
    const resume = fake.sent.find((s) => s.kind === "user");
    expect(String(resume!.kind === "user" && resume!.content)).toContain("Continue the task that was interrupted");
  });

  it("a prompt request renders its diagnostics for the agent", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    const client = await connect(repo);
    const diagnostics = [{ line: 2, severity: "error", message: "bad", source: "lsp" }];
    await client.request("prompt", { text: "fix", context: { path: "a.ts", startLine: 1, endLine: 3, diagnostics } });
    const sent = fake.sent.find((s) => s.kind === "user");
    expect(String(sent!.kind === "user" && sent!.content)).toContain("Diagnostics:\n  a.ts:2 error bad [lsp]");
  });
});

describe("pi-nvim checkpoint mode in a session nobody can review", () => {
  const BASE_TOOLS = ["read", "bash", "edit", "write"];

  async function pastTheCap(fake: FakePi, repo: TestRepo): Promise<void> {
    await agentWrite(fake, repo, "a.txt", lines(151));
  }

  it("a tool allowlist without checkpoint: no cap block, no chunk at end of run, status says off and why", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints", allowedTools: BASE_TOOLS });
    expect(fake.pi.getActiveTools()).not.toContain("checkpoint");
    await pastTheCap(fake, repo);
    expect(await fake.fire("tool_call", { toolName: "edit", input: {} })).toEqual([undefined]);
    await fake.fire("agent_before_settle");
    await fake.fire("agent_settled", { aborted: true });
    const client = await connect(repo);
    const status = (await client.request("status")).result;
    expect(status.openChunk).toBeNull();
    expect(status.mode).toBe("off");
    expect(status.modeNote).toBe("checkpoint mode is on for this repo, but this session can't stop for review");
    await fake.runCommand("checkpoints", "");
    expect(fake.notifications.at(-1)?.message).toContain("checkpoint mode is on for this repo, but this session can't stop for review");
    expect(fake.confirms).toEqual([]);
  });

  it("an allowlisted session records turn chunks like checkpoints off", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints", allowedTools: BASE_TOOLS });
    await agentWrite(fake, repo, "a.txt", "a\n");
    await fake.fire("turn_end", { turnIndex: 0 });
    const client = await connect(repo);
    expect((await client.request("list_chunks")).result).toMatchObject([{ n: 1, status: "recorded" }]);
  });

  it("without a UI: no cap block, no chunk at end of run, a checkpoint call returns at once", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints", hasUI: false });
    expect(fake.pi.getActiveTools()).not.toContain("checkpoint");
    await pastTheCap(fake, repo);
    expect(await fake.fire("tool_call", { toolName: "edit", input: {} })).toEqual([undefined]);
    expect(text(await fake.callTool("checkpoint", { note: "x" }))).toBe(NO_REVIEW);
    await fake.fire("agent_before_settle");
    const client = await connect(repo);
    const status = (await client.request("status")).result;
    expect(status.openChunk).toBeNull();
    expect(status.mode).toBe("off");
  });

  it("checkpoint taken away after start (a child runtime applying its allowlist late) stops blocking", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "checkpoints" });
    await pastTheCap(fake, repo);
    expect(await fake.fire("tool_call", { toolName: "edit", input: {} })).toHaveLength(1);
    expect((await fake.fire("tool_call", { toolName: "edit", input: {} }))[0]).toMatchObject({ block: true });
    fake.pi.setActiveTools(BASE_TOOLS);
    expect(await fake.fire("tool_call", { toolName: "edit", input: {} })).toEqual([undefined]);
  });

  it("a session in checkpoint mode that can't be reviewed does not keep another session out of checkpoint mode", async () => {
    const repo = await makeRepo();
    await start(repo, { mode: "checkpoints", hasUI: false, sessionId: "child" });
    const main = await start(repo, { sessionId: "main" });
    expect(main.pi.getActiveTools()).toContain("checkpoint");
    expect(main.notifications.some((n) => n.message.includes("one checkpoint-mode session per worktree"))).toBe(false);
  });
});
