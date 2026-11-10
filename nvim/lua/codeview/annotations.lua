local discover = require("codeview.discover")

local M = {}

local ns = vim.api.nvim_create_namespace("codeview")
local items = {}
local next_id = 0
local change_listener = nil

local function notify_change()
  if change_listener then
    vim.schedule(change_listener)
  end
end

-- Returns 1-based inclusive (start, end) read back from the extmark, or nil if gone.
local function position(item)
  if not vim.api.nvim_buf_is_valid(item.buf) then
    return nil
  end
  local mark = vim.api.nvim_buf_get_extmark_by_id(item.buf, ns, item.extmark_id, { details = true })
  if #mark == 0 then
    return nil
  end
  local last = math.max(vim.api.nvim_buf_line_count(item.buf), 1)
  local start_line = math.min(mark[1] + 1, last)
  local end_row = mark[3] and mark[3].end_row or mark[1]
  local end_line = math.max(math.min(end_row + 1, last), start_line)
  return start_line, end_line
end

local function place(buf, start_line, end_line, note)
  local last = vim.api.nvim_buf_line_count(buf)
  start_line = math.max(1, math.min(start_line, last))
  end_line = math.max(start_line, math.min(end_line, last))
  local extmark_id = vim.api.nvim_buf_set_extmark(buf, ns, start_line - 1, 0, {
    end_row = end_line - 1,
    end_col = 0,
    right_gravity = false,
    end_right_gravity = true,
    sign_text = "▎",
    sign_hl_group = "DiagnosticSignInfo",
    virt_text = { { "  ✎ " .. note, "Comment" } },
    virt_text_pos = "eol",
  })
  next_id = next_id + 1
  items[#items + 1] = { id = next_id, buf = buf, extmark_id = extmark_id, note = note }
end

function M.add(buf, start_line, end_line, note)
  place(buf, start_line, end_line, note)
  notify_change()
end

local function drop(item)
  if vim.api.nvim_buf_is_valid(item.buf) then
    pcall(vim.api.nvim_buf_del_extmark, item.buf, ns, item.extmark_id)
  end
end

function M.remove_at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local kept, removed = {}, 0
  for _, item in ipairs(items) do
    local s, e = nil, nil
    if item.buf == buf then
      s, e = position(item)
    end
    if s and line >= s and line <= e then
      drop(item)
      removed = removed + 1
    else
      kept[#kept + 1] = item
    end
  end
  items = kept
  if removed > 0 then
    notify_change()
  end
  return removed
end

function M.list(root)
  local kept, result = {}, {}
  for _, item in ipairs(items) do
    local s, e = position(item)
    if s then
      kept[#kept + 1] = item
      local name = vim.api.nvim_buf_get_name(item.buf)
      local real = name ~= "" and vim.uv.fs_realpath(name) or nil
      local rel = real and discover.relpath(root, real) or nil
      if rel then
        result[#result + 1] = { path = rel, startLine = s, endLine = e, note = item.note }
      end
    end
  end
  items = kept
  table.sort(result, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.startLine < b.startLine
  end)
  return result
end

function M.clear()
  for _, item in ipairs(items) do
    drop(item)
  end
  items = {}
  notify_change()
end

function M.restore(drafts, root)
  for _, draft in ipairs(drafts) do
    local path = root .. "/" .. draft.path
    if vim.uv.fs_stat(path) then
      local buf = vim.fn.bufadd(path)
      vim.fn.bufload(buf)
      place(buf, draft.startLine, draft.endLine, draft.note)
    end
  end
  notify_change()
end

function M.on_change(fn)
  change_listener = fn
end

function M.count()
  return #items
end

return M
