-- pi.nvim: commands, keys and autocommands over session, panel and diff.
local annotations = require("pi.annotations")
local badge = require("pi.badge")
local diagnostics = require("pi.diagnostics")
local diff = require("pi.diff")
local discover = require("pi.discover")
local highlights = require("pi.highlights")
local keys_state = require("pi.keys")
local live = require("pi.live")
local panel = require("pi.panel")
local session = require("pi.session")

local M = {}

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

-- Tells that checkpoint n waits and which keys (or commands) look at it and continue.
function M.notify_waiting(n)
  local look = keys_state.label("checkpoints", ":PiCheckpoints")
  local go = keys_state.label("continue", ":PiContinue")
  vim.notify(("pi: checkpoint %s waiting — %s to look, %s to continue"):format(n, look, go))
end

-- One notice when a run ends; reads the open checkpoint from a fresh status.
function M.notify_run_end(data)
  local aborted = type(data) == "table" and data.aborted
  local files = type(data) == "table" and data.files or 0
  local function report(chunk)
    if chunk then
      if aborted then
        vim.notify(("pi: stopped — checkpoint %s waiting"):format(chunk.n))
      else
        M.notify_waiting(chunk.n)
      end
    elseif aborted then
      vim.notify("pi: stopped")
    elseif files == 0 then
      vim.notify("pi: done")
    else
      vim.notify(("pi: done — %d file%s changed"):format(files, files == 1 and "" or "s"))
    end
  end
  if not session.connected() then
    return report(nil)
  end
  session.refresh_status(function(err, status)
    report(not err and type(status.openChunk) == "table" and status.openChunk or nil)
  end)
end

local function on_event(name, data)
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
    vim.notify(
      ("pi: the agent is editing files outside %s — checkpoint mode can't show them; start pi in that worktree"):format(root or "its worktree"),
      vim.log.levels.WARN
    )
  end
  if name == "chunk_ready" then
    -- The server sends { chunk = {...} }.
    local n = data and (data.chunk and data.chunk.n) or "?"
    if panel.visible() or diff.is_diff_window(vim.api.nvim_get_current_win()) then
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

-- Sends text as a prompt; context is { path, startLine?, endLine? } or nil.
function M.prompt(text, context)
  session.request("prompt", { text = text, context = context }, function(err, result)
    if err then
      return vim.notify("pi: " .. err, vim.log.levels.ERROR)
    end
    if result and result.queued then
      vim.notify("pi: prompt queued until the open checkpoint is reviewed")
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
    return vim.notify(refusal)
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
      vim.notify("pi: nothing to stop")
    end
    session.refresh_status()
  end)
end

-- Moves on: with a checkpoint waiting, sends the annotations as its review (no message, no
-- confirmation) and the agent continues; without one, sends the annotations as a new prompt.
function M.continue()
  session.ensure(function(conn, root)
    -- Saved inside ensure, so the saves are reported as Philipp's edits to the attached session.
    vim.cmd("silent! wall")
    session.refresh_status(function(status_err, status)
      if status_err then
        return vim.notify("pi: " .. status_err, vim.log.levels.ERROR)
      end
      local open_chunk = type(status.openChunk) == "table" and status.openChunk or nil
      local count = #annotations.list(root)
      if not open_chunk and count == 0 then
        return vim.notify("pi: nothing to send")
      end
      local payload = {
        annotations = annotations.list(root, { diagnostics = true }),
        note = "",
        viewed = open_chunk ~= nil and diff.viewed(open_chunk.n), -- ignored by the extension, kept for older ones
      }
      conn:request("send", payload, function(err)
        if err then
          return vim.notify("pi: " .. err, vim.log.levels.ERROR)
        end
        annotations.clear_root(root)
        local counted = ("%d annotation%s"):format(count, count == 1 and "" or "s")
        if open_chunk then
          vim.notify(("pi: continuing — checkpoint %d reviewed%s"):format(open_chunk.n, count > 0 and " with " .. counted or ""))
        else
          vim.notify(("pi: %s sent"):format(counted))
        end
        session.refresh_status()
      end)
    end)
  end)
end

local MODE_TEXT = {
  checkpoints = "pi: checkpoint mode on — the agent stops at each checkpoint for your review",
  off = "pi: checkpoint mode off",
}

function M.set_mode(mode)
  session.request("set_mode", { mode = mode }, function(err, result)
    if err then
      return vim.notify("pi: " .. err, vim.log.levels.ERROR)
    end
    vim.notify(MODE_TEXT[result.mode] or ("pi: mode " .. tostring(result.mode)))
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
    M.set_mode(status.mode == "checkpoints" and "off" or "checkpoints")
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
  vim.ui.input({ prompt = "pi ask: " }, function(text)
    if not text or text == "" then
      return
    end
    session.ensure(function(_, root)
      M.prompt(text, M.prompt_context(buf, root, sel))
    end, { buf = buf })
  end)
end

local function annotate_command(cmd)
  local buf = vim.api.nvim_get_current_buf()
  local start_line, end_line = range_of(cmd)
  local refusal = annotate_refusal(buf)
  if refusal then
    return vim.notify(refusal)
  end
  vim.ui.input({ prompt = "pi annotation: " }, function(note)
    if note and note ~= "" then
      M.annotate(buf, start_line, end_line, note)
    end
  end)
end

-- Picks one of the annotations at the cursor (no picker when exactly one), then calls act(item).
local function pick_annotation(prompt, act)
  local found = annotations.at_cursor()
  if #found == 0 then
    vim.notify("pi: no annotation at the cursor")
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

local function edit_command()
  pick_annotation("pi: edit which annotation?", function(item)
    vim.ui.input({ prompt = "pi annotation: ", default = item.note }, function(text)
      text = text and vim.trim(text) or ""
      if text ~= "" then
        annotations.edit(item, text)
      end
    end)
  end)
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

function M.setup(opts)
  opts = opts or {}
  local keys = vim.tbl_extend("force", M.default_keys, opts.keys or {})
  for _, legacy in ipairs({ "send", "cancel", "chunks" }) do
    if (opts.keys or {})[legacy] ~= nil then
      vim.notify(
        "pi: setup keys renamed — send/cancel → continue/stop, chunks → checkpoints, checkpoints (mode) → mode",
        vim.log.levels.INFO
      )
      break
    end
  end
  session.on_event(on_event)
  diff.mode = opts.diff or "auto"

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

  -- Default keys never replace an existing mapping (e.g. another plugin's <leader>p… key); keys passed in
  -- opts.keys always map.
  local skipped = {}
  keys_state.mapped = {}
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
  if #skipped > 0 then
    vim.notify("pi: kept existing mappings, not mapped: " .. table.concat(skipped, ", "), vim.log.levels.INFO)
  end

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
  vim.api.nvim_create_autocmd({ "VimResized", "TabEnter" }, { group = group, callback = badge.reposition })
  vim.api.nvim_create_autocmd("TabClosed", { group = group, callback = diff.cleanup })
end

return M
