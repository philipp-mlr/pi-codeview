import { describe, expect, it } from "vitest";
import { ActivityLog, toolLine } from "../extensions/activity.ts";

describe("ActivityLog", () => {
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
