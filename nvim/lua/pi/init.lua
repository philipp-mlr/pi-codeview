-- pi.nvim: commands, keys and autocommands over session, panel and diff.
local annotations = require("pi.annotations")
local diagnostics = require("pi.diagnostics")
local diff = require("pi.diff")
local discover = require("pi.discover")
local live = require("pi.live")
local panel = require("pi.panel")
local session = require("pi.session")

local M = {}

M.default_keys = {
  ask = "<leader>pa",
  session = "<leader>ps",
  annotate = "<leader>pn",
  remove = "<leader>px",
  send = "<leader>pr",
  chunks = "<leader>pv",
  checkpoints = "<leader>pm",
  cancel = "<leader>pc",
}

-- Repo-relative path of buf, or nil when it is not a file inside root.
local function relpath(buf, root)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or name:match("^pi://") then
    return nil
  end
  local real = vim.uv.fs_realpath(name)
  return real and discover.relpath(root, real) or nil
end

local function on_event(name, data)
  -- Only a tool end carries `mutating`; tool start, agent_start and agent_settled events do not reload.
  local mutating = name == "activity_current" and type(data) == "table" and data.mutating == true
  if mutating or name == "chunk_ready" or name == "chunk_reviewed" then
    live.schedule(session.refresh_live)
  end
  if name == "chunk_ready" then
    -- The server sends { chunk = {...} }.
    local n = data and (data.chunk and data.chunk.n) or "?"
    if panel.visible() or diff.is_diff_window(vim.api.nvim_get_current_win()) then
      vim.notify(("pi: chunk %s ready"):format(n))
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
      vim.notify("pi: prompt queued until the open chunk is reviewed")
    else
      session.mark_busy()
    end
  end)
end

-- Places the annotation right away, so the note survives even when pi is unreachable; it is saved
-- as a draft once attached.
function M.annotate(buf, start_line, end_line, note)
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
function M.cancel()
  session.request("cancel", nil, function(err, result)
    if err then
      return vim.notify("pi: " .. err, vim.log.levels.ERROR)
    end
    vim.notify(result.cancelled and "pi: cancelled" or "pi: nothing to cancel")
    session.refresh_status()
  end)
end

-- Sends the annotations and opts.note (asked via vim.ui.input when nil) as review or prompt.
function M.send(opts)
  opts = opts or {}
  session.ensure(function(conn, root)
    -- Saved inside ensure, so the saves are reported as Philipp's edits to the attached session.
    vim.cmd("silent! wall")
    local function plural(n)
      return ("%d annotation%s"):format(n, n == 1 and "" or "s")
    end
    local function deliver(note, count, open_chunk)
      if note == nil then
        return
      end
      local payload = {
        annotations = annotations.list(root, { diagnostics = true }),
        note = note,
        viewed = open_chunk ~= nil and diff.viewed(open_chunk.n),
      }
      conn:request("send", payload, function(err)
        if err then
          return vim.notify("pi: " .. err, vim.log.levels.ERROR)
        end
        annotations.clear_root(root)
        vim.notify(
          open_chunk and ("pi: review of chunk %d sent with %s"):format(open_chunk.n, plural(count))
            or ("pi: %s sent"):format(plural(count))
        )
        session.refresh_status()
      end)
    end
    session.refresh_status(function(status_err, status)
      if status_err then
        return vim.notify("pi: " .. status_err, vim.log.levels.ERROR)
      end
      local open_chunk = type(status.openChunk) == "table" and status.openChunk or nil
      local count = #annotations.list(root)
      if not open_chunk and count == 0 then
        return vim.notify("pi: no annotations to send")
      end
      if opts.note ~= nil then
        return deliver(opts.note, count, open_chunk)
      end
      local prompt = open_chunk and ("pi: review of chunk %d with %s — optional message: "):format(open_chunk.n, plural(count))
        or ("pi: send %s — optional message: "):format(plural(count))
      vim.ui.input({ prompt = prompt }, function(note)
        deliver(note, count, open_chunk)
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
  vim.ui.input({ prompt = "pi annotation: " }, function(note)
    if note and note ~= "" then
      M.annotate(buf, start_line, end_line, note)
    end
  end)
end

local function remove_command()
  if annotations.remove_at_cursor() == 0 then
    vim.notify("pi: no annotation at the cursor")
  end
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
  session.on_event(on_event)

  vim.api.nvim_set_hl(0, "PiAnnotation", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "PiAnnotationSign", { link = "DiagnosticSignInfo", default = true })

  local command = vim.api.nvim_create_user_command
  command("PiChunks", M.toggle_panel, { desc = "pi: toggle the chunk panel" })
  command("PiAsk", prompt_command, { range = true, desc = "pi: ask pi" })
  command("PiAnnotate", annotate_command, { range = true, desc = "pi: annotate lines" })
  command("PiAnnotationRemove", remove_command, { desc = "pi: remove the annotation at the cursor" })
  command("PiSendAnnotations", function()
    M.send()
  end, { desc = "pi: send annotations" })
  command("PiCancel", M.cancel, { desc = "pi: cancel the agent's current run" })
  command("PiSession", M.attach, { desc = "pi: choose the pi session to work with" })
  command("PiCheckpoints", function(cmd)
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

  -- Default keys never replace an existing mapping (e.g. another plugin's <leader>p… key); keys passed in
  -- opts.keys always map.
  local skipped = {}
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
  end
  map("n", "ask", "<cmd>PiAsk<CR>", "pi: ask with file context")
  map("x", "ask", ":PiAsk<CR>", "pi: ask with selection context")
  map("n", "cancel", "<cmd>PiCancel<CR>", "pi: cancel the agent's current run")
  map("n", "session", "<cmd>PiSession<CR>", "pi: choose pi session")
  map("n", "annotate", "<cmd>PiAnnotate<CR>", "pi: annotate line")
  map("x", "annotate", ":PiAnnotate<CR>", "pi: annotate selection")
  map("n", "remove", "<cmd>PiAnnotationRemove<CR>", "pi: remove annotation")
  map("n", "send", "<cmd>PiSendAnnotations<CR>", "pi: send annotations")
  map("n", "chunks", "<cmd>PiChunks<CR>", "pi: toggle chunk panel")
  map("n", "checkpoints", "<cmd>PiCheckpoints<CR>", "pi: toggle checkpoint mode")
  if #skipped > 0 then
    vim.notify("pi: kept existing mappings, not mapped: " .. table.concat(skipped, ", "), vim.log.levels.INFO)
  end

  local group = vim.api.nvim_create_augroup("pi", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", { group = group, callback = on_write })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function()
      if session.connected() then
        live.schedule(session.refresh_live)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = session.flush })
  vim.api.nvim_create_autocmd("TabClosed", { group = group, callback = diff.cleanup })
end

return M
