# Feedback badge, annotation edit/remove, live signs, easier continue — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make it obvious in Neovim that the agent is running and when it is done; let Philipp remove or edit one annotation among several; align the live-change sign with gitsigns; let him continue a checkpoint without remarks in one step.

**Architecture:** Small changes on both sides of the existing socket protocol (stays `PROTOCOL_VERSION = 2`, additive fields only). New Neovim module `badge.lua` for the floating indicator.

**Spec:** decisions from the conversation of 2026-11-11 (recorded here) on top of `docs/superpowers/specs/2026-11-11-pi-nvim-design.md`:
- Feedback: floating badge, top-right, while the agent works; one notice when a run ends.
- Annotations: `px` removes one (picker when several cover the line); new `pe` edits one (picker, then input pre-filled).
- Live sign: `┃` like gitsigns, in its own colour (fg only), so the bar no longer jumps sideways.
- Checkpoint mode: drop the "open the chunk first" rule. `pr` with no annotations and no message asks `pi: continue without remarks? (y/n)` and sends on yes.

## Global Constraints

- Protocol additive only; version stays 2.
- Keys under `<leader>p`; new default `pe` = edit annotation (`:PiAnnotationEdit`). Default keys never replace existing mappings.
- Exact texts:
  - remove picker prompt `pi: remove which annotation?`; edit picker prompt `pi: edit which annotation?`; edit input prompt `pi annotation: ` pre-filled; nothing at cursor: `pi: no annotation at the cursor`.
  - continue confirm `pi: continue without remarks? (y/n)`.
  - run end, off mode: `pi: done — N files changed` (singular `1 file changed`; `pi: done` when 0); aborted: `pi: cancelled`.
  - run end with an open chunk (checkpoint mode): `pi: chunk N waiting for your review — <leader>pv to look, <leader>pr to continue`.
  - badge while working: `<spinner> pi · <tool> <target>` (target trimmed to 40 chars) or `<spinner> pi · working`; while a chunk waits: `pi · chunk N waiting for your review`.
- Badge: not focusable, never steals focus, hidden when idle and when not attached; spinner timer runs only while visible; `setup({ badge = false })` disables it.
- Never block typing; all timers cleaned up on detach / VimLeavePre.
- Commits conventional, signed; never `git add -f` under `.superpowers`.

## Review Focus

1. Badge with several windows/tabs, splits, `:resize`, `VimResized`, and the chunk diff tab — position stays top-right of the editor, never covers the cursor's typing position permanently, never errors.
2. Picker cancel (Esc) changes nothing.
3. Empty-review confirm declined → nothing sent, chunk stays open.
4. A run that ends while nvim is detached does not leave a stale badge on reattach.

---

### Task 1: Remove one / edit one annotation (nvim)

**Files:** `nvim/lua/pi/annotations.lua`, `nvim/lua/pi/init.lua`, `nvim/tests/annotations_spec.lua`, `nvim/tests/init_spec.lua`, `README.md` (keys table).

**Interfaces:**
- `annotations.at_cursor() -> item[]` (items whose range contains the cursor line in the current buffer, sorted by start line).
- `annotations.remove(item)`, `annotations.edit(item, text)` (updates note + rebuilds its text mark; fires on_change).
- `:PiAnnotationRemove` / `px`: 0 → message; 1 → remove it; >1 → `vim.ui.select` with items formatted `L<start>-<end>: <text>` → remove the chosen one.
- `:PiAnnotationEdit` / `pe`: same selection, then `vim.ui.input({ prompt = "pi annotation: ", default = <text> })`; empty or cancelled → unchanged.

- [ ] Tests: two annotations on one line + a range covering it → remove picks exactly one; edit changes text and the virt line; Esc in picker / input changes nothing; single annotation removed without a picker.
- [ ] Commit `feat(nvim): remove or edit one annotation at the cursor`.

### Task 2: Continue without remarks, live sign alignment, files changed on run end (both sides)

**Files:** `extensions/state.ts`, `extensions/loop.ts`, `extensions/protocol.ts`, tests in `test/`, `nvim/lua/pi/init.lua` (send), `nvim/lua/pi/live.lua`, `nvim/lua/pi/highlights.lua`, nvim tests, e2e, `docs/protocol.md`, `README.md`.

**Interfaces:**
- Extension: an empty review of the open chunk is accepted (drop the viewed/content requirement; keep accepting the `viewed` field for compatibility, ignore it). Remove `SEND_REFUSED` usage for this case.
- `run_settled` data gains `files: number` = distinct files the agent changed during the run (from agent steps recorded since `agent_start`, including steps folded into chunks created during the run).
- nvim send: no annotations + empty message + open chunk → `vim.fn.confirm`-style y/n with the exact text; yes → send; no → nothing. Outside checkpoint mode the existing "no annotations to send" rule stays.
- Live signs: add/change use `┃` with sign groups `PiLiveSignAdd` / `PiLiveSignChange` (fg-only; default-link to `DiagnosticHint` and `DiagnosticInfo`), delete keeps `▁` with `PiLiveSignDelete` (default-link `DiagnosticWarn`); line highlight `PiLive` unchanged. All links in `highlights.lua`.

- [ ] Tests: empty review accepted by the server; confirm yes sends / no doesn't (stub confirm); `run_settled.files` counts distinct files across two edits of one file + one other file = 2; live signs use `┃` and the new groups.
- [ ] Commit `feat: continue without remarks, aligned live signs, files changed per run`.

### Task 3: Floating badge and run-end notice (nvim)

**Files:** create `nvim/lua/pi/badge.lua`, `nvim/tests/badge_spec.lua`; modify `nvim/lua/pi/session.lua` / `init.lua` (feed state changes to the badge; run-end notice on `run_settled`; `setup({ badge = false })`), e2e, `README.md`.

**Interfaces:**
- `badge.update(state)` where state is `{ busy, tool?, target?, chunk? }` or nil → shows/updates/hides; `badge.close()`.
- Float: `relative = "editor"`, `row = 0`, `col = vim.o.columns - width - 1`, `width = #text`, `height = 1`, `focusable = false`, `style = "minimal"`, `zindex = 60`, `noautocmd = true`, highlight group `PiBadge` (default-link `PmenuSel`); repositioned on `VimResized`; spinner frames `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` at 100 ms via one `vim.uv` timer that stops when hidden.
- Run-end notice from `run_settled` (+ status for the open chunk) with the exact texts.

- [ ] Tests (headless): badge appears with the tool text when busy, hides on idle, shows the waiting text with an open chunk, timer stops when hidden, `badge = false` never opens a window, `VimResized` keeps it at the right edge; e2e: run_settled with files=2 → notice `pi: done — 2 files changed`.
- [ ] Commit `feat(nvim): floating badge while the agent works, notice when it is done`.
