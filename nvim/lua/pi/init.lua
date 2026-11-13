-- pi.nvim: commands, keys and autocommands over session, panel and diff.
local annotations = require("pi.annotations")
local badge = require("pi.badge")
local diagnostics = require("pi.diagnostics")
local diff = require("pi.diff")
local discover = require("pi.discover")
local editor = require("pi.editor")
local highlights = require("pi.highlights")
local keys_state = require("pi.keys")
local live = require("pi.live")
local panel = require("pi.panel")
local peek = require("pi.peek")
local session = require("pi.session")
local pi_text = require("pi.text")

local M = {}

-- The last path-like tool target the agent touched, with the session root current then; file tools
-- end fast, so at Follow time the live activity is usually gone.
local last_edit = nil -- { target, root }
-- Move counter: only the newest root_changed may open the follow picker.
local move_seq = 0

-- Whether a tool target looks like a file path (absolute or repo-relative), not a shell command:
-- absolute-ish always; otherwise no spaces (commands have them, paths rarely), and a slash or an
-- extension ("src/a.lua", "f.txt", but not "ls" or "npm test").
local function is_path_like(target)
  if target == "" or target:find("[;&|><$`]") then
    return false
  end
  if vim.startswith(target, "/") or vim.startswith(target, "./") or vim.startswith(target, "../") or vim.startswith(target, "~/") then
    return true
  end
  if target:find("%s") then
    return false
  end
  return target:find("/", 1, true) ~= nil or target:match("^[%w_.%-]+%.[%w_.%-]+$") ~= nil
end

M.auto_open_panel = true -- setup({ panel = { auto_open = false } }) only notifies when a checkpoint arrives

M.default_keys = {
  ask = "<leader>pa",
  continue = "<leader>pc",
  stop = "<leader>ps",
  annotate = "<leader>pn",
  edit = "<leader>pe",
  remove = "<leader>px",
  checkpoints = "<leader>pv",
  mode = "<leader>pm",
  session = "<leader>pi",
  peek = "<leader>pk",
  follow = "<leader>pf",
}

-- Repo-relative path of buf, or nil when it is not a file inside root.
local function relpath(buf, root)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or name:match("^pi://") then
    return nil
  end
  local real = vim.uv.fs_realpath(name)
  if not real then
    -- A named buffer whose file is not on disk yet: resolve its directory instead.
    local dir = vim.uv.fs_realpath(vim.fs.dirname(name))
    real = dir and (dir:gsub("/+$", "") .. "/" .. vim.fs.basename(name))
  end
  return real and discover.relpath(root, real) or nil
end

-- Tells that checkpoint n waits and which keys (or commands) look at it and continue; shorter
-- wordings when the message line is narrow.
function M.notify_waiting(n)
  local look = keys_state.label("checkpoints", ":PiCheckpoints")
  local go = keys_state.label("continue", ":PiContinue")
  pi_text.notify_fit({
    ("pi: checkpoint %s waiting — %s to look, %s to continue"):format(n, look, go),
    ("pi: checkpoint %s waiting — %s look, %s continue"):format(n, look, go),
    ("pi: checkpoint %s waiting — %s to continue"):format(n, go),
    ("pi: checkpoint %s waiting"):format(n),
  })
end

-- One notice when a run ends; reads the open checkpoint from a fresh status.
function M.notify_run_end(data)
  local aborted = type(data) == "table" and data.aborted
  local files = type(data) == "table" and data.files or 0
  local function report(chunk)
    if chunk then
      if aborted then
        pi_text.notify_fit(("pi: stopped — checkpoint %s waiting"):format(chunk.n))
      else
        M.notify_waiting(chunk.n)
      end
    elseif aborted then
      pi_text.notify_fit("pi: stopped")
    elseif files == 0 then
      pi_text.notify_fit("pi: done")
    else
      pi_text.notify_fit(("pi: done — %d file%s changed"):format(files, files == 1 and "" or "s"))
    end
  end
  if not session.connected() then
    return report(nil)
  end
  session.refresh_status(function(err, status)
    report(not err and type(status.openChunk) == "table" and status.openChunk or nil)
  end)
end

-- The file the agent is editing now, as an absolute path under root; nil unless it exists on disk.
-- `activity.target` is a path (repo-relative or absolute) for file tools, else a command or nothing.
local function current_file(root)
  local activity = session.cached and session.cached.activity
  local target = type(activity) == "table" and type(activity.target) == "string" and is_path_like(activity.target)
    and activity.target
    or nil
  local seen_root
  if not target and last_edit and is_path_like(last_edit.target) then
    target, seen_root = last_edit.target, last_edit.root
  end
  if not target then
    return nil
  end
  -- Relative targets are seen before the follow moves the session, so they are relative to the
  -- worktree the agent edits in now (the follow root); fall back to the root current when seen.
  if vim.startswith(target, "~/") then
    target = vim.fn.expand(target)
  end
  local bases = target:sub(1, 1) == "/" and { "" } or vim.tbl_filter(function(r)
    return type(r) == "string" and r ~= ""
  end, { root, seen_root })
  for _, base in ipairs(bases) do
    local path = base == "" and target or (base .. "/" .. target)
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type == "file" then
      return path
    end
  end
  return nil
end

-- Moves this tab into the session's worktree and shows the file the agent is editing in a vertical
-- split, so the live marks are on screen.
local function follow_into(root)
  -- Land in a normal window: leave a checkpoint diff tab for the tab it was opened from, and the
  -- panel for the code window, so the split does not cut the panel or the diff layout.
  local view = diff.view_of_tab(vim.api.nvim_get_current_tabpage())
  if view and view.origin and vim.api.nvim_tabpage_is_valid(view.origin) then
    vim.api.nvim_set_current_tabpage(view.origin)
  end
  if panel.is_panel_window(vim.api.nvim_get_current_win()) then
    if not pcall(vim.cmd, "wincmd p") or panel.is_panel_window(vim.api.nvim_get_current_win()) then
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if not panel.is_panel_window(w) then
          vim.api.nvim_set_current_win(w)
          break
        end
      end
    end
  end
  local ok = pcall(vim.cmd, "tcd " .. vim.fn.fnameescape(root))
  if not ok then
    return pi_text.notify_fit(("pi: could not follow into %s"):format(vim.fs.basename(root)))
  end
  session.refresh_live()
  local file = current_file(root)
  if file then
    vim.cmd("vsplit " .. vim.fn.fnameescape(file))
  end
end

-- Asks, once per move, whether to follow the agent into root (Esc or a closed picker is Stay).
local function ask_follow(root)
  vim.ui.select({ "Follow", "Stay" }, {
    prompt = ("pi: agent moved to %s — follow here?"):format(vim.fs.basename(root)),
  }, function(choice)
    if choice == "Follow" and session.root == root then
      follow_into(root)
    end
  end)
end

-- Follows the agent into the worktree the attached session runs in now (`:PiFollow`, same as Follow
-- in the automatic prompt).
function M.follow()
  session.ensure(function(_, root)
    if root == discover.root(vim.uv.cwd()) then
      return pi_text.notify_fit("pi: nothing to follow")
    end
    follow_into(root)
  end)
end

local function on_event(name, data)
  if name == "root_changed" and type(data) == "table" and type(data.root) == "string" then
    -- The marks of the old worktree's buffers are stale now; refresh_live draws the new root's.
    live.clear()
    local base = vim.fs.basename(data.root)
    -- session.lua already moved its root; a client attached from another worktree is asked.
    local root = session.root
    local will_ask = root and root ~= discover.root(vim.uv.cwd())
    pi_text.notify_fit(
      will_ask and {
        ("pi: following the agent into %s — %s to follow"):format(base, keys_state.label("follow", ":PiFollow")),
        ("pi: following the agent into %s"):format(base),
      } or { ("pi: following the agent into %s"):format(base) }
    )
    move_seq = move_seq + 1
    local mine = move_seq
    if will_ask then
      vim.schedule(function()
        if mine == move_seq then
          ask_follow(root)
        end
      end)
    end
  end
  if name == "activity_current" and type(data) == "table" and type(data.current) == "table" and data.mutating then
    local target = data.current.target
    if type(target) == "string" and is_path_like(target) then
      last_edit = { target = target, root = session.root }
    end
  end
  if name == "run_settled" then
    M.notify_run_end(data)
  end
  -- Only a tool end carries `mutating`; tool start, agent_start and agent_settled events do not reload.
  local mutating = name == "activity_current" and type(data) == "table" and data.mutating == true
  if mutating or name == "chunk_ready" or name == "chunk_reviewed" then
    live.schedule(session.refresh_live)
  end
  -- The extension sends this once per agent run.
  if name == "outside_worktree" then
    local root = session.cached and session.cached.root
    local worktree = type(root) == "string" and vim.fs.basename(root) or "its worktree"
    pi_text.notify_fit({
      ("pi: the agent is editing outside %s — start pi in that worktree to review it"):format(worktree),
      ("pi: the agent is editing outside %s"):format(worktree),
    }, vim.log.levels.WARN)
  end
  -- The server sends { chunk = {...} }. Only an open chunk waits for review; a recorded one (each
  -- changed turn with checkpoint mode off) only shows up in the list, refreshed below.
  local ready = name == "chunk_ready" and type(data) == "table" and type(data.chunk) == "table" and data.chunk or nil
  if ready and ready.status == "open" then
    local n = ready.n or "?"
    if not M.auto_open_panel or panel.visible() or diff.is_diff_window(vim.api.nvim_get_current_win()) then
      M.notify_waiting(n)
    else
      panel.open()
    end
  end
  if name == "chunk_reviewed" and data and data.chunk then
    diff.forget(data.chunk.n)
  end
  if name == "chunk_ready" or name == "chunk_reviewed" or name == "mode_changed" then
    panel.refresh()
  end
end

function M.toggle_panel()
  panel.toggle()
end

function M.open_chunk(n)
  diff.open(n)
end

function M.status()
  return session.status_line()
end

-- The statusline as { { text, hl } ... } (hl nil for plain text); {} when not attached.
function M.statusline_parts()
  return session.statusline_parts()
end

-- "pi: <label>[ [checkpoints]] · <state>" for the statusline; "" when not attached. Reads cached state only.
function M.statusline()
  return session.statusline()
end

-- Name (or short id) of the attached pi session; "" when not attached.
function M.session_label()
  return session.attached_label()
end

-- Lists the pi sessions of this worktree and attaches to the chosen one.
function M.attach()
  session.choose()
end

-- Whether the git worktree of dir (a directory, or nil) is exactly root; a worktree nested in root is not root.
local function in_worktree(root, dir)
  return dir ~= nil and dir ~= "" and discover.root(dir) == root
end

-- Called by pi (`nvim --server … --remote-expr`) when a checkpoint waits and no Neovim is attached.
-- Returns "not here" unless this nvim's cwd or current file is inside root; else returns "ok" at once
-- and then attaches to exactly that session and opens the checkpoint list.
function M.review(root, session_id)
  root = vim.uv.fs_realpath(root) or root
  local name = vim.api.nvim_buf_get_name(0)
  local file = name ~= "" and vim.uv.fs_realpath(name) or nil
  local file_dir = file and vim.fs.dirname(file) or nil
  if not in_worktree(root, vim.uv.cwd()) and not in_worktree(root, file_dir) then
    return "not here"
  end
  -- Deferred: the remote-expr caller waits for the answer, attaching may take a moment.
  vim.schedule(function()
    session.attach_to(root, session_id, function()
      panel.open()
    end)
  end)
  return "ok"
end

-- Sends text as a prompt; context is { path, startLine?, endLine? } or nil.
function M.prompt(text, context, on_sent)
  session.request("prompt", { text = text, context = context }, function(err, result)
    if err then
      return vim.notify("pi: " .. err, vim.log.levels.ERROR)
    end
    if on_sent then
      on_sent()
    end
    if result and result.queued then
      pi_text.notify_fit({ "pi: prompt queued until the open checkpoint is reviewed", "pi: prompt queued" })
    else
      session.mark_busy()
    end
  end)
end

-- The notice explaining why buf cannot be annotated, or nil for a real file buffer. Real files of
-- any worktree pass: session.ensure switches to the worktree's session.
local function annotate_refusal(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name:match("^diffview://") or name:match("^pi://.*@to$") then
    return "pi: past checkpoints are read-only — annotate the file itself"
  end
  if name == "" or name:match("^pi://") or vim.bo[buf].buftype ~= "" then
    return "pi: annotate your file — in a diff, the right side"
  end
end

-- Places the annotation right away, so the note survives even when pi is unreachable; it is saved
-- as a draft once attached.
function M.annotate(buf, start_line, end_line, note)
  local refusal = annotate_refusal(buf)
  if refusal then
    return pi_text.notify_fit(refusal)
  end
  annotations.add(buf, start_line, end_line, note)
  session.ensure(function()
    session.schedule_save()
  end, { buf = buf })
end

-- ERROR and WARN diagnostics of buf (optionally only lines line1..line2) as prompt context.
function M.diagnostics(buf, line1, line2)
  return diagnostics.collect(buf, line1, line2)
end

-- Asks pi to abort the agent's current run.
function M.stop()
  session.request("cancel", nil, function(err, result)
    if err then
      return vim.notify("pi: " .. err, vim.log.levels.ERROR)
    end
    -- A stop that took effect is announced once, by the run-end notice.
    if not result.cancelled then
      pi_text.notify_fit("pi: nothing to stop")
    end
    session.refresh_status()
  end)
end

-- Writes the modified, listed, file-backed buffers whose file lies inside the session's root; buffers
-- of other projects, pi:// views and scratch buffers stay as they are. Returns the file name of the
-- first buffer that could not be written, or nil when all were saved.
local function save_session_buffers(root)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if
      name ~= ""
      and vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].buflisted
      and vim.bo[buf].modified
      and vim.bo[buf].buftype == ""
    then
      local real = vim.uv.fs_realpath(name) or name
      if discover.relpath(root, real) then
        local saved = vim.api.nvim_buf_call(buf, function()
          return pcall(vim.cmd, "silent update")
        end)
        if not saved then
          return vim.fs.basename(name)
        end
      end
    end
  end
end

-- Moves on: with a checkpoint waiting, sends the annotations as its review (no message, no
-- confirmation) and the agent continues; without one, sends the annotations as a new prompt.
function M.continue()
  session.ensure(function(conn, root)
    -- Saved inside ensure, so the saves are reported as Philipp's edits to the attached session. A
    -- review against a file that did not save would be against the old text: nothing is sent.
    local unsaved = save_session_buffers(root)
    if unsaved then
      return pi_text.notify_fit({ ("pi: could not save %s — nothing sent"):format(unsaved), "pi: could not save a file — nothing sent" }, vim.log.levels.WARN)
    end
    session.refresh_status(function(status_err, status)
      if status_err then
        return vim.notify("pi: " .. status_err, vim.log.levels.ERROR)
      end
      local open_chunk = type(status.openChunk) == "table" and status.openChunk or nil
      local roots = session.visited and #session.visited > 0 and session.visited or { root }
      local count = #annotations.list_union(roots)
      if not open_chunk and count == 0 then
        local annotate = keys_state.label("annotate", ":PiAnnotate")
        local ask = keys_state.label("ask", ":PiAsk")
        return pi_text.notify_fit({ ("pi: nothing to send — %s to annotate, %s to ask"):format(annotate, ask), "pi: nothing to send" })
      end
      local payload = {
        annotations = annotations.list_union(roots, { diagnostics = true }),
        note = "",
        viewed = open_chunk ~= nil and diff.viewed(open_chunk.n), -- ignored by the extension, kept for older ones
      }
      conn:request("send", payload, function(err)
        if err then
          return vim.notify("pi: " .. err, vim.log.levels.ERROR)
        end
        for _, r in ipairs(roots) do
          annotations.clear_root(r)
        end
        local counted = ("%d annotation%s"):format(count, count == 1 and "" or "s")
        local label = session.label(status)
        if open_chunk then
          pi_text.notify_fit({
            ("pi[%s]: continuing — checkpoint %d reviewed%s"):format(label, open_chunk.n, count > 0 and " with " .. counted or ""),
            ("pi[%s]: checkpoint %d reviewed"):format(label, open_chunk.n),
            ("pi[%s]: continuing"):format(label),
          })
        else
          pi_text.notify_fit({ ("pi[%s]: %s sent"):format(label, counted), ("pi[%s]: sent"):format(label) })
        end
        session.refresh_status()
      end)
    end)
  end)
end

local MODE_TEXT = {
  checkpoints = {
    "pi: checkpoint mode on — the agent stops at each checkpoint for your review",
    "pi: checkpoint mode on — the agent stops at each checkpoint",
    "pi: checkpoint mode on",
  },
  off = "pi: checkpoint mode off",
}

function M.set_mode(mode)
  session.request("set_mode", { mode = mode }, function(err, result)
    if err then
      return vim.notify("pi: " .. err, vim.log.levels.ERROR)
    end
    pi_text.notify_fit(MODE_TEXT[result.mode] or ("pi: mode " .. tostring(result.mode)))
    session.refresh_status()
  end)
end

-- Switches checkpoint mode on or off, based on the session's current mode. Attaches first when
-- needed, so it works as the very first pi command.
function M.toggle_mode()
  session.request("status", nil, function(err, status)
    if err then
      return vim.notify("pi: " .. err, vim.log.levels.ERROR)
    end
    -- modeNote: the repo's mode is on but this session can't stop for review; "on" again would change nothing.
    M.set_mode((status.mode == "checkpoints" or status.modeNote) and "off" or "checkpoints")
  end)
end

local function range_of(cmd)
  if cmd.range > 0 then
    return cmd.line1, cmd.line2
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return line, line
end

-- Prompt context for buf: the line range, the selected text exactly as in the buffer (so unsaved
-- edits and a selection inside one line come through), and whether the buffer has unsaved changes.
-- sel = { line1, line2, visual = true|nil }; visual uses the '< '> marks and the last visual mode.
function M.prompt_context(buf, root, sel)
  local path = relpath(buf, root)
  if not path and session.visited then
    -- The session may have followed the agent away from the buffer's worktree.
    for i = #session.visited, 1, -1 do
      local tried = relpath(buf, session.visited[i])
      if tried then
        path = tried
        break
      end
    end
  end
  if not path then
    return nil
  end
  local context = { path = path, startLine = sel.line1, endLine = sel.line2 }
  if vim.bo[buf].modified then
    context.unsaved = true
  end
  if sel.visual then
    local ok, lines = pcall(vim.fn.getregion, vim.fn.getpos("'<"), vim.fn.getpos("'>"), { type = vim.fn.visualmode() })
    if not ok then
      lines = vim.api.nvim_buf_get_lines(buf, sel.line1 - 1, sel.line2, false)
    end
    context.text = table.concat(lines, "\n")
  end
  -- Normal mode: the whole file; visual mode: the selected lines.
  local found
  if sel.visual then
    found = diagnostics.collect(buf, sel.line1, sel.line2)
  else
    found = diagnostics.collect(buf)
  end
  if #found > 0 then
    context.diagnostics = found
  end
  return context
end

-- `<file>:<line>` or `<file>:<first>-<last>` for editor titles; the file is buf's base name, so
-- the title stays short.
local function where(buf, line1, line2)
  local name = vim.fs.basename(vim.api.nvim_buf_get_name(buf))
  if name == "" then
    name = "[No Name]"
  end
  local lines = line1 == line2 and tostring(line1) or ("%d-%d"):format(line1, line2)
  return ("%s:%s"):format(name, lines)
end

local function prompt_command(cmd)
  local buf = vim.api.nvim_get_current_buf()
  local sel
  if cmd.range > 0 then
    -- A range that matches the last visual selection came from the visual-mode key.
    local visual = cmd.line1 == vim.fn.line("'<") and cmd.line2 == vim.fn.line("'>")
    sel = { line1 = cmd.line1, line2 = cmd.line2, visual = visual }
  else
    local line = vim.api.nvim_win_get_cursor(0)[1]
    sel = { line1 = line, line2 = line }
  end
  -- Resolve the session first: a missing one errors before anything is typed.
  session.ensure(function()
    local label = session.attached_label()
    local title = (" pi ask · %s%s "):format(where(buf, sel.line1, sel.line2), label ~= "" and " · " .. label or "")
    editor.open({
      title = title,
      draft = "ask",
      on_submit = function(text)
        -- Kept as the draft until pi has taken it, so a failed send does not lose it.
        editor.stash("ask", text)
        session.ensure(function(_, send_root)
          M.prompt(text, M.prompt_context(buf, send_root, sel), function()
            editor.discard_draft("ask", text)
          end)
        end, { buf = buf })
      end,
    })
  end, { buf = buf })
end

local function annotate_command(cmd)
  local buf = vim.api.nvim_get_current_buf()
  local start_line, end_line = range_of(cmd)
  local refusal = annotate_refusal(buf)
  if refusal then
    return pi_text.notify_fit(refusal)
  end
  editor.open({
    title = (" pi note · %s "):format(where(buf, start_line, end_line)),
    draft = "note",
    on_submit = function(note)
      M.annotate(buf, start_line, end_line, note)
    end,
  })
end

-- Picks one of the annotations at the cursor (no picker when exactly one), then calls act(item).
local function pick_annotation(prompt, act)
  local found = annotations.at_cursor()
  if #found == 0 then
    pi_text.notify_fit("pi: no annotation at the cursor")
  elseif #found == 1 then
    act(found[1])
  else
    vim.ui.select(found, { prompt = prompt, format_item = annotations.label }, function(item)
      if item then
        act(item)
      end
    end)
  end
end

local function remove_command()
  pick_annotation("pi: remove which annotation?", annotations.remove)
end

-- An unsent edit of a removed annotation has nothing left to edit.
annotations.on_remove(function(item)
  editor.discard_draft("edit:" .. item.id)
end)

local function edit_command()
  pick_annotation("pi: edit which annotation?", function(item)
    local start_line, end_line = annotations.range(item)
    editor.open({
      title = (" pi edit note · %s "):format(where(item.buf, start_line, end_line)),
      text = item.note,
      draft = "edit:" .. item.id,
      on_submit = function(text)
        annotations.edit(item, text)
      end,
    })
  end)
end

-- Shows the full text behind the previews at the cursor (see pi.peek).
function M.peek()
  peek.open()
end

local function report_write(buf)
  local path = relpath(buf, session.root)
  if path then
    session.request("human_write", { path = path })
  end
  -- Extmarks may have moved with the edit; store the drafts' new positions.
  session.schedule_save()
end

-- Every save is reported, so Philipp's edits are never counted as the agent's. When not attached
-- yet, attach quietly: no message, no picker; nothing happens without exactly one matching session.
local function on_write(args)
  if session.connected() then
    return report_write(args.buf)
  end
  local name = vim.api.nvim_buf_get_name(args.buf)
  if name == "" or name:match("^pi://") then
    return
  end
  local real = vim.uv.fs_realpath(name)
  if not real or #discover.sockets(vim.fs.dirname(real)) == 0 then
    return
  end
  session.ensure(function()
    report_write(args.buf)
  end, { buf = args.buf, quiet = true })
end

-- Splits a key notation into keys: "<leader>pa" → { "<leader>", "p", "a" }.
local function key_tokens(lhs)
  local tokens = {}
  local i = 1
  while i <= #lhs do
    local special = lhs:match("^<[^>]+>", i)
    tokens[#tokens + 1] = special or lhs:sub(i, i)
    i = i + #(special or lhs:sub(i, i))
  end
  return tokens
end

-- The key prefix (at least two keys, e.g. "<leader>p") shared by every key setup mapped; nil if none
-- or fewer than two keys are mapped (one key's whole lhs is a key, not a group).
local function common_prefix()
  if vim.tbl_count(keys_state.mapped) < 2 then
    return nil
  end
  local prefix
  for _, lhs in pairs(keys_state.mapped) do
    local tokens = key_tokens(lhs)
    if not prefix then
      prefix = tokens
    else
      local n = 0
      while n < #prefix and n < #tokens and prefix[n + 1] == tokens[n + 1] do
        n = n + 1
      end
      prefix = vim.list_slice(prefix, 1, n)
    end
  end
  return prefix and #prefix >= 2 and table.concat(prefix) or nil
end

-- Names the shared key prefix "pi" in which-key; which-key is optional and never required.
local function register_which_key_group()
  local prefix = common_prefix()
  local loaded, wk = pcall(require, "which-key")
  if prefix and loaded and type(wk) == "table" and type(wk.add) == "function" then
    pcall(wk.add, { { prefix, group = "pi" } })
  end
end

function M.setup(opts)
  opts = opts or {}
  local keys = vim.tbl_extend("force", M.default_keys, opts.keys or {})
  for _, legacy in ipairs({ "send", "cancel", "chunks" }) do
    if (opts.keys or {})[legacy] ~= nil then
      pi_text.notify_fit({
        "pi: setup keys renamed — send/cancel → continue/stop, chunks → checkpoints, checkpoints (mode) → mode",
        "pi: setup keys renamed — see :help pi-setup-keys",
      }, vim.log.levels.INFO)
      break
    end
  end
  session.on_event(on_event)
  diff.mode = opts.diff or "auto"
  M.auto_open_panel = (opts.panel or {}).auto_open ~= false

  local live_opts = opts.live or {}
  live.sign = live_opts.sign or "▎"
  live.line_hl = live_opts.line_hl == true
  highlights.define()
  badge.enabled = opts.badge ~= false
  if not badge.enabled then
    badge.close()
  end

  local command = vim.api.nvim_create_user_command
  command("PiAsk", prompt_command, { range = true, desc = "pi: ask pi" })
  command("PiContinue", M.continue, { desc = "pi: continue — review the waiting checkpoint or send annotations" })
  command("PiStop", M.stop, { desc = "pi: stop the agent's current run" })
  command("PiAnnotate", annotate_command, { range = true, desc = "pi: annotate lines" })
  command("PiAnnotationEdit", edit_command, { desc = "pi: edit the annotation at the cursor" })
  command("PiAnnotationRemove", remove_command, { desc = "pi: remove the annotation at the cursor" })
  command("PiCheckpoints", M.toggle_panel, { desc = "pi: toggle the checkpoint list" })
  command("PiCheckpointMode", function(cmd)
    if cmd.args == "" then
      return M.toggle_mode()
    end
    M.set_mode(cmd.args)
  end, {
    nargs = "?",
    complete = function()
      return { "on", "off" }
    end,
    desc = "pi: checkpoint mode on|off, toggle without argument",
  })
  command("PiSession", M.attach, { desc = "pi: choose the pi session to work with" })
  command("PiFollow", M.follow, { desc = "pi: follow the agent into the worktree it moved to" })
  command("PiPeek", M.peek, { desc = "pi: peek at the full note or annotation" })

  -- Default keys never replace an existing mapping (e.g. another plugin's <leader>p… key); keys passed in
  -- opts.keys always map.
  local skipped = {}
  keys_state.mapped = {}
  keys_state.skipped = skipped
  local function map(modes, name, rhs, desc)
    local lhs = keys[name]
    if not lhs then
      return
    end
    if (opts.keys or {})[name] == nil then
      local existing = vim.fn.maparg(lhs, modes, false, true)
      if not vim.tbl_isempty(existing) and not vim.startswith(existing.desc or "", "pi:") then
        skipped[#skipped + 1] = ("%s (%s)"):format(lhs, modes)
        return
      end
    end
    vim.keymap.set(modes, lhs, rhs, { desc = desc })
    keys_state.mapped[name] = lhs
  end
  map("n", "ask", "<cmd>PiAsk<CR>", "pi: ask with file context")
  map("x", "ask", ":PiAsk<CR>", "pi: ask with selection context")
  map("n", "continue", "<cmd>PiContinue<CR>", "pi: continue — review the waiting checkpoint or send annotations")
  map("n", "stop", "<cmd>PiStop<CR>", "pi: stop the agent's current run")
  map("n", "annotate", "<cmd>PiAnnotate<CR>", "pi: annotate line")
  map("x", "annotate", ":PiAnnotate<CR>", "pi: annotate selection")
  map("n", "edit", "<cmd>PiAnnotationEdit<CR>", "pi: edit annotation")
  map("n", "remove", "<cmd>PiAnnotationRemove<CR>", "pi: remove annotation")
  map("n", "checkpoints", "<cmd>PiCheckpoints<CR>", "pi: toggle checkpoint list")
  map("n", "mode", "<cmd>PiCheckpointMode<CR>", "pi: toggle checkpoint mode")
  map("n", "session", "<cmd>PiSession<CR>", "pi: choose pi session")
  map("n", "follow", "<cmd>PiFollow<CR>", "pi: follow the agent's worktree")
  map("n", "peek", "<cmd>PiPeek<CR>", "pi: peek at the full note or annotation")
  if #skipped > 0 then
    pi_text.notify_fit({
      "pi: kept existing mappings, not mapped: " .. table.concat(skipped, ", "),
      ("pi: kept %d existing mapping%s — :checkhealth pi lists them"):format(#skipped, #skipped == 1 and "" or "s"),
    }, vim.log.levels.INFO)
  end

  register_which_key_group()

  local group = vim.api.nvim_create_augroup("pi", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", { group = group, callback = on_write })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights.define })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function()
      if session.connected() then
        live.schedule(session.refresh_live)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      badge.close()
      session.flush()
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "TabEnter", "TabNew", "TabClosed" }, { group = group, callback = badge.reposition })
  vim.api.nvim_create_autocmd("TabClosed", { group = group, callback = diff.cleanup })
end

return M
