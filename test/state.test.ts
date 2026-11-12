import { describe, expect, it } from "vitest";
import { PiNvimState } from "../extensions/state.ts";

describe("PiNvimState", () => {
  it("createChunk attributes steps", () => {
    const s = new PiNvimState();
    s.setBaseline("base");
    s.recordStep({ from: "f1", sha: "1", author: "agent", files: ["a.ts"], lines: 10 });
    s.recordStep({ from: "f2", sha: "2", author: "agent", files: ["b.ts"], lines: 5 });
    s.recordStep({ from: "f3", sha: "3", author: "human", files: ["c.ts"], lines: 7 });
    expect(s.agentLines()).toBe(15);
    const c = s.createChunk("note", "tip");
    expect(c).toMatchObject({ n: 1, fromSha: "base", toSha: "tip", status: "open", agentFiles: ["a.ts", "b.ts"], humanFiles: ["c.ts"] });
    expect(s.agentLines()).toBe(0);
    expect(s.baseline).toBe("tip");
    expect(s.steps).toEqual([]);
  });
  it("createChunk keeps why only for chunk files, normalizes ./ and caps length", () => {
    const s = new PiNvimState();
    s.recordStep({ from: "f1", sha: "1", author: "agent", files: ["a.ts"], lines: 1 });
    const c = s.createChunk("n", "t", "open", [
      { path: "./a.ts", why: "x".repeat(300) },
      { path: "zzz.ts", why: "unknown" },
    ]);
    expect(c.why).toEqual({ "a.ts": "x".repeat(200) });
  });
  it("createChunk stores the title with whitespace collapsed, capped at 60 code points, omitted when empty", () => {
    const s = new PiNvimState();
    s.recordStep({ from: "f1", sha: "1", author: "agent", files: ["a.ts"], lines: 1 });
    const c = s.createChunk("n", "t", "open", [], "  add\n  parser  ");
    expect(c.title).toBe("add parser");
    s.recordStep({ from: "f2", sha: "2", author: "agent", files: ["a.ts"], lines: 1 });
    s.chunks[0].status = "reviewed";
    expect(s.createChunk("n", "t2", "open", [], "😀".repeat(70)).title).toBe("😀".repeat(60));
    s.recordStep({ from: "f3", sha: "3", author: "agent", files: ["a.ts"], lines: 1 });
    s.chunks[1].status = "reviewed";
    expect(s.createChunk("n", "t3", "open", [], "  \n ")).not.toHaveProperty("title");
  });
  it("createChunk collapses whitespace in why and drops blank ones", () => {
    const s = new PiNvimState();
    s.recordStep({ from: "f1", sha: "1", author: "agent", files: ["a.ts", "b.ts"], lines: 1 });
    const c = s.createChunk("n", "t", "open", [
      { path: "a.ts", why: "  line one\n  line two\t\n" },
      { path: "b.ts", why: " \n\t " },
    ]);
    expect(c.why).toEqual({ "a.ts": "line one line two" });
  });
  it("createChunk omits why when empty and restores chunks persisted without it", () => {
    const s = new PiNvimState();
    s.recordStep({ from: "f1", sha: "1", author: "agent", files: ["a.ts"], lines: 1 });
    expect("why" in s.createChunk("n", "t", "open", [{ path: "nope", why: "w" }])).toBe(false);
    expect(new PiNvimState(s.serialize()).chunks[0]!.why).toBeUndefined();
  });
  it("human lines do not count toward agentLines", () => {
    const s = new PiNvimState();
    s.recordStep({ from: "f1", sha: "1", author: "human", files: ["a.ts"], lines: 99 });
    expect(s.agentLines()).toBe(0);
  });
  it("only one open chunk", () => {
    const s = new PiNvimState();
    s.createChunk("a", "x");
    expect(() => s.createChunk("b", "y")).toThrow("chunk already open");
    expect(s.createChunk("c", "z", "recorded").n).toBe(2);
    expect(s.openChunk()?.n).toBe(1);
    expect(() => s.closeChunk(2, { status: "reviewed", annotations: [] })).toThrow("no open chunk 2");
    const closed = s.closeChunk(1, { status: "reviewed", annotations: [], reviewNote: "ok" });
    expect(closed).toMatchObject({ status: "reviewed", reviewNote: "ok" });
    expect(s.openChunk()).toBeUndefined();
  });
  it("serialize/restore round-trips", () => {
    const s = new PiNvimState();
    s.mode = "checkpoints";
    s.setBaseline("b");
    s.recordStep({ from: "f1", sha: "1", author: "agent", files: ["a.ts"], lines: 3 });
    s.createChunk("n", "t");
    s.recordStep({ from: "f2", sha: "2", author: "human", files: ["h.ts"], lines: 1 });
    s.setDrafts([{ path: "a.ts", startLine: 1, endLine: 2, note: "x" }]);
    s.queuePrompt("p");
    const data = JSON.parse(JSON.stringify(s.serialize()));
    const r = new PiNvimState(data);
    expect(r.serialize()).toEqual(s.serialize());
    expect(r.mode).toBe("checkpoints");
    expect(r.chunks).toHaveLength(1);
    expect(r.drafts).toHaveLength(1);
    expect(r.queuedPrompts).toEqual(["p"]);
    expect(new PiNvimState().serialize()).toMatchObject({ mode: "off", baseline: "" });
  });
  it("restores steps persisted without from, chaining them from the baseline", () => {
    const r = new PiNvimState({
      mode: "checkpoints", baseline: "b", chunks: [], drafts: [], queuedPrompts: [],
      steps: [{ sha: "1", author: "agent", files: ["a.ts"], lines: 1 }, { sha: "2", author: "human", files: ["a.ts"], lines: 1 }] as any,
    });
    expect(r.steps.map((s) => s.from)).toEqual(["b", "1"]);
  });
  it("advanceAfterReview keeps agent steps recorded during review and marks human ones reported", () => {
    const s = new PiNvimState();
    s.setBaseline("b");
    s.createChunk("n", "t");
    s.recordStep({ from: "t", sha: "1", author: "agent", files: ["a.ts"], lines: 4 });
    s.recordStep({ from: "1", sha: "2", author: "human", files: ["h.ts"], lines: 1 });
    s.closeChunk(1, { status: "reviewed", annotations: [] });
    s.advanceAfterReview("2");
    expect(s.baseline).toBe("t");
    expect(s.agentLines()).toBe(4);
    expect(s.humanFiles()).toEqual([]);
    s.recordStep({ from: "2", sha: "3", author: "human", files: ["h.ts"], lines: 1 });
    expect(s.humanSteps().map((x) => x.sha)).toEqual(["3"]);
    expect(s.createChunk("next", "3")).toMatchObject({ agentFiles: ["a.ts"], humanFiles: ["h.ts"], humanSteps: [{ sha: "3" }] });
    const s2 = new PiNvimState();
    s2.recordStep({ from: "t", sha: "1", author: "human", files: ["h.ts"], lines: 1 });
    s2.advanceAfterReview("1");
    expect(s2).toMatchObject({ baseline: "1", steps: [] });
  });
  it("migration: restores the old persisted mode names review/vibe as checkpoints/off", () => {
    const old = (mode: string) => ({ mode, baseline: "b", chunks: [], steps: [], drafts: [], queuedPrompts: [] }) as any;
    expect(new PiNvimState(old("review")).mode).toBe("checkpoints");
    expect(new PiNvimState(old("vibe")).mode).toBe("off");
  });
  it("takeQueuedPrompts drains the queue", () => {
    const s = new PiNvimState();
    s.queuePrompt("a");
    s.queuePrompt("b");
    expect(s.takeQueuedPrompts()).toEqual(["a", "b"]);
    expect(s.takeQueuedPrompts()).toEqual([]);
  });
});
