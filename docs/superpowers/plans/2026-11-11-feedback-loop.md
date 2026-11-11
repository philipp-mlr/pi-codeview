# Feedback Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** While the agent works, Philipp sees in Neovim what it is doing (statusline, activity log), the code changing in his buffers, and why each file changed when a chunk arrives.

**Architecture:** The extension adds an `activity` event and an in-memory activity ring (200 items), a `get_activity` request, and an optional `files: [{path, why}]` on `checkpoint` stored on the chunk. The plugin caches the latest activity for a statusline function, renders a log buffer, reloads changed buffers and marks changed lines against the chunk baseline, and shows the per-file `why` in the diff view.

**Tech Stack:** TypeScript (vitest, fake pi), Lua (nvim 0.12, headless specs + e2e), as in the existing repo.

**Spec:** `docs/superpowers/specs/2026-11-11-feedback-loop-design.md` (and the v1 spec `docs/superpowers/specs/2026-11-10-pi-codeview-design.md` for everything else).

## Global Constraints

- Protocol stays `PROTOCOL_VERSION = 1`; additions only (new event `activity`, new request `get_activity`, new optional fields). Old clients must keep working.
- Activity items: `{ seq: number; kind: "prompt" | "text" | "tool" | "checkpoint" | "settled"; text: string; tool?: string; target?: string; at: number }`. `seq` increases by 1 per item per session. Ring keeps the last 200.
- Text excerpts: first 300 characters of an assistant message's text blocks, whitespace-collapsed, suffix `…` when cut. Never thinking blocks.
- Tool lines: `<tool> <target>` where target is the `path` argument if present, else the first 60 chars of `command`, else empty.
- A buffer with unsaved changes (`modified`) is never reloaded by codeview.
- Default keys: `<leader>cl` log toggle. Existing defaults unchanged.
- No new runtime dependencies.
- Commits: conventional subjects, signed; never `git add -f` under `.superpowers`.

## Review Focus

1. Activity flood: a long run with hundreds of tool calls must not grow memory or socket traffic unbounded (ring cap; one event per tool start/end, one per message_end).
2. Philipp's unsaved buffer while the agent writes the same file: no reload, one warning per file per chunk, and no lost edits.
3. A fresh nvim attaching mid-run sees the current tool in the statusline and recent log entries (via `status` + `get_activity`).
4. `checkpoint` without `files` (older agents/models) still works; diff view shows just the note.
5. Detach / switch session clears live signs and stale statusline text.

---

### Task 1: Activity in the extension (events, ring, get_activity)

**Files:**
- Create: `extensions/activity.ts`, `test/activity.test.ts`
- Modify: `extensions/protocol.ts` (EventName `activity`, Request `get_activity { since?: number }`), `extensions/loop.ts` (own an `ActivityLog`, expose `current` in `status`, handle `get_activity`), `extensions/codeview.ts` (wire `tool_execution_start`, `tool_execution_end`, `message_end`, `input`/prompt, `agent_settled`), `test/codeview.test.ts`, `docs/protocol.md`

**Interfaces:**
- Produces in `extensions/activity.ts`:
  - `type ActivityItem` as in Global Constraints.
  - `class ActivityLog { constructor(cap = 200); add(item: Omit<ActivityItem,"seq"|"at">): ActivityItem; since(seq?: number): ActivityItem[]; current(): { tool?: string; target?: string } | null }` — `current()` is the tool started but not yet ended (last one wins), null when none.
  - `function excerpt(message: { content?: unknown }): string | null` — text blocks only, rules from Global Constraints; null when no text.
  - `function toolLine(toolName: string, args: unknown): { tool: string; target: string }`.
- `status` result gains `activity: { tool?: string; target?: string } | null` and `activitySeq: number` (last seq, 0 when empty).
- Event `activity` data: the `ActivityItem` plus `current` (same as status.activity).

- [ ] Tests (`test/activity.test.ts`): ring keeps last 200 and seq keeps increasing; `since(seq)` returns items after seq; `excerpt` collapses whitespace, cuts at 300 with `…`, ignores thinking/tool blocks, returns null for no text; `toolLine` uses path, then command (60 chars), else empty; `current()` set on start, cleared on matching end.
- [ ] Tests (`test/codeview.test.ts`): firing `tool_execution_start {toolName:"edit", args:{path:"a.ts"}}` broadcasts `activity` with `current {tool:"edit",target:"a.ts"}` and `status.activity` matches; `tool_execution_end` clears it; `message_end` with an assistant message broadcasts a `text` item with the excerpt; a user message (role user) adds a `prompt` item; `agent_settled` adds `settled` and clears current; `get_activity {since}` returns the tail. 250 tool events → `get_activity` returns 200 items.
- [ ] Implement; keep `loop.ts` changes small (delegate to ActivityLog).
- [ ] `npm test`, `npm run typecheck` pass; commit `feat: activity events and log in the extension`.

### Task 2: Statusline and activity log in Neovim

**Files:**
- Create: `nvim/lua/codeview/log.lua`, `nvim/tests/log_spec.lua`
- Modify: `nvim/lua/codeview/session.lua` (cache `activity`/`current` from status and events; on attach fetch `get_activity`), `nvim/lua/codeview/init.lua` (route `activity` events to log; `M.statusline()`; `:CodeviewLog` + `<leader>cl`), `test/e2e.nvim.test.ts`, `README.md`

**Interfaces:**
- `require("codeview").statusline() -> string`: `""` when not attached; else `"codeview: <label> · <state>"` where state is `review N`, `working · <tool> <target>` (target trimmed to 40 chars, tool alone if no target), `working`, or `idle`. Non-blocking (cached).
- `log.lua`: `M.append(items)`, `M.toggle()`, `M.open()`, `M.close()`, `M.visible()`, `M.clear()`; buffer `codeview://log`, `filetype=codeview-log`, `buftype=nofile`, `modifiable=false` except while appending; bottom split height 12; auto-scrolls when the cursor is on the last line; `q` closes. Line format: `prompt  ▸ <text>`, `agent   │ <text>`, `tool    ▸ <tool> <target>`, `ckpt    ✓ <note>`, `done    ─ run settled`; a `prompt` item starts with a blank separator line. Multi-line text is joined with ` ⏎ `.
- On attach: `get_activity {since=0}` fills the log buffer (without opening it).

- [ ] Specs: `log_spec` — append renders the formats above, separator before prompts, buffer not modifiable after append, `toggle` opens/closes, auto-scroll only when at bottom.
- [ ] e2e: extension + nvim: fire tool start → `statusline()` contains `working · edit a.ts`; tool end → `working` ; settled → `idle`; nvim attaching after 3 tool events gets them in the log buffer.
- [ ] README: statusline snippet and `<leader>cl`.
- [ ] Tests pass; commit `feat(nvim): statusline and activity log`.

### Task 3: Live changes in buffers

**Files:**
- Create: `nvim/lua/codeview/live.lua`, `nvim/tests/live_spec.lua`
- Modify: `nvim/lua/codeview/init.lua` (on `activity` tool end for a mutating tool, and on `chunk_ready`/`chunk_reviewed`, call `live.refresh(root, baseline)`), `nvim/lua/codeview/session.lua` (expose `baseline` from status), `extensions/loop.ts` (add `baseline: string` to `status`), `test/codeview.test.ts` (status has baseline), `test/e2e.nvim.test.ts`

**Interfaces:**
- `live.refresh(root, baseline)`: for every loaded, listed buffer whose realpath is inside root and not a `codeview://` buffer: if `modified`, skip reload and, if its file changed on disk since last check, warn once per file per baseline (`codeview: <path> changed on disk; your unsaved edits are kept`); else `checktime` it. Then compute changed line ranges vs `git show <baseline>:<path>` using `vim.diff(..., { result_type = "indices" })` and place signs (`▍`, hl `DiffChange`/`DiffAdd`) + line hl `CodeviewLive` (linked to `DiffText` dim) in namespace `codeview_live`.
- `live.clear()`: removes all live marks (called on detach/switch).
- Highlight group `CodeviewLive` defined with `default = true`.

- [ ] Specs (`live_spec`): with a temp repo + baseline commit, a changed file gets marks on exactly the changed lines; a modified buffer is not reloaded and warns once; `clear` removes marks; a file deleted vs baseline doesn't error.
- [ ] e2e: agent writes `a.txt` while nvim has it open → after the tool-end activity the buffer shows the new content and has marks; with an unsaved edit in nvim, content is kept and one warning appears.
- [ ] Tests pass; commit `feat(nvim): live reload and change marks while the agent works`.

### Task 4: Per-file explanation with the chunk

**Files:**
- Modify: `extensions/codeview.ts` (checkpoint params: optional `files: Array<{path: string; why: string}>`), `extensions/loop.ts` (`checkpoint(note, signal, files?)`), `extensions/state.ts` (`Chunk.why?: Record<string,string>`; createChunk accepts it), `extensions/render.ts` (CHECKPOINT_GUIDELINES gains: "Pass checkpoint files with one short line per changed file saying why it changed."), `nvim/lua/codeview/diff.lua` (header with note + current file's why above the diff, updated on file switch), tests in `test/codeview.test.ts`, `test/render.test.ts`, `nvim/tests/diff_spec.lua`, `test/e2e.nvim.test.ts`

**Interfaces:**
- `Chunk.why` keys are repo-relative paths; unknown paths are dropped; missing `files` → `why` absent.
- Diff view header: the winbar keeps its current content; above the right window a 2–3 line scratch window (or `virt_lines` on line 0 of the left buffer — pick the simpler that survives `]f`) shows `<note>` and `why: <text>` for the current file, or nothing for `why` when absent.

- [ ] Tests: checkpoint with files stores `why` on the chunk (status/list_chunks/get_chunk carry it); without files nothing breaks; guideline names `checkpoint` and mentions files; diff view shows note + why and updates on `]f`.
- [ ] Tests pass; commit `feat: per-file explanation with each chunk`.

### Task 5 (controller): README, nixos-config lualine component, bump, deploy

- Add the statusline to `modules/features/programs/nixvim/_plugins/lualine.nix` (lualine_x component calling `require("codeview").statusline()` guarded by `pcall`), bump `pi-codeview`, build all hosts, push.
