import { execFile } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export interface TestRepo {
  root: string;
  write(path: string, text: string): void;
  rm(path: string): void;
  git(...args: string[]): Promise<string>;
  /**
   * Adds another worktree of this repo on a new branch: at `at` (relative to this root, e.g. a nested
   * `.worktrees/x`, excluded from this worktree's snapshots like superpowers does), else in a fresh temp dir.
   */
  worktree(at?: string): Promise<TestRepo>;
}

let worktreeSeq = 0;

function repoAt(root: string): TestRepo {
  const git = async (...args: string[]) => {
    const { stdout } = await execFileAsync("git", args, { cwd: root });
    return stdout;
  };
  const repo: TestRepo = {
    root,
    write(path, text) {
      const full = join(root, path);
      mkdirSync(dirname(full), { recursive: true });
      writeFileSync(full, text);
    },
    rm(path) {
      rmSync(join(root, path), { force: true });
    },
    git,
    async worktree(at) {
      let dir: string;
      if (at) {
        dir = join(root, at);
        const exclude = join(root, (await git("rev-parse", "--git-path", "info/exclude")).trim());
        mkdirSync(dirname(exclude), { recursive: true });
        writeFileSync(exclude, `/${at.split("/")[0]}/\n`, { flag: "a" });
      } else {
        dir = join(realpathSync(mkdtempSync(join(tmpdir(), "pi-nvim-wt-"))), "wt");
      }
      await git("worktree", "add", "-q", "-b", `wt-${process.pid}-${worktreeSeq++}`, dir);
      return repoAt(realpathSync(dir));
    },
  };
  return repo;
}

export async function makeRepo(opts: { commit?: boolean } = {}): Promise<TestRepo> {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "pi-nvim-repo-")));
  const repo = repoAt(root);
  await repo.git("init", "-q");
  await repo.git("config", "user.name", "Test");
  await repo.git("config", "user.email", "test@example.com");
  await repo.git("config", "commit.gpgsign", "false");
  if (opts.commit ?? true) {
    repo.write("README.md", "hello\n");
    await repo.git("add", "-A");
    await repo.git("commit", "-q", "-m", "init");
  }
  return repo;
}
