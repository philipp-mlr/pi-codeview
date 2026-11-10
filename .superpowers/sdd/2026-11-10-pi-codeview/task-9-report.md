# Task 9 report
RED: `FAIL annotations_spec <load>: module 'codeview.annotations' not found`.
GREEN: 5 annotations specs pass (4 brief specs + remove_at_cursor/on_change); `npm run test:nvim` all ok; `npm test` 64 passed.
Notes: list(root) realpaths buffer names; collapsed extmarks are clamped; on_change fires (scheduled) on add/remove/clear/restore only.

## Fix round 1
Changes (nvim/lua/codeview/annotations.lua): module-level `unplaced` list for missing-file drafts, included verbatim in `list(root)`, emptied by `clear()`; `restore` skips drafts already present (path/startLine/endLine/note), fires on_change only if something new was placed/kept; `count(root?)` consistent with list (file-backed + unplaced).
Tests (annotations_spec): restore places drafts (now expects unplaced in list); new "restore is idempotent, keeps unplaced, fires on_change only on news".
Command: `npm run test:nvim` — all ok.

## Fix round 2
Changes: `restore` in nvim/lua/codeview/annotations.lua now compares drafts against the draft clamped to the target buffer's line count (fixes duplicate placement for out-of-range lines). When a draft's file now exists, its parked `unplaced` entry is removed and the draft is placed once.
Tests added (nvim/tests/annotations_spec.lua): "restore dedupes out-of-range drafts that were clamped"; "restore places a previously unplaced draft once its file exists".
Command: `npm run test:nvim` — all 19 lines `ok` (including both new tests), no failures.
