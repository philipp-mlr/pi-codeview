local discover = require("pi.discover")
local diagnostics = require("pi.diagnostics")
local pi_text = require("pi.text")

local M = {}

local ns = vim.api.nvim_create_namespace("pi_annotations")
local items = {}
local unplaced = {} -- drafts whose file is missing; kept verbatim so save round-trips never drop them
local next_id = 0
local change_listener = nil
local remove_listener = nil

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

local REBUILD_MS = 50
local attached = {} -- buf -> true while an on_lines callback rebuilds that buffer's extra marks
local timers = {} -- buf -> debounce timer

local function buffer_items(buf)
  local found = {}
  for _, item in ipairs(items) do
    if item.buf == buf then
      found[#found + 1] = item
    end
  end
  return found
end

local function delete_extras(item)
  for _, id in ipairs(item.extra_ids) do
    pcall(vim.api.nvim_buf_del_extmark, item.buf, ns, id)
  end
  item.extra_ids = {}
end

-- The width `buf`'s annotation text may take: the narrowest text area of the windows showing it,
-- or the editor width when none does.
local function text_width(buf)
  local width
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local info = vim.fn.getwininfo(win)[1]
    local room = info.width - info.textoff
    width = width and math.min(width, room) or room
  end
  return width or vim.o.columns
end

local PREFIX, INDENT = "  ✎ ", "    " -- the same width, so both preview lines start in one column
local LABEL_TEXT_WIDTH = 80

-- note as at most 2 lines of `width` cells, broken at spaces; the second ends with "…" when cut.
local function preview(note, width)
  local room = math.max(10, width - vim.fn.strdisplaywidth(PREFIX))
  local lines = pi_text.wrap(note, room)
  if #lines > 2 then
    -- The "…" always follows a cut second line, also when the line itself is short.
    lines = { lines[1], pi_text.fit(lines[2] .. "…", room) }
  end
  return lines
end

-- The main extmark is the source of truth for the range; the number highlight and the text lines
-- are derived from it, since a ranged extmark highlights only its first line's number.
local function build_extras(item)
  local s, e = position(item)
  if not s then
    return
  end
  delete_extras(item)
  for line = s, e do
    item.extra_ids[#item.extra_ids + 1] = vim.api.nvim_buf_set_extmark(item.buf, ns, line - 1, 0, {
      number_hl_group = "PiAnnotationSign",
    })
  end
  local virt = {}
  for i, line in ipairs(preview(item.note, text_width(item.buf))) do
    virt[i] = { { (i == 1 and PREFIX or INDENT) .. line, "PiAnnotation" } }
  end
  item.extra_ids[#item.extra_ids + 1] = vim.api.nvim_buf_set_extmark(item.buf, ns, e - 1, 0, {
    virt_lines = virt,
  })
end

local function stop_timer(buf)
  local timer = timers[buf]
  if timer then
    timer:stop()
    timer:close()
    timers[buf] = nil
  end
end

local function schedule_rebuild(buf)
  local timer = timers[buf]
  if not timer then
    timer = vim.uv.new_timer()
    timers[buf] = timer
  end
  timer:stop()
  timer:start(REBUILD_MS, 0, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(buf) then
      stop_timer(buf)
      return
    end
    if #buffer_items(buf) == 0 then
      stop_timer(buf)
      return
    end
    for _, item in ipairs(buffer_items(buf)) do
      build_extras(item)
    end
  end))
end

local function attach(buf)
  if attached[buf] then
    return
  end
  attached[buf] = true
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if #buffer_items(buf) == 0 then
        attached[buf] = nil
        stop_timer(buf)
        return true
      end
      schedule_rebuild(buf)
    end,
    on_reload = function()
      schedule_rebuild(buf)
    end,
    on_detach = function()
      attached[buf] = nil
      stop_timer(buf)
    end,
  })
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
    sign_text = "✎",
    sign_hl_group = "PiAnnotationSign",
    priority = 200,
  })
  next_id = next_id + 1
  local item = { id = next_id, buf = buf, extmark_id = extmark_id, extra_ids = {}, note = note }
  items[#items + 1] = item
  build_extras(item)
  attach(buf)
end

function M.add(buf, start_line, end_line, note)
  place(buf, start_line, end_line, note)
  notify_change()
end

local function drop(item)
  if vim.api.nvim_buf_is_valid(item.buf) then
    pcall(vim.api.nvim_buf_del_extmark, item.buf, ns, item.extmark_id)
    delete_extras(item)
  end
end

local function report_removed(removed)
  if remove_listener then
    for _, item in ipairs(removed) do
      remove_listener(item)
    end
  end
end

-- Items whose current range contains the cursor line in the current buffer, sorted by start line.
function M.at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local found = {}
  for _, item in ipairs(items) do
    if item.buf == buf then
      local s, e = position(item)
      if s and line >= s and line <= e then
        found[#found + 1] = { item = item, start_line = s }
      end
    end
  end
  table.sort(found, function(a, b)
    if a.start_line ~= b.start_line then
      return a.start_line < b.start_line
    end
    return a.item.id < b.item.id
  end)
  return vim.tbl_map(function(f)
    return f.item
  end, found)
end

-- Picker label: `L<start>-<end>: <text>`, text cut to 80 cells followed by "…".
function M.label(item)
  local s, e = position(item)
  local text = item.note:gsub("%s+", " ")
  if vim.fn.strdisplaywidth(text) > LABEL_TEXT_WIDTH then
    text = pi_text.fit(text .. "…", LABEL_TEXT_WIDTH + 1)
  end
  return ("L%d-%d: %s"):format(s or 0, e or 0, text)
end

function M.remove(item)
  local kept = {}
  for _, other in ipairs(items) do
    if other ~= item then
      kept[#kept + 1] = other
    end
  end
  items = kept
  drop(item)
  report_removed({ item })
  notify_change()
end

-- fn(item) runs after M.remove, M.clear_root or M.clear took an annotation away.
function M.on_remove(fn)
  remove_listener = fn
end

function M.edit(item, text)
  item.note = text
  build_extras(item)
  notify_change()
end

-- The current 1-based (start, end) lines of item, or nil when its mark is gone.
function M.range(item)
  return position(item)
end

-- Rewraps the previews of every buffer shown in a resized window, or newly shown in a window.
local function on_resized(args)
  local resized = {}
  local wins = args.event == "BufWinEnter" and { vim.api.nvim_get_current_win() } or vim.v.event.windows or vim.api.nvim_list_wins()
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      resized[vim.api.nvim_win_get_buf(win)] = true
    end
  end
  for _, item in ipairs(items) do
    if resized[item.buf] then
      build_extras(item)
    end
  end
end

vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "BufWinEnter" }, {
  group = vim.api.nvim_create_augroup("PiAnnotationsResize", { clear = true }),
  callback = on_resized,
})

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
  local kept, removed = {}, {}
  for _, item in ipairs(items) do
    local name = vim.api.nvim_buf_is_valid(item.buf) and vim.api.nvim_buf_get_name(item.buf) or ""
    local real = name ~= "" and vim.uv.fs_realpath(name) or nil
    if real and discover.relpath(root, real) then
      drop(item)
      removed[#removed + 1] = item
    else
      kept[#kept + 1] = item
    end
  end
  items = kept
  unplaced = vim.tbl_filter(function(u)
    return u.root ~= root
  end, unplaced)
  report_removed(removed)
  notify_change()
end

function M.clear()
  local removed = items
  for _, item in ipairs(items) do
    drop(item)
  end
  items = {}
  unplaced = {}
  for buf in pairs(timers) do
    stop_timer(buf)
  end
  report_removed(removed)
  notify_change()
end

-- Test hook: the debounce timers still open, keyed by buffer.
function M._timers()
  return timers
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
