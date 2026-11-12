# Continue / stop, checkpoint naming, empty checkpoints — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make moving on obvious (one "continue" key), skip checkpoints with no changes, say "checkpoint" everywhere the user sees "chunk", warn when the agent edits outside the session's worktree, and fix the three open findings from the chunk-view final review. Ships on branch feat/chunk-view together with the chunk-view work.

**Decisions (conversation 2026-11-12, approved by Philipp):**
- Keys: `pa` ask · `pc` **continue** (`:PiContinue`) · `ps` **stop** (`:PiStop`, was cancel) · `pn` annotate · `pe` edit annotation · `px` remove annotation · `pv` checkpoint list (`:PiCheckpoints`) · `pm` checkpoint mode on/off (`:PiCheckpointMode [on|off]`) · `pi` choose pi session (`:PiSession`). `<leader>pr` / `:PiSendAnnotations` / `:PiCancel` / `:PiChunks` are removed.
- Continue (`pc`): with a checkpoint waiting → send all annotations and saved edits as the review, no message prompt, no y/n; the agent continues. A message for the agent goes via `pa` first (queued behind the review, existing behaviour). With no checkpoint waiting → send annotations as a new prompt; none → `pi: nothing to send`.
- Empty checkpoints are skipped: if the agent calls `checkpoint` and nothing changed since the last checkpoint (no agent or human steps, no files), no checkpoint is created, nothing is shown, and the tool returns immediately with a short text telling the agent nothing changed and to continue.
- User-facing "chunk" → "checkpoint" (messages, badge, statusline, panel, winbar, README, picker labels). Protocol and code names stay "chunk" (no protocol change for the rename).
- Outside-worktree warning: when the agent changes a file outside the session's worktree root, warn once per run: `pi: the agent is editing files outside <root> — checkpoint mode can't show them; start pi in that worktree`.

## Global Constraints

- Protocol stays version 2; additions only.
- Default keys never replace existing mappings (existing rule).
- Exact texts:
  - continue with checkpoint: notify `pi: continuing — checkpoint N reviewed` plus ` with K annotations` when K > 0 (singular for 1).
  - continue without checkpoint, with annotations: `pi: K annotations sent`; without: `pi: nothing to send`.
  - stop: `pi: nothing to stop` when idle; success silent (run-end notice says `pi: stopped`, replacing `pi: cancelled`).
  - checkpoint waiting notice: `pi: checkpoint N waiting — <pv> to look, <pc> to continue` (keys via keys.lua, commands when unmapped).
  - badge waiting: `pi · checkpoint N waiting — <pc> continue`.
  - empty checkpoint tool result: `Nothing changed since the last checkpoint; no review needed. Continue.`
- Commits conventional, signed; never `git add -f` under `.superpowers`.

## Review Focus

1. Continue while a checkpoint call is not waiting (aborted / restarted pi) still resumes via the resume path.
2. An empty checkpoint while Philipp has unsent annotations: annotations stay as drafts, nothing lost.
3. Old saved sessions with an open chunk keep working (no rename on the wire or in persisted state).
4. Warning fires once per run, not per tool call; paths given relative to cwd vs absolute; bash edits are not detectable (accepted).

---

### Task 1: Final-review fixes from chunk-view

**Files:** `nvim/lua/pi/init.lua` (annotate refusal, annotate_command), `nvim/lua/pi/diff.lua` (passthrough), tests `nvim/tests/init_spec.lua`, `nvim/tests/diff_spec.lua`.

- Refusal regression: a real file in ANOTHER worktree must be annotatable (session switches as before). Refuse only when the buffer is not a real file (empty name, `pi://`, `diffview://`, buftype ~= "") or when its own git root equals the attached root but it is outside it (cannot happen — so in practice: drop the root clause, keep the buffer checks).
- Check before the prompt: annotate_command checks the buffer first and refuses before asking for the note.
- Message: left side / scratch → `pi: annotate your file — in a diff, the right side`; past checkpoint or diffview buffers on the right → `pi: past checkpoints are read-only — annotate the file itself`.
- Passthrough: with no buffer-local saved map, look up the GLOBAL normal-mode map for the key (`nvim_get_keymap("n")`) and run it (callback or rhs, remap per its noremap); else the plain key.
- [ ] Tests for each; commit `fix(nvim): annotate files in other worktrees, check before asking, pass through global maps`.

### Task 2: Continue / stop keys, checkpoint naming (nvim)

**Files:** `nvim/lua/pi/init.lua`, `nvim/lua/pi/keys.lua`, `nvim/lua/pi/session.lua` (statusline text), `nvim/lua/pi/badge.lua`, `nvim/lua/pi/panel.lua`, `nvim/lua/pi/diff.lua` (winbar), `nvim/lua/pi/diffview.lua` (notice), tests (nvim specs + e2e), `README.md`.

- Keys and commands exactly as in Decisions; remove send/cancel/chunks names; `M.continue()` implements the continue rule (sends with `note = ""`, no prompt, no confirm); `M.stop()`.
- All user-visible "chunk" → "checkpoint" (messages, badge, statusline `review N` → `checkpoint N`, panel title/lines, winbar `checkpoint N · i/total …`, picker, README). Keep wire/persisted names.
- Help line / notices use `pc continue`.
- [ ] Tests updated + new (continue with/without checkpoint, with/without annotations; stop idle/busy; texts); commit `feat(nvim)!: continue and stop keys, say checkpoint`.

### Task 3: Skip empty checkpoints, outside-worktree warning (extension + nvim notice)

**Files:** `extensions/loop.ts`, `extensions/protocol.ts` (event `outside_worktree { path }`), tests `test/extension.test.ts`, `nvim/lua/pi/init.lua` (show the warning), `docs/protocol.md`, `README.md`.

- `checkpoint()`: if no open chunk and `recordSince("agent")` finds no changes AND there are no steps since the last checkpoint (no agent or human changes) → return the exact empty text immediately; nothing persisted or broadcast.
- Outside worktree: on `tool_call` (or tool_result) for a mutating tool with a `path` argument, resolve it against ctx.cwd; if it is outside the root (realpath-safe) and not yet warned this run → `ctx.ui.notify` the exact text in pi and broadcast `outside_worktree { path }`; nvim shows the same text once. Reset per run (agent_start).
- [ ] Tests: empty checkpoint returns immediately, no chunk, drafts untouched; checkpoint with only human changes still opens; warning once per run with absolute and relative paths; nvim shows it. Commit `feat: skip empty checkpoints, warn when the agent edits outside the worktree`.
