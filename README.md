# pi-codeview

Keep the code in view while a coding agent works on it.

pi-codeview is a [pi](https://pi.dev) extension plus a Neovim plugin. In
review mode the agent works in small chunks and stops at the end of each
one. You read the chunk in Neovim with your usual tools, then comment on
it, edit it, or ask about it. Your feedback goes back to the agent before
its next step. You can switch the loop off per repository when you just
want to vibe-code.

You drive it from Neovim: send the agent a task, annotate as many lines
across as many files as you like, review its chunks, send the next task.
pi keeps running in its own window.

Status: design phase. See
[docs/superpowers/specs/2026-11-10-pi-codeview-design.md](docs/superpowers/specs/2026-11-10-pi-codeview-design.md).

## Usage

### Install

pi side, as a pi package:

```sh
pi install /path/to/pi-codeview
```

Neovim side (Neovim 0.10 or newer): put the repo's `nvim/` directory on the
runtimepath and call `setup()`.

```lua
vim.opt.rtp:append("/path/to/pi-codeview/nvim")
require("codeview").setup()
```

With nixvim:

```nix
extraPlugins = [
  (pkgs.vimUtils.buildVimPlugin {
    pname = "codeview";
    version = "0.1.0";
    src = "${pi-codeview}/nvim"; # the flake input or a path to this repository
  })
];
extraConfigLua = ''require("codeview").setup()'';
```

`setup({ keys = { send = "<leader>rs" } })` overrides single keys; set a key
to `false` to leave it unmapped. A default key that is already mapped (for
example `<leader>cc` by another plugin) is left alone, and `setup()` lists the
skipped keys in one message; keys you pass in `keys` are always mapped.

### Commands and keys

| Command | Default key | What it does |
|---|---|---|
| `:Codeview` | `<leader>cv` | Toggle the chunk panel (`<CR>` opens a chunk, `r` refreshes, `q` closes). |
| `:CodeviewPrompt` | `<leader>cp` | Prompt the agent. Normal mode sends the file and cursor line; visual mode sends the line range and the selected text exactly as in your buffer. Unsaved changes are flagged. |
| `:CodeviewAnnotate` | `<leader>cc` | Annotate the current line or the visual range. |
| `:CodeviewRemove` | `<leader>cx` | Remove the annotation under the cursor. |
| `:CodeviewSend` | `<leader>cs` | Save all buffers, then send the annotations and an optional note. |
| `:CodeviewMode [review\|vibe\|on\|off]` | `<leader>cm` | Switch the mode for this repository; without an argument it toggles. |
| `:CodeviewAttach` | `<leader>ct` | Choose the pi session to work with (listed by session name, mode and state). |

### Which pi session nvim talks to

nvim attaches to a pi session running in the same worktree as the current
buffer. With one such session it attaches on first use; with several it asks.
When you run a command from a buffer in a different worktree, it switches to
that worktree's session. `<leader>ct` picks a session on purpose. Name your pi
sessions (`/name` in pi) to tell them apart in the picker.
`require("codeview").session_label()` gives the attached session's name for
the statusline.

In a chunk diff, `]f` and `[f` move to the next and previous file. For the
chunk waiting for review the right side is the real file, so LSP and editing
work; past chunks open read-only. For the statusline,
`require("codeview").status()` returns `"review N"`, `"working"`, `"idle"`, or
`""` when not connected.

In pi, `/codeview` shows the state, `/codeview on|off` switches review mode,
`/codeview continue <note>` sends a review without Neovim, and
`/codeview discard <note>` throws the open chunk away.

### The loop

1. `/codeview on` in pi (or `<leader>cm` / `:CodeviewMode review`).
2. `<leader>cp`: give the agent a task; it works in pi's window.
3. The agent stops at a checkpoint; the panel opens with the new chunk.
4. `<CR>` on the chunk: read the diff with LSP, edit the live file, `]f` for the next file.
5. `<leader>cc` on lines you have something to say about.
6. `<leader>cs`: the review goes to the agent and it continues.

## Why

Agent harnesses like pi hide the codebase. The agent reads, writes and
runs things, and you see the result in a chat. Often you only see the
actual change once it has been committed.

That is a problem if you are an engineer who understands a system by
working with its code. Peter Naur argued in 1985 that the real product of
programming is the *theory* of the program in the programmer's head, and
the code is a by-product. You build that theory by reading, judging and
changing code. When an agent does all of that for you, the code keeps
growing and your theory of it doesn't.

The problems this project addresses:

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

## What the research says

### Understanding suffers when the agent does the work

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

### The bottleneck moved to review

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

### What practitioners do about it

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
- **Simon Willison, vibe engineering**: tests, version control and a
  culture of code review matter more with agents, not less.
  <https://simonwillison.net/2025/Oct/7/vibe-engineering/>
- **Naur and the agent era**: Peter Naur, "Programming as Theory
  Building" (1985), <https://pages.cs.wisc.edu/~remzi/Naur.pdf>; Sean
  Goedecke on applying it to agents,
  <https://www.seangoedecke.com/programming-with-ai-agents-as-theory-building/>

## How pi-codeview responds

| Problem | Response |
|---|---|
| Changes land unseen | Every agent turn is snapshotted to a hidden git ref, so any turn can be opened in Neovim before anything is committed, even in vibe mode. |
| Passive acceptance | There is no accept button. A chunk closes when you send a review: comments, your own edits, or a note. |
| Volume beats review | The agent stops at each logical step (`checkpoint` tool) and is held after a size cap, so chunks stay review-sized and can't pile up. |
| Feedback has nowhere to go | Annotations on any number of lines and files, plus your own edits, go straight into the agent's next step, during review or as a new task. |
| Early design drift | Small chunks and a stop before every next step give you the chance to hold the invariants while they are still forming. |
| Not every project needs this | Review mode is per repository; the default is vibe mode. |

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
