# pi-codeview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pi extension and a Neovim plugin that hold the agent at
review-sized checkpoints, let Philipp review, annotate, edit and prompt
from Neovim, and record every change to hidden git refs.

**Architecture:** The pi extension owns all state: snapshots under hidden
git refs, a pure state machine for chunks, steps, drafts and queued
prompts (persisted to the session log), the `checkpoint` tool, and a Unix
socket server that speaks newline-delimited JSON. codeview.nvim is a thin
client. It discovers the socket for the current repo, shows chunks and
diffs, keeps annotations as extmarks, and reports buffer saves.

**Tech Stack:** TypeScript (ES2023, NodeNext, strict), vitest 3, Node 22+,
`@earendil-works/pi-coding-agent` (peer), `typebox`; Lua for Neovim 0.11+
(`vim.uv`, extmarks), tests run with `nvim --headless -l`.

**Spec:** `docs/superpowers/specs/2026-11-10-pi-codeview-design.md`

## Global Constraints

- Mode lives in local git config `pi-codeview.mode` with values `review` and `vibe`; unset means `vibe`.
- Snapshot refs: `refs/pi-codeview/<session-id>/<n>`. Never touch the branch, the real index, stash or HEAD. Build snapshots with a temporary `GIT_INDEX_FILE`.
- Default size cap: 150 changed lines (agent-attributed only). Default ref retention: 14 days. Both configurable through git config `pi-codeview.cap` and `pi-codeview.retentionDays`.
- Socket path: `$XDG_RUNTIME_DIR/pi-codeview/<repo-hash>/<session-id>.sock`, where `<repo-hash>` = first 12 hex chars of sha256 of the realpath of `git rev-parse --git-common-dir`. Fall back to `os.tmpdir()` when `XDG_RUNTIME_DIR` is unset.
- Protocol: newline-delimited JSON, `PROTOCOL_VERSION = 1`. A mismatched version is refused with an error naming both versions.
- Only one chunk can be open at a time. Only one review-mode session per worktree.
- In vibe mode the `checkpoint` tool is inactive and nothing blocks; snapshots are still recorded at `turn_end` when files changed.
- No accept-with-one-key: sending a review with no annotations, note or human edits requires `viewed: true` from the plugin.
- Commands: `/codeview`, `/codeview on`, `/codeview off`, `/codeview continue <note>` (note required), `/codeview discard <note>` (note required).
- Outside a git repo the extension registers its commands but stays inactive, and `/codeview` says why.
- Commits use conventional subjects. Commit signing is on in Philipp's setup; if the key is unavailable, stop and report instead of disabling signing.

## Review Focus

1. **Brand-new repo with no commits** (the main use case is greenfield work). Snapshots and diffs must work without HEAD. Test in Task 2.
2. **Unusual files**: paths with spaces or unicode, binary files, deleted files, new untracked files. `--numstat` reports binary files as `-`, which must count as 0 lines and not crash. Test in Task 2.
3. **Escape while `checkpoint` is waiting**: the tool returns, the chunk stays open and is persisted, and a later send resumes the agent through `sendUserMessage` without losing drafts. Test in Task 6.
4. **Stale socket or pi gone**: a leftover `.sock` file must not stop a new server from starting, and the plugin must skip dead sockets instead of erroring. Tests in Tasks 5 and 8.
5. **pi started in a subdirectory or worktree**: all paths on the wire are relative to the worktree root; the plugin converts buffer paths the same way. Tests in Tasks 2 and 8.

---

## File Structure

```
package.json, tsconfig.json, vitest.config.ts, .gitignore
extensions/
  codeview.ts     entry: wires pi events, tool, commands, server
  git.ts          snapshots, diffs, refs, repo hash, mode/config
  state.ts        pure state machine (chunks, steps, drafts, queue)
  render.ts       text sent to the agent
  protocol.ts     message types, PROTOCOL_VERSION, NDJSON framing
  server.ts       Unix socket server
test/
  helpers/repo.ts     temp git repo fixture
  helpers/fake-pi.ts  fake ExtensionAPI + ctx for driving events
  git.test.ts, state.test.ts, render.test.ts, protocol.test.ts,
  server.test.ts, codeview.test.ts, e2e.nvim.test.ts
nvim/
  lua/codeview/init.lua         setup, commands, keymaps, autocmds
  lua/codeview/discover.lua     repo hash + socket discovery
  lua/codeview/client.lua       socket client, requests, events
  lua/codeview/annotations.lua  extmarks, drafts, collection
  lua/codeview/panel.lua        chunk list
  lua/codeview/diff.lua         chunk diff views
  tests/run.lua                 minimal headless test runner
  tests/*_spec.lua
```

Shared types. `Mode` is exported from `git.ts` (Task 2); the rest are
exported from `state.ts` (Task 3), which re-exports `Mode`:

```ts
type Author = "agent" | "human";
type Step = { sha: string; author: Author; files: string[]; lines: number };
type Annotation = { path: string; startLine: number; endLine: number; note: string; quote?: string };
type ChunkStatus = "open" | "reviewed" | "discarded" | "recorded";
type Chunk = {
  n: number; note: string; status: ChunkStatus;
  fromSha: string; toSha: string;
  agentFiles: string[]; humanFiles: string[];
  annotations: Annotation[]; reviewNote?: string;
};
type Mode = "review" | "vibe";
```

---

### Task 1: Scaffold the package

**Files:**
- Create: `package.json`, `tsconfig.json`, `vitest.config.ts`, `.gitignore`, `extensions/codeview.ts`, `test/smoke.test.ts`

**Interfaces:**
- Produces: `export default function codeview(pi: ExtensionAPI): void` in `extensions/codeview.ts`.

- [ ] **Step 1:** Create `package.json` modelled on `~/repos/pi-impeccable/package.json`: name `pi-codeview`, version `0.1.0`, `"type": "module"`, keywords `["pi-package"]`, `"pi": { "extensions": ["./extensions/codeview.ts"] }`, `files` `["extensions", "nvim", "README.md", "LICENSE"]`, scripts `test`, `typecheck`, `test:nvim` (`nvim --headless -l nvim/tests/run.lua`). Same peer/dev dependencies as pi-impeccable, plus `typebox`. Copy `tsconfig.json` and `vitest.config.ts` from pi-impeccable. Add `.superpowers/` and `node_modules/` to `.gitignore`. Add an MIT `LICENSE`.
- [ ] **Step 2:** Write `test/smoke.test.ts`: it imports the default export and asserts `typeof codeview === "function"`.
- [ ] **Step 3:** Run `npm install && npm test`. Expected: FAIL (module missing).
- [ ] **Step 4:** Create `extensions/codeview.ts` with an empty default export.
- [ ] **Step 5:** Run `npm test && npm run typecheck`. Expected: both pass.
- [ ] **Step 6:** Commit with the subject `chore: scaffold pi-codeview package`.

### Task 2: Git layer (snapshots, diffs, refs, config)

**Files:**
- Create: `extensions/git.ts`, `test/helpers/repo.ts`, `test/git.test.ts`

**Interfaces:**
- Produces, all async and all taking `root` (the worktree root):
  - `findRoot(cwd: string): Promise<string | null>`: `git rev-parse --show-toplevel`; null outside a repo.
  - `repoHash(root: string): Promise<string>`: see Global Constraints.
  - `snapshot(root: string, ref: string, message: string): Promise<string>`: writes the full working tree (tracked and untracked, `.gitignore` respected) to a commit via a temp index (`git add -A` with `GIT_INDEX_FILE` set to a temp file seeded by `git read-tree HEAD` when HEAD exists), then `commit-tree` with no parent and `update-ref`. Returns the commit sha.
  - `numstat(root: string, from: string, to: string): Promise<{ path: string; lines: number }[]>`: added plus deleted; binary counts 0.
  - `diffText(root: string, from: string, to: string, paths?: string[]): Promise<string>`: unified diff.
  - `showFile(root: string, sha: string, path: string): Promise<string | null>`: null if the file is absent at that sha.
  - `pruneRefs(root: string, olderThanDays: number): Promise<number>`: deletes `refs/pi-codeview/*` whose commit date is older than the threshold and returns the count.
  - `readConfig(root: string): Promise<{ mode: Mode; cap: number; retentionDays: number }>` and `writeMode(root: string, mode: Mode): Promise<void>`.
- `test/helpers/repo.ts` produces `makeRepo(opts?: { commit?: boolean }): Promise<{ root: string; write(path: string, text: string): void; rm(path: string): void; git(...args: string[]): Promise<string> }>`. It sets `user.name`, `user.email` and `commit.gpgsign=false` locally, so tests never need a signing key.

- [ ] **Step 1:** Write `test/git.test.ts` with these tests:
  - `snapshot works in a repo with no commits`: makeRepo `{commit:false}`, write `a.ts`, snapshot to `refs/pi-codeview/s/0`; `showFile(sha,"a.ts")` equals the content; `git rev-parse HEAD` still fails.
  - `snapshot leaves branch, index and HEAD untouched`: committed repo, stage a change to `b.ts`, snapshot; afterwards `git diff --cached --name-only` still prints `b.ts` and HEAD is unchanged.
  - `snapshot includes untracked and respects .gitignore`: `.gitignore` contains `out/`; write `new.ts` and `out/x.js`; snapshot contains `new.ts` and not `out/x.js`.
  - `numstat counts added+deleted, binary as 0, handles spaces and unicode`: files `my file.ts` (3 lines added), `ä.ts`, and a binary `img.bin`; expect lines 3 for the first and 0 for `img.bin`.
  - `numstat reports deletions`: delete a file between two snapshots and expect its line count.
  - `findRoot from a subdirectory returns the worktree root` and `returns null outside a repo`.
  - `repoHash is equal for two worktrees of one repo`: `git worktree add` and compare.
  - `pruneRefs deletes only old refs`: create one ref with `GIT_COMMITTER_DATE` 20 days ago and one now; `pruneRefs(root, 14)` returns 1.
  - `readConfig defaults to vibe/150/14`, and `writeMode` persists to `git config --local`.
- [ ] **Step 2:** Run `npx vitest run test/git.test.ts`. Expected: FAIL.
- [ ] **Step 3:** Implement `extensions/git.ts` with `node:child_process` `execFile`, not a shell, so paths with spaces are safe. Use `-z` output parsing for numstat.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit with the subject `feat: git snapshots, diffs and config`.

### Task 3: State machine

**Files:**
- Create: `extensions/state.ts`, `test/state.test.ts`

**Interfaces:**
- Produces the shared types above, plus `class CodeviewState`:
  - `constructor(init?: Serialized)`, `serialize(): Serialized` (plain JSON).
  - `mode: Mode`, `baseline: string` (sha), `chunks: Chunk[]`, `steps: Step[]` (since the last checkpoint), `drafts: Annotation[]`, `queuedPrompts: string[]`.
  - `setBaseline(sha: string): void`: clears `steps`.
  - `recordStep(step: Step): void`.
  - `agentLines(): number`: the sum of `lines` over agent steps.
  - `agentFiles(): string[]` and `humanFiles(): string[]` (unique, ordered).
  - `openChunk(): Chunk | undefined`.
  - `createChunk(note: string, toSha: string, status?: "open" | "recorded"): Chunk`: uses `fromSha = baseline` and the attribution from `steps`, then sets the baseline to `toSha`. It throws `Error("chunk already open")` when one is open and status is `open`.
  - `closeChunk(n: number, outcome: { status: "reviewed" | "discarded"; annotations: Annotation[]; reviewNote?: string }): Chunk`.
  - `canSend(input: { annotations: number; note: string; humanEdits: number; viewed: boolean }): boolean`: true when any count is greater than 0, the note is non-empty, or `viewed` is true.
  - `queuePrompt(text: string): void` and `takeQueuedPrompts(): string[]`.
  - `setDrafts(a: Annotation[]): void`.

- [ ] **Step 1:** Write `test/state.test.ts`:
  - `createChunk attributes steps`: two agent steps (`a.ts` 10 lines, `b.ts` 5 lines) and one human step (`c.ts`); the chunk has `agentFiles` `["a.ts","b.ts"]` and `humanFiles` `["c.ts"]`; `agentLines()` resets to 0.
  - `human lines do not count toward agentLines`.
  - `only one open chunk`: a second `createChunk` throws `chunk already open`; `recorded` is allowed.
  - `canSend refuses an empty, unviewed review`: `{0,"",0,false}` gives false; `{0,"",0,true}` gives true; `{1,"",0,false}` gives true.
  - `serialize/restore round-trips` chunks, steps, drafts, queue and mode.
  - `takeQueuedPrompts drains the queue`.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement. No I/O in this file.
- [ ] **Step 4:** Run it. Expected: PASS.
- [ ] **Step 5:** Commit with the subject `feat: codeview state machine`.

### Task 4: Rendering the agent's input

**Files:**
- Create: `extensions/render.ts`, `test/render.test.ts`

**Interfaces:**
- Produces:
  - `renderReview(r: { chunk: Chunk; annotations: Annotation[]; note: string; humanDiff: string }): string`
  - `renderResume(review: string, queued: string[]): string`
  - `renderAnnotationPrompt(annotations: Annotation[], instruction: string): string`
  - `humanChangedSteer(path: string): string`
  - `CHECKPOINT_GUIDELINES: string[]`

- [ ] **Step 1:** Write the tests:
  - `renderReview lists annotations as path:start-end with quoted code and note`. It contains `src/a.ts:3-5`, the quote in a fenced block, and the note.
  - `renderReview labels human edits as intentional`. It contains `Philipp changed these files himself. Treat the changes as intentional` followed by the diff. The section is omitted when the diff is empty.
  - `renderReview with nothing but viewed says the chunk was reviewed with no remarks`.
  - `renderResume tells the agent to continue the interrupted task and appends queued prompts in order`. It contains `Continue the task that was interrupted`, then each queued prompt under `Then:`.
  - `humanChangedSteer` equals `Philipp changed <path>. Re-read it before editing it.`
  - `CHECKPOINT_GUIDELINES` names `checkpoint` in every line, says to call it after each logical step and before starting the next, and says the note states what was done and why.
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Implement as plain string building.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit with the subject `feat: render reviews and prompts for the agent`.

### Task 5: Protocol and socket server

**Files:**
- Create: `extensions/protocol.ts`, `extensions/server.ts`, `docs/protocol.md`, `test/protocol.test.ts`, `test/server.test.ts`

**Interfaces:**
- `protocol.ts` produces `PROTOCOL_VERSION = 1` and these message types:
  - Request: `{ id: number; type: RequestType; ...payload }`, where `RequestType` is one of:
    - `hello {version}`
    - `status`
    - `list_chunks`
    - `get_chunk {n}`, which returns the chunk plus its `diff: string`
    - `prompt {text, context?: {path, startLine?, endLine?}}`
    - `send {annotations: Annotation[], note: string, viewed: boolean}`
    - `save_drafts {annotations}`
    - `human_write {path}`
    - `set_mode {mode}`
  - Response: `{ id, ok: true, result } | { id, ok: false, error: string }`.
  - Event: `{ event: "chunk_ready" | "chunk_reviewed" | "mode_changed" | "run_settled" | "state", data }`.
  - `class LineDecoder { push(chunk: string): unknown[] }` buffers partial lines.
  - `encode(msg: object): string` adds a trailing `\n`.
- `server.ts` produces:
  - `startServer(opts: { path: string; handle(req: Request): Promise<unknown> }): Promise<{ broadcast(e: Event): void; close(): Promise<void> }>`.
  - It creates parent directories with mode `0700`. If the path exists, it tries to connect: a refused connection means the file is stale and is unlinked. A successful connection throws `Error("socket in use")`.
  - Requests are handled only after `hello` with a matching version. Otherwise the reply is `ok:false` with `protocol version mismatch: server 1, client N`.
- `docs/protocol.md` lists every message with an example. This is the documentation the spec requires.

- [ ] **Step 1:** Write the tests:
  - `LineDecoder handles split and multiple lines`.
  - `server answers after hello` (use `net.connect` against a temp path).
  - `server refuses version mismatch` with that error text.
  - `server replaces a stale socket file`: create a plain file at the path and check that start succeeds.
  - `server refuses a live socket`: start two servers on one path; the second rejects with `socket in use`.
  - `broadcast reaches every client`.
  - `handler errors become ok:false responses`.
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Implement using `node:net`.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit with the subject `feat: ndjson protocol and socket server`.

### Task 6: Extension wiring (the review loop)

**Files:**
- Modify: `extensions/codeview.ts`
- Create: `test/helpers/fake-pi.ts`, `test/codeview.test.ts`

**Interfaces:**
- Consumes: everything from Tasks 2–5.
- `test/helpers/fake-pi.ts` produces `makeFakePi(cwd: string)`, which returns:
  - `pi`: implements the `ExtensionAPI` subset used: `on`, `registerTool`, `registerCommand`, `setActiveTools`, `getActiveTools`, `sendMessage`, `sendUserMessage`, `appendEntry`.
  - `fire(event, payload)`: runs the handlers and returns their results.
  - `callTool(name, params, signal?)`.
  - `runCommand(name, args)`.
  - `sent`: recorded `sendMessage` and `sendUserMessage` calls.
  - `entries`: appended entries.
  - `ctx`: `cwd`, `ui.setStatus`, `ui.notify`, `sessionManager.getSessionId()` returning `"test-session"`, `getEntries()` returning `entries`, and `isIdle()`, which is controllable.
- Behaviour to implement in `codeview.ts`, as decided by the spec:
  - `session_start`: `findRoot`; if null, stay inactive. Otherwise:
    - `pruneRefs` and `readConfig`.
    - Restore `CodeviewState` from the last `pi-codeview-state` entry, if any.
    - Take the baseline snapshot.
    - Start the server at the socket path.
    - Set the active tools for the mode.
  - Persistence: after every state change, call `pi.appendEntry("pi-codeview-state", state.serialize())`.
  - `checkpoint` tool, parameter `note: string`, with guidelines `CHECKPOINT_GUIDELINES`:
    1. Snapshot.
    2. `createChunk(note, sha)`.
    3. Broadcast `chunk_ready`.
    4. Set the status to `codeview: chunk N waiting for review`.
    5. Await the review promise, or `signal` abort.
    - On review: return `renderReview(...)` as the tool content.
    - On abort: return `Review pending. Philipp will send it later.` The chunk stays open.
  - Step attribution: on `tool_result` for any tool other than `read`, `checkpoint`, or tools whose names start with `lens_`, `module_report` or `symbol_search`, take a snapshot. A non-empty numstat against the previous step's sha records an agent step. (Use a deny-list of read-only tools; when unsure, a tool counts as mutating.)
  - Size cap: on `tool_call` for a mutating tool in review mode, when `agentLines() > cap`, return `{ block: true, reason: "Changed lines since the last checkpoint exceed <cap>. Call checkpoint with a note first." }`.
  - `human_write {path}`: snapshot and record a human step. If the path is in `agentFiles()` of the current steps, send `sendMessage({ customType: "pi-codeview", content: humanChangedSteer(path), display: true }, { deliverAs: "steer" })`.
  - `send`:
    1. Snapshot first.
    2. Quote each annotation from that snapshot with `showFile` plus the line slice.
    3. The human diff is `diffText` over the human steps' files.
    4. Enforce `canSend`; if it fails, the error is `open at least one file of the chunk or add a note`.
    5. Route by state:
       - The checkpoint is waiting: resolve its promise.
       - The chunk is open but nothing is waiting (aborted or resumed session): close it, then `sendUserMessage(renderResume(review, takeQueuedPrompts()))`, using `deliverAs: "followUp"` when not idle.
       - No open chunk: `sendUserMessage(renderAnnotationPrompt(...))`, with `followUp` when busy.
    6. Clear drafts and broadcast `chunk_reviewed`.
  - `input` event: if a chunk is open and `event.source !== "extension"`, call `queuePrompt(event.text)`, notify `Prompt queued until chunk N is reviewed`, and return `{ action: "handled" }`.
  - `prompt` from nvim: if a chunk is open, queue it exactly like `input`. Otherwise call `sendUserMessage(text + context block)`, with `followUp` when busy.
  - End of run (`agent_before_settle`): in review mode, with agent steps since the last checkpoint and no open chunk, create an open chunk with the note `end of run, no checkpoint` and broadcast it. This is my call: no continuation is requested, because sending its review resumes the agent through the same path as an interrupted chunk.
  - `agent_settled` broadcasts `run_settled`. In vibe mode, `turn_end` creates a `recorded` chunk when files changed.
  - Commands:
    - `/codeview` shows mode, open chunk and socket path.
    - `on` and `off` write the mode, set active tools and broadcast `mode_changed`. Turning it on resets the baseline. Turning it on refuses when another live socket exists for the same worktree (`one review-mode session per worktree`).
    - `continue <note>` acts like `send` with that note. It errors without a note.
    - `discard <note>` closes with `discarded`. It errors without a note.
  - `session_shutdown`: close the server and remove the socket.

- [ ] **Step 1:** Write `test/codeview.test.ts` against a real temp repo and the fake pi:
  - `inactive outside a git repo`.
  - `vibe mode: checkpoint tool inactive, turn_end records a chunk`.
  - `checkpoint blocks until send, returns the rendered review`.
  - `abort while waiting leaves the chunk open and persisted; send later resumes via sendUserMessage with renderResume` (Review Focus 3). Assert the drafts saved before the abort are still in the restored state.
  - `prompt typed while a chunk is open is queued and delivered after the review`.
  - `cap blocks the next edit after 150 agent lines, not counting human lines`.
  - `human_write on an agent-touched file steers the agent`.
  - `send refuses an empty unviewed review`.
  - `annotations quote code from the send-time snapshot`.
  - `session restore after restart keeps the open chunk`: a new fake pi gets the same entries.
  - `/codeview continue and discard require a note`.
  - `second session in the same worktree cannot enter review mode`.
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Implement in `codeview.ts`. Keep the handlers short and delegate to the state, git, render and server modules.
- [ ] **Step 4:** Run `npm test && npm run typecheck`. Expected: PASS.
- [ ] **Step 5:** Commit with the subject `feat: checkpoint review loop in the pi extension`.

### Task 7: Lua test runner and socket discovery

**Files:**
- Create: `nvim/tests/run.lua`, `nvim/lua/codeview/discover.lua`, `nvim/tests/discover_spec.lua`

**Interfaces:**
- `run.lua` adds `nvim/lua` to `package.path` and loads every `nvim/tests/*_spec.lua`. Each spec returns a table of `name -> function`. The runner prints `ok`/`FAIL` per test and exits with code 1 on any failure.
- `discover.lua` produces:
  - `repo_hash(dir) -> string|nil`: same algorithm as `git.ts` (`vim.fn.sha256` of the resolved common dir, first 12 characters).
  - `root(dir) -> string|nil`.
  - `sockets(dir) -> string[]`: the live sockets for the repo. Each candidate is checked with a `vim.uv` pipe connect. Sockets that refuse the connection are skipped.
  - `relpath(root, abspath) -> string`.

- [ ] **Step 1:** Write the specs:
  - `repo_hash matches the TypeScript value`: the spec creates a temp repo, writes the expected hash with `node --experimental-strip-types -e` importing `extensions/git.ts`, and compares.
  - `sockets skips a stale socket file` (Review Focus 4).
  - `relpath from a subdirectory buffer` (Review Focus 5).
- [ ] **Step 2:** Run `npm run test:nvim`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `npm run test:nvim`. Expected: PASS.
- [ ] **Step 5:** Commit with the subject `feat(nvim): test runner and socket discovery`.

### Task 8: Lua socket client

**Files:**
- Create: `nvim/lua/codeview/client.lua`, `nvim/tests/client_spec.lua`

**Interfaces:**
- Produces:
  - `client.connect(path, on_event) -> conn|nil, err`: sends `hello` with version 1.
  - `conn:request(type, payload, cb)`, where `cb(err, result)`.
  - `conn:close()`.
- Callbacks run through `vim.schedule`.
- If several sockets are found, `init.lua` (Task 10) asks with `vim.ui.select`.

- [ ] **Step 1:** Write the specs against a small `vim.uv` pipe server in the spec:
  - `request/response by id`.
  - `events reach on_event`.
  - `split lines are reassembled`.
  - `connect to a dead path returns an error, not a throw`.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run them. Expected: PASS.
- [ ] **Step 5:** Commit with the subject `feat(nvim): socket client`.

### Task 9: Annotations

**Files:**
- Create: `nvim/lua/codeview/annotations.lua`, `nvim/tests/annotations_spec.lua`

**Interfaces:**
- Produces:
  - `add(buf, start_line, end_line, note)`
  - `remove_at_cursor()`
  - `list() -> Annotation[]`: current 1-based line ranges read back from the extmarks, with paths relative to the root.
  - `clear()`
  - `restore(drafts)`: places extmarks for drafts received in `status`.
  - `on_change(fn)`: used to push `save_drafts`.
- Each annotation is an extmark with `end_row`, a sign, and virtual text showing the note. The file contents are never modified.

- [ ] **Step 1:** Write the specs:
  - `annotation follows inserted lines above it`: add on line 5, insert 2 lines at the top, and `list()` reports 7.
  - `annotations across two buffers are all listed`.
  - `buffer text is unchanged`.
  - `restore places drafts`.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement with one namespace `codeview`.
- [ ] **Step 4:** Run them. Expected: PASS.
- [ ] **Step 5:** Commit with the subject `feat(nvim): annotations as extmarks`.

### Task 10: Panel, diff view, commands, end-to-end

**Files:**
- Create: `nvim/lua/codeview/panel.lua`, `nvim/lua/codeview/diff.lua`, `nvim/lua/codeview/init.lua`, `test/e2e.nvim.test.ts`
- Modify: `README.md` (a Usage section: install, commands, keymaps)

**Interfaces:**
- `init.lua` produces `require("codeview").setup(opts?)`, with `opts.keys` overriding the defaults below. It defines:

  | Command | Default key | Action |
  |---|---|---|
  | `:Codeview` | `<leader>cv` | toggle panel |
  | `:CodeviewPrompt` | `<leader>ca` (n: file context, v: selection context) | `vim.ui.input` then `prompt` |
  | `:CodeviewAnnotate` | `<leader>cc` (n: line, v: range) | `vim.ui.input` then `annotations.add` |
  | `:CodeviewRemove` | `<leader>cx` | remove annotation at cursor |
  | `:CodeviewSend` | `<leader>cs` | `silent! wall`, then `send` with `annotations.list()`, an optional note via `vim.ui.input`, and `viewed` |

  - Autocommand `BufWritePost` sends `human_write` with the relative path while connected.
  - Statusline helper: `require("codeview").status() -> "working" | "review N" | "idle" | ""`.
  - The connection is made lazily on first use, for the repo of the current buffer.
- `panel.lua`: a scratch buffer listing the chunks (`#N status note — files, comments`). `<CR>` opens the chunk through `diff.lua` and marks it viewed. A `chunk_ready` event opens the panel unless the panel or a diff is already focused.
- `diff.lua`: for each file in the chunk, the left side is a scratch buffer with `git show <fromSha>:<path>`. The right side is the live file for the open chunk, and `git show <toSha>:<path>` (read-only) for past chunks. Run `diffthis` on both. `]f` and `[f` move to the next or previous file. Agent and human files get labels in the winbar. My call: a custom split diff instead of diffview.nvim, to avoid coupling to diffview's internals.
- The only state the plugin keeps is `viewed[n]`. Everything else comes from the server.

- [ ] **Step 1:** Write `test/e2e.nvim.test.ts`. It starts the extension with a fake pi in a temp repo, makes a change, and calls `checkpoint` (left waiting). Then it spawns `nvim --headless` with `nvim/` on the runtimepath. A Lua snippet runs `setup()`, opens the panel, opens chunk 1, annotates line 1, and runs `CodeviewSend`. Assertions:
  - The checkpoint promise resolves, and its content contains the annotation note and quote.
  - A `BufWritePost` in nvim on an agent-touched file results in a steer message.
  - `CodeviewSend` without opening the chunk and without content is refused, with the error shown via `vim.notify`.
- [ ] **Step 2:** Run `npx vitest run test/e2e.nvim.test.ts`. Expected: FAIL.
- [ ] **Step 3:** Implement panel, diff and init.
- [ ] **Step 4:** Run `npm test && npm run typecheck && npm run test:nvim`. Expected: all pass.
- [ ] **Step 5:** Manual smoke test in a real session: link the repo with `pi install <path>` or add it to settings temporarily, put `nvim/` on nvim's runtimepath, and do one prompt → chunk → annotate → send cycle in a fresh test repo. Report what was observed.
- [ ] **Step 6:** Write the README Usage section.
- [ ] **Step 7:** Commit with the subject `feat(nvim): panel, diff view and commands`.

### Task 11: Wire into nixos-config (needs Philipp's go-ahead)

This task needs the repo published as `github:philipp-mlr/pi-codeview`. Ask Philipp before creating the GitHub repo or pushing anything. Pushing to nixos-config `main` deploys to every host.

**Files (in `~/repos/nixos-config`, on a worktree branch):**
- Modify: `modules/features/programs/pi/pi.nix`: add `"git:github.com/philipp-mlr/pi-codeview"` to `settings.packages`, next to pi-impeccable.
- Modify: `flake.nix`: add the input `pi-codeview = { url = "github:philipp-mlr/pi-codeview"; flake = false; }`.
- Modify: `modules/features/programs/nixvim/nixvim.nix`: build `codeview-nvim-pkg` with `pkgs.vimUtils.buildVimPlugin { pname = "codeview.nvim"; src = "${inputs.pi-codeview}/nvim"; ... }` and add it to `extraPlugins`.
- Create: `modules/features/programs/nixvim/_plugins/codeview.nix` with `extraConfigLua = ''require("codeview").setup({})''`, imported like `pi-nvim.nix`.

- [ ] **Step 1:** Run `nix flake lock --update-input pi-codeview` and `nix flake check`. Expected: no errors.
- [ ] **Step 2:** Build the current host configuration (`nixos-rebuild build --flake .#<host>`). Expected: success.
- [ ] **Step 3:** Commit locally on the branch with the subject `feat: add pi-codeview`, then hand the branch to Philipp. Do not push.
