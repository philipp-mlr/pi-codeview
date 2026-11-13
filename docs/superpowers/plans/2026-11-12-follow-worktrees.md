# Follow the agent across worktrees — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** When the agent edits another worktree of the same repo, the pi-nvim session follows it there instead of leaving Philipp alone with a warning; his attached nvim is prompted automatically to follow too. Design: `docs/superpowers/specs/2026-11-12-follow-worktrees-design.md` (approved by Philipp 2026-11-12, incl. the automatic prompt and opening the agent's current file).

**Decisions (from the design, binding):**
- Same repo (same `git-common-dir`) → follow; anything else keeps today's outside-worktree warning unchanged.
- Follow = session root moves, baseline and mark base re-snapshot there, recorded history stays, socket path stays (repo hash + session id). Never happens with an open checkpoint (a waiting one blocks the agent).
- pi notifies `pi: following the agent into <basename>`; new additive event `root_changed { root }`.
- nvim on `root_changed`: update cached root, refresh status/marks, notify; if attached from another worktree, prompt automatically (`vim.ui.select`, Follow/Stay, Esc = Stay, once per move). Follow = `:tcd` + refresh + open the file the agent is currently editing (if any, if it exists).
- pi's pane offer (openInNeovim chain) fires only when **no** client is attached, once per run.
- `<leader>pf` / `:PiFollow` does the follow manually later; key under `<leader>p`, never replacing an existing mapping, hint via `keys.label`.
- Drafts/annotations keep their repo-relative paths; nothing is dropped or auto-reviewed.

## Global Constraints

- Protocol stays version 2; `root_changed` is additive; old nvim ignores unknown events (verified).
- nvim 0.12 API; Philipp's setup: herdr, many worktrees, dressing-style `vim.ui.select` picker.
- Each task: TDD, all three suites green before commit (`npm test`, `npm run typecheck`, `nvim --headless -l nvim/tests/run.lua > /tmp/out 2>&1; echo exit=$?` — exit 0 and `0 failed` in the summary), README and `nvim/doc/pi.txt` updated (vimdoc lines ≤ 78 display columns).
- Commits conventional, signed; never `git add -f` under `.superpowers`.

## Review Focus

1. Follow must never fire for paths outside the repo, `~`, `/tmp`, or a different repo — those keep the warning.
2. The re-snapshot must not lose unreported human steps or an inherited open chunk (subagent child).
3. No dialog/notice from a stopped or UI-less session (subagents) — the guarded offer rules apply.
4. Old nvim clients plus the new event; old extensions plus a client that reconnects.

---

### Task 1: Extension — follow, event, pane offer

**Files:** `extensions/loop.ts` (root switching, `toolCall`/`isOutsideRoot`, snapshot/baseline, `root_changed` broadcast, notices, pane-offer gate), `extensions/git.ts` (worktree/repo test: same `git-common-dir` for a path), `extensions/open-nvim.ts` (label for the follow offer), `docs/protocol.md`, `test/extension.test.ts`, `test/helpers/repo.ts` (second worktree helper), README.

- [ ] `sameRepoWorktree(path)`: resolves the target's repo via `git -C <dir> rev-parse --git-common-dir` (realpath) and compares it with the session's; cheap, cached per directory. Tests: another worktree true; different repo, `~`, `/tmp` false; non-existent path false.
- [ ] `toolCall`: outside the current root → if same repo, `followTo(targetWorktreeRoot)`; else today's warning. Follow: root := new root, re-snapshot baseline + mark base inside the serial lock, persist, notify `pi: following the agent into <basename>` (INFO, via `notify` rules), broadcast `root_changed { root }`; recorded chunks stay; drafts stay.
- [ ] Pane offer after a follow only when `clientCount() === 0`, once per run (`offered` set reuse or its own), guarded like `offerToOpen` (never from a stopped or UI-less session). Offer text `Open <basename> in Neovim?`; reuse `openInNeovim`.
- [ ] `status`/`describe`/`setMode`/`otherReviewSession` keep working after a root switch (status.root is the new root; repo config is re-read only at start — mode/cap keep their session values; note this in the code).
- [ ] Back-and-forth: a second move (also back to the first root) follows again; each move notifies once. Tests: two follows in one run; human steps unreported at follow time are not lost (they are reported at the next checkpoint of the new root or sent as drafts — state what the code does and pin it in a test).
- [ ] Commit `feat: the session follows the agent into another worktree`.

### Task 2: Neovim — auto prompt, PiFollow, live file

**Files:** `nvim/lua/pi/session.lua` (root_changed → cached root update + refresh), `nvim/lua/pi/init.lua` (event wiring, prompt, `:PiFollow` + `pf` key, open current file), `nvim/lua/pi/keys.lua`, `nvim/tests/init_spec.lua` + `session_spec.lua`, `test/e2e.nvim.test.ts` (root_changed e2e), README, `nvim/doc/pi.txt`.

- [ ] On `root_changed { root }`: update the cached root, refresh status and live marks, notify `pi: following the agent into <basename>`; when the previous root differs from the new one and a client is attached from another worktree, prompt automatically once per move: `pi: agent moved to <basename> — follow here?` Follow / Stay (`vim.ui.select`, Esc = Stay).
- [ ] Follow (`pf`, `:PiFollow`, or the prompt): `:tcd <root>` (tab-local), refresh, then open the agent's current file (cached `activity.target`, repo-relative → absolute under the new root) in a split if it exists; `pi: nothing to follow` when the root already matches.
- [ ] Key `pf = "<leader>pf"` in `default_keys` (skip-existing rule applies); hint via `keys.label("follow", ":PiFollow")`.
- [ ] Session discovery across worktrees (from the Task 1 review): `session.collect`/`ensure` accept a session whose `status.root` is a different worktree of the SAME repo (compare via `discover.repo_hash`), so a fresh nvim in the start worktree still finds a followed session; the picker shows that session's worktree basename in its row. Specs for both.
- [ ] e2e: extension follow → nvim receives `root_changed`, cached root changes, prompt appears (stubbed `vim.ui.select`), Follow switches dir and opens the file.
- [ ] Commit `feat(nvim): automatic follow prompt when the agent moves worktrees`.
