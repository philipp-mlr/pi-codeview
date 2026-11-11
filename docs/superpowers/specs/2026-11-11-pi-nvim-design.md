# pi.nvim — design

Date: 2026-11-11 · Status: draft for approval

## Intent

pi-codeview started as a review tool: the agent stops at checkpoints and
Philipp reviews each chunk in Neovim. In daily use he wants something
broader: his own pi plugin for Neovim, the everyday way to work with pi
from the editor, replacing pablopunk's pi.nvim in his config. Review stays,
but as an opt-in mode for the times he wants to be forced to look at every
step ("checkpoint mode").

The project is renamed to **pi.nvim**. What it keeps from codeview is the
core idea: the code stays in view. He asks from his editor with real
context (file, selection, cursor line, diagnostics), sees what the agent is
doing (statusline, buffers reloading, change marks), and can point the
agent at lines with notes.

## Goals

- Ask pi from Neovim with the file, cursor line or selection, unsaved
  buffer text, and LSP diagnostics as context.
- See what the agent does while it works: statusline, live reload of
  unmodified buffers, change marks.
- Leave notes on lines and send them to the agent; notes are clearly
  visible in the buffer.
- Cancel the agent's current run from Neovim.
- Choose and switch the pi session per worktree.
- Checkpoint mode (opt-in, per repo): today's review loop, unchanged in
  behaviour.
- All keys under `<leader>p`.
- pablopunk's pi.nvim leaves Philipp's config; this plugin replaces it.

## Non-goals

- The activity log (dropped: pi's own window already shows the same, and
  the statusline plus live marks cover the "what is it doing" need).
- Running pi headless from Neovim (pablopunk's model). pi keeps running in
  its own window; Neovim talks to that session.
- Streaming the agent's text into Neovim.

## Decisions

### Name and identifiers

| Thing | Old | New |
|---|---|---|
| GitHub repo | philipp-mlr/pi-codeview | philipp-mlr/pi-nvim (GitHub redirects the old URL) |
| Local checkout | ~/repos/pi-codeview | ~/repos/pi-nvim |
| npm package name | pi-codeview | pi-nvim |
| Lua module | `require("codeview")`, `codeview.*` | `require("pi")`, `pi.*` |
| User commands | `:Codeview*` | `:Pi*` (see Keys) |
| pi command | `/codeview on\|off\|continue\|discard` | `/checkpoints on\|off\|continue <note>\|discard <note>`; `/checkpoints` alone shows state |
| Git config | `pi-codeview.mode` (+ `.cap`, `.retentionDays`) | `pi-nvim.checkpoints` (bool), `pi-nvim.cap`, `pi-nvim.retentionDays` |
| Snapshot refs | `refs/pi-codeview/<session>/<n>` | `refs/pi-nvim/<session>/<n>` |
| Socket dir | `$XDG_RUNTIME_DIR/pi-codeview/<hash>/` | `$XDG_RUNTIME_DIR/pi-nvim/<hash>/` |
| Session log entry | `pi-codeview-state` | `pi-nvim-state` |
| Steer message customType | `pi-codeview` | `pi-nvim` |
| pi footer status key | `codeview` | `pi-nvim` |
| Namespaces / augroup | `codeview`, `codeview_live`, `codeview_why` | `pi_notes`, `pi_live`, `pi_why`; augroup `pi` |
| Scratch buffers | `codeview://…` | `pi://…` |
| Highlight groups | `CodeviewLive*` | `PiLive`, `PiLiveAdd`, `PiLiveChange`, `PiLiveDelete`, `PiNote`, `PiNoteSign` |

Migration (read old, write new; no manual steps):
- `pi-nvim.checkpoints` unset → fall back to `pi-codeview.mode` (`review`
  or `on` → true). Switching the mode always writes
  `pi-nvim.checkpoints` explicitly (`true`/`false`), so the old key never
  overrides a later choice; the old key is left untouched.
- Restore state from the last `pi-nvim-state` entry, else the last
  `pi-codeview-state` entry.
- Ref pruning covers both `refs/pi-nvim/` and `refs/pi-codeview/`.

### Modes

- **Default (checkpoints off):** nothing blocks; no `checkpoint` tool;
  snapshots recorded per turn as today (vibe mode). The word "vibe" leaves
  the UI.
- **Checkpoint mode:** today's review mode, unchanged in behaviour.
- Internally `Mode = "checkpoints" | "off"`. Protocol `status.mode` uses
  those values; `set_mode` accepts `checkpoints`/`on`/`review` and
  `off`/`vibe`.
- `PROTOCOL_VERSION` becomes 2. A Neovim plugin and a pi extension of
  different versions refuse each other with the existing clear message.

### Keys (all under `<leader>p`)

| Key | Command | Action |
|---|---|---|
| `pa` | `:PiAsk` | Ask pi. Normal: file + cursor line + file diagnostics. Visual: selection text + range + its diagnostics. |
| `pc` | `:PiCancel` | Cancel the agent's current run (pi's abort). In checkpoint mode a waiting chunk stays open, as with Escape in pi. |
| `ps` | `:PiSession` | Choose the pi session for this worktree. |
| `pn` | `:PiNote` | Note on the line / selection. |
| `px` | `:PiNoteRemove` | Remove the note at the cursor. |
| `pr` | `:PiSend` | Send notes (+ optional message). In checkpoint mode: the review of the open chunk. |
| `pv` | `:PiChunks` | Chunk panel. |
| `pm` | `:PiCheckpoints [on\|off]` | Toggle checkpoint mode; says which mode is now on. |

Default keys still never replace an existing mapping (current behaviour).
`<leader>pl` (log) is gone.

### Delivery (unchanged, stated for the builder)

- Ask and note-send use the existing path: idle → `sendUserMessage` starts a
  run; busy → `deliverAs: "followUp"`. In checkpoint mode, with a chunk
  open, a prompt is queued behind the review as today.
- Unsaved buffer text: as today. Visual mode sends the selected text from
  the buffer; normal mode sends path and cursor line and flags the buffer
  as unsaved when it is modified. The whole buffer is not sent. (Builder's
  call, recorded: keeps prompts small and the human-write tracking intact.)

### Cancel

- `:PiCancel` sends a new request `cancel`; the extension calls
  `ctx.abort()` when pi is not idle and replies `{ cancelled: boolean }`.
- In checkpoint mode a waiting `checkpoint` call ends exactly as with
  Escape in pi today (it returns "Review pending…", the chunk stays open
  and persisted, and a later send resumes the agent via the existing
  resume path, covered by the existing test).

### Diagnostics as context

- Collected with `vim.diagnostic.get(buf)`, severity ERROR and WARN only.
- Ask in normal mode: the whole file; visual mode: lines of the selection.
  Notes: the diagnostics on the note's lines.
- At most 20 per prompt or note, errors first, then by line.
- Wire: `PromptContext.diagnostics?` and `Annotation.diagnostics?`, each
  `{ line: number; severity: "error" | "warning"; message: string; source?: string }`.
- Rendered for the agent under the context or note:
  `Diagnostics:` then one line each, `  <path>:<line> <severity> <message> [<source>]`,
  message whitespace-collapsed and cut at 200 characters.

### Notes are visible

(Fixes the reported "I don't see annotations".)
- The note text is shown on its own line below the noted range
  (`virt_lines`), `  ✎ <note>`, highlight `PiNote` (default linked to
  `DiagnosticInfo`), not at end of line.
- Sign `✎` on the first line with a priority above live marks and
  gitsigns; highlight `PiNoteSign`.
- The whole range is marked in the number column (`number_hl_group`
  `PiNoteSign`), so a multi-line note reads as one block.

### Statusline

`require("pi").statusline()`: `pi: <session> · working · edit a.ts`,
`· review N` when a chunk is open, `· idle`; `[checkpoints]` after the
session name only while checkpoint mode is on; `""` when not attached.

### Log removal

- Neovim: `log.lua`, its spec, `:CodeviewLog` and the key go away.
- Extension: the activity ring, `get_activity`, `activitySeq`, text and
  prompt excerpts and the `activity` item event go away. What stays is the
  current-tool tracking and one event, `activity_current { current,
  mutating?, busy }`, sent on tool start, tool end, run start and run
  settle — enough for the statusline and live reload.

### Order of the rename

1. Code and tests renamed inside the repo; all suites green.
2. Rename the GitHub repo to `philipp-mlr/pi-nvim` (`gh repo rename`;
   GitHub redirects the old URL) and the local checkout to
   `~/repos/pi-nvim`; push; CI green.
3. Only then the nixos-config change below (it needs the new repo to
   exist), built for all hosts before pushing.

### Config (nixos-config)

- Remove the `pi-nvim` (pablopunk) flake input, `_plugins/pi-nvim.nix`
  and its keymaps; the old design docs in `docs/superpowers/` stay as
  history.
- New flake input `pi-nvim = github:philipp-mlr/pi-nvim` (flake = false);
  pi's `settings.packages` and the nixvim plugin build use it.
- `_plugins/codeview.nix` becomes `_plugins/pi-nvim.nix` with
  `require("pi").setup({})`.
- lualine component calls `require("pi").statusline()`.

## Approaches considered

| | Approach | Trade-off | Decision |
|---|---|---|---|
| 1 | Rename to pi.nvim, review becomes opt-in checkpoint mode | Touches every file, mechanically; name matches "our own pi-nvim" | **Chosen** |
| 2 | Keep the codeview name, change keys and default mode | Less churn; name keeps sounding like a review tool | Rejected |

Log: keep vs drop → dropped (duplicates pi's window; less code).

## Left to the builder

- Exact command names beyond those listed, and the wording of messages.
- Internal file layout (the `ReviewLoop` class may keep its name or become
  `Session`; renames inside are free as long as behaviour is unchanged).
- How the README is restructured: lead with everyday use; checkpoint mode
  and the research section move below it.

## Later

- Per-file why for checkpoint chunks stays as built.
- Possible: send the quickfix list or a picked diagnostic as context.
