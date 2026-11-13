# Follow the agent across worktrees — Design

**Why:** When the agent (or a superpowers worktree flow) starts editing another worktree of the
same repo, pi-nvim today only warns "start pi in that worktree to review it" and checkpoints stop
covering the work. Philipp wants the review to follow the agent instead.

**Decisions (Philipp, 2026-11-12):**
- Follow the agent: the session moves to the worktree the agent edits.
- After moving, pi offers to open that worktree in Neovim (same opener chain as checkpoints).

## Behaviour

- **Trigger:** the existing per-tool-call check that today warns about outside paths. If the target
  resolves inside a different worktree **of the same repo** (same `git-common-dir`), the session
  follows instead of warning. A path outside the repo entirely keeps today's warning, unchanged.
- **Following means:** the session's root becomes the new worktree; baseline and mark base are
  re-snapshotted there; recorded chunk history stays; there is never an open checkpoint at that
  moment (a waiting checkpoint blocks the agent, so follows only happen mid-run). The socket path
  does not change (repo hash + session id), so nvim clients stay attached and the session stays
  discoverable from every worktree.
- **Everyone is told:**
  - pi notifies `pi: following the agent into <basename>` (once per move).
  - New additive event `root_changed { root }`. nvim updates its cached root, refreshes status and
    live marks, and shows the same notice. Old nvim ignores it safely.
- **The Neovim side, by case:**
  - No nvim attached at all: pi asks "Open <basename> in Neovim?" (once per run) using the existing
    `openInNeovim` chain — running nvim in that worktree, else `pi-nvim.openCommand`, else
    herdr / tmux / zellij, else the hint. The pane opens on the checkpoint list, attached to the
    session.
  - An attached nvim already in that worktree: nothing to open.
  - An attached nvim in another worktree (the usual case): it stays attached — the list, diffs and
    peek work for the new worktree anyway — and it **prompts automatically**: `pi: agent moved to
    <basename> — follow here?` with Follow / Stay (his `vim.ui.select` picker; Esc counts as Stay,
    asked once per move). Follow does a `:tcd` to the new root, refreshes, and opens the file the
    agent is currently editing so the live marks are on screen at once. `<leader>pf` (`:PiFollow`)
    does the same later; no pane is opened for it. No dialog in pi.
- **Back and forth:** every same-repo outside move follows, also back to the original worktree. Each
  follow re-snapshots (cheap) and notifies.
- **Live edits:** unchanged — `▎` marks and buffer reloads work in any open buffer; after a follow
  they apply to the new worktree's files once opened (the Follow choice opens the current one).
- **Annotations:** drafts from the old worktree are kept as drafts; their paths are repo-relative and
  still sent with the next review, so nothing of Philipp's is dropped.

## Non-goals

- No config flag (a "keep it in its worktree" mode can be added later if wanted).
- No following into other repos or the home directory — those keep the warning.
- Nothing is auto-discarded or auto-reviewed on a follow.

## Approaches considered

- **Follow the agent (chosen):** review always covers the real work; matches the worktree workflow.
- **Keep the agent in its worktree:** would fight superpowers' worktree flows; rejected.
- **Follow with an opt-out flag:** deferred until someone needs it; the behaviour is the default.

## Left to the builder

- Exact placement of the follow inside `toolCall`/`isOutsideRoot` (extensions/loop.ts), re-snapshot
  order, and the `root_changed` wiring in nvim (`session.lua` root cache, `init.lua` notice).
- Tests for: same-repo follow, other-repo warning unchanged, re-snapshot baseline, event payload,
  nvim root refresh + notice, pane offer only with no attached client (asked once per run), no UI
  (subagent) → no offer, attached nvim gets the `<leader>pf` hint and `:PiFollow` switches + refreshes,
  back-and-forth.
