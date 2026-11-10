import type { Annotation, Chunk } from "./state.ts";

export const CHECKPOINT_GUIDELINES: string[] = [
  "Call checkpoint after each logical step, before starting the next one.",
  "The checkpoint note states what was done and why.",
];

function formatAnnotation(a: Annotation): string {
  const lines = [`${a.path}:${a.startLine}-${a.endLine}`];
  if (a.quote !== undefined) lines.push("```", a.quote, "```");
  lines.push(`Note: ${a.note}`);
  return lines.join("\n");
}

function formatAnnotations(annotations: Annotation[]): string {
  return annotations.map(formatAnnotation).join("\n\n");
}

export function renderReview(r: { chunk: Chunk; annotations: Annotation[]; note: string; humanDiff: string }): string {
  const sections: string[] = [`Review of chunk ${r.chunk.n} ("${r.chunk.note}"):`];
  if (r.note !== "") sections.push(`Philipp's note:\n${r.note}`);
  if (r.annotations.length > 0) sections.push(formatAnnotations(r.annotations));
  if (r.humanDiff !== "") {
    sections.push(`Philipp changed these files himself. Treat the changes as intentional:\n${r.humanDiff}`);
  }
  if (r.annotations.length === 0 && r.note === "" && r.humanDiff === "") {
    sections.push("Philipp reviewed this chunk and has no remarks. Continue.");
  }
  return sections.join("\n\n");
}

export function renderResume(review: string, queued: string[]): string {
  const sections = [
    "Continue the task that was interrupted. Philipp's review of the last chunk:",
    review,
  ];
  if (queued.length > 0) sections.push(`Then:\n${queued.join("\n\n")}`);
  return sections.join("\n\n");
}

export function renderAnnotationPrompt(annotations: Annotation[], instruction: string): string {
  if (annotations.length === 0) return instruction;
  return `${instruction}\n\n${formatAnnotations(annotations)}`;
}

export function humanChangedSteer(path: string): string {
  return `Philipp changed ${path}. Re-read it before editing it.`;
}
