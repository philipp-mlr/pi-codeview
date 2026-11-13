import { execFile } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";
import {
  commonDir,
  findRoot,
  numstat,
  pruneRefs,
  readConfig,
  repoHash,
  sameRepoWorktree,
  seedIndex,
  showFile,
  snapshot,
  writeMode,
} from "../extensions/git.ts";
import { makeRepo } from "./helpers/repo.ts";

const execFileAsync = promisify(execFile);

describe("snapshot", () => {
  it("works in a repo with no commits", async () => {
    const r = await makeRepo({ commit: false });
    r.write("a.ts", "const a = 1;\n");
    const sha = await snapshot(r.root, "refs/pi-nvim/s/0", "snap");
    expect(await showFile(r.root, sha, "a.ts")).toBe("const a = 1;\n");
    await expect(r.git("rev-parse", "HEAD")).rejects.toThrow();
  });

  it("leaves branch, index and HEAD untouched", async () => {
    const r = await makeRepo();
    const head = (await r.git("rev-parse", "HEAD")).trim();
    r.write("b.ts", "x\n");
    await r.git("add", "b.ts");
    await snapshot(r.root, "refs/pi-nvim/s/0", "snap");
    expect((await r.git("diff", "--cached", "--name-only")).trim()).toBe("b.ts");
    expect((await r.git("rev-parse", "HEAD")).trim()).toBe(head);
  });

  it("never writes the real index file", async () => {
    const r = await makeRepo();
    r.write("b.ts", "x\n");
    await r.git("add", "b.ts");
    r.write("README.md", "changed\n");
    r.write("c.ts", "c\n");
    const index = join(r.root, ".git", "index");
    const before = readFileSync(index);
    const sha = await snapshot(r.root, "refs/pi-nvim/s/0", "snap");
    expect(readFileSync(index).equals(before)).toBe(true);
    expect(await showFile(r.root, sha, "README.md")).toBe("changed\n");
    expect(await showFile(r.root, sha, "b.ts")).toBe("x\n");
    expect(await showFile(r.root, sha, "c.ts")).toBe("c\n");
  });

  it("seedIndex copies the real index (cached stat data, no rehash) and leaves no file without one", async () => {
    const r = await makeRepo();
    const dest = join(realpathSync(mkdtempSync(join(tmpdir(), "pi-nvim-seed-"))), "index");
    await seedIndex(r.root, dest);
    expect(readFileSync(dest).equals(readFileSync(join(r.root, ".git", "index")))).toBe(true);
    const empty = await makeRepo({ commit: false });
    const dest2 = join(realpathSync(mkdtempSync(join(tmpdir(), "pi-nvim-seed-"))), "index");
    await seedIndex(empty.root, dest2);
    expect(existsSync(dest2)).toBe(false);
  });

  it("snapshot keeps a file removed from the real index but still on disk", async () => {
    const r = await makeRepo();
    r.write("b.ts", "x\n");
    await r.git("add", "b.ts");
    // A path removed from the real index but still on disk is untracked; it stays in the snapshot.
    await r.git("rm", "-q", "--cached", "README.md");
    const sha = await snapshot(r.root, "refs/pi-nvim/s/0", "snap");
    expect(await showFile(r.root, sha, "README.md")).toBe("hello\n");
    expect(await showFile(r.root, sha, "b.ts")).toBe("x\n");
  });

  it("includes untracked and respects .gitignore", async () => {
    const r = await makeRepo();
    r.write(".gitignore", "out/\n");
    r.write("new.ts", "n\n");
    r.write("out/x.js", "x\n");
    const sha = await snapshot(r.root, "refs/pi-nvim/s/0", "snap");
    expect(await showFile(r.root, sha, "new.ts")).toBe("n\n");
    expect(await showFile(r.root, sha, "out/x.js")).toBeNull();
  });
});

describe("numstat", () => {
  it("counts added+deleted, binary as 0, handles spaces and unicode", async () => {
    const r = await makeRepo();
    const a = await snapshot(r.root, "refs/pi-nvim/s/0", "a");
    r.write("my file.ts", "1\n2\n3\n");
    r.write("ä.ts", "x\n");
    writeFileSync(join(r.root, "img.bin"), Buffer.from([0, 1, 2, 0, 255, 0]));
    const b = await snapshot(r.root, "refs/pi-nvim/s/1", "b");
    const stat = await numstat(r.root, a, b);
    const by = Object.fromEntries(stat.map((s) => [s.path, s.lines]));
    expect(by["my file.ts"]).toBe(3);
    expect(by["ä.ts"]).toBe(1);
    expect(by["img.bin"]).toBe(0);
  });

  it("reports deletions", async () => {
    const r = await makeRepo();
    r.write("d.ts", "1\n2\n");
    const a = await snapshot(r.root, "refs/pi-nvim/s/0", "a");
    r.rm("d.ts");
    const b = await snapshot(r.root, "refs/pi-nvim/s/1", "b");
    expect(await numstat(r.root, a, b)).toEqual([{ path: "d.ts", lines: 2 }]);
  });

  it("shows a rename as delete plus add", async () => {
    const r = await makeRepo();
    r.write("old.ts", "1\n2\n");
    const a = await snapshot(r.root, "refs/pi-nvim/s/0", "a");
    r.rm("old.ts");
    r.write("new name.ts", "1\n2\n");
    const b = await snapshot(r.root, "refs/pi-nvim/s/1", "b");
    const stat = await numstat(r.root, a, b);
    expect(stat.map((s) => s.path).sort()).toEqual(["new name.ts", "old.ts"]);
  });
});

describe("findRoot", () => {
  it("from a subdirectory returns the worktree root", async () => {
    const r = await makeRepo();
    r.write("sub/dir/f.ts", "x\n");
    expect(await findRoot(join(r.root, "sub/dir"))).toBe(r.root);
  });

  it("returns null outside a repo", async () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "pi-nvim-norepo-")));
    expect(await findRoot(dir)).toBeNull();
  });
});

describe("repoHash", () => {
  it("is equal for two worktrees of one repo", async () => {
    const r = await makeRepo();
    const wt = join(realpathSync(mkdtempSync(join(tmpdir(), "pi-nvim-wt-"))), "wt");
    await r.git("worktree", "add", "-q", wt, "-b", "other");
    const h1 = await repoHash(r.root);
    expect(h1).toMatch(/^[0-9a-f]{12}$/);
    expect(await repoHash(wt)).toBe(h1);
  });
});

describe("pruneRefs", () => {
  async function oldCommit(r: Awaited<ReturnType<typeof makeRepo>>): Promise<string> {
    const tree = (await r.git("rev-parse", "HEAD^{tree}")).trim();
    const old = new Date(Date.now() - 20 * 86400_000).toISOString();
    const env = { ...process.env, GIT_COMMITTER_DATE: old, GIT_AUTHOR_DATE: old };
    const { stdout } = await execFileAsync("git", ["commit-tree", tree, "-m", "old"], { cwd: r.root, env });
    return stdout.trim();
  }

  it("deletes only old refs", async () => {
    const r = await makeRepo();
    await r.git("update-ref", "refs/pi-nvim/s/0", await oldCommit(r));
    await snapshot(r.root, "refs/pi-nvim/s/1", "new");
    expect(await pruneRefs(r.root, 14)).toBe(1);
    const refs = (await r.git("for-each-ref", "--format=%(refname)", "refs/pi-nvim/")).trim();
    expect(refs).toBe("refs/pi-nvim/s/1");
  });

  it("migration: also prunes old refs left under refs/pi-codeview/", async () => {
    const r = await makeRepo();
    const sha = await oldCommit(r);
    await r.git("update-ref", "refs/pi-codeview/s/0", sha);
    await r.git("update-ref", "refs/pi-nvim/s/0", sha);
    await snapshot(r.root, "refs/pi-codeview/s/1", "new");
    expect(await pruneRefs(r.root, 14)).toBe(2);
    const refs = (await r.git("for-each-ref", "--format=%(refname)", "refs/pi-codeview/", "refs/pi-nvim/")).trim();
    expect(refs).toBe("refs/pi-codeview/s/1");
  });
});

describe("config", () => {
  it("readConfig defaults to off/150/14", async () => {
    const r = await makeRepo();
    expect(await readConfig(r.root)).toEqual({ mode: "off", cap: 150, retentionDays: 14 });
  });

  it("falls back to defaults on invalid values", async () => {
    const r = await makeRepo();
    await r.git("config", "--local", "pi-nvim.checkpoints", "foo");
    await r.git("config", "--local", "pi-nvim.cap", "abc");
    expect(await readConfig(r.root)).toEqual({ mode: "off", cap: 150, retentionDays: 14 });
  });

  it("reads pi-nvim.checkpoints, cap and retentionDays", async () => {
    const r = await makeRepo();
    await r.git("config", "--local", "pi-nvim.checkpoints", "true");
    await r.git("config", "--local", "pi-nvim.cap", "40");
    await r.git("config", "--local", "pi-nvim.retentionDays", "3");
    expect(await readConfig(r.root)).toEqual({ mode: "checkpoints", cap: 40, retentionDays: 3 });
  });

  it("writeMode writes pi-nvim.checkpoints explicitly", async () => {
    const r = await makeRepo();
    await writeMode(r.root, "checkpoints");
    expect((await r.git("config", "--local", "pi-nvim.checkpoints")).trim()).toBe("true");
    expect((await readConfig(r.root)).mode).toBe("checkpoints");
    await writeMode(r.root, "off");
    expect((await r.git("config", "--local", "pi-nvim.checkpoints")).trim()).toBe("false");
    expect((await readConfig(r.root)).mode).toBe("off");
  });
});

describe("config migration from pi-codeview", () => {
  for (const [old, mode] of [["review", "checkpoints"], ["on", "checkpoints"], ["vibe", "off"], ["off", "off"]] as const) {
    it(`unset pi-nvim.checkpoints falls back to pi-codeview.mode=${old} → ${mode}`, async () => {
      const r = await makeRepo();
      await r.git("config", "--local", "pi-codeview.mode", old);
      expect((await readConfig(r.root)).mode).toBe(mode);
    });
  }

  it("falls back to pi-codeview.cap and pi-codeview.retentionDays when the new keys are unset", async () => {
    const r = await makeRepo();
    await r.git("config", "--local", "pi-codeview.cap", "60");
    await r.git("config", "--local", "pi-codeview.retentionDays", "5");
    expect(await readConfig(r.root)).toEqual({ mode: "off", cap: 60, retentionDays: 5 });
    await r.git("config", "--local", "pi-nvim.cap", "70");
    expect((await readConfig(r.root)).cap).toBe(70);
  });

  it("switching writes pi-nvim.checkpoints, which wins over the old key, and leaves the old key untouched", async () => {
    const r = await makeRepo();
    await r.git("config", "--local", "pi-codeview.mode", "review");
    await writeMode(r.root, "off");
    expect((await r.git("config", "--local", "pi-nvim.checkpoints")).trim()).toBe("false");
    expect((await r.git("config", "--local", "pi-codeview.mode")).trim()).toBe("review");
    expect((await readConfig(r.root)).mode).toBe("off");
  });
});

describe("sameRepoWorktree", () => {
  it("names another worktree of the same repo, also for a new file in it; null for other repos, ~, /tmp and missing paths", async () => {
    const r = await makeRepo();
    const common = await commonDir(r.root);
    const wt = await r.worktree();
    const nested = await r.worktree(".worktrees/feature");
    const other = await makeRepo();
    expect(await sameRepoWorktree(join(wt.root, "README.md"), common)).toBe(wt.root);
    expect(await sameRepoWorktree(join(wt.root, "new/dir/x.ts"), common)).toBe(wt.root);
    expect(await sameRepoWorktree(join(nested.root, "x.ts"), common)).toBe(nested.root);
    expect(await sameRepoWorktree(join(r.root, "x.ts"), common)).toBe(r.root);
    expect(await sameRepoWorktree(join(other.root, "x.ts"), common)).toBeNull();
    expect(await sameRepoWorktree(join(homedir(), "pi-nvim-follow-test.txt"), common)).toBeNull();
    expect(await sameRepoWorktree(join(tmpdir(), "pi-nvim-follow-test.txt"), common)).toBeNull();
    expect(await sameRepoWorktree("/pi-nvim-does-not-exist/x.ts", common)).toBeNull();
  });

  it("asks git once per directory when given a cache", async () => {
    const r = await makeRepo();
    const common = await commonDir(r.root);
    const wt = await r.worktree();
    const cache = new Map<string, Promise<{ root: string; commonDir: string } | null>>();
    await sameRepoWorktree(join(wt.root, "a.ts"), common, cache);
    await sameRepoWorktree(join(wt.root, "b.ts"), common, cache);
    expect([...cache.keys()]).toEqual([wt.root]);
  });
});
