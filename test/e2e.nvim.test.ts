import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { spawn, type ChildProcess } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import codeview from "../extensions/codeview.ts";
import { SEND_REFUSED } from "../extensions/loop.ts";
import { humanChangedSteer } from "../extensions/render.ts";
import { makeFakePi, type FakePi } from "./helpers/fake-pi.ts";
import { makeRepo, type TestRepo } from "./helpers/repo.ts";

const NVIM_RTP = path.resolve(import.meta.dirname, "../nvim");
const TIMEOUT_MS = 20_000;

type Notification = { msg: string; level: number };

let runtimeDir: string;
let scratchDir: string;
const cleanups: Array<() => Promise<void> | void> = [];

beforeEach(() => {
  runtimeDir = fs.mkdtempSync(path.join(os.tmpdir(), "cv-"));
  scratchDir = fs.mkdtempSync(path.join(os.tmpdir(), "cv-e2e-"));
  process.env.XDG_RUNTIME_DIR = runtimeDir;
});

afterEach(async () => {
  for (const c of cleanups.splice(0).reverse()) await c();
  delete process.env.XDG_RUNTIME_DIR;
  fs.rmSync(runtimeDir, { recursive: true, force: true });
  fs.rmSync(scratchDir, { recursive: true, force: true });
});

async function start(repo: TestRepo, opts: { root?: string; sessionId?: string } = {}): Promise<FakePi> {
  await repo.git("config", "pi-codeview.mode", "review");
  const fake = makeFakePi(opts.root ?? repo.root, { sessionId: opts.sessionId });
  codeview(fake.pi);
  await fake.fire("session_start", { reason: "startup" });
  cleanups.push(() => fake.fire("session_shutdown", { reason: "quit" }).then(() => {}));
  return fake;
}

async function agentWrite(fake: FakePi, repo: TestRepo, file: string, text: string): Promise<void> {
  repo.write(file, text);
  await fake.fire("tool_result", { toolName: "write", input: { path: file }, content: [], isError: false });
}

/** Runs `body` inside a headless nvim in the repo; every vim.notify call is appended to a JSON log. */
function runNvim(repo: TestRepo, body: string, cwd = repo.root): { notifications(): Notification[]; exited: Promise<void> } {
  const run = fs.mkdtempSync(path.join(scratchDir, "n"));
  const log = path.join(run, "notify.json");
  const script = path.join(run, "script.lua");
  fs.writeFileSync(
    script,
    `
local log = ${JSON.stringify(log)}
local notes = {}
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = tostring(msg), level = level or vim.log.levels.INFO }
  vim.fn.writefile({ vim.json.encode(notes) }, log)
end
local ok, err = xpcall(function()
${body}
end, debug.traceback)
if not ok then vim.notify("SCRIPT ERROR: " .. err, vim.log.levels.ERROR) end
`,
  );
  const nvim: ChildProcess = spawn(
    "nvim",
    ["--headless", "--clean", "-u", "NONE", "--cmd", `set rtp^=${NVIM_RTP}`, "-c", `luafile ${script}`],
    { cwd, env: { ...process.env, XDG_RUNTIME_DIR: runtimeDir }, stdio: "ignore" },
  );
  cleanups.push(() => {
    if (nvim.exitCode === null) nvim.kill("SIGKILL");
  });
  const exited = new Promise<void>((resolve) => nvim.once("exit", () => resolve()));
  return {
    exited,
    notifications() {
      if (!fs.existsSync(log)) return [];
      return JSON.parse(fs.readFileSync(log, "utf8")) as Notification[];
    },
  };
}

async function until<T>(fn: () => T | undefined | null | false, what: string): Promise<T> {
  for (let i = 0; i < 1000; i++) {
    const v = fn();
    if (v) return v;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error(`timed out waiting for ${what}`);
}

async function settled<T>(p: Promise<T>, ms = 200): Promise<boolean> {
  let done = false;
  void p.then(() => (done = true));
  await new Promise((r) => setTimeout(r, ms));
  return done;
}

function text(result: any): string {
  return result.content.map((c: { text: string }) => c.text).join("");
}

const ERROR = 4;

describe("codeview.nvim end to end", () => {
  it("panel, chunk diff, annotation and CodeviewSend resolve the waiting checkpoint", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    await agentWrite(fake, repo, "a.txt", "one\ntwo\n");
    await agentWrite(fake, repo, "b.txt", "bee\n");
    const pending = fake.callTool("checkpoint", { note: "add a" });

    const nvim = runNvim(
      repo,
      `
local cv = require("codeview")
cv.setup()
vim.cmd("edit a.txt")
cv.toggle_panel()
local panel_line
vim.wait(5000, function()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "codeview" then
      panel_line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    end
  end
  return panel_line ~= nil and panel_line:match("^#1") ~= nil
end)
vim.notify("PANEL " .. tostring(panel_line))
cv.open_chunk(1)
vim.wait(5000, function() return #vim.api.nvim_list_tabpages() == 2 end)
vim.notify("WINBAR " .. vim.wo.winbar)
vim.cmd("normal ]f")
vim.notify("WINBAR " .. vim.wo.winbar)
vim.cmd("normal [f")
local buf = vim.fn.bufnr(vim.uv.fs_realpath("a.txt"))
cv.annotate(buf, 1, 1, "why one?")
cv.send({ note = "" })
`,
    );

    const out = text(await pending);
    expect(out).toContain("why one?");
    expect(out).toContain("a.txt:1-1\n```\none\n```");
    const notes = await until(
      () => nvim.notifications().some((n) => n.msg.includes("review of chunk 1 sent")) && nvim.notifications(),
      "send notification",
    );
    expect(notes.filter((n) => n.level === ERROR)).toEqual([]);
    expect(notes.map((n) => n.msg)).toContain("PANEL #1 [open] add a — a.txt, b.txt (0 comments)");
    expect(notes.map((n) => n.msg).filter((m) => m.startsWith("WINBAR"))).toEqual([
      "WINBAR chunk 1 · 1/2 · a.txt · agent",
      "WINBAR chunk 1 · 2/2 · b.txt · agent",
    ]);
  }, TIMEOUT_MS);

  it("BufWritePost on an agent-touched file steers the agent", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    await agentWrite(fake, repo, "a.txt", "one\n");

    const nvim = runNvim(
      repo,
      `
local cv = require("codeview")
cv.setup()
vim.cmd("edit a.txt")
cv.toggle_panel()
vim.wait(5000, function() return cv.status() ~= "" end)
vim.notify("STATUS " .. cv.status())
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one changed by Philipp" })
vim.cmd("write")
`,
    );

    await until(() => fake.sent.length > 0, "steer message");
    expect(fake.sent).toEqual([
      {
        kind: "message",
        message: { customType: "pi-codeview", content: humanChangedSteer("a.txt"), display: true },
        options: { deliverAs: "steer" },
      },
    ]);
    expect(nvim.notifications().map((n) => n.msg)).toContain("STATUS idle");
  }, TIMEOUT_MS);

  it("CodeviewSend without opening the chunk and without content is refused via vim.notify", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    await agentWrite(fake, repo, "a.txt", "one\n");
    const pending = fake.callTool("checkpoint", { note: "add a" });

    const nvim = runNvim(
      repo,
      `
local cv = require("codeview")
cv.setup()
vim.cmd("edit a.txt")
cv.send({ note = "" })
`,
    );

    const refused = await until(
      () => nvim.notifications().find((n) => n.level === ERROR),
      "error notification",
    );
    expect(refused.msg).toContain(SEND_REFUSED);
    expect(await settled(pending)).toBe(false);
  }, TIMEOUT_MS);

  it("an annotation added just before quitting is saved as a draft and restored by the next nvim", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    await agentWrite(fake, repo, "a.txt", "one\ntwo\n");

    const first = runNvim(
      repo,
      `
local cv = require("codeview")
cv.setup()
vim.cmd("edit a.txt")
cv.annotate(vim.api.nvim_get_current_buf(), 2, 2, "draft survives quit")
vim.wait(5000, function() return require("codeview.session").connected() end)
vim.cmd("qa!")
`,
    );
    await first.exited;

    const second = runNvim(
      repo,
      `
local cv = require("codeview")
cv.setup()
vim.cmd("edit a.txt")
require("codeview.session").ensure(function(_, root)
  vim.notify("DRAFTS " .. vim.json.encode(require("codeview.annotations").list(root)))
end)
`,
    );
    const drafts = await until(() => second.notifications().find((n) => n.msg.startsWith("DRAFTS")), "restored drafts");
    expect(drafts.msg).toContain("draft survives quit");
  }, TIMEOUT_MS);

  it("]f and [f are not left mapped on the real buffer after the diff tab closes", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    await agentWrite(fake, repo, "a.txt", "one\n");
    void fake.callTool("checkpoint", { note: "add a" });

    const nvim = runNvim(
      repo,
      `
local cv = require("codeview")
cv.setup()
vim.cmd("edit a.txt")
local buf = vim.api.nvim_get_current_buf()
cv.toggle_panel()
cv.open_chunk(1)
vim.wait(5000, function() return vim.fn.maparg("]f", "n", false, true).desc ~= nil end)
vim.notify("OPEN " .. tostring(vim.fn.maparg("]f", "n", false, true).desc))
vim.cmd("tabclose")
vim.notify("CLOSED " .. vim.inspect(vim.api.nvim_buf_call(buf, function() return vim.fn.maparg("]f", "n", false, true) end)))
`,
    );
    const notes = await until(() => nvim.notifications().some((n) => n.msg.startsWith("CLOSED") || n.msg.startsWith("SCRIPT")) && nvim.notifications(), "mapping check");
    const msgs = notes.map((n) => n.msg);
    expect(msgs).toContain("OPEN codeview: next file in chunk");
    expect(msgs.filter((m) => !m.startsWith("OPEN"))).toEqual(["CLOSED vim.empty_dict()"]);
  }, TIMEOUT_MS);

  it("a save before any codeview command attaches quietly and is recorded as Philipp's step", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    await agentWrite(fake, repo, "a.txt", "one\n");

    const nvim = runNvim(
      repo,
      `
require("codeview").setup()
vim.cmd("edit README.md")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "hello from Philipp" })
vim.cmd("write")
`,
    );

    const steps = await until(() => {
      const state = fake.entries.at(-1)?.data as { steps: { author: string; files: string[] }[] } | undefined;
      return state?.steps.some((s) => s.author === "human") && state.steps;
    }, "human step");
    expect(steps.find((s) => s.author === "human")?.files).toEqual(["README.md"]);
    await new Promise((r) => setTimeout(r, 200));
    expect(nvim.notifications()).toEqual([]);
  }, TIMEOUT_MS);

  it("nvim in one worktree attaches to that worktree's pi session, not another worktree's", async () => {
    const repo = await makeRepo();
    const other = path.join(fs.realpathSync(scratchDir), "wt");
    await repo.git("worktree", "add", "-q", other, "-b", "other");
    const inOther = await start(repo, { root: other, sessionId: "other" });
    await new Promise((r) => setTimeout(r, 20));
    const inMain = await start(repo, { sessionId: "main" });
    await agentWrite(inMain, repo, "a.txt", "one\n");

    const nvim = runNvim(
      repo,
      `
require("codeview").setup()
vim.cmd("edit README.md")
require("codeview.session").ensure(function(_, root)
  vim.notify("ATTACHED " .. require("codeview.session").cached.sessionId .. " " .. root)
end)
`,
    );
    const attached = await until(() => nvim.notifications().find((n) => n.msg.startsWith("ATTACHED") || n.level === ERROR), "attach");
    expect(attached.msg).toBe(`ATTACHED main ${repo.root}`);

    const wtNvim = runNvim(
      repo,
      `
require("codeview").setup()
vim.cmd("edit README.md")
require("codeview.session").ensure(function(_, root)
  vim.notify("ATTACHED " .. require("codeview.session").cached.sessionId .. " " .. root)
end)
`,
      other,
    );
    const wtAttached = await until(() => wtNvim.notifications().find((n) => n.msg.startsWith("ATTACHED") || n.level === ERROR), "attach in worktree");
    expect(wtAttached.msg).toBe(`ATTACHED other ${other}`);
    expect(inOther.sent).toEqual([]);
  }, TIMEOUT_MS);

  it("saving a file stores the drafts' moved positions", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    repo.write("b.txt", "one\ntwo\n");
    await agentWrite(fake, repo, "a.txt", "x\n");

    runNvim(
      repo,
      `
local cv = require("codeview")
cv.setup()
vim.cmd("edit b.txt")
cv.annotate(vim.api.nvim_get_current_buf(), 2, 2, "moves")
vim.wait(5000, function() return require("codeview.session").connected() end)
vim.wait(1000)
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new 1", "new 2" })
vim.cmd("write")
`,
    );
    await until(() => {
      const state = fake.entries.at(-1)?.data as { drafts: { startLine: number }[] } | undefined;
      return state?.drafts[0]?.startLine === 4;
    }, "draft saved at line 4");
  }, TIMEOUT_MS);
});
