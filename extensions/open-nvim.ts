import { execFile } from "node:child_process";
import * as fs from "node:fs";
import * as net from "node:net";
import * as path from "node:path";

/** How long one running nvim may take to answer `review()`. */
const REMOTE_EXPR_TIMEOUT_MS = 2000;
const LIVE_PROBE_TIMEOUT_MS = 300;
const HERDR_TIMEOUT_MS = 5000;

export type RunResult = { code: number; stdout: string };

/** Runs external commands; tests replace `run` so no real nvim or herdr pane is started. */
export const processRunner = {
  run(cmd: string, args: string[], timeoutMs = REMOTE_EXPR_TIMEOUT_MS): Promise<RunResult> {
    return new Promise((resolve) => {
      execFile(cmd, args, { timeout: timeoutMs, encoding: "utf8" }, (err, stdout) => {
        const code = err ? (typeof err.code === "number" ? err.code : 1) : 0;
        resolve({ code, stdout: stdout ?? "" });
      });
    });
  },
};

/** Where the checkpoint was opened: a running nvim, a new herdr pane, or nowhere (Philipp gets a hint). */
export type OpenedIn = "nvim" | "herdr" | "hint";

function isLiveSocket(sockPath: string): Promise<boolean> {
  return new Promise((resolve) => {
    const sock = net.connect(sockPath);
    const finish = (live: boolean) => {
      clearTimeout(timer);
      sock.destroy();
      resolve(live);
    };
    const timer = setTimeout(() => finish(false), LIVE_PROBE_TIMEOUT_MS);
    sock.once("connect", () => finish(true));
    sock.once("error", () => finish(false));
  });
}

/** `$NVIM` first, then the `nvim.*` server sockets in `runtimeDir`, newest first. */
function nvimSockets(runtimeDir: string | undefined, env: NodeJS.ProcessEnv): string[] {
  const found: { path: string; mtime: number }[] = [];
  if (runtimeDir && fs.existsSync(runtimeDir)) {
    for (const name of fs.readdirSync(runtimeDir)) {
      if (!name.startsWith("nvim.")) continue;
      const full = path.join(runtimeDir, name);
      try {
        found.push({ path: full, mtime: fs.statSync(full).mtimeMs });
      } catch {
        // Gone between readdir and stat.
      }
    }
  }
  found.sort((a, b) => b.mtime - a.mtime);
  const sockets = found.map((f) => f.path);
  return env.NVIM ? [env.NVIM, ...sockets.filter((s) => s !== env.NVIM)] : sockets;
}

function luaCall(root: string, sessionId: string): string {
  return `lua require("pi").review(${JSON.stringify(root)}, ${JSON.stringify(sessionId)})`;
}

function shellQuote(s: string): string {
  return `'${s.replaceAll("'", `'\\''`)}'`;
}

/** Asks each running nvim in turn to open the checkpoint list; the first that answers "ok" (its cwd or buffer is in root) wins. */
async function askRunningNvim(root: string, sessionId: string, runtimeDir: string | undefined, env: NodeJS.ProcessEnv): Promise<boolean> {
  const expr = `luaeval('require("pi").review(_A[1], _A[2])', [${JSON.stringify(root)}, ${JSON.stringify(sessionId)}])`;
  for (const sock of nvimSockets(runtimeDir, env)) {
    if (!(await isLiveSocket(sock))) continue;
    const { code, stdout } = await processRunner.run("nvim", ["--server", sock, "--remote-expr", expr]);
    if (code === 0 && stdout.trim() === "ok") return true;
  }
  return false;
}

/** Splits a herdr pane to the right of pi's pane, in root, and starts nvim there with the review call. */
async function openHerdrPane(root: string, sessionId: string, paneId: string): Promise<boolean> {
  const split = await processRunner.run("herdr", ["pane", "split", paneId, "--direction", "right", "--cwd", root, "--focus"], HERDR_TIMEOUT_MS);
  if (split.code !== 0) return false;
  let newPane: unknown;
  try {
    newPane = (JSON.parse(split.stdout) as { result?: { pane?: { pane_id?: unknown } } }).result?.pane?.pane_id;
  } catch {
    return false;
  }
  if (typeof newPane !== "string") return false;
  const run = await processRunner.run("herdr", ["pane", "run", newPane, `nvim -c ${shellQuote(luaCall(root, sessionId))}`], HERDR_TIMEOUT_MS);
  return run.code === 0;
}

/** Opens the checkpoint list for this session in Neovim: a running nvim in root, else a new herdr pane, else nowhere. */
export async function openInNeovim(opts: {
  root: string;
  sessionId: string;
  runtimeDir: string | undefined;
  env?: NodeJS.ProcessEnv;
}): Promise<OpenedIn> {
  const env = opts.env ?? process.env;
  if (await askRunningNvim(opts.root, opts.sessionId, opts.runtimeDir, env)) return "nvim";
  if (env.HERDR_PANE_ID && (await openHerdrPane(opts.root, opts.sessionId, env.HERDR_PANE_ID))) return "herdr";
  return "hint";
}
