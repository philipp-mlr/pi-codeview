import { execFile } from "node:child_process";
import { mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";
import {
  findRoot,
  numstat,
  pruneRefs,
  readConfig,
  repoHash,
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
    const sha = await snapshot(r.root, "refs/pi-codeview/s/0", "snap");
    expect(await showFile(r.root, sha, "a.ts")).toBe("const a = 1;\n");
    await expect(r.git("rev-parse", "HEAD")).rejects.toThrow();
  });

  it("leaves branch, index and HEAD untouched", async () => {
    const r = await makeRepo();
    const head = (await r.git("rev-parse", "HEAD")).trim();
    r.write("b.ts", "x\n");
    await r.git("add", "b.ts");
    await snapshot(r.root, "refs/pi-codeview/s/0", "snap");
    expect((await r.git("diff", "--cached", "--name-only")).trim()).toBe("b.ts");
    expect((await r.git("rev-parse", "HEAD")).trim()).toBe(head);
  });

  it("includes untracked and respects .gitignore", async () => {
    const r = await makeRepo();
    r.write(".gitignore", "out/\n");
    r.write("new.ts", "n\n");
    r.write("out/x.js", "x\n");
    const sha = await snapshot(r.root, "refs/pi-codeview/s/0", "snap");
    expect(await showFile(r.root, sha, "new.ts")).toBe("n\n");
    expect(await showFile(r.root, sha, "out/x.js")).toBeNull();
  });
});

describe("numstat", () => {
  it("counts added+deleted, binary as 0, handles spaces and unicode", async () => {
    const r = await makeRepo();
    const a = await snapshot(r.root, "refs/pi-codeview/s/0", "a");
    r.write("my file.ts", "1\n2\n3\n");
    r.write("ä.ts", "x\n");
    writeFileSync(join(r.root, "img.bin"), Buffer.from([0, 1, 2, 0, 255, 0]));
    const b = await snapshot(r.root, "refs/pi-codeview/s/1", "b");
    const stat = await numstat(r.root, a, b);
    const by = Object.fromEntries(stat.map((s) => [s.path, s.lines]));
    expect(by["my file.ts"]).toBe(3);
    expect(by["ä.ts"]).toBe(1);
    expect(by["img.bin"]).toBe(0);
  });

  it("reports deletions", async () => {
    const r = await makeRepo();
    r.write("d.ts", "1\n2\n");
    const a = await snapshot(r.root, "refs/pi-codeview/s/0", "a");
    r.rm("d.ts");
    const b = await snapshot(r.root, "refs/pi-codeview/s/1", "b");
    expect(await numstat(r.root, a, b)).toEqual([{ path: "d.ts", lines: 2 }]);
  });

  it("shows a rename as delete plus add", async () => {
    const r = await makeRepo();
    r.write("old.ts", "1\n2\n");
    const a = await snapshot(r.root, "refs/pi-codeview/s/0", "a");
    r.rm("old.ts");
    r.write("new name.ts", "1\n2\n");
    const b = await snapshot(r.root, "refs/pi-codeview/s/1", "b");
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
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "codeview-norepo-")));
    expect(await findRoot(dir)).toBeNull();
  });
});

describe("repoHash", () => {
  it("is equal for two worktrees of one repo", async () => {
    const r = await makeRepo();
    const wt = join(realpathSync(mkdtempSync(join(tmpdir(), "codeview-wt-"))), "wt");
    await r.git("worktree", "add", "-q", wt, "-b", "other");
    const h1 = await repoHash(r.root);
    expect(h1).toMatch(/^[0-9a-f]{12}$/);
    expect(await repoHash(wt)).toBe(h1);
  });
});

describe("pruneRefs", () => {
  it("deletes only old refs", async () => {
    const r = await makeRepo();
    const tree = (await r.git("rev-parse", "HEAD^{tree}")).trim();
    const old = new Date(Date.now() - 20 * 86400_000).toISOString();
    const env = { ...process.env, GIT_COMMITTER_DATE: old, GIT_AUTHOR_DATE: old };
    const { stdout } = await execFileAsync("git", ["commit-tree", tree, "-m", "old"], { cwd: r.root, env });
    await r.git("update-ref", "refs/pi-codeview/s/0", stdout.trim());
    await snapshot(r.root, "refs/pi-codeview/s/1", "new");
    expect(await pruneRefs(r.root, 14)).toBe(1);
    const refs = (await r.git("for-each-ref", "--format=%(refname)", "refs/pi-codeview/")).trim();
    expect(refs).toBe("refs/pi-codeview/s/1");
  });
});

describe("config", () => {
  it("readConfig defaults to vibe/150/14", async () => {
    const r = await makeRepo();
    expect(await readConfig(r.root)).toEqual({ mode: "vibe", cap: 150, retentionDays: 14 });
  });

  it("falls back to defaults on invalid values", async () => {
    const r = await makeRepo();
    await r.git("config", "--local", "pi-codeview.mode", "foo");
    await r.git("config", "--local", "pi-codeview.cap", "abc");
    expect(await readConfig(r.root)).toEqual({ mode: "vibe", cap: 150, retentionDays: 14 });
  });

  it("writeMode persists to local git config", async () => {
    const r = await makeRepo();
    await writeMode(r.root, "review");
    expect((await r.git("config", "--local", "pi-codeview.mode")).trim()).toBe("review");
    expect((await readConfig(r.root)).mode).toBe("review");
  });
});
