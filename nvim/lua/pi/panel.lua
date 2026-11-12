-- Checkpoint list in a left vertical split.
local diff = require("pi.diff")
local keys = require("pi.keys")
local session = require("pi.session")
local pi_text = require("pi.text")

local fit, wrap = pi_text.fit, pi_text.wrap

local M = {}

local MIN_WIDTH, MAX_WIDTH, WIDTH_SHARE = 40, 60, 0.35
local HELP_PREFIX = " pi checkpoints —"
local HELP_KEYS = " <CR> open · za more · g? keys"
local ICONS = { open = "●", reviewed = "✓", discarded = "✗", recorded = "·" }
local STATUS_WORDS = { open = "waiting", reviewed = "reviewed", discarded = "discarded", recorded = "recorded" }

local ns = vim.api.nvim_create_namespace("pi_panel")
local buf = nil
local list = {} -- chunks from the last refresh
local show_recorded = false
local expanded = {} -- chunk n -> true while its details are shown
local stats = {} -- chunk n -> { path, added, removed }[], "loading" or "failed"; dropped by refresh when the status changed
local generation = 0 -- bumped by refresh so late get_chunk answers are dropped
local lines_info = {} -- line number -> { n = chunk n, path = file path or nil }

local function panel_win()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
end

function M.visible()
  return panel_win() ~= nil
end

function M.is_panel_window(win)
  return buf ~= nil and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf
end

local function files_of(chunk)
  local files = {}
  for _, path in ipairs(chunk.agentFiles or {}) do
    files[#files + 1] = path
  end
  for _, path in ipairs(chunk.humanFiles or {}) do
    if not vim.tbl_contains(files, path) then
      files[#files + 1] = path
    end
  end
  table.sort(files)
  return files
end

-- The chunk's title, else the first sentence of its note (up to ". " or a newline).
local function title_of(chunk)
  if chunk.title and chunk.title ~= "" then
    return chunk.title
  end
  local note = chunk.note or ""
  local first = note:match("^%s*([^\n]-)%s*\n") or note
  local cut = first:find(". ", 1, true)
  if cut then
    first = first:sub(1, cut)
  end
  return (first:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- "● 1 waiting  <title>  2 files": the title takes all the room the rest leaves.
local function format(chunk, width)
  local count = #files_of(chunk)
  local prefix = ("%s %d %s  "):format(ICONS[chunk.status] or "?", chunk.n, STATUS_WORDS[chunk.status] or chunk.status)
  local suffix = ("  %d file%s"):format(count, count == 1 and "" or "s")
  local room = width - vim.fn.strdisplaywidth(prefix) - vim.fn.strdisplaywidth(suffix)
  return prefix .. fit(title_of(chunk), room) .. suffix
end

-- 35% of the screen, at least 40 and at most 60 columns.
local function panel_width()
  return math.max(MIN_WIDTH, math.min(MAX_WIDTH, math.floor(vim.o.columns * WIDTH_SHARE)))
end

-- Columns of `win` left for text after the sign, fold and number columns.
local function text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  return info.width - info.textoff
end

-- The full help line when it fits, else without the " pi checkpoints —" prefix, cut with … if needed.
local function help_line(width)
  local full = HELP_PREFIX .. HELP_KEYS
  if vim.fn.strdisplaywidth(full) <= width then
    return full
  end
  return fit(HELP_KEYS, width)
end

-- Open checkpoint first, then the rest newest first; recorded ones only while `show_recorded`.
local function visible_chunks()
  local shown = {}
  for _, chunk in ipairs(list) do
    if chunk.status ~= "recorded" or show_recorded then
      shown[#shown + 1] = chunk
    end
  end
  table.sort(shown, function(a, b)
    local a_open, b_open = a.status == "open", b.status == "open"
    if a_open ~= b_open then
      return a_open
    end
    return a.n > b.n
  end)
  return shown
end

local function detail_lines(chunk, width)
  local out = {}
  for _, text in ipairs(wrap(chunk.note or "", math.max(width - 4, 1))) do
    out[#out + 1] = { text = "    " .. text }
  end
  local counts = stats[chunk.n]
  for _, path in ipairs(files_of(chunk)) do
    local info = "…"
    local by_agent = vim.tbl_contains(chunk.agentFiles or {}, path)
    if counts == "failed" then
      info = "?"
    elseif type(counts) == "table" then
      info = by_agent and "+0 −0" or "(you)"
      for _, entry in ipairs(counts) do
        if entry.path == path and by_agent then
          info = ("+%d −%d"):format(entry.added, entry.removed)
        end
      end
    end
    out[#out + 1] = { text = ("    %s  %s"):format(path, info), path = path }
  end
  for _, a in ipairs(chunk.annotations or {}) do
    local note = (a.note or ""):gsub("%s+", " ")
    out[#out + 1] = { text = ("    ✎ L%d-%d %s: %s"):format(a.startLine, a.endLine, a.path, note) }
  end
  return out
end

local function render()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local win = panel_win()
  local width = win and text_width(win) or panel_width()
  local lines = { help_line(width) }
  local waiting_lines = {}
  lines_info = {}
  for _, chunk in ipairs(visible_chunks()) do
    lines[#lines + 1] = fit(format(chunk, width), width)
    lines_info[#lines] = { n = chunk.n }
    if chunk.status == "open" then
      waiting_lines[#lines] = true
    end
    if expanded[chunk.n] then
      for _, detail in ipairs(detail_lines(chunk, width)) do
        lines[#lines + 1] = fit(detail.text, width)
        lines_info[#lines] = { n = chunk.n, path = detail.path }
      end
    end
  end
  if #lines == 1 then
    local off = session.cached and session.cached.mode == "off"
    if session.cached and session.cached.modeNote then
      lines[2] = fit("checkpoints unavailable here", width)
    else
      lines[2] = fit(off and ("checkpoint mode is off — %s to turn it on"):format(keys.label("mode", ":PiCheckpointMode")) or "no checkpoints yet", width)
    end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { line_hl_group = "Comment" })
  for lnum in pairs(waiting_lines) do
    vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, { line_hl_group = "PiCheckpointWaitingRow" })
  end
end

-- Loads the file counts of checkpoint n; a late answer from before a refresh is dropped.
local function fetch_stats(n)
  stats[n] = "loading"
  local mine = generation
  session.request("get_chunk", { n = n }, function(err, result)
    if mine ~= generation then
      return
    end
    if err then
      stats[n] = "failed"
      vim.notify("pi: " .. err, vim.log.levels.ERROR)
    else
      stats[n] = result.stats or {}
    end
    render()
  end)
end

-- Puts the panel cursor on checkpoint `n`'s line, else back on `line` clamped to the buffer.
local function restore_cursor(win, n, line)
  local target
  for lnum = 1, vim.api.nvim_buf_line_count(buf) do
    local info = lines_info[lnum]
    if info and info.n == n and not info.path and not target then
      target = lnum
    end
  end
  target = target or math.min(line, vim.api.nvim_buf_line_count(buf))
  vim.api.nvim_win_set_cursor(win, { math.max(target, 1), 0 })
end

function M.refresh()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  session.request("list_chunks", nil, function(err, chunks)
    if err then
      return vim.notify("pi: " .. err, vim.log.levels.ERROR)
    end
    local win = panel_win()
    local line = win and vim.api.nvim_win_get_cursor(win)[1] or 1
    local anchor = win and lines_info[line] and lines_info[line].n
    local old_status = {}
    for _, c in ipairs(list) do
      old_status[c.n] = c.status
    end
    list = chunks or {}
    local present = {}
    for _, c in ipairs(list) do
      present[c.n] = true
      if old_status[c.n] ~= c.status or stats[c.n] == "loading" then
        stats[c.n] = nil
      end
    end
    for n in pairs(expanded) do
      if not present[n] then
        expanded[n] = nil
      end
    end
    for n in pairs(stats) do
      if not present[n] then
        stats[n] = nil
      end
    end
    generation = generation + 1
    for n in pairs(expanded) do
      if stats[n] == nil then
        fetch_stats(n)
      end
    end
    render()
    if win then
      restore_cursor(win, anchor, line)
    end
  end)
end

local function cursor_info()
  return lines_info[vim.api.nvim_win_get_cursor(0)[1]]
end

-- Shows or hides the per-turn records; says so when there are none.
local function toggle_recorded()
  local any = false
  for _, chunk in ipairs(list) do
    any = any or chunk.status == "recorded"
  end
  if not any and not show_recorded then
    return vim.notify("pi: no recorded turns")
  end
  show_recorded = not show_recorded
  render()
end

-- Every panel key with a word each, plus the global continue and peek keys.
local function help_rows()
  return {
    { "<CR>", "open the checkpoint (on a file line: at that file)" },
    { "za", "more: note, files and annotations" },
    { "a", "show or hide per-turn records" },
    { "r", "refresh" },
    { "q", "close the list" },
    { "g?", "these keys" },
    { keys.label("continue", ":PiContinue"), "continue" },
    { keys.label("peek", ":PiPeek"), "peek at the full note" },
  }
end

-- A float listing the panel keys, styled like the editor; q or <Esc> closes it, and so does leaving it
-- (like LSP hover).
local function show_help()
  local rows = help_rows()
  local key_width = 0
  for _, row in ipairs(rows) do
    key_width = math.max(key_width, vim.fn.strdisplaywidth(row[1]))
  end
  local width = math.max(1, math.min(vim.o.columns - 4, 60))
  local text = {}
  for _, row in ipairs(rows) do
    local key = row[1] .. (" "):rep(key_width - vim.fn.strdisplaywidth(row[1]))
    text[#text + 1] = fit(key .. "  " .. row[2], width)
  end
  local content = 0
  for _, line in ipairs(text) do
    content = math.max(content, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width, math.max(content, 20))
  local help_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, text)
  vim.bo[help_buf].modifiable = false
  vim.bo[help_buf].bufhidden = "wipe"
  local origin = vim.api.nvim_get_current_win()
  local float = vim.api.nvim_open_win(help_buf, true, {
    relative = "editor",
    width = width,
    height = math.max(1, math.min(#text, vim.o.lines - 2)),
    row = math.max(0, math.floor((vim.o.lines - #text) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2) - 1),
    style = "minimal",
    border = "rounded",
    title = " pi checkpoint keys ",
    title_pos = "center",
  })
  local group = vim.api.nvim_create_augroup("PiPanelHelp", { clear = true })
  local function close()
    pcall(vim.api.nvim_del_augroup_by_id, group)
    pcall(vim.api.nvim_win_close, float, true)
    if vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
  end
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, close, { buffer = help_buf, nowait = true, desc = "pi: close keys help" })
  end
  -- Leaving goes where it was going: only the float closes, focus is not moved back.
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    group = group,
    buffer = help_buf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
      vim.schedule(function()
        pcall(vim.api.nvim_win_close, float, true)
      end)
    end,
  })
end

local function toggle_details()
  local info = cursor_info()
  if not info then
    return
  end
  local n = info.n
  expanded[n] = not expanded[n] or nil
  if expanded[n] and stats[n] == nil then
    fetch_stats(n)
  end
  render()
  if not expanded[n] then
    restore_cursor(0, n, vim.api.nvim_win_get_cursor(0)[1])
  end
end

local function ensure_buf()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "pi://checkpoints")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "pi-checkpoints"
  local opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "<CR>", function()
    local info = cursor_info()
    if info then
      diff.open(info.n, info.path)
    end
  end, vim.tbl_extend("force", opts, { desc = "pi: open checkpoint diff" }))
  vim.keymap.set("n", "za", toggle_details, vim.tbl_extend("force", opts, { desc = "pi: toggle checkpoint details" }))
  vim.keymap.set("n", "a", toggle_recorded, vim.tbl_extend("force", opts, { desc = "pi: toggle per-turn records" }))
  vim.keymap.set("n", "r", M.refresh, vim.tbl_extend("force", opts, { desc = "pi: refresh panel" }))
  vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", opts, { desc = "pi: close panel" }))
  vim.keymap.set("n", "g?", show_help, vim.tbl_extend("force", opts, { desc = "pi: panel keys" }))
  return buf
end

-- Not cleared: a second load of this module (specs do that) must not drop the first one's autocmds.
local resize_group = vim.api.nvim_create_augroup("PiPanelResize", { clear = false })
-- A new screen size gives the panel its share of the columns again; any resize re-fits the text.
vim.api.nvim_create_autocmd("VimResized", {
  group = resize_group,
  callback = function()
    local win = panel_win()
    if win then
      vim.api.nvim_win_set_width(win, panel_width())
      render()
    end
  end,
})
vim.api.nvim_create_autocmd("WinResized", {
  group = resize_group,
  callback = function()
    local win = panel_win()
    if win and vim.tbl_contains(vim.v.event.windows or {}, win) then
      render()
    end
  end,
})

function M.open()
  session.ensure(function()
    local win = panel_win()
    if not win then
      list, expanded, stats = {}, {}, {} -- a freshly opened panel starts collapsed
      local previous = vim.api.nvim_get_current_win()
      vim.cmd("topleft vertical " .. panel_width() .. "split")
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, ensure_buf())
      local wo = vim.wo[win]
      wo.winfixwidth = true
      wo.number = false
      wo.relativenumber = false
      wo.signcolumn = "no"
      wo.foldcolumn = "0"
      wo.cursorline = true
      wo.wrap = false
      vim.api.nvim_set_current_win(previous)
    end
    M.refresh()
  end)
end

function M.close()
  local win = panel_win()
  if win and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.api.nvim_win_close(win, true)
  end
end

function M.toggle()
  if M.visible() then
    M.close()
  else
    M.open()
  end
end

return M
