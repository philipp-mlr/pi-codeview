import { describe, expect, it } from "vitest";
import { CodeviewState } from "../extensions/state.ts";

describe("CodeviewState", () => {
  it("createChunk attributes steps", () => {
    const s = new CodeviewState();
    s.setBaseline("base");
    s.recordStep({ sha: "1", author: "agent", files: ["a.ts"], lines: 10 });
    s.recordStep({ sha: "2", author: "agent", files: ["b.ts"], lines: 5 });
    s.recordStep({ sha: "3", author: "human", files: ["c.ts"], lines: 7 });
    expect(s.agentLines()).toBe(15);
    const c = s.createChunk("note", "tip");
    expect(c).toMatchObject({ n: 1, fromSha: "base", toSha: "tip", status: "open", agentFiles: ["a.ts", "b.ts"], humanFiles: ["c.ts"] });
    expect(s.agentLines()).toBe(0);
    expect(s.baseline).toBe("tip");
    expect(s.steps).toEqual([]);
  });
  it("human lines do not count toward agentLines", () => {
    const s = new CodeviewState();
    s.recordStep({ sha: "1", author: "human", files: ["a.ts"], lines: 99 });
    expect(s.agentLines()).toBe(0);
  });
  it("only one open chunk", () => {
    const s = new CodeviewState();
    s.createChunk("a", "x");
    expect(() => s.createChunk("b", "y")).toThrow("chunk already open");
    expect(s.createChunk("c", "z", "recorded").n).toBe(2);
    expect(s.openChunk()?.n).toBe(1);
    expect(() => s.closeChunk(2, { status: "reviewed", annotations: [] })).toThrow("no open chunk 2");
    const closed = s.closeChunk(1, { status: "reviewed", annotations: [], reviewNote: "ok" });
    expect(closed).toMatchObject({ status: "reviewed", reviewNote: "ok" });
    expect(s.openChunk()).toBeUndefined();
  });
  it("canSend refuses an empty, unviewed review", () => {
    const s = new CodeviewState();
    expect(s.canSend({ annotations: 0, note: "", humanEdits: 0, viewed: false })).toBe(false);
    expect(s.canSend({ annotations: 0, note: "", humanEdits: 0, viewed: true })).toBe(true);
    expect(s.canSend({ annotations: 1, note: "", humanEdits: 0, viewed: false })).toBe(true);
  });
  it("serialize/restore round-trips", () => {
    const s = new CodeviewState();
    s.mode = "review";
    s.setBaseline("b");
    s.recordStep({ sha: "1", author: "agent", files: ["a.ts"], lines: 3 });
    s.createChunk("n", "t");
    s.recordStep({ sha: "2", author: "human", files: ["h.ts"], lines: 1 });
    s.setDrafts([{ path: "a.ts", startLine: 1, endLine: 2, note: "x" }]);
    s.queuePrompt("p");
    const data = JSON.parse(JSON.stringify(s.serialize()));
    const r = new CodeviewState(data);
    expect(r.serialize()).toEqual(s.serialize());
    expect(r.mode).toBe("review");
    expect(r.chunks).toHaveLength(1);
    expect(r.drafts).toHaveLength(1);
    expect(r.queuedPrompts).toEqual(["p"]);
    expect(new CodeviewState().serialize()).toMatchObject({ mode: "vibe", baseline: "" });
  });
  it("takeQueuedPrompts drains the queue", () => {
    const s = new CodeviewState();
    s.queuePrompt("a");
    s.queuePrompt("b");
    expect(s.takeQueuedPrompts()).toEqual(["a", "b"]);
    expect(s.takeQueuedPrompts()).toEqual([]);
  });
});
