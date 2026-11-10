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
}

export async function makeRepo(opts: { commit?: boolean } = {}): Promise<TestRepo> {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "codeview-repo-")));
  const git = async (...args: string[]) => {
    const { stdout } = await execFileAsync("git", args, { cwd: root });
    return stdout;
  };
  await git("init", "-q");
  await git("config", "user.name", "Test");
  await git("config", "user.email", "test@example.com");
  await git("config", "commit.gpgsign", "false");
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
  };
  if (opts.commit ?? true) {
    repo.write("README.md", "hello\n");
    await git("add", "-A");
    await git("commit", "-q", "-m", "init");
  }
  return repo;
}
