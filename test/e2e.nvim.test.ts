import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { spawn, type ChildProcess } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import piNvim from "../extensions/pi-nvim.ts";
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

async function start(
  repo: TestRepo,
  opts: { root?: string; sessionId?: string; sessionName?: string; mode?: "checkpoints" | "off" } = {},
): Promise<FakePi> {
  await repo.git("config", "pi-nvim.checkpoints", String((opts.mode ?? "checkpoints") === "checkpoints"));
  const fake = makeFakePi(opts.root ?? repo.root, { sessionId: opts.sessionId, sessionName: opts.sessionName });
  piNvim(fake.pi);
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
  -- Write then rename, so the test never reads a half-written file.
  vim.fn.writefile({ vim.json.encode(notes) }, log .. ".tmp")
  vim.uv.fs_rename(log .. ".tmp", log)
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
  let last: Notification[] = [];
  return {
    exited,
    notifications() {
      if (!fs.existsSync(log)) return last;
      try {
        last = JSON.parse(fs.readFileSync(log, "utf8")) as Notification[];
      } catch {
        // A read racing the rename on a slow machine: keep the previous complete list.
      }
      return last;
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

/** Waits until the extension has an open chunk, so nvim never asks for a chunk that doesn't exist yet. */
async function chunkOpen(fake: FakePi): Promise<void> {
  await until(() => {
    const last = fake.entries.filter((e) => e.customType === "pi-nvim-state").at(-1);
    return (last?.data as { chunks?: { status: string }[] } | undefined)?.chunks?.some((c) => c.status === "open");
  }, "open chunk");
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

describe("pi.nvim end to end", () => {
  it("panel, chunk diff, annotation and PiSendAnnotations resolve the waiting checkpoint", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    await agentWrite(fake, repo, "a.txt", "one\ntwo\n");
    await agentWrite(fake, repo, "b.txt", "bee\n");
    const pending = fake.callTool("checkpoint", { note: "add a" });
    await chunkOpen(fake);

    const nvim = runNvim(
      repo,
      `
local cv = require("pi")
cv.setup()
vim.cmd("edit a.txt")
cv.toggle_panel()
local panel_line
vim.wait(5000, function()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "pi-chunks" then
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
local cv = require("pi")
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
        message: { customType: "pi-nvim", content: humanChangedSteer("a.txt"), display: true },
        options: { deliverAs: "steer" },
      },
    ]);
    expect(nvim.notifications().map((n) => n.msg)).toContain("STATUS idle");
  }, TIMEOUT_MS);

  it("an empty review asks to continue without remarks; yes sends it", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    await agentWrite(fake, repo, "a.txt", "one\n");
    const pending = fake.callTool("checkpoint", { note: "add a" });
    await chunkOpen(fake);

    const nvim = runNvim(
      repo,
      `
local cv = require("pi")
cv.setup()
vim.cmd("edit a.txt")
vim.fn.confirm = function(msg) vim.notify("CONFIRM " .. msg); return 1 end
cv.send({ note = "" })
`,
    );

    expect(text(await pending)).toContain("has no remarks");
    const notes = await until(() => nvim.notifications().some((n) => n.msg.includes("review of chunk 1 sent")) && nvim.notifications(), "send notification");
    expect(notes.map((n) => n.msg)).toContain("CONFIRM pi: continue without remarks? (y/n)");
  }, TIMEOUT_MS);

  it("an empty review asks to continue without remarks; no sends nothing", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    await agentWrite(fake, repo, "a.txt", "one\n");
    const pending = fake.callTool("checkpoint", { note: "add a" });
    await chunkOpen(fake);

    const nvim = runNvim(
      repo,
      `
local cv = require("pi")
cv.setup()
vim.cmd("edit a.txt")
vim.fn.confirm = function(msg) vim.notify("CONFIRM " .. msg); return 2 end
cv.send({ note = "" })
`,
    );

    await until(() => nvim.notifications().some((n) => n.msg.startsWith("CONFIRM")), "confirm");
    await new Promise((r) => setTimeout(r, 500));
    expect(nvim.notifications().map((n) => n.msg)).toContain("CONFIRM pi: continue without remarks? (y/n)");
    expect(nvim.notifications().some((n) => n.msg.includes("sent"))).toBe(false);
    expect(await settled(pending)).toBe(false);
  }, TIMEOUT_MS);

  it("sending outside checkpoint mode names the annotations in the prompt and the result", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "off" });
    const nvim = runNvim(
      repo,
      `
local cv = require("pi")
cv.setup()
vim.cmd("edit a.txt")
local buf = vim.api.nvim_get_current_buf()
vim.ui.input = function(o, cb) vim.notify("PROMPT " .. o.prompt); cb("") end
cv.annotate(buf, 1, 1, "first")
cv.annotate(buf, 2, 2, "second")
cv.send()
vim.wait(5000, function() return #require("pi.annotations").list(vim.fn.getcwd()) == 0 end, 20)
cv.annotate(buf, 1, 1, "again")
cv.send()
`,
    );
    repo.write("a.txt", "one\ntwo\n");
    await until(
      () => nvim.notifications().some((n) => n.msg === "pi: 1 annotation sent"),
      "both sends",
    );
    const msgs = nvim.notifications().map((n) => n.msg);
    expect(msgs).toContain("PROMPT pi: send 2 annotations — optional message: ");
    expect(msgs).toContain("pi: 2 annotations sent");
    expect(msgs).toContain("PROMPT pi: send 1 annotation — optional message: ");
    expect(fake.sent.length).toBe(2);
  }, TIMEOUT_MS);

  it("sending with zero annotations outside checkpoint mode does not ask and does not send", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "off" });
    const nvim = runNvim(
      repo,
      `
local cv = require("pi")
cv.setup()
vim.ui.input = function(o, cb) vim.notify("PROMPT " .. o.prompt); cb("") end
cv.send()
`,
    );
    await until(() => nvim.notifications().some((n) => n.msg === "pi: no annotations to send"), "notice");
    expect(nvim.notifications().some((n) => n.msg.startsWith("PROMPT"))).toBe(false);
    expect(fake.sent).toEqual([]);
  }, TIMEOUT_MS);

  it("sending in checkpoint mode with an open chunk says review of chunk N with M annotations", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    await agentWrite(fake, repo, "a.txt", "one\ntwo\n");
    const pending = fake.callTool("checkpoint", { note: "add a" });
    await chunkOpen(fake);
    const nvim = runNvim(
      repo,
      `
local cv = require("pi")
cv.setup()
vim.cmd("edit a.txt")
vim.ui.input = function(o, cb) vim.notify("PROMPT " .. o.prompt); cb("") end
cv.open_chunk(1)
vim.wait(5000, function() return #vim.api.nvim_list_tabpages() == 2 end)
local buf = vim.fn.bufnr(vim.uv.fs_realpath("a.txt"))
cv.annotate(buf, 1, 1, "why one?")
cv.send()
`,
    );
    await settled(pending, 100);
    await until(() => nvim.notifications().some((n) => n.msg.includes("sent with")), "sent");
    const msgs = nvim.notifications().map((n) => n.msg);
    expect(msgs).toContain("PROMPT pi: review of chunk 1 with 1 annotation — optional message: ");
    expect(msgs).toContain("pi: review of chunk 1 sent with 1 annotation");
    expect(text(await pending)).toContain("why one?");
  }, TIMEOUT_MS);

  it("an annotation added just before quitting is saved as a draft and restored by the next nvim", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    await agentWrite(fake, repo, "a.txt", "one\ntwo\n");

    const first = runNvim(
      repo,
      `
local cv = require("pi")
cv.setup()
vim.cmd("edit a.txt")
cv.annotate(vim.api.nvim_get_current_buf(), 2, 2, "draft survives quit")
vim.wait(5000, function() return require("pi.session").connected() end)
vim.cmd("qa!")
`,
    );
    await first.exited;

    const second = runNvim(
      repo,
      `
local cv = require("pi")
cv.setup()
vim.cmd("edit a.txt")
require("pi.session").ensure(function(_, root)
  vim.notify("DRAFTS " .. vim.json.encode(require("pi.annotations").list(root)))
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
    await chunkOpen(fake);

    const nvim = runNvim(
      repo,
      `
local cv = require("pi")
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
    expect(msgs).toContain("OPEN pi: next file in chunk");
    // Only the mapping checks matter here; a "chunk N ready" notice can race in on slow machines.
    expect(msgs.filter((m) => m.startsWith("CLOSED") || m.startsWith("SCRIPT"))).toEqual(["CLOSED vim.empty_dict()"]);
  }, TIMEOUT_MS);

  it("a save before any pi command attaches quietly and is recorded as Philipp's step", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    await agentWrite(fake, repo, "a.txt", "one\n");

    const nvim = runNvim(
      repo,
      `
require("pi").setup()
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
require("pi").setup()
vim.cmd("edit README.md")
require("pi.session").ensure(function(_, root)
  vim.notify("ATTACHED " .. require("pi.session").cached.sessionId .. " " .. root)
end)
`,
    );
    const attached = await until(() => nvim.notifications().find((n) => n.msg.startsWith("ATTACHED") || n.level === ERROR), "attach");
    expect(attached.msg).toBe(`ATTACHED main ${repo.root}`);

    const wtNvim = runNvim(
      repo,
      `
require("pi").setup()
vim.cmd("edit README.md")
require("pi.session").ensure(function(_, root)
  vim.notify("ATTACHED " .. require("pi.session").cached.sessionId .. " " .. root)
end)
`,
      other,
    );
    const wtAttached = await until(() => wtNvim.notifications().find((n) => n.msg.startsWith("ATTACHED") || n.level === ERROR), "attach in worktree");
    expect(wtAttached.msg).toBe(`ATTACHED other ${other}`);
    expect(inOther.sent).toEqual([]);
  }, TIMEOUT_MS);

  it("a command from a buffer in another worktree switches to that worktree's session", async () => {
    const repo = await makeRepo();
    const other = path.join(fs.realpathSync(scratchDir), "wt2");
    await repo.git("worktree", "add", "-q", other, "-b", "other2");
    await start(repo, { root: other, sessionId: "other" });
    await new Promise((r) => setTimeout(r, 20));
    await start(repo, { sessionId: "main" });

    const nvim = runNvim(
      repo,
      `
local session = require("pi.session")
require("pi").setup()
vim.cmd("edit README.md")
session.ensure(function()
  vim.notify("FIRST " .. session.cached.sessionId)
  vim.cmd("edit ${other}/README.md")
  session.ensure(function(_, root)
    vim.notify("SECOND " .. session.cached.sessionId .. " " .. root)
  end)
end)
`,
    );
    const second = await until(() => nvim.notifications().find((n) => n.msg.startsWith("SECOND") || n.level === ERROR), "switch");
    expect(nvim.notifications().map((n) => n.msg)).toContain("FIRST main");
    expect(second.msg).toBe(`SECOND other ${other}`);
    // Switching on purpose drops the old session quietly: no disconnect warning.
    expect(nvim.notifications().some((n) => n.msg.includes("disconnected"))).toBe(false);
  }, TIMEOUT_MS);

  it(":PiSession lists sessions by name and attaches to the chosen one", async () => {
    const repo = await makeRepo();
    await start(repo, { sessionId: "aaaa1111-x", sessionName: "refactor", mode: "off" });
    await new Promise((r) => setTimeout(r, 20));
    await start(repo, { sessionId: "bbbb2222-y", sessionName: "bugfix", mode: "off" });

    const nvim = runNvim(
      repo,
      `
local cv = require("pi")
local session = require("pi.session")
cv.setup()
vim.cmd("edit README.md")
vim.ui.select = function(items, opts, on_choice)
  local labels = {}
  for _, item in ipairs(items) do labels[#labels + 1] = opts.format_item(item) end
  table.sort(labels)
  vim.notify("LABELS " .. table.concat(labels, " | "))
  for _, item in ipairs(items) do
    if item.status.name == "bugfix" then return on_choice(item) end
  end
end
cv.attach()
vim.wait(5000, function() return session.cached ~= nil end)
vim.notify("ATTACHED " .. cv.session_label() .. " " .. session.cached.sessionId)
`,
    );
    const attached = await until(() => nvim.notifications().find((n) => n.msg.startsWith("ATTACHED") || n.level === ERROR), "attach");
    const labels = nvim.notifications().find((n) => n.msg.startsWith("LABELS"))!.msg;
    expect(labels).toContain("bugfix  [idle]");
    expect(labels).toContain("refactor  [idle]");
    expect(labels).not.toContain("aaaa1111-x");
    expect(attached.msg).toBe("ATTACHED bugfix bbbb2222-y");
  }, TIMEOUT_MS);

  it("statusline follows the agent's activity", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { sessionName: "work", mode: "off" });
    fake.setIdle(false);
    const nvim = runNvim(
      repo,
      `
local cv = require("pi")
cv.setup()
vim.cmd("edit README.md")
require("pi.session").ensure(function() end)
vim.wait(5000, function() return cv.statusline() ~= "" end)
vim.notify("S0 " .. cv.statusline())
local last = ""
vim.wait(15000, function()
  local now = cv.statusline()
  if now ~= last then
    last = now
    vim.notify("S " .. now)
  end
  return false
end, 5)
`,
    );
    await until(() => nvim.notifications().some((n) => n.msg.startsWith("S0")), "attached");
    await fake.fire("tool_execution_start", { toolCallId: "t1", toolName: "edit", args: { path: "a.ts" } });
    await until(() => nvim.notifications().some((n) => n.msg === "S pi: work · working · edit a.ts"), "working · edit a.ts");
    await fake.fire("tool_execution_end", { toolCallId: "t1", toolName: "edit", result: {}, isError: false });
    await until(() => nvim.notifications().some((n) => n.msg === "S pi: work · working"), "working");
    fake.setIdle(true);
    await fake.fire("agent_settled", { aborted: false });
    await until(() => nvim.notifications().some((n) => n.msg === "S pi: work · idle"), "idle");
  }, TIMEOUT_MS);

  it("run_settled gives one notice: files changed, cancelled, or the waiting chunk", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "off" });
    const nvim = runNvim(
      repo,
      `
local cv = require("pi")
cv.setup()
vim.cmd("edit README.md")
require("pi.session").ensure(function() vim.notify("ATTACHED") end)
vim.wait(15000, function() return false end, 20)
`,
    );
    const has = (msg: string) => nvim.notifications().some((n) => n.msg === msg);
    await until(() => has("ATTACHED"), "attached");
    await fake.fire("agent_start", {});
    await agentWrite(fake, repo, "a.txt", "one\n");
    await agentWrite(fake, repo, "b.txt", "two\n");
    await fake.fire("turn_end", { turnIndex: 0 });
    await fake.fire("agent_settled", { aborted: false });
    await until(() => has("pi: done — 2 files changed"), "done notice");
    await fake.fire("agent_settled", { aborted: true });
    await until(() => has("pi: cancelled"), "cancelled notice");
  }, TIMEOUT_MS);

  it("run_settled with a chunk open names the chunk and the keys", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    const nvim = runNvim(
      repo,
      `
local cv = require("pi")
cv.setup()
vim.cmd("edit README.md")
require("pi.session").ensure(function() vim.notify("ATTACHED") end)
local announced = false
local session = require("pi.session")
vim.wait(15000, function()
  session.refresh_status()
  if not announced and session.cached and type(session.cached.openChunk) == "table" then
    announced = true
    vim.notify("CHUNK_OPEN")
  end
  return false
end, 20)
`,
    );
    await until(() => nvim.notifications().some((n) => n.msg === "ATTACHED"), "attached");
    await agentWrite(fake, repo, "a.txt", "one\n");
    void fake.callTool("checkpoint", { note: "add a" });
    await chunkOpen(fake);
    await until(() => nvim.notifications().some((n) => n.msg === "CHUNK_OPEN"), "chunk open");
    await fake.fire("agent_settled", { aborted: false });
    await until(
      () => nvim.notifications().some((n) => n.msg === "pi: chunk 1 waiting for your review — <leader>pv to look, <leader>pr to continue"),
      "waiting notice",
    );
  }, TIMEOUT_MS);

  it("<leader>pm toggles checkpoint mode before any other command, says which mode is on and shows it in the statusline", async () => {
    const repo = await makeRepo();
    await start(repo, { sessionName: "work", mode: "off" });
    const nvim = runNvim(
      repo,
      `
local cv = require("pi")
vim.g.mapleader = " "
cv.setup()
vim.cmd("edit README.md")
vim.notify("KEY " .. vim.fn.maparg("<leader>pm", "n", false, true).desc)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>pm", true, false, true), "mx", false)
vim.wait(5000, function() return cv.statusline():find("%[checkpoints%]") ~= nil end)
vim.notify("S1 " .. cv.statusline())
vim.cmd("PiCheckpoints off")
vim.wait(5000, function() return cv.statusline() ~= "" and cv.statusline():find("%[checkpoints%]") == nil end)
vim.notify("S2 " .. cv.statusline())
`,
    );
    await until(() => nvim.notifications().some((n) => n.msg.startsWith("S2") || n.level === ERROR), "two toggles");
    const msgs = nvim.notifications().map((n) => n.msg);
    expect(msgs).toContain("KEY pi: toggle checkpoint mode");
    expect(msgs).toContain("pi: checkpoint mode on — the agent stops at each checkpoint for your review");
    expect(msgs).toContain("S1 pi: work [checkpoints] · idle");
    expect(msgs).toContain("pi: checkpoint mode off");
    expect(msgs).toContain("S2 pi: work · idle");
    expect((await repo.git("config", "pi-nvim.checkpoints")).trim()).toBe("false");
  }, TIMEOUT_MS);

  it("the agent's write shows in an open buffer with change marks", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "off" });
    repo.write("a.txt", "one\n");
    await repo.git("add", ".");
    await repo.git("commit", "-q", "-m", "add a");
    const nvim = runNvim(
      repo,
      `
require("pi").setup()
vim.cmd("edit a.txt")
require("pi.session").ensure(function() end)
vim.wait(5000, function() return require("pi.session").connected() end)
vim.notify("READY")
vim.wait(15000, function()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local marks = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("pi_live"), 0, -1, {})
  if #marks > 0 then
    vim.notify("LIVE " .. table.concat(lines, "|") .. " " .. #marks)
    return true
  end
end, 20)
`,
    );
    await until(() => nvim.notifications().some((n) => n.msg === "READY"), "attached");
    await agentWrite(fake, repo, "a.txt", "one\ntwo\n");
    await fake.fire("tool_execution_end", { toolCallId: "t1", toolName: "write", result: {}, isError: false });
    const note = await until(() => nvim.notifications().find((n) => n.msg.startsWith("LIVE")), "live marks");
    expect(note.msg).toBe("LIVE one|two 2");
  }, TIMEOUT_MS);

  it("marks stay when the chunk opens for review and clear after send", async () => {
    const repo = await makeRepo();
    repo.write("a.txt", "one\n");
    await repo.git("add", ".");
    await repo.git("commit", "-q", "-m", "add a");
    const fake = await start(repo);
    const nvim = runNvim(
      repo,
      `
local cv = require("pi")
cv.setup()
vim.cmd("edit a.txt")
local buf = vim.api.nvim_get_current_buf()
local ns = vim.api.nvim_create_namespace("pi_live")
local function count() return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) end
require("pi.session").ensure(function() end)
vim.wait(5000, function() return require("pi.session").connected() end)
vim.notify("READY")
vim.wait(15000, function() return count() == 1 end, 20)
vim.notify("WRITTEN " .. count())
vim.wait(15000, function() return require("pi.panel").visible() end, 20)
vim.wait(1500, function() return count() ~= 1 end, 20)
vim.notify("OPEN " .. count())
cv.send({ note = "ok" })
vim.wait(5000, function() return count() == 0 end, 20)
vim.notify("SENT " .. count())
`,
    );
    await until(() => nvim.notifications().some((n) => n.msg === "READY"), "attached");
    await agentWrite(fake, repo, "a.txt", "one\ntwo\n");
    await fake.fire("tool_execution_end", { toolCallId: "t1", toolName: "write", result: {}, isError: false });
    await until(() => nvim.notifications().some((n) => n.msg.startsWith("WRITTEN")), "marks after the write");
    const pending = fake.callTool("checkpoint", { note: "add two" });
    await chunkOpen(fake);
    expect(text(await pending)).toContain('Review of chunk 1 ("add two")');
    await until(() => nvim.notifications().some((n) => n.msg.startsWith("SENT")), "sent");
    const notes = nvim.notifications().map((n) => n.msg);
    expect(notes).toContain("WRITTEN 1");
    expect(notes).toContain("OPEN 1");
    expect(notes).toContain("SENT 0");
  }, TIMEOUT_MS);

  it("marks show on attach and in a buffer opened after attach, without a tool event", async () => {
    const repo = await makeRepo();
    repo.write("a.txt", "one\n");
    repo.write("b.txt", "bee\n");
    await repo.git("add", ".");
    await repo.git("commit", "-q", "-m", "add a and b");
    const fake = await start(repo);
    await agentWrite(fake, repo, "a.txt", "one\ntwo\n");
    await agentWrite(fake, repo, "b.txt", "bee\nsting\n");
    const nvim = runNvim(
      repo,
      `
require("pi").setup()
local ns = vim.api.nvim_create_namespace("pi_live")
local function count(buf) return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) end
vim.cmd("edit a.txt")
local a = vim.api.nvim_get_current_buf()
require("pi.session").ensure(function() end)
vim.wait(5000, function() return count(a) > 0 end, 20)
vim.notify("ATTACHED " .. count(a))
vim.cmd("edit b.txt")
local b = vim.api.nvim_get_current_buf()
vim.wait(5000, function() return count(b) > 0 end, 20)
vim.notify("OPENED " .. count(b))
`,
    );
    const opened = await until(() => nvim.notifications().find((n) => n.msg.startsWith("OPENED")), "opened");
    expect(nvim.notifications().map((n) => n.msg)).toContain("ATTACHED 1");
    expect(opened.msg).toBe("OPENED 1");
  }, TIMEOUT_MS);

  it("activity_current for a read-only tool reloads nothing", async () => {
    const repo = await makeRepo();
    repo.write("a.txt", "one\n");
    await repo.git("add", ".");
    await repo.git("commit", "-q", "-m", "add a");
    const fake = await start(repo, { mode: "off" });
    const nvim = runNvim(
      repo,
      `
require("pi").setup()
vim.cmd("edit a.txt")
require("pi.session").ensure(function() end)
vim.wait(5000, function() return require("pi.session").connected() end)
vim.wait(500)
vim.notify("READY")
vim.wait(1500, function() return false end, 20)
vim.notify("DONE " .. table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|"))
`,
    );
    await until(() => nvim.notifications().some((n) => n.msg === "READY"), "attached");
    await new Promise((r) => setTimeout(r, 1100));
    repo.write("a.txt", "one\ntwo\n");
    await fake.fire("tool_execution_end", { toolCallId: "r1", toolName: "read", result: {}, isError: false });
    const done = await until(() => nvim.notifications().find((n) => n.msg.startsWith("DONE")), "done");
    expect(done.msg).toBe("DONE one");
  }, TIMEOUT_MS);

  it("tool start, agent_start and agent_settled reload nothing; a mutating tool end does", async () => {
    const repo = await makeRepo();
    repo.write("a.txt", "one\n");
    await repo.git("add", ".");
    await repo.git("commit", "-q", "-m", "add a");
    const fake = await start(repo, { mode: "off" });
    const nvim = runNvim(
      repo,
      `
require("pi").setup()
vim.cmd("edit a.txt")
require("pi.session").ensure(function() end)
vim.wait(5000, function() return require("pi.session").connected() end)
vim.wait(500)
vim.notify("READY")
vim.wait(1500, function() return false end, 20)
vim.notify("BEFORE " .. table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|"))
vim.wait(15000, function() return #vim.api.nvim_buf_get_lines(0, 0, -1, false) == 2 end, 20)
vim.notify("AFTER " .. table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|"))
`,
    );
    await until(() => nvim.notifications().some((n) => n.msg === "READY"), "attached");
    await new Promise((r) => setTimeout(r, 1100));
    repo.write("a.txt", "one\ntwo\n");
    await fake.fire("agent_start", {});
    await fake.fire("tool_execution_start", { toolCallId: "w1", toolName: "write", args: { path: "a.txt" } });
    await fake.fire("agent_settled", { aborted: false });
    const before = await until(() => nvim.notifications().find((n) => n.msg.startsWith("BEFORE")), "before");
    expect(before.msg).toBe("BEFORE one");
    await fake.fire("tool_execution_end", { toolCallId: "w1", toolName: "write", result: {}, isError: false });
    const after = await until(() => nvim.notifications().find((n) => n.msg.startsWith("AFTER")), "after");
    expect(after.msg).toBe("AFTER one|two");
  }, TIMEOUT_MS);

  it("an unsaved buffer keeps its edit and warns once when the agent changes the file", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "off" });
    repo.write("a.txt", "one\n");
    await repo.git("add", ".");
    await repo.git("commit", "-q", "-m", "add a");
    const nvim = runNvim(
      repo,
      `
require("pi").setup()
vim.cmd("edit a.txt")
vim.api.nvim_buf_set_lines(0, 0, 1, false, { "mine" })
require("pi.session").ensure(function() end)
vim.wait(5000, function() return require("pi.session").connected() end)
vim.notify("READY")
vim.wait(1500, function() return false end, 20)
vim.notify("DONE " .. vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
`,
    );
    await until(() => nvim.notifications().some((n) => n.msg === "READY"), "attached");
    await new Promise((r) => setTimeout(r, 1100));
    await agentWrite(fake, repo, "a.txt", "agent\n");
    await fake.fire("tool_execution_end", { toolCallId: "t1", toolName: "write", result: {}, isError: false });
    await fake.fire("tool_execution_end", { toolCallId: "t2", toolName: "write", result: {}, isError: false });
    await until(() => nvim.notifications().some((n) => n.msg.startsWith("DONE")), "done");
    const notes = nvim.notifications().map((n) => n.msg);
    expect(notes).toContain("DONE mine");
    expect(notes.filter((m) => m === "pi: a.txt changed on disk; your unsaved edits are kept")).toHaveLength(1);
  }, TIMEOUT_MS);

  it("saving a file stores the drafts' moved positions", async () => {
    const repo = await makeRepo();
    const fake = await start(repo);
    repo.write("b.txt", "one\ntwo\n");
    await agentWrite(fake, repo, "a.txt", "x\n");

    runNvim(
      repo,
      `
local cv = require("pi")
cv.setup()
vim.cmd("edit b.txt")
cv.annotate(vim.api.nvim_get_current_buf(), 2, 2, "moves")
vim.wait(5000, function() return require("pi.session").connected() end)
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

  it("a prompt from nvim carries the buffer's diagnostics into the agent's message", async () => {
    const repo = await makeRepo();
    const fake = await start(repo, { mode: "off" });
    repo.write("a.txt", "one\ntwo\nthree\n");
    await repo.git("add", ".");
    await repo.git("commit", "-q", "-m", "add a");
    const nvim = runNvim(
      repo,
      `
local cv = require("pi")
cv.setup()
vim.cmd("edit a.txt")
local buf = vim.api.nvim_get_current_buf()
vim.diagnostic.set(vim.api.nvim_create_namespace("e2e"), buf, {
  { lnum = 1, col = 0, severity = vim.diagnostic.severity.ERROR, message = "bad\\nthing", source = "lsp" },
  { lnum = 2, col = 0, severity = vim.diagnostic.severity.HINT, message = "just a hint" },
})
require("pi.session").ensure(function(_, root)
  cv.prompt("fix it", cv.prompt_context(buf, root, { line1 = 1, line2 = 1 }))
  vim.notify("PROMPTED")
end, { buf = buf })
vim.wait(5000, function() return false end, 20)
`,
    );
    await until(() => nvim.notifications().some((n) => n.msg === "PROMPTED"), "prompted");
    const sent = await until(() => fake.sent.find((s) => s.kind === "user"), "user message");
    const content = String(sent.kind === "user" && sent.content);
    expect(content).toContain("Diagnostics:\n  a.txt:2 error bad thing [lsp]");
    expect(content).not.toContain("just a hint");
  }, TIMEOUT_MS);
});
