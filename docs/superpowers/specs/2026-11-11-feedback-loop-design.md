# pi-codeview — feedback loop while the agent works

Date: 2026-11-11 · Status: approved by Philipp (four features, in order)

## Why

After sending a prompt from Neovim, Philipp sees nothing until a chunk
arrives. Between prompt and checkpoint he cannot tell whether the agent is
alive, what it is touching, or why. The point of pi-codeview is keeping him
in the code while the agent works, so the code itself should move in front
of him, with a thin line of context about what is happening.

## Features (build order)

1. **Statusline.** A lualine component shows
   `codeview: <session> · working · edit src/foo.al` (or `review N`, `idle`).
   The extension forwards each tool start/end as an `activity` event; the
   plugin keeps the current tool and target cached. Never blocks.
2. **Live changes.** When the agent finishes a tool that may change files,
   buffers whose file changed on disk reload (`checktime`), and changed
   lines get a sign and a light highlight against the chunk's baseline
   snapshot, while the agent works. A buffer with unsaved edits by Philipp
   is never reloaded; he gets one warning naming the file instead. Signs
   are recomputed when a chunk is reviewed (the baseline moves).
3. **Activity log.** `<leader>cl` toggles a read-only split that fills as
   the agent works: Philipp's prompt, short excerpts of the agent's text
   (first ~300 chars per message), one line per tool call
   (`edit src/foo.al`, `bash npm test`), each checkpoint note, and run end.
   A new prompt starts a new section; the last ~200 entries are kept by the
   extension so a freshly attached nvim sees recent history. The pi pane
   stays the full transcript.
4. **Explanation with the chunk.** The `checkpoint` tool takes an optional
   `files` list `[{ path, why }]`, one short line per changed file. The
   chunk diff view shows the chunk note and the current file's `why` above
   the diff and updates on `]f`/`[f`. The checkpoint guidelines ask the
   agent to fill it.

## Decisions

- Activity is in memory only (not in the session log), capped at 200 items.
- Excerpts, not the token stream: activity is sent on `message_end`, not
  per delta.
- Live signs use their own namespace and are cleared when codeview
  detaches or the buffer is not in the attached worktree.
- Statusline component lives in nixos-config (`lualine.nix`), using
  `require("codeview").statusline()`, which returns "" when not attached.

## Non-goals

- Streaming tokens into Neovim.
- Mirroring pi's full chat UI.
- Showing thinking blocks.
