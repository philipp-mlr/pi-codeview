# pi-codeview wire protocol

Transport: unix socket at `$XDG_RUNTIME_DIR/pi-codeview/<repo-hash>/<session-id>.sock`
(`os.tmpdir()` when `XDG_RUNTIME_DIR` is unset). The directory is mode `0700`.

## Framing

Newline-delimited JSON: one JSON object per line, UTF-8, terminated by `\n`.
A line that is not valid JSON gets `{"id":null,"ok":false,"error":"invalid json"}`;
the connection stays open.

## Versioning

`PROTOCOL_VERSION = 1`. The first request on a connection must be `hello`.
- Match: `{"id":1,"ok":true,"result":{"version":1}}`.
- Mismatch: `{"id":1,"ok":false,"error":"protocol version mismatch: server 1, client 2"}`; the connection stays unusable until a matching `hello`.
- Any other request before a successful `hello`: `ok:false`, `error:"hello required"`.

Events are sent only to clients that completed `hello`.

## Requests

Each request is `{"id": <number>, "type": <name>, ...payload}`. The reply is
`{"id", "ok": true, "result"}` or `{"id", "ok": false, "error": "<message>"}`;
handler failures are returned as `ok:false`.

| type | example |
|---|---|
| `hello` | `{"id":1,"type":"hello","version":1}` |
| `status` | `{"id":2,"type":"status"}` |
| `list_chunks` | `{"id":3,"type":"list_chunks"}` |
| `get_chunk` (result: chunk plus `diff: string`) | `{"id":4,"type":"get_chunk","n":2}` |
| `prompt` | `{"id":5,"type":"prompt","text":"why?","context":{"path":"a.ts","startLine":3,"endLine":9}}` |
| `send` | `{"id":6,"type":"send","annotations":[{"path":"a.ts","startLine":3,"endLine":4,"note":"rename","quote":"foo"}],"note":"overall","viewed":true}` |
| `save_drafts` | `{"id":7,"type":"save_drafts","annotations":[{"path":"a.ts","startLine":3,"endLine":4,"note":"wip"}]}` |
| `human_write` | `{"id":8,"type":"human_write","path":"a.ts"}` |
| `set_mode` (`review` or `vibe`) | `{"id":9,"type":"set_mode","mode":"review"}` |

`prompt.context` is optional; `startLine`/`endLine` inside it are optional.

## Events

`{"event": <name>, "data": ...}`, no `id`.

| event | example |
|---|---|
| `chunk_ready` | `{"event":"chunk_ready","data":{"chunk":{"n":2,"status":"open","...":"..."}}}` |
| `chunk_reviewed` | `{"event":"chunk_reviewed","data":{"n":2,"status":"reviewed"}}` |
| `mode_changed` | `{"event":"mode_changed","data":{"mode":"review"}}` |
| `run_settled` | `{"event":"run_settled","data":{}}` |
| `state` | `{"event":"state","data":{"mode":"review","openChunk":2}}` |
