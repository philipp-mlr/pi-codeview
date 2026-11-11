import { describe, expect, it } from "vitest";
import { ActivityLog, excerpt, toolLine } from "../extensions/activity.ts";

describe("ActivityLog", () => {
  it("keeps the last 200 items and seq keeps increasing", () => {
    const log = new ActivityLog();
    for (let i = 0; i < 250; i++) log.add({ kind: "tool", text: `t${i}` });
    const all = log.since();
    expect(all).toHaveLength(200);
    expect(all[0].seq).toBe(51);
    expect(all.at(-1)?.seq).toBe(250);
    expect(log.lastSeq()).toBe(250);
  });

  it("since(seq) returns items after seq", () => {
    const log = new ActivityLog();
    for (let i = 0; i < 5; i++) log.add({ kind: "text", text: `t${i}` });
    expect(log.since(3).map((i) => i.seq)).toEqual([4, 5]);
    expect(log.since(5)).toEqual([]);
  });

  it("current is set on start and cleared on the matching end", () => {
    const log = new ActivityLog();
    expect(log.current()).toBeNull();
    log.startTool("1", "read", "a.ts");
    log.startTool("2", "bash", "ls");
    expect(log.current()).toEqual({ tool: "bash", target: "ls" });
    log.endTool("2");
    expect(log.current()).toEqual({ tool: "read", target: "a.ts" });
    log.endTool("1");
    expect(log.current()).toBeNull();
  });
});

describe("excerpt", () => {
  it("collapses whitespace and ignores thinking and tool blocks", () => {
    const message = {
      content: [
        { type: "thinking", thinking: "secret" },
        { type: "text", text: "hello \n  world" },
        { type: "toolCall", name: "x" },
        { type: "text", text: "again" },
      ],
    };
    expect(excerpt(message)).toBe("hello world again");
  });

  it("cuts at 300 chars with an ellipsis", () => {
    const out = excerpt({ content: [{ type: "text", text: "a".repeat(400) }] });
    expect(out).toBe("a".repeat(300) + "…");
    expect(excerpt({ content: [{ type: "text", text: "a".repeat(300) }] })).toBe("a".repeat(300));
  });

  it("accepts string content and returns null without text", () => {
    expect(excerpt({ content: "hi  there" })).toBe("hi there");
    expect(excerpt({ content: [{ type: "thinking", thinking: "x" }] })).toBeNull();
    expect(excerpt({ content: [{ type: "text", text: "  \n " }] })).toBeNull();
    expect(excerpt({})).toBeNull();
  });
});

describe("toolLine", () => {
  it("uses path, then command (60 chars), else empty", () => {
    expect(toolLine("edit", { path: "a.ts", command: "x" })).toEqual({ tool: "edit", target: "a.ts" });
    expect(toolLine("bash", { command: "c".repeat(80) })).toEqual({ tool: "bash", target: "c".repeat(60) });
    expect(toolLine("bash", { command: "cat <<'EOF'\n  a\tb\nEOF" })).toEqual({ tool: "bash", target: "cat <<'EOF' a b EOF" });
    expect(toolLine("bash", { command: "  x\n".repeat(40) })).toEqual({ tool: "bash", target: "x ".repeat(30).slice(0, 60) });
    expect(toolLine("todo", {})).toEqual({ tool: "todo", target: "" });
    expect(toolLine("todo", undefined)).toEqual({ tool: "todo", target: "" });
  });
});
