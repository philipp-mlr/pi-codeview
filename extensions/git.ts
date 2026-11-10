import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, mkdtemp, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

export type Mode = "review" | "vibe";

export interface CodeviewConfig {
  mode: Mode;
  cap: number;
  retentionDays: number;
}

const DEFAULT_CAP = 150;
const DEFAULT_RETENTION_DAYS = 14;
const SNAPSHOT_IDENTITY = {
  GIT_AUTHOR_NAME: "pi-codeview",
  GIT_AUTHOR_EMAIL: "pi-codeview@localhost",
  GIT_COMMITTER_NAME: "pi-codeview",
  GIT_COMMITTER_EMAIL: "pi-codeview@localhost",
};

function git(cwd: string, args: string[], env?: NodeJS.ProcessEnv): Promise<string> {
  return new Promise((resolvePromise, reject) => {
    execFile(
      "git",
      args,
      { cwd, env: env ? { ...process.env, ...env } : process.env, maxBuffer: 256 * 1024 * 1024 },
      (error, stdout) => (error ? reject(error) : resolvePromise(stdout)),
    );
  });
}

export async function findRoot(cwd: string): Promise<string | null> {
  try {
    return (await git(cwd, ["rev-parse", "--show-toplevel"])).trim() || null;
  } catch {
    return null;
  }
}

export async function repoHash(root: string): Promise<string> {
  const common = (await git(root, ["rev-parse", "--git-common-dir"])).trim();
  const real = await realpath(resolve(root, common));
  return createHash("sha256").update(real).digest("hex").slice(0, 12);
}

/**
 * Copies the worktree's real index to `dest` so `add -A` reuses its cached stat data instead of
 * rehashing every file. The real index is only read. Without one, `dest` is left absent (empty index).
 */
export async function seedIndex(root: string, dest: string): Promise<void> {
  const index = resolve(root, (await git(root, ["rev-parse", "--git-path", "index"])).trim());
  try {
    await copyFile(index, dest);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
  }
}

export async function snapshot(root: string, ref: string, message: string): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "codeview-index-"));
  try {
    const env = { GIT_INDEX_FILE: join(dir, "index"), ...SNAPSHOT_IDENTITY };
    await seedIndex(root, env.GIT_INDEX_FILE);
    await git(root, ["add", "-A"], env);
    const tree = (await git(root, ["write-tree"], env)).trim();
    const sha = (
      await git(root, ["-c", "commit.gpgsign=false", "commit-tree", tree, "-m", message], env)
    ).trim();
    await git(root, ["update-ref", ref, sha]);
    return sha;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

export async function numstat(
  root: string,
  from: string,
  to: string,
): Promise<{ path: string; lines: number }[]> {
  const out = await git(root, ["diff", "--numstat", "-z", "--no-renames", from, to]);
  const result: { path: string; lines: number }[] = [];
  for (const entry of out.split("\0")) {
    if (!entry) continue;
    const [added, deleted, ...rest] = entry.split("\t");
    const path = rest.join("\t");
    const lines = added === "-" || deleted === "-" ? 0 : Number(added) + Number(deleted);
    result.push({ path, lines });
  }
  return result;
}

export async function diffText(
  root: string,
  from: string,
  to: string,
  paths?: string[],
): Promise<string> {
  const args = ["diff", "--no-renames", "--no-color", from, to];
  if (paths && paths.length > 0) args.push("--", ...paths);
  return git(root, args);
}

export async function showFile(root: string, sha: string, path: string): Promise<string | null> {
  try {
    return await git(root, ["cat-file", "blob", `${sha}:${path}`]);
  } catch {
    return null;
  }
}

export async function pruneRefs(root: string, olderThanDays: number): Promise<number> {
  const out = await git(root, [
    "for-each-ref",
    "--format=%(refname) %(committerdate:unix)",
    "refs/pi-codeview/",
  ]);
  const cutoff = Date.now() / 1000 - olderThanDays * 86400;
  let deleted = 0;
  for (const line of out.split("\n")) {
    if (!line) continue;
    const space = line.lastIndexOf(" ");
    const refName = line.slice(0, space);
    if (Number(line.slice(space + 1)) < cutoff) {
      await git(root, ["update-ref", "-d", refName]);
      deleted++;
    }
  }
  return deleted;
}

async function configValue(root: string, key: string): Promise<string | null> {
  try {
    return (await git(root, ["config", "--get", key])).trim();
  } catch {
    return null;
  }
}

function positiveInt(value: string | null, fallback: number): number {
  if (value === null || !/^\d+$/.test(value)) return fallback;
  const n = Number(value);
  return n > 0 ? n : fallback;
}

export async function readConfig(root: string): Promise<CodeviewConfig> {
  const [mode, cap, retention] = await Promise.all([
    configValue(root, "pi-codeview.mode"),
    configValue(root, "pi-codeview.cap"),
    configValue(root, "pi-codeview.retentionDays"),
  ]);
  return {
    mode: mode === "review" ? "review" : "vibe",
    cap: positiveInt(cap, DEFAULT_CAP),
    retentionDays: positiveInt(retention, DEFAULT_RETENTION_DAYS),
  };
}

export async function writeMode(root: string, mode: Mode): Promise<void> {
  await git(root, ["config", "--local", "pi-codeview.mode", mode]);
}
