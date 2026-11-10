import { describe, expect, it } from "vitest";
import type { Chunk } from "../extensions/state.ts";
import {
  CHECKPOINT_GUIDELINES,
  humanChangedSteer,
  renderAnnotationPrompt,
  renderResume,
  renderReview,
} from "../extensions/render.ts";

const chunk: Chunk = {
  n: 3,
  note: "wire up parser",
  status: "open",
  fromSha: "a",
  toSha: "b",
  agentFiles: ["src/a.ts"],
  humanFiles: [],
  humanSteps: [],
  annotations: [],
};

describe("renderReview", () => {
  it("renderReview lists annotations as path:start-end with quoted code and note", () => {
    const text = renderReview({
      chunk,
      annotations: [{ path: "src/a.ts", startLine: 3, endLine: 5, note: "rename this", quote: "const x = 1;" }],
      note: "",
      humanDiff: "",
    });
    expect(text).toContain("src/a.ts:3-5");
    expect(text).toContain("```\nconst x = 1;\n```");
    expect(text).toContain("Note: rename this");
  });

  it("renderReview uses the a-b form for single-line annotations and omits the quote block without a quote", () => {
    const text = renderReview({
      chunk,
      annotations: [{ path: "src/a.ts", startLine: 7, endLine: 7, note: "why?" }],
      note: "",
      humanDiff: "",
    });
    expect(text).toContain("src/a.ts:7-7");
    expect(text).not.toContain("```");
    expect(text).toContain("Note: why?");
  });

  it("renderReview fences a quote containing backticks with a longer fence", () => {
    const quote = "const md = `\n```ts\nx\n```\n`;";
    const text = renderReview({ chunk, annotations: [{ path: "a.md", startLine: 1, endLine: 5, note: "n", quote }], note: "", humanDiff: "" });
    expect(text).toContain(`a.md:1-5\n\`\`\`\`\n${quote}\n\`\`\`\`\nNote: n`);
    const long = renderReview({ chunk, annotations: [{ path: "b", startLine: 1, endLine: 1, note: "n", quote: "a ````` b" }], note: "", humanDiff: "" });
    expect(long).toContain("``````\na ````` b\n``````");
  });

  it("renderReview includes the chunk number and agent note in the header", () => {
    const text = renderReview({ chunk, annotations: [], note: "", humanDiff: "" });
    expect(text).toContain('Review of chunk 3 ("wire up parser"):');
  });

  it("renderReview includes Philipp's note only when non-empty", () => {
    const withNote = renderReview({ chunk, annotations: [], note: "looks good overall", humanDiff: "" });
    expect(withNote).toContain("Philipp's note:");
    expect(withNote).toContain("looks good overall");
    const without = renderReview({ chunk, annotations: [], note: "", humanDiff: "" });
    expect(without).not.toContain("Philipp's note:");
  });

  it("renderReview labels human edits as intentional", () => {
    const diff = "--- a/src/a.ts\n+++ b/src/a.ts\n+const y = 2;";
    const text = renderReview({ chunk, annotations: [], note: "", humanDiff: diff });
    expect(text).toContain("Philipp changed these files himself. Treat the changes as intentional");
    expect(text.indexOf("Philipp changed these files himself")).toBeLessThan(text.indexOf(diff));
    expect(text).toContain(diff);
  });

  it("renderReview omits the human edit section when the diff is empty", () => {
    const text = renderReview({ chunk, annotations: [], note: "", humanDiff: "" });
    expect(text).not.toContain("Philipp changed these files himself");
  });

  it("renderReview with nothing but viewed says the chunk was reviewed with no remarks", () => {
    const text = renderReview({ chunk, annotations: [], note: "", humanDiff: "" });
    expect(text).toContain("Philipp reviewed this chunk and has no remarks. Continue.");
  });
});

describe("renderResume", () => {
  it("renderResume tells the agent to continue the interrupted task and appends queued prompts in order", () => {
    const text = renderResume("REVIEW BODY", ["first prompt", "second prompt"]);
    expect(text).toContain("Continue the task that was interrupted");
    expect(text).toContain("REVIEW BODY");
    const then = text.indexOf("Then:");
    expect(then).toBeGreaterThan(-1);
    expect(text.indexOf("first prompt")).toBeGreaterThan(then);
    expect(text.indexOf("second prompt")).toBeGreaterThan(text.indexOf("first prompt"));
  });

  it("renderResume omits Then: when there are no queued prompts", () => {
    expect(renderResume("REVIEW BODY", [])).not.toContain("Then:");
  });
});

describe("renderAnnotationPrompt", () => {
  it("lists annotations after the instruction in the review block format", () => {
    const text = renderAnnotationPrompt(
      [{ path: "src/b.ts", startLine: 1, endLine: 2, note: "split this", quote: "let a;" }],
      "Address these comments.",
    );
    expect(text.startsWith("Address these comments.")).toBe(true);
    expect(text).toContain("src/b.ts:1-2");
    expect(text).toContain("```\nlet a;\n```");
    expect(text).toContain("Note: split this");
  });
});

describe("humanChangedSteer", () => {
  it("humanChangedSteer equals the steer message for the path", () => {
    expect(humanChangedSteer("src/a.ts")).toBe("Philipp changed src/a.ts. Re-read it before editing it.");
  });
});

describe("CHECKPOINT_GUIDELINES", () => {
  it("CHECKPOINT_GUIDELINES names checkpoint in every line", () => {
    expect(CHECKPOINT_GUIDELINES.length).toBeGreaterThanOrEqual(2);
    expect(CHECKPOINT_GUIDELINES.length).toBeLessThanOrEqual(3);
    for (const line of CHECKPOINT_GUIDELINES) expect(line).toContain("checkpoint");
  });

  it("CHECKPOINT_GUIDELINES says to call checkpoint after each logical step and before the next", () => {
    expect(CHECKPOINT_GUIDELINES.join("\n")).toMatch(/after each logical step[\s\S]*before starting the next/);
  });

  it("CHECKPOINT_GUIDELINES says the note states what was done and why", () => {
    expect(CHECKPOINT_GUIDELINES.join("\n")).toMatch(/note[^\n]*what was done[^\n]*why/);
  });
});
