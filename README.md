# pi.nvim

Ask [pi](https://pi.dev) from Neovim with real context, watch the agent work
in your buffers, annotate lines and send the annotations back.

pi.nvim is a pi extension plus a Neovim plugin. pi keeps running in its own
window; Neovim talks to that session over a local socket. An optional
checkpoint mode makes the agent stop after each chunk of work so you can
review it before it continues.

## Install

pi side, as a pi package:

```sh
pi install /path/to/pi-nvim
```

Neovim side, minimum Neovim 0.10. Put the repo's `nvim/` directory on the
runtimepath and call `setup()`.

With lazy.nvim:

```lua
{
  dir = "/path/to/pi-nvim/nvim",
  config = function()
    require("pi").setup({})
  end,
}
```

Or with a plain runtimepath:

```lua
vim.opt.rtp:append("/path/to/pi-nvim/nvim")
require("pi").setup({})
```

With nixvim, declare the repository as a flake input that is not a flake:

```nix
inputs.pi-nvim = {
  url = "github:philipp-mlr/pi-nvim";
  flake = false;
};
```

Then build the plugin from it:

```nix
extraPlugins = [
  (pkgs.vimUtils.buildVimPlugin {
    pname = "pi-nvim";
    version = "0.1.0";
    src = "${pi-nvim}/nvim";
  })
];
extraConfigLua = ''require("pi").setup({})'';
```

Register the same input as a pi package so pi loads the extension, by adding
its path to pi's `packages` setting:

```nix
settings.packages = [ "${inputs.pi-nvim}" ];
```

`setup({ keys = { send = "<leader>rs" } })` overrides single keys; set a key
to `false` to leave it unmapped. A default key that is already mapped by
another plugin is left alone, and `setup()` lists the skipped keys in one
message. Keys you pass in `keys` are always mapped. The key names are `ask`,
`cancel`, `session`, `annotate`, `remove`, `edit`, `send`, `chunks`, `checkpoints`.

## Keys and commands

| Key | Command | What it does |
|---|---|---|
| `<leader>pa` | `:PiAsk` | Ask pi. Normal mode sends the file and cursor line; visual mode sends the line range and the selected text. |
| `<leader>pc` | `:PiCancel` | Cancel the agent's current run (like Escape in pi). |
| `<leader>ps` | `:PiSession` | Choose the pi session to work with. |
| `<leader>pn` | `:PiAnnotate` | Annotate the current line or the visual range. |
| `<leader>px` | `:PiAnnotationRemove` | Remove one annotation under the cursor; when several cover the line, pick which. |
| `<leader>pe` | `:PiAnnotationEdit` | Edit the text of one annotation under the cursor; when several cover the line, pick which. |
| `<leader>pr` | `:PiSendAnnotations` | Save all buffers, then send the annotations and an optional message. |
| `<leader>pv` | `:PiChunks` | Toggle the chunk panel (checkpoint mode). |
| `<leader>pm` | `:PiCheckpoints [on\|off]` | Switch checkpoint mode for this repository; without an argument it toggles. |

## Asking

`<leader>pa` opens a prompt and sends your text with context:

- The file path (relative to the repository).
- Normal mode: the cursor line. Visual mode: the line range and the selected
  text exactly as it is in your buffer, so unsaved edits come through.
- A marker when the buffer has unsaved changes. The whole buffer is not sent.
- LSP diagnostics (errors and warnings only). Normal mode: those of the whole
  file. Visual mode: those on the selected lines. At most 20, errors first,
  then by line.

If pi is idle the text starts a run; if it is busy the text is delivered as a
follow-up. In checkpoint mode with a chunk open, the prompt waits until the
chunk is reviewed.

## While the agent works

Statusline, with lualine:

```lua
lualine_x = { function() return require("pi").statusline() end }
```

It shows `pi: <session> · working · <tool> <target>`, `· working`,
`· review N` (a chunk is open) or `· idle`. `[checkpoints]` follows the
session name while checkpoint mode is on. It is empty when Neovim is not
attached to a session. `require("pi").status()` returns `"review N"`,
`"working"`, `"idle"` or `""`.

- A small badge in the top-right corner shows that the agent works:
  `⠋ pi · <tool> <target>` or `⠋ pi · working`, with a spinner. While a chunk
  waits for your review it reads `pi · chunk N waiting for your review`. It
  never takes focus and is hidden when idle or not attached. Turn it off with
  `setup({ badge = false })`; colors come from the `PiBadge` highlight group
  (links to `PmenuSel`).
- When a run ends you get one notice: `pi: done — N files changed`
  (`1 file changed` for one), `pi: done` when nothing changed,
  `pi: cancelled`, or, with a chunk waiting,
  `pi: chunk N waiting for your review — <leader>pv to look, <leader>pr to continue`
  (`pi: cancelled — chunk N waiting for your review` after a cancel). The
  notice names your configured keys, or `:PiChunks` / `:PiSendAnnotations`
  when a key is not mapped.
- Open buffers whose file the agent changed reload by themselves.
- Changed lines get a sign and a light line highlight: `┃` marks added or
  changed lines (same column as gitsigns), `▁` marks lines deleted below that line. They compare
  against the start of the open chunk in checkpoint mode, and against the
  start of the current (or last) agent run otherwise. Your own unsaved edits
  show as marks too.
- A buffer with unsaved edits is never reloaded. When the agent changes its
  file you get one warning naming it, and your edits stay.
- The highlight groups `PiLive` (line), `PiLiveSignAdd`, `PiLiveSignChange`
  and `PiLiveSignDelete` (signs) can be overridden.

## Annotations

`<leader>pn` on a line, or on a visual range, asks for a note. The note
shows on its own line below the range as `✎ <text>` (highlight
`PiAnnotation`), with a `✎` sign on the first line and the line numbers of
the range highlighted (`PiAnnotationSign`). `<leader>px` removes the one
under the cursor.

`<leader>pr` sends all annotations of the worktree and an optional message.
The prompt says how many it sends (`pi: send 3 annotations — optional
message:`) and afterwards `pi: 3 annotations sent`. Buffers are saved first.
With no annotations and no open chunk nothing is sent. Each annotation
carries the LSP errors and warnings on its lines, under a `Diagnostics:`
heading in the agent's message.

## Sessions

Neovim attaches to a pi session running in the same worktree as the current
buffer. With one such session it attaches on first use; with several it
asks. Running a command from a buffer in another worktree switches to that
worktree's session. `<leader>ps` (`:PiSession`) picks a session on purpose.
Name your pi sessions (`/name` in pi) to tell them apart in the picker.
`require("pi").session_label()` gives the attached session's name.

## Checkpoint mode

In checkpoint mode the agent works in small chunks and stops at the end of
each one, using a `checkpoint` tool, or when it passes a size cap
(`pi-nvim.cap`, default 150 changed lines). You read the chunk, comment on
it, edit it, or ask about it, and your feedback goes back before the next
step. Use it when you want to be forced to look at every step, for example
at the start of a new codebase. It is off by default and set per repository
(git config `pi-nvim.checkpoints`).

Switch it with `<leader>pm` / `:PiCheckpoints on|off` in Neovim, or in pi:

- `/checkpoints` shows the state.
- `/checkpoints on|off` switches the mode.
- `/checkpoints continue <note>` sends a review without Neovim.
- `/checkpoints discard <note>` throws the open chunk away.

Review flow:

1. Turn checkpoint mode on and give the agent a task with `<leader>pa`.
2. The agent stops at a checkpoint. The chunk panel (`<leader>pv`) opens with
   the new chunk; `<CR>` opens a chunk, `r` refreshes, `q` closes.
3. The chunk opens in its own tab as a diff view: on the left the file
   before the chunk, on the right your file. Above the diff you see the
   checkpoint note and the agent's one-line reason for the current file.
   `<Tab>` and `<S-Tab>` move to the next and previous file (they stop at the
   ends), `q` closes the tab and takes you back to where you came from. Vim's
   own diff keys work: `]c` and `[c` jump between changes, `do` and `dp`
   take or put a change. For the open chunk the right side is the real file,
   so LSP and editing work; past chunks are read-only. A help line in the
   window bar lists the keys.
4. Annotate lines with `<leader>pn` on the right side, your file. The left
   side is only a copy of the old state and cannot be annotated.
5. `<leader>pr` sends the review: your annotations, your own edits and an
   optional note. The chunk closes and the agent continues. There is no
   accept button. Prompts sent meanwhile are queued behind the review.
   With nothing to add (no annotations, empty message) Neovim asks
   `pi: continue without remarks? (y/n)`; `y` sends an empty review and the
   agent continues, `n` sends nothing.

`<leader>pc` cancels the run; a waiting chunk stays open.

## Upgrading from pi-codeview

The project was called pi-codeview. Settings and saved sessions migrate
automatically: the git config `pi-codeview.mode`, `.cap` and `.retentionDays`
are read while the `pi-nvim.*` ones are unset, saved chunk state is restored
from the old session entry, and old snapshot refs are pruned as before.
Update your config to `require("pi")`, `:Pi*` commands and the `<leader>p`
keys, and to `/checkpoints` in pi.

If you use pablopunk's pi.nvim, remove it. Both plugins use `require("pi")`
and `<leader>p` keys.

## Why seeing the code matters

Agent harnesses hide the codebase. The agent reads, writes and
runs things, and you see the result in a chat. Often you only see the
actual change once it has been committed.

That is a problem if you are an engineer who understands a system by
working with its code. Peter Naur argued in 1985 that the real product of
programming is the *theory* of the program in the programmer's head, and
the code is a by-product. You build that theory by reading, judging and
changing code. When an agent does all of that for you, the code keeps
growing and your theory of it doesn't.

The problems this plugin works against:

1. **Changes land unseen.** There is no point between "the agent is
   working" and "it's committed" where you naturally look at the code.
2. **Passive acceptance erodes understanding.** Accepting agent output
   without engaging with it is the behaviour most clearly linked to lost
   comprehension.
3. **Volume beats review.** Agents produce code faster than people can
   review it, and reviews get shallow once the volume outgrows attention.
4. **Feedback has nowhere to go.** When you do read the code and have
   something to say about line 42, there is no direct way to put it in
   front of the agent.
5. **Design drifts early.** In a new codebase the first few chunks set the
   invariants. If nobody holds them, the agent defends locally against
   every failure and complexity piles up.

### What the research says

#### Understanding suffers when the agent does the work

- **Anthropic, "How AI assistance impacts the formation of coding skills"
  (Jan 2026).** Randomised trial, 52 mostly junior developers learning a
  new Python library. The AI group scored 50% on a comprehension quiz,
  the hand-coding group 67% (Cohen's d = 0.74). The largest gap was in
  debugging. The AI group was not significantly faster. *How* people used
  AI mattered: those who delegated everything scored under 40%; those who
  generated code and then asked questions about it, or only asked
  conceptual questions, scored 65% or more.
  <https://www.anthropic.com/research/AI-assistance-coding-skills>
- **Balepur et al., "(Im)Paired Programming: Coding Agents Improve
  Productivity but Harm Understanding" (2026).** 54 students built a web
  app with either an editing agent or a chatbot. Agent users finished the
  first task better but understood their code clearly worse (d ≈ 0.9) and
  were no better at extending it without the agent. Low comprehension went
  with copy-paste prompts and **auto-accepted edits**. Users still
  preferred the agent. <https://arxiv.org/pdf/2607.26375>
- **"Cognitive Debt in the GenAI Era" (grey-literature review of 76
  practitioner sources, Oct 2026).** Cognitive debt builds up unnoticed
  behind working code and passing tests and surfaces when code has to be
  changed or explained. Polished code gets mistaken for understood code.
  <https://arxiv.org/html/2610.37888v1>
- **"Agents That Teach" (2026).** Agents short-circuit *incidental
  learning*, the knowledge you used to pick up while solving problems
  yourself. The authors argue it has to be designed back in.
  <https://arxiv.org/html/2607.06101v1>

#### The bottleneck moved to review

- **Chen & Stratton (Harvard), Jellyfish data from 700+ firms (Oct 2026).**
  After agents were introduced: about +30% lines of code, +20% commits,
  +23% pull requests, but no significant change in issues or features
  delivered. Gains were absorbed by longer reviews and more revisions.
  <https://arstechnica.com/ai/2026/10/ai-coding-agents-generate-more-code-but-not-more-software/>
- **METR.** Early-2025 trial: experienced open-source developers took 19%
  longer with AI. The 2026 follow-up suggests a speed-up now but calls its
  own data unreliable because of selection effects. Nobody has clean
  productivity numbers.
  <https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/>,
  <https://metr.org/blog/2026-02-24-uplift-update/>

#### What practitioners do about it

- **"The unit of review is the unit of comprehension"**: never generate
  more than you can review in one sitting (cognitive-debt review).
- **Kent Beck, augmented coding**: small TDD steps, watch intermediate
  results, stop the agent on loops, unrequested features or deleted tests.
  <https://newsletter.kentbeck.com/p/augmented-coding-beyond-the-vibes>
- **Armin Ronacher, building pi with pi**: agents defend locally against
  bad state; the human has to keep pulling the work back to the global
  invariant. <https://lucumr.pocoo.org/2026/5/24/pi-oss/>
- **Geoffrey Litt, "Understanding is the new bottleneck"**: understand in
  order to *participate*, not only to verify. Explanations ordered as a
  story instead of a raw diff; a quiz as a speed regulator.
  <https://www.geoffreylitt.com/2026/07/02/understanding-is-the-new-bottleneck.html>
- **Mitchell Hashimoto**: decide deliberately what to delegate and what to
  keep doing yourself; you decide when to check on the agent, not the
  other way round. <https://mitchellh.com/writing/my-ai-adoption-journey>
- **Simon Willison, engineering with agents**: tests, version control and a
  culture of code review matter more with agents, not less.
  <https://simonwillison.net/2025/Oct/7/vibe-engineering/>
- **Naur and the agent era**: Peter Naur, "Programming as Theory
  Building" (1985), <https://pages.cs.wisc.edu/~remzi/Naur.pdf>; Sean
  Goedecke on applying it to agents,
  <https://www.seangoedecke.com/programming-with-ai-agents-as-theory-building/>

### What pi.nvim does about it

- Changes land unseen: live reload and change marks put every edit in your
  buffers while the agent works. Every agent turn is also snapshotted to a
  hidden git ref (`refs/pi-nvim/…`), even with checkpoint mode off.
- Feedback has nowhere to go: annotations on any number of lines and files,
  with the diagnostics on them, go straight to the agent.
- Volume and passive acceptance: checkpoint mode stops the agent at each
  logical step and after a size cap, and a chunk closes only when you send
  a review. There is no accept button. It is off by default and switched per
  repository, because not every project needs it.

## Related tools

Prior art this builds on or differs from:
[pi-diff-review](https://github.com/badlogic/pi-diff-review),
[Plannotator](https://plannotator.ai/),
[review.nvim](https://github.com/georgeguimaraes/review.nvim),
[tuicr](https://tuicr.dev/),
[Monocle](https://getmonocle.sh/).
None of them scopes changes per agent step or holds the agent until you
have engaged with the change. Overview of how editors handle review
comments for agents:
<https://dev.to/urion/every-editor-now-reviews-your-agents-code-where-do-your-comments-go-34fc>
