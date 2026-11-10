# pi-codeview — design

Date: 2026-11-10 · Status: draft for approval

## Intent

pi hides the codebase. While an agent works, Philipp often cannot see a
change until it is committed. As an engineer he builds his mental model of
a system by working with its code: reading it, judging it, changing it,
and leaving comments for the agent. Without that he loses the model, and
with it the ability to steer, debug and extend the system.

pi-codeview keeps the code in view while the agent works. The agent works
in review-sized chunks. At each chunk boundary it stops, Philipp reviews
the chunk in Neovim with his normal tooling, and he lets the agent continue
by engaging with the code (comments, his own edits, an explicit note), not
by clicking "accept".

It matters most in codebases he is building from the ground up, where the
mental model and the design invariants are still forming.

### Why this shape (research basis)

- Anthropic RCT (Jan 2026): AI-assisted developers scored 50% vs 67% on
  comprehension, with the biggest gap in debugging. Developers who
  generated code and then asked questions about it scored close to
  hand-coders. Active engagement afterwards is enough; passive acceptance
  is not.
- "(Im)Paired Programming" (2026): auto-accepted agent edits are linked to
  lower comprehension.
- Cognitive-debt grey-literature review (Oct 2026): "the unit of review is
  the unit of comprehension"; never generate more than you can review in a
  sitting. Shallow review sets in once volume exceeds bandwidth.
- Practitioners (Beck, Ronacher, Litt, Hashimoto): watch intermediate
  results and stop drift early; hold the global invariants; understand in
  order to participate, not only to verify; the human decides when to check
  in, not the agent.

## Goals

- The agent cannot run ahead of Philipp's review: it stops at chunk
  boundaries until he has reviewed.
- Chunks are review-sized and come with the agent's own note on what it did
  and why.
- Review happens in Neovim with LSP, go-to-definition and his own keymaps.
- Philipp's feedback reaches the agent before its next step: line comments,
  his own code edits, free-text notes.
- Every agent turn's changes are viewable before commit, even in vibe mode.
- Can be switched off per repo ("just vibecoding is fine here").
- Philipp can drive the whole loop from Neovim: give the agent a task,
  review its chunks, give the next task, back to back, without switching
  to the pi window.

## Non-goals (v1)

- Approving individual edits.
- Review surfaces other than Neovim (TUI overlay, browser, VS Code).
- Comprehension quizzes, generated explainer documents.
- Comments that outlive the session or live in the repository.
- Non-git working directories.
- Agents other than pi.

## Anti-goals (failure even if it technically works)

- Rubber-stamping: if continuing is as cheap as pressing Enter, the tool has
  rebuilt auto-accept with extra steps.
- Interrupting Philipp: the tool must not pull him out of his own work. He
  checks in when he chooses.
- Touching his branch, index or commit history without being asked.
- Heavy upkeep: two components and a protocol are the ceiling; no daemon,
  no database, no extra service.
- Slowing down vibe-mode projects in any noticeable way.

## Approaches considered

| | Approach | Trade-off | Decision |
|---|---|---|---|
| A | pi extension only; review with existing diffview/gitsigns against hidden refs; feedback as marker comments in source | One component, reuses known tools; no dedicated panel, markers pollute source | Rejected |
| B | pi extension + dedicated Neovim plugin over a local socket | Best review experience, comments stay out of files; two languages plus a protocol | **Chosen** |
| C | Review inside pi's TUI | Single window; no LSP, navigation or real editing — contradicts "working with the code" | Rejected |

Chunk boundaries considered: (1) agent-declared checkpoints with a hard
size cap — **chosen**; (2) one prompt = one chunk, which can produce
unreviewable chunks; (3) size-only cuts, which split mid-thought and carry
no explanation.

Prompting from Neovim considered: (1) Neovim sends prompts to a running
pi session over the socket, pi keeps its own UI — **chosen**; (2) Neovim
runs pi headless and renders its output, which means rebuilding pi's chat
UI in Lua.

Comment lifetime considered: (1) stored in the pi session — **chosen**;
(2) files in the repo with re-anchoring; (3) discarded once addressed.

## Decisions

### Components

1. **pi extension** (TypeScript), loaded as a pi package.
2. **codeview.nvim** (Lua) Neovim plugin.
3. Both live in one repository, `pi-codeview`, and share one versioned
   protocol. They are wired into nixos-config as a flake input (like
   `pi-impeccable`): the extension via pi `settings.packages`, the plugin
   via nixvim `extraPlugins`.

### Modes

- `review`: checkpoints active, agent blocks at chunk boundaries.
- `vibe`: no blocking. The `checkpoint` tool is not active (the agent does
  not see it). Snapshots are still recorded per turn, so past turns can be
  viewed in Neovim.
- Mode is stored per repo in local git config:
  `git config pi-codeview.mode review|vibe`. Never committed; shared by all
  worktrees of the repo. Unset means `vibe`.
- `/codeview on|off` sets the mode for the current repo (writes the git
  config) and applies it to the running session. Turning it on mid-session
  starts a new chunk from the current working-tree state.
- `/codeview` with no argument shows mode and current chunk state.

### Snapshots

- Each snapshot is a git tree of the full working tree (tracked plus
  untracked, respecting `.gitignore`), built with a temporary index
  (`GIT_INDEX_FILE`), never with the real index.
- Stored as commits under `refs/pi-codeview/<session-id>/<n>`. The branch,
  index, stash and HEAD are never touched.
- Taken at: session start / mode switch to review (baseline), after every
  file-changing step by the agent or Philipp (see Philipp editing while the
  agent works), every checkpoint, every review submission, and in vibe mode
  at every `turn_end` that changed files.
- A chunk is the diff between the snapshots at two consecutive
  checkpoints; the step snapshots in between say who changed what.
- Cleanup: refs for sessions older than a configurable age (default 14
  days) are deleted on session start.

### Chunks and the checkpoint tool

- In review mode the agent has a `checkpoint` tool with one parameter,
  `note` (what was done in this step and why). Its prompt guideline tells
  the agent to call it after each logical step and before starting the
  next.
- Calling `checkpoint` takes a snapshot, opens a chunk for review and
  **blocks** until the review is submitted. The tool result is the review
  (see Feedback below). The agent reads it before doing anything else.
- **Hard cap:** if the changed lines since the last snapshot exceed a
  threshold (default 150, configurable), the next `write`/`edit`/mutating
  tool call is blocked with a reason telling the agent to call
  `checkpoint` first. Bash commands that may write files cannot be detected
  reliably; the cap counts the working-tree diff on each `tool_call` for
  write/edit, and on `turn_end` for everything else.
- If a prompt ends (`agent_before_settle`) with unreviewed changes since the
  last checkpoint, the extension creates the chunk itself (note: "end of
  run, no checkpoint") and requests one continuation that blocks on it the
  same way. Nothing reaches "done" unreviewed.
- Waiting for review shows in pi's footer via `ctx.ui.setStatus`, e.g.
  `codeview: chunk 3 waiting for review`.

### Interruptions and resuming

Principle: Philipp's input is never lost, and picking the work back up is
one action.

- An open chunk survives Escape, quitting pi and resuming the session. Its
  state lives in the session log (`pi.appendEntry`), not only in memory.
- Unsent annotations are drafts stored by the extension as soon as they
  are added, so they survive restarts of Neovim and of pi.
- If the waiting `checkpoint` call is gone (Escape, quit), sending the
  review **resumes the agent**: the extension delivers it as a user message
  that contains the review and tells the agent to continue the interrupted
  task.
- A new prompt (from pi or Neovim) while a chunk is open is not dropped
  and does not skip the chunk: the review goes first, the prompt is queued
  right behind it. Philipp is told that the prompt is waiting on the
  review.
- Only one chunk can be open at a time, so chunks cannot pile up.
- `/codeview discard <note>` closes an open chunk without review, for when
  the work is being thrown away. The note is recorded in the session log.

### Philipp editing while the agent works

Philipp may edit the same checkout at any time, not only during review.

- Attribution is by event. The extension takes a snapshot after every
  agent tool call that may change files (`write`, `edit`, `bash`, other
  mutating tools) and the plugin reports every buffer save over the socket
  (`human_write` with the path), after which the extension also takes a
  snapshot. Each step between two snapshots belongs to whoever caused it.
  Changes made by bash commands count as the agent's.
- A chunk shows the agent's changes and Philipp's changes separately.
  His changes do not count toward the size cap.
- His changes reach the agent as human edits, labelled as intentional, at
  the next checkpoint. If he saves a file the agent has touched in the
  current chunk, the agent is told immediately (steer message: `Philipp
  changed FILE, re-read it before editing it`), so it does not work on a
  stale copy.
- Edits made outside Neovim (another editor, formatter run by hand) are
  not reported and land in the agent's side. This is accepted for v1.
- Only one review-mode pi session per worktree. A second one refuses to
  enter review mode and says why.

### Feedback

A submitted review consists of any combination of:

- **Annotations** (any number, across files), anchored to file + line
  range in the chunk's snapshot. See Prompting from Neovim.
- **Philipp's own edits**: everything attributed to him since the last
  checkpoint (see Philipp editing while the agent works), sent as a diff
  labelled as human changes. The agent must treat them as intentional, and
  they become part of the new baseline.
- **A general note** (free text).
- **Continue with no remarks** is allowed, but the plugin requires the chunk
  to have been opened (at least one file viewed) before it can be sent. No
  one-key accept from the panel list.

The tool result rendered to the agent is plain text: the note, the
annotations (file:line range, quoted code, note), the human-edit diff.

### Prompting from Neovim

- pi keeps running in its own pane or terminal with its full UI (history,
  model switching, `/` commands). The setup does not depend on a terminal
  multiplexer: Philipp uses herdr, and the socket works with any layout.
- The plugin sends prompts to the attached pi session over the socket,
  optionally with context: the current file, or a visual selection with
  file and line range. The extension delivers them with
  `pi.sendUserMessage` (as a new prompt when idle, as a follow-up when the
  agent is busy).
- The loop: prompt from Neovim, the agent works, the chunk is pushed to
  Neovim (`chunk_ready`), Philipp reviews and sends, the agent continues,
  and when the run settles Neovim shows it is ready for the next prompt
  (`run_settled` event).
- **Annotations** are the one mechanism for pointing the agent at code,
  in review and outside it. Philipp adds any number of them across files
  (a line or visual range plus a note), sees the pending list, and sends
  them together with an optional overall instruction. They are extmarks,
  never written into the file, and they follow the code while he edits
  before sending. Each annotation reaches the agent as file:line range,
  quoted code and note.
- What sending does depends on the agent's state:
  - a chunk is waiting: they are sent as that chunk's review;
  - the agent is idle: they are sent as a new prompt;
  - the agent is working (no chunk waiting): they are queued as a
    follow-up.
- Annotations are always placed on the live code. On send, the extension
  first takes a snapshot, and the line ranges and quoted code refer to that
  snapshot. Past chunks open read-only for viewing; feedback goes on the
  current code. The annotations are stored with the snapshot in the
  session log.
- The agent's streaming output is not mirrored into Neovim in v1; it
  stays visible in the pi pane. Neovim shows only state (working /
  waiting for review / idle).

### Escape hatch without Neovim

`/codeview continue <note>` in pi submits a review for the waiting chunk
with a mandatory non-empty note. Escape behaves as described under
Interruptions and resuming.

### Comments: storage and lifetime

- Stored in the pi session log via `pi.appendEntry` (not in LLM context by
  themselves; they reach the agent only through the tool result).
- Anchored to the snapshot they were written on, so they never need
  re-anchoring.
- After submission they leave the active view and stay in the chunk's
  history in the panel.

### Neovim plugin (codeview.nvim)

- **Panel**: list of chunks in the current session: number, agent note,
  files, status (waiting / reviewed / vibe-recorded), comment count.
- **Chunk view**: opens the chunk's diff, file by file, in normal buffers
  where LSP and navigation work. For the open chunk, the right-hand side is
  the live working-tree file, so Philipp can edit in place. Past chunks
  show snapshot against snapshot, read-only.
- **Comments**: review comments are annotations (see Prompting from
  Neovim), shown as virtual text or extmarks, never written into the file.
- **Send review**: collects comments and the general note and sends the
  review. The extension computes the human-edit diff itself.
- Works in vibe mode as a read-only history viewer (no send).

### Protocol

- One Unix domain socket per pi session at
  `$XDG_RUNTIME_DIR/pi-codeview/<repo-hash>/<session-id>.sock`, where
  repo-hash identifies the repository's common git dir (so worktrees of the
  same repo are grouped but each session is distinct).
- Newline-delimited JSON, request/response plus server-pushed events
  (`chunk_ready`, `chunk_reviewed`, `mode_changed`, `run_settled`).
- Requests include `prompt` (text plus optional file/selection context),
  `submit_review`, `save_draft_annotations`, `human_write`, `list_chunks`,
  `get_chunk`, `set_mode`.
- The plugin finds sockets for the repo of the current buffer. With several
  sessions it asks which one to attach to.
- The protocol carries a version number; mismatches are reported and
  refused.

## Left to the builder

- Exact diff rendering in Neovim: building on diffview.nvim (already in
  Philipp's config) or a small custom split diff.
- Panel layout, keymaps (defaults under a `<leader>c…` prefix are fine) and
  highlight groups.
- JSON message schemas, as long as they are versioned and documented in
  the repo.
- How the extension counts changed lines for the cap (`git diff --numstat`
  against the last snapshot is fine).
- Test strategy, within the constraint that snapshot/ref handling is tested
  against real git repositories.
- The exact wording of the `checkpoint` tool's prompt guideline.

## Later (not v1)

- The agent can hand a piece of work to Philipp at a checkpoint ("you write
  the retry policy"), and his code becomes the input to its next step.
- Asking the agent about a line from Neovim, not only commenting.
- Skeleton-first chunks in new codebases (types and interfaces first).
- Litt-style ordered explanation ("literate diff") and comprehension quiz
  per chunk.
