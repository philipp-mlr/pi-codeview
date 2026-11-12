# pi-nvim wire protocol

Transport: unix socket at `$XDG_RUNTIME_DIR/pi-nvim/<repo-hash>/<session-id>.sock`
(`os.tmpdir()` when `XDG_RUNTIME_DIR` is unset). The directory is mode `0700`.

## Framing

Newline-delimited JSON: one JSON object per line, UTF-8, terminated by `\n`.
A line that is not valid JSON gets `{"id":null,"ok":false,"error":"invalid json"}`;
the connection stays open.

## Versioning

`PROTOCOL_VERSION = 2`. The first request on a connection must be `hello`.
- Match: `{"id":1,"ok":true,"result":{"version":2}}`.
- Mismatch: `{"id":1,"ok":false,"error":"protocol version mismatch: server 2, client 1"}`; the connection stays unusable until a matching `hello`.
- Any other request before a successful `hello`: `ok:false`, `error:"hello required"`.

Events are sent only to clients that completed `hello`.

## Requests

Each request is `{"id": <number>, "type": <name>, ...payload}`. The reply is
`{"id", "ok": true, "result"}` or `{"id", "ok": false, "error": "<message>"}`;
handler failures are returned as `ok:false`.

| type | example |
|---|---|
| `hello` | `{"id":1,"type":"hello","version":2}` |
| `status` | `{"id":2,"type":"status"}` |
| `list_chunks` | `{"id":3,"type":"list_chunks"}` |
| `get_chunk` (result: chunk plus `diff: string`) | `{"id":4,"type":"get_chunk","n":2}` |
| `prompt` | `{"id":5,"type":"prompt","text":"why?","context":{"path":"a.ts","startLine":3,"endLine":9}}` |
| `send` | `{"id":6,"type":"send","annotations":[{"path":"a.ts","startLine":3,"endLine":4,"note":"rename","quote":"foo"}],"note":"overall","viewed":true}` |
| `save_drafts` | `{"id":7,"type":"save_drafts","annotations":[{"path":"a.ts","startLine":3,"endLine":4,"note":"wip"}]}` |
| `human_write` | `{"id":8,"type":"human_write","path":"a.ts"}` |
| `set_mode` (`checkpoints` or `off`; also accepts `on`, `review`) | `{"id":9,"type":"set_mode","mode":"checkpoints"}` |
| `cancel` | `{"id":10,"type":"cancel"}` |

`prompt.context` is optional; only `path` is required inside it. `startLine`/`endLine` are optional.
`text` is the selected text, which the extension quotes for the agent. `unsaved` is `true` when the buffer differs from the file on disk.
`prompt.context.diagnostics` and each `annotations[].diagnostics` (`send`, `save_drafts`) are optional arrays of
`{"line":3,"severity":"error"|"warning","message":"…","source":"eslint"}` (`line` is 1-based, `source` optional): the LSP errors and warnings
on the context's or annotation's lines, at most 20, errors first then by line, messages whitespace-collapsed and cut at 200 characters.
The extension renders them under the context or the annotation's note as a `Diagnostics:` section.

### Results

- `status`: `{"mode":"checkpoints","root":"/abs/worktree","sessionId":"…","name":"my session"|null,"baseline":"<sha>","markBase":"<sha>","openChunk":<chunk>|null,"drafts":[<annotation>],"busy":false,"queued":0,"activity":{"tool":"edit","target":"a.ts"}|null,"lastActive":1731400000000}`.
  `mode` is `checkpoints` or `off`: the checkpoint mode in effect for this session. A session that can't stop for review
  (no UI, or its tool allowlist keeps the `checkpoint` tool out) reports `off` even when the repo's mode is on, and then
  `modeNote` (optional, absent otherwise) says why: `"checkpoint mode is on for this repo, but this session can't stop for review"`. `name` is the pi session name or `null`. `baseline` is the sha of the latest recorded snapshot.
  `root` is the worktree the session runs in; clients attach only to sessions whose `root` is their own worktree.
  `busy` is true while the agent is working (`activity_current` events carry it too); `queued` counts prompts waiting behind the open chunk.
  `lastActive` is the epoch ms of the session's last sign of life (agent start or settle, tool call or result, prompt or send from nvim; session start otherwise). Optional: older extensions omit it.
  `activity` is the tool currently running (`{"tool":"edit","target":"a.ts"}`, the most recently started one when several run) or `null`.
  `markBase` is the snapshot sha clients mark changed lines against: the open chunk's `fromSha`; without one,
  `baseline` in checkpoint mode and with checkpoints off the `baseline` at the start of the current or last agent run (kept in memory, so
  `baseline` again after a restart).
- `cancel`: `{"cancelled":true}` after aborting the agent's run (pi's abort, as Escape), `{"cancelled":false}` when pi is idle. A waiting `checkpoint` call returns "Review pending", the chunk stays open.
- `prompt`: `{"queued":true}` when a chunk is open and the prompt waits for its review, else `{"queued":false}` (sent to the agent).
- `list_chunks`: array of chunks. `get_chunk`: `{"chunk":<chunk>,"diff":"<unified diff fromSha..toSha>","stats":[{"path":"a.ts","added":3,"removed":1}]}` (`stats` has one entry per file of the chunk; binary files are 0/0).
- A chunk may carry `title` (the agent's short title, at most 60 characters, whitespace collapsed); clients show the first sentence of `note` when it is absent.
- A chunk may carry `why`: `{"<repo-relative path>":"<one short line, max 200 chars>"}`, set from the `files` argument of the agent's `checkpoint` call. Only paths changed in the chunk are kept; the field is absent when empty. Clients must tolerate its absence.
- `send`: `{"chunk":<closed chunk>}` for a review, `{"chunk":null}` when sent as a prompt (no open chunk).
- `save_drafts`: `{"saved":<count>}`. `human_write`: `{"files":[<paths changed since the last snapshot>]}`. `set_mode`: `{"mode":"checkpoints"}` (the mode in effect, as in `status`).

## Events

`{"event": <name>, "data": ...}`, no `id`.

| event | example |
|---|---|
| `chunk_ready` | `{"event":"chunk_ready","data":{"chunk":{"n":2,"status":"open","...":"..."}}}` |
| `chunk_reviewed` | `{"event":"chunk_reviewed","data":{"chunk":{"n":2,"status":"reviewed","...":"..."}}}` |
| `mode_changed` | `{"event":"mode_changed","data":{"mode":"checkpoints"}}` |
| `run_settled` | `{"event":"run_settled","data":{"aborted":false,"files":2}}` |
| `outside_worktree` | `{"event":"outside_worktree","data":{"path":"/abs/other-worktree/x.al"}}` |
| `activity_current` | `{"event":"activity_current","data":{"current":{"tool":"edit","target":"a.ts"},"mutating":true,"busy":true}}` |

`activity_current` is sent on tool start (`busy` true, `current` the tool), tool end (`current` the still-running tool or `null`; `mutating` only here), `agent_start` (`busy` true, `current` null) and `agent_settled` (`busy` false, `current` null).
`mutating` is false when the tool that ended cannot change files (e.g. `read`); clients reload buffers only when it is true.

`mode_changed.mode` is the mode in effect (as in `status`); it is also sent when `/tree` changes whether the session can be reviewed.

`outside_worktree` is sent at most once per agent run, when a mutating tool's `path` argument resolves outside the session's root (the tool is not blocked). Clients show a warning.

A `checkpoint` call with no changes since the last checkpoint (no agent and no human steps) creates no chunk and broadcasts nothing; it returns "Nothing changed since the last checkpoint; no review needed. Continue." Drafts are untouched.

`run_settled.files` is the number of distinct files the agent changed during the run (Philipp's edits do not count).

`send` with an open chunk is always accepted, also with no annotations and an empty note (an empty review: "no remarks, continue"); `viewed` is accepted and ignored. Without an open chunk, `send` with no annotations and an empty note fails with `nothing to send`.

`chunk_reviewed` is also sent for a discarded chunk (`status: "discarded"`).
