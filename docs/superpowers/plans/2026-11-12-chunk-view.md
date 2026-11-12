# Chunk view: diffview when available, clearer built-in view — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Opening a chunk uses diffview.nvim when it is installed (supported, not required) and the built-in view otherwise; the built-in view gets familiar keys, a way back, and a help line; annotating on a side that is not a real file says so instead of silently dropping the annotation.

**Decisions (conversation 2026-11-11/12):**
- Philipp asked what to do in the diff view, whether he can annotate, and how to get back; found `]f`/`[f` odd; chose: diffview's keys in our view, and **open the chunk in diffview when diffview is available**.
- Built-in view keys: `<Tab>` / `<S-Tab>` next / previous file (as diffview), `q` closes the chunk tab and returns to the tab the chunk was opened from (where the panel is). `]f` / `[f` are removed.
- Help line in the winbar: `chunk N · i/total · path · agent|human   <Tab> next · <leader>pn annotate · <leader>pr send · q back` (keys taken from the resolved mapping, commands when unmapped — same rule as the run-end notice).
- Annotating a buffer that is not a file in the repo (diff left side, `pi://` and `diffview://` buffers, scratch buffers): no mark; notify `pi: annotate your file — in a diff, the right side` (Controller ruling: refuse instead of mapping lines across sides — simpler, can't land on the wrong line).
- diffview path: `setup({ diff = "auto" | "diffview" | "builtin" })`, default `"auto"` = diffview when `require("diffview")` loads and `:DiffviewOpen` exists. Open chunk: `:DiffviewOpen <fromSha> -C<root> -- <files>` (right side = working tree, editable); past chunk: `:DiffviewOpen <fromSha>..<toSha> -C<root> -- <files>`. On opening, notify once: `pi: chunk N — <Tab> next file · <leader>pn annotate · <leader>pr send · :DiffviewClose to go back`. The chunk note and per-file why are shown as `virt_lines` above line 1 of diffview's left buffer for the current file (via `User DiffviewDiffBufWinEnter`, only inside the chunk's diffview tab), same text/highlights as the built-in view. When the chunk is reviewed, its diffview tab is closed (as the built-in tab is today).

## Global Constraints

- No hard dependency on diffview; all diffview calls guarded; tests must pass without diffview installed (CI has none).
- Default keys under `<leader>p` unchanged; `q`/`<Tab>`/`<S-Tab>` are buffer-local in the built-in chunk tab only and must not replace a user's existing buffer-local mapping on the real file (save/restore as `]f`/`[f` did).
- Exact texts as in Decisions.
- Commits conventional, signed; never `git add -f` under `.superpowers`.

## Review Focus

1. diffview not installed / fails to open → falls back to the built-in view, no error.
2. `q` in the built-in view when the origin tab was closed meanwhile → closes the chunk tab, lands on any remaining tab, no error.
3. Opening the same chunk twice → reuses the existing tab (built-in and diffview).
4. Annotate refusal does not trigger for real files opened via `:edit` in the right side.

---

### Task 1: Built-in view keys, way back, help line; annotate refusal

**Files:** `nvim/lua/pi/diff.lua`, `nvim/lua/pi/init.lua` (annotate path, resolved keys), `nvim/lua/pi/annotations.lua` if needed, tests `nvim/tests/diff_spec.lua`, `nvim/tests/init_spec.lua`, `test/e2e.nvim.test.ts` (replace `]f` usages), `README.md`.

- [ ] Tests: `<Tab>`/`<S-Tab>` move between files (and wrap or stop at the ends — pick one, test it); `q` closes the chunk tab and returns to the origin tab; origin tab gone → no error; user buffer-local `<Tab>`/`q` on the real file restored after the tab closes; winbar contains the help text with the resolved keys; annotate on the left (scratch) side → no annotation listed, exact notice; annotate on the right (real file) side still works.
- [ ] Commit `feat(nvim): chunk view keys like diffview, q to go back, help line`.

### Task 2: Open chunks in diffview when available

**Files:** `nvim/lua/pi/diff.lua` (or a small `nvim/lua/pi/diffview.lua`), `nvim/lua/pi/init.lua` (setup option `diff`), tests (fake diffview: `package.preload["diffview"]` + a fake `:DiffviewOpen` user command that records args and opens a tab with two windows; fake `User DiffviewDiffBufWinEnter` firing), `README.md`.

- [ ] Tests: auto with fake diffview → `DiffviewOpen` called with exact args for open and past chunks; auto without diffview → built-in; `diff = "builtin"` forces built-in; `diff = "diffview"` without diffview → built-in + one WARN `pi: diffview.nvim not found, using the built-in view`; notice text on open; virt_lines with note/why placed on the left buffer on the fake event, only in the chunk's tab; chunk_reviewed closes the diffview tab; opening the same chunk twice reuses the tab.
- [ ] Controller will additionally run one headless check against Philipp's real installed diffview.nvim.
- [ ] Commit `feat(nvim): open chunks in diffview.nvim when it is installed`.
