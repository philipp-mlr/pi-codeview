local discover = require("pi.discover")
local diagnostics = require("pi.diagnostics")

local M = {}

local ns = vim.api.nvim_create_namespace("pi_annotations")
local items = {}
local unplaced = {} -- drafts whose file is missing; kept verbatim so save round-trips never drop them
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

-- opts.diagnostics: attach the ERROR/WARN diagnostics on each annotation's current lines.
function M.list(root, opts)
  local kept, result = {}, {}
  for _, item in ipairs(items) do
    local s, e = position(item)
    if s then
      kept[#kept + 1] = item
      local name = vim.api.nvim_buf_get_name(item.buf)
      local real = name ~= "" and vim.uv.fs_realpath(name) or nil
      local rel = real and discover.relpath(root, real) or nil
      if rel then
        local entry = { path = rel, startLine = s, endLine = e, note = item.note }
        if opts and opts.diagnostics then
          local found = diagnostics.collect(item.buf, s, e)
          if #found > 0 then
            entry.diagnostics = found
          end
        end
        result[#result + 1] = entry
      end
    end
  end
  items = kept
  for _, u in ipairs(unplaced) do
    if u.root == root then
      result[#result + 1] = vim.deepcopy(u.draft)
    end
  end
  table.sort(result, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.startLine < b.startLine
  end)
  return result
end

-- Drops the annotations of files under root and the unplaced drafts of root; others stay.
function M.clear_root(root)
  local kept = {}
  for _, item in ipairs(items) do
    local name = vim.api.nvim_buf_is_valid(item.buf) and vim.api.nvim_buf_get_name(item.buf) or ""
    local real = name ~= "" and vim.uv.fs_realpath(name) or nil
    if real and discover.relpath(root, real) then
      drop(item)
    else
      kept[#kept + 1] = item
    end
  end
  items = kept
  unplaced = vim.tbl_filter(function(u)
    return u.root ~= root
  end, unplaced)
  notify_change()
end

function M.clear()
  for _, item in ipairs(items) do
    drop(item)
  end
  items = {}
  unplaced = {}
  notify_change()
end

local function same(a, b)
  return a.path == b.path and a.startLine == b.startLine and a.endLine == b.endLine and a.note == b.note
end

function M.restore(drafts, root)
  local changed = false
  for _, draft in ipairs(drafts) do
    local path = root .. "/" .. draft.path
    local exists = vim.uv.fs_stat(path) ~= nil
    local buf = nil
    local target = draft
    if exists then
      -- A draft parked as unplaced becomes placeable once its file exists.
      local parked = {}
      for _, u in ipairs(unplaced) do
        if not (u.root == root and same(u.draft, draft)) then
          parked[#parked + 1] = u
        end
      end
      unplaced = parked
      buf = vim.fn.bufadd(path)
      vim.fn.bufload(buf)
      -- Stored ranges are clamped to the buffer, so compare against the clamped draft.
      local last = math.max(vim.api.nvim_buf_line_count(buf), 1)
      local s = math.max(1, math.min(draft.startLine, last))
      target = { path = draft.path, startLine = s, endLine = math.max(s, math.min(draft.endLine, last)), note = draft.note }
    end
    local duplicate = false
    for _, p in ipairs(M.list(root)) do
      if same(p, target) or (not exists and same(p, draft)) then
        duplicate = true
        break
      end
    end
    if not duplicate then
      if exists then
        place(buf, draft.startLine, draft.endLine, draft.note)
      else
        unplaced[#unplaced + 1] = { root = root, draft = vim.deepcopy(draft) }
      end
      changed = true
    end
  end
  if changed then
    notify_change()
  end
end

function M.on_change(fn)
  change_listener = fn
end

function M.count(root)
  if root then
    return #M.list(root)
  end
  local n = #unplaced
  for _, item in ipairs(items) do
    if position(item) and vim.api.nvim_buf_get_name(item.buf) ~= "" then
      n = n + 1
    end
  end
  return n
end

return M
