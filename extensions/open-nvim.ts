import { execFile } from "node:child_process";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";

/** How long one running nvim may take to answer `review()`. */
const REMOTE_EXPR_TIMEOUT_MS = 2000;
const LIVE_PROBE_TIMEOUT_MS = 300;
const HERDR_TIMEOUT_MS = 5000;
const PANE_TIMEOUT_MS = 5000;

/** Working directory and extra environment variables for one command. */
export type RunOptions = { cwd?: string; env?: Record<string, string> };

/** `reason` is set when the program was not found or was killed for running past the timeout. */
export type RunResult = { code: number; stdout: string; reason?: "missing" | "timeout" };

/** Runs external commands; tests replace `run` so no real nvim or herdr pane is started. */
export const processRunner = {
  run(cmd: string, args: string[], timeoutMs = REMOTE_EXPR_TIMEOUT_MS, options: RunOptions = {}): Promise<RunResult> {
    return new Promise((resolve) => {
      const env = options.env ? { ...process.env, ...options.env } : undefined;
      execFile(cmd, args, { timeout: timeoutMs, encoding: "utf8", cwd: options.cwd, env }, (err, stdout) => {
        const code = err ? (typeof err.code === "number" ? err.code : 1) : 0;
        const reason = err?.code === "ENOENT" ? "missing" : err?.killed ? "timeout" : undefined;
        resolve({ code, stdout: stdout ?? "", ...(reason && { reason }) });
      });
    });
  },
};

/**
 * Where the checkpoint was opened: a running nvim, a new pane of a terminal multiplexer, the user's own
 * `pi-nvim.openCommand`, or nowhere (Philipp gets a hint; `commandFailure` is set when openCommand failed).
 */
export type CommandFailure = { program: string; exit: number; reason?: "missing" | "timeout" };

export type OpenedIn =
  | { opened: "nvim" }
  | { opened: "pane"; tool: "herdr" | "tmux" | "zellij" }
  | { opened: "command" }
  | { opened: "hint"; commandFailure?: CommandFailure };

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

/** The `nvim.*` entries of dir with their mtimes; none when dir does not exist. */
function socketsIn(dir: string): { path: string; mtime: number }[] {
  const found: { path: string; mtime: number }[] = [];
  let names: string[];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return found;
  }
  for (const name of names) {
    if (!name.startsWith("nvim.")) continue;
    const full = path.join(dir, name);
    try {
      found.push({ path: full, mtime: fs.statSync(full).mtimeMs });
    } catch {
      // Gone between readdir and stat.
    }
  }
  return found;
}

/** The login name, or undefined when the uid has no passwd entry and $USER is unset. */
function currentUserName(): string | undefined {
  try {
    return os.userInfo().username;
  } catch {
    return process.env.USER || undefined;
  }
}

/**
 * Where nvim puts its server sockets: `runtimeDir` ($XDG_RUNTIME_DIR), else one directory per nvim
 * under `<tmpdir>/nvim.<user>/`.
 */
function socketDirs(runtimeDir: string | undefined): string[] {
  if (runtimeDir) return [runtimeDir];
  const user = currentUserName();
  if (!user) return [];
  const base = path.join(os.tmpdir(), `nvim.${user}`);
  try {
    return fs.readdirSync(base).map((name) => path.join(base, name));
  } catch {
    return [];
  }
}

/** `$NVIM` first, then the `nvim.*` server sockets nvim creates by default, newest first. */
function nvimSockets(runtimeDir: string | undefined, env: NodeJS.ProcessEnv): string[] {
  const found = socketDirs(runtimeDir).flatMap(socketsIn);
  found.sort((a, b) => b.mtime - a.mtime);
  const sockets = found.map((f) => f.path);
  return env.NVIM ? [env.NVIM, ...sockets.filter((s) => s !== env.NVIM)] : sockets;
}

const NVIM_REVIEW_LUA = "lua require('pi').review(vim.env.PI_NVIM_ROOT, vim.env.PI_NVIM_SESSION)";
/** The nvim command line as argv; root and session come from PI_NVIM_ROOT / PI_NVIM_SESSION. */
const NVIM_ARGV = ["nvim", "-c", NVIM_REVIEW_LUA];

/**
 * The command typed into the new pane's shell. Root and session come from the pane's environment, so
 * nothing in it depends on their characters or on the shell's quoting rules (fish, bash, zsh).
 */
const HERDR_NVIM_COMMAND = `nvim -c "${NVIM_REVIEW_LUA}"`;

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
  const split = await processRunner.run(
    "herdr",
    ["pane", "split", paneId, "--direction", "right", "--cwd", root, "--env", `PI_NVIM_ROOT=${root}`, "--env", `PI_NVIM_SESSION=${sessionId}`, "--focus"],
    HERDR_TIMEOUT_MS,
  );
  if (split.code !== 0) return false;
  let newPane: unknown;
  try {
    newPane = (JSON.parse(split.stdout) as { result?: { pane?: { pane_id?: unknown } } }).result?.pane?.pane_id;
  } catch {
    return false;
  }
  if (typeof newPane !== "string") return false;
  const run = await processRunner.run("herdr", ["pane", "run", newPane, HERDR_NVIM_COMMAND], HERDR_TIMEOUT_MS);
  return run.code === 0;
}

/** Splits a tmux pane next to pi's (the `-t` target, when known), in root; tmux runs the argv directly, without a shell. */
async function openTmuxPane(root: string, sessionId: string, paneId: string | undefined): Promise<boolean> {
  const target = paneId ? ["-t", paneId] : [];
  const split = await processRunner.run(
    "tmux",
    ["split-window", "-h", "-c", root, "-e", `PI_NVIM_ROOT=${root}`, "-e", `PI_NVIM_SESSION=${sessionId}`, ...target, ...NVIM_ARGV],
    PANE_TIMEOUT_MS,
  );
  return split.code === 0;
}

/** `zellij run` has no environment flag, so the variables go through env(1). */
async function openZellijPane(root: string, sessionId: string): Promise<boolean> {
  const run = await processRunner.run(
    "zellij",
    ["run", "--direction", "right", "--cwd", root, "--", "env", `PI_NVIM_ROOT=${root}`, `PI_NVIM_SESSION=${sessionId}`, ...NVIM_ARGV],
    PANE_TIMEOUT_MS,
  );
  return run.code === 0;
}

/**
 * Runs `pi-nvim.openCommand`: split on whitespace (no quoting, no shell), `{root}` and `{session}`
 * substituted inside arguments, `{nvim}` expanded to the separate arguments of the nvim command.
 * Returns null on success, else how it failed.
 */
async function runOpenCommand(command: string, root: string, sessionId: string): Promise<CommandFailure | null> {
  const argv = command
    .split(/\s+/)
    .filter(Boolean)
    .flatMap((arg) => (arg === "{nvim}" ? NVIM_ARGV : [arg.replaceAll("{root}", root).replaceAll("{session}", sessionId)]));
  const { code, reason } = await processRunner.run(argv[0], argv.slice(1), PANE_TIMEOUT_MS, {
    cwd: root,
    env: { PI_NVIM_ROOT: root, PI_NVIM_SESSION: sessionId },
  });
  return code === 0 ? null : { program: argv[0], exit: code, ...(reason && { reason }) };
}

/**
 * Opens the checkpoint list for this session in Neovim: a running nvim in root, else `openCommand`
 * (alone: when it fails the built-ins are not tried), else a new herdr, tmux or zellij pane, else nowhere.
 */
export async function openInNeovim(opts: {
  root: string;
  sessionId: string;
  runtimeDir: string | undefined;
  openCommand?: string | null;
  env?: NodeJS.ProcessEnv;
}): Promise<OpenedIn> {
  const env = opts.env ?? process.env;
  if (await askRunningNvim(opts.root, opts.sessionId, opts.runtimeDir, env)) return { opened: "nvim" };
  if (opts.openCommand?.trim()) {
    const commandFailure = await runOpenCommand(opts.openCommand, opts.root, opts.sessionId);
    return commandFailure ? { opened: "hint", commandFailure } : { opened: "command" };
  }
  if (env.HERDR_PANE_ID && (await openHerdrPane(opts.root, opts.sessionId, env.HERDR_PANE_ID))) return { opened: "pane", tool: "herdr" };
  if (env.TMUX && (await openTmuxPane(opts.root, opts.sessionId, env.TMUX_PANE))) return { opened: "pane", tool: "tmux" };
  if (env.ZELLIJ !== undefined && (await openZellijPane(opts.root, opts.sessionId))) return { opened: "pane", tool: "zellij" };
  return { opened: "hint" };
}
