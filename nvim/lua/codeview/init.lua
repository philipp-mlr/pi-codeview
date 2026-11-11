-- codeview.nvim: commands, keys and autocommands over session, panel and diff.
local annotations = require("codeview.annotations")
local diff = require("codeview.diff")
local discover = require("codeview.discover")
local live = require("codeview.live")
local panel = require("codeview.panel")
local session = require("codeview.session")

local M = {}

M.default_keys = {
  panel = "<leader>cv",
  prompt = "<leader>cp",
  annotate = "<leader>cc",
  remove = "<leader>cx",
  send = "<leader>cs",
  mode = "<leader>cm",
  attach = "<leader>ct",
}

-- Repo-relative path of buf, or nil when it is not a file inside root.
local function relpath(buf, root)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or name:match("^codeview://") then
    return nil
  end
  local real = vim.uv.fs_realpath(name)
  return real and discover.relpath(root, real) or nil
end

local function on_event(name, data)
  -- A tool that cannot change files triggers no reload; `mutating` is absent from older extensions.
  local mutating = name == "activity_current" and not (type(data) == "table" and data.mutating == false)
  if mutating or name == "chunk_ready" or name == "chunk_reviewed" then
    live.schedule(session.refresh_live)
  end
  if name == "chunk_ready" then
    -- The server sends { chunk = {...} }.
    local n = data and (data.chunk and data.chunk.n) or "?"
    if panel.visible() or diff.is_diff_window(vim.api.nvim_get_current_win()) then
      vim.notify(("codeview: chunk %s ready"):format(n))
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

-- "codeview: <label> · <state>" for the statusline; "" when not attached. Reads cached state only.
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
      return vim.notify("codeview: " .. err, vim.log.levels.ERROR)
    end
    if result and result.queued then
      vim.notify("codeview: prompt queued until the open chunk is reviewed")
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

-- Sends the annotations and opts.note (asked via vim.ui.input when nil) as review or prompt.
function M.send(opts)
  opts = opts or {}
  session.ensure(function(conn, root)
    -- Saved inside ensure, so the saves are reported as Philipp's edits to the attached session.
    vim.cmd("silent! wall")
    local function deliver(note)
      if note == nil then
        return
      end
      session.refresh_status(function(status_err, status)
        if status_err then
          return vim.notify("codeview: " .. status_err, vim.log.levels.ERROR)
        end
        local open_chunk = type(status.openChunk) == "table" and status.openChunk or nil
        local payload = {
          annotations = annotations.list(root),
          note = note,
          viewed = open_chunk ~= nil and diff.viewed(open_chunk.n),
        }
        conn:request("send", payload, function(err)
          if err then
            return vim.notify("codeview: " .. err, vim.log.levels.ERROR)
          end
          annotations.clear_root(root)
          vim.notify(open_chunk and ("codeview: review of chunk %d sent"):format(open_chunk.n) or "codeview: annotations sent")
          session.refresh_status()
        end)
      end)
    end
    if opts.note ~= nil then
      deliver(opts.note)
    else
      vim.ui.input({ prompt = "codeview note (optional): " }, deliver)
    end
  end)
end

local MODE_TEXT = {
  review = "codeview: review mode — the agent stops at each checkpoint for your review",
  vibe = "codeview: vibe mode — no checkpoints, changes are only recorded",
}

function M.set_mode(mode)
  session.request("set_mode", { mode = mode }, function(err, result)
    if err then
      return vim.notify("codeview: " .. err, vim.log.levels.ERROR)
    end
    vim.notify(MODE_TEXT[result.mode] or ("codeview: mode " .. tostring(result.mode)))
    session.refresh_status()
  end)
end

-- Switches between review and vibe, based on the session's current mode. Attaches first when
-- needed, so it works as the very first codeview command.
function M.toggle_mode()
  session.request("status", nil, function(err, status)
    if err then
      return vim.notify("codeview: " .. err, vim.log.levels.ERROR)
    end
    M.set_mode(status.mode == "review" and "vibe" or "review")
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
  vim.ui.input({ prompt = "codeview prompt: " }, function(text)
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
  vim.ui.input({ prompt = "codeview annotation: " }, function(note)
    if note and note ~= "" then
      M.annotate(buf, start_line, end_line, note)
    end
  end)
end

local function remove_command()
  if annotations.remove_at_cursor() == 0 then
    vim.notify("codeview: no annotation at the cursor")
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
  if name == "" or name:match("^codeview://") then
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

  local command = vim.api.nvim_create_user_command
  command("Codeview", M.toggle_panel, { desc = "codeview: toggle the chunk panel" })
  command("CodeviewPrompt", prompt_command, { range = true, desc = "codeview: prompt the agent" })
  command("CodeviewAnnotate", annotate_command, { range = true, desc = "codeview: annotate lines" })
  command("CodeviewRemove", remove_command, { desc = "codeview: remove the annotation at the cursor" })
  command("CodeviewSend", function()
    M.send()
  end, { desc = "codeview: send annotations and note" })
  command("CodeviewAttach", M.attach, { desc = "codeview: choose the pi session to work with" })
  command("CodeviewMode", function(cmd)
    if cmd.args == "" then
      return M.toggle_mode()
    end
    M.set_mode(cmd.args)
  end, {
    nargs = "?",
    complete = function()
      return { "review", "vibe", "on", "off" }
    end,
    desc = "codeview: set mode review|vibe (on|off), toggle without argument",
  })

  -- Default keys never replace an existing mapping (e.g. an LSP <leader>c… key); keys passed in
  -- opts.keys always map.
  local skipped = {}
  local function map(modes, name, rhs, desc)
    local lhs = keys[name]
    if not lhs then
      return
    end
    if (opts.keys or {})[name] == nil then
      local existing = vim.fn.maparg(lhs, modes, false, true)
      if not vim.tbl_isempty(existing) and not vim.startswith(existing.desc or "", "codeview:") then
        skipped[#skipped + 1] = ("%s (%s)"):format(lhs, modes)
        return
      end
    end
    vim.keymap.set(modes, lhs, rhs, { desc = desc })
  end
  map("n", "panel", "<cmd>Codeview<CR>", "codeview: toggle panel")
  map("n", "prompt", "<cmd>CodeviewPrompt<CR>", "codeview: prompt with file context")
  map("x", "prompt", ":CodeviewPrompt<CR>", "codeview: prompt with selection context")
  map("n", "annotate", "<cmd>CodeviewAnnotate<CR>", "codeview: annotate line")
  map("x", "annotate", ":CodeviewAnnotate<CR>", "codeview: annotate selection")
  map("n", "remove", "<cmd>CodeviewRemove<CR>", "codeview: remove annotation")
  map("n", "send", "<cmd>CodeviewSend<CR>", "codeview: send")
  map("n", "mode", "<cmd>CodeviewMode<CR>", "codeview: toggle review/vibe mode")
  map("n", "attach", "<cmd>CodeviewAttach<CR>", "codeview: choose pi session")
  if #skipped > 0 then
    vim.notify("codeview: kept existing mappings, not mapped: " .. table.concat(skipped, ", "), vim.log.levels.INFO)
  end

  local group = vim.api.nvim_create_augroup("codeview", { clear = true })
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
