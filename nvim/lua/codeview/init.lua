-- codeview.nvim: commands, keys and autocommands over session, panel and diff.
local annotations = require("codeview.annotations")
local diff = require("codeview.diff")
local discover = require("codeview.discover")
local panel = require("codeview.panel")
local session = require("codeview.session")

local M = {}

M.default_keys = {
  panel = "<leader>cv",
  prompt = "<leader>ca",
  annotate = "<leader>cc",
  remove = "<leader>cx",
  send = "<leader>cs",
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
  if name == "chunk_ready" then
    -- The server sends { chunk = {...} }; docs/protocol.md shows { n = ... }.
    local n = data and (data.n or (data.chunk and data.chunk.n)) or "?"
    if panel.visible() or diff.is_diff_window(vim.api.nvim_get_current_win()) then
      vim.notify(("codeview: chunk %s ready"):format(n))
    else
      panel.open()
    end
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

function M.annotate(buf, start_line, end_line, note)
  session.ensure(function()
    annotations.add(buf, start_line, end_line, note)
  end)
end

-- Sends the annotations and opts.note (asked via vim.ui.input when nil) as review or prompt.
function M.send(opts)
  opts = opts or {}
  vim.cmd("silent! wall")
  session.ensure(function(conn, root)
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
          annotations.clear()
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

function M.set_mode(mode)
  session.request("set_mode", { mode = mode }, function(err, result)
    if err then
      return vim.notify("codeview: " .. err, vim.log.levels.ERROR)
    end
    vim.notify("codeview: mode " .. result.mode)
  end)
end

local function range_of(cmd)
  if cmd.range > 0 then
    return cmd.line1, cmd.line2
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return line, line
end

local function prompt_command(cmd)
  local buf = vim.api.nvim_get_current_buf()
  local start_line, end_line = cmd.line1, cmd.line2
  local ranged = cmd.range > 0
  vim.ui.input({ prompt = "codeview prompt: " }, function(text)
    if not text or text == "" then
      return
    end
    session.ensure(function(_, root)
      local path = relpath(buf, root)
      local context = nil
      if path and ranged then
        context = { path = path, startLine = start_line, endLine = end_line }
      elseif path then
        context = { path = path }
      end
      M.prompt(text, context)
    end)
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

local function on_write(args)
  if not session.connected() then
    return
  end
  local path = relpath(args.buf, session.root)
  if path then
    session.request("human_write", { path = path })
  end
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
  command("CodeviewMode", function(cmd)
    M.set_mode(cmd.args)
  end, {
    nargs = 1,
    complete = function()
      return { "review", "vibe" }
    end,
    desc = "codeview: set mode review or vibe",
  })

  local function map(modes, lhs, rhs, desc)
    if lhs then
      vim.keymap.set(modes, lhs, rhs, { desc = desc })
    end
  end
  map("n", keys.panel, "<cmd>Codeview<CR>", "codeview: toggle panel")
  map("n", keys.prompt, "<cmd>CodeviewPrompt<CR>", "codeview: prompt with file context")
  map("x", keys.prompt, ":CodeviewPrompt<CR>", "codeview: prompt with selection context")
  map("n", keys.annotate, "<cmd>CodeviewAnnotate<CR>", "codeview: annotate line")
  map("x", keys.annotate, ":CodeviewAnnotate<CR>", "codeview: annotate selection")
  map("n", keys.remove, "<cmd>CodeviewRemove<CR>", "codeview: remove annotation")
  map("n", keys.send, "<cmd>CodeviewSend<CR>", "codeview: send")

  local group = vim.api.nvim_create_augroup("codeview", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", { group = group, callback = on_write })
end

return M
