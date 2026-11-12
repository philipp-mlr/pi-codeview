-- Checkpoint list in a left vertical split.
local diff = require("pi.diff")
local keys = require("pi.keys")
local session = require("pi.session")

local M = {}

local PANEL_WIDTH = 60
local ICONS = { open = "●", reviewed = "✓", discarded = "✗", recorded = "·" }
local STATUS_WORDS = { open = "waiting", reviewed = "reviewed", discarded = "discarded", recorded = "recorded" }

local ns = vim.api.nvim_create_namespace("pi_panel")
local buf = nil
local list = {} -- chunks from the last refresh
local show_recorded = false
local expanded = {} -- chunk n -> true while its details are shown (reset by refresh)
local stats = {} -- chunk n -> { path, added, removed }[] or "loading" (reset by refresh)
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

-- `text` cut to at most `width` display cells, ending in "…" when cut.
local function fit(text, width)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local chars = vim.fn.strchars(text)
  while chars > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, chars)) > width - 1 do
    chars = chars - 1
  end
  return vim.fn.strcharpart(text, 0, chars) .. "…"
end

local function format(chunk, width)
  local count = #files_of(chunk)
  local prefix = ("%s %-2d %-9s "):format(ICONS[chunk.status] or "?", chunk.n, STATUS_WORDS[chunk.status] or chunk.status)
  local suffix = ("   %d file%s"):format(count, count == 1 and "" or "s")
  local room = width - vim.fn.strdisplaywidth(prefix) - vim.fn.strdisplaywidth(suffix)
  return prefix .. fit(title_of(chunk), room) .. suffix
end

-- `text` broken at spaces into lines of at most `width` cells; longer words are cut.
local function wrap(text, width)
  local out, current = {}, ""
  for word in text:gmatch("%S+") do
    while vim.fn.strdisplaywidth(word) > width do
      if current ~= "" then
        out[#out + 1] = current
        current = ""
      end
      out[#out + 1] = vim.fn.strcharpart(word, 0, width)
      word = vim.fn.strcharpart(word, width)
    end
    if current == "" then
      current = word
    elseif vim.fn.strdisplaywidth(current) + 1 + vim.fn.strdisplaywidth(word) <= width then
      current = current .. " " .. word
    else
      out[#out + 1] = current
      current = word
    end
  end
  if current ~= "" then
    out[#out + 1] = current
  end
  return out
end

local function help_line()
  local go = keys.label("continue", ":PiContinue")
  return ("pi checkpoints — <CR> open · za details · a all · %s continue"):format(go)
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
  for _, text in ipairs(wrap(chunk.note or "", width - 4)) do
    out[#out + 1] = { text = "    " .. text }
  end
  local counts = stats[chunk.n]
  for _, path in ipairs(files_of(chunk)) do
    local info = "…"
    if type(counts) == "table" then
      info = "+0 −0"
      for _, entry in ipairs(counts) do
        if entry.path == path then
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
  local width = win and vim.api.nvim_win_get_width(win) or PANEL_WIDTH
  local lines = { help_line() }
  local waiting_lines = {}
  lines_info = {}
  for _, chunk in ipairs(visible_chunks()) do
    lines[#lines + 1] = format(chunk, width)
    lines_info[#lines] = { n = chunk.n }
    if chunk.status == "open" then
      waiting_lines[#lines] = true
    end
    if expanded[chunk.n] then
      for _, detail in ipairs(detail_lines(chunk, width)) do
        lines[#lines + 1] = detail.text
        lines_info[#lines] = { n = chunk.n, path = detail.path }
      end
    end
  end
  if #lines == 1 then
    lines[2] = "no checkpoints yet"
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { line_hl_group = "Comment" })
  for lnum in pairs(waiting_lines) do
    vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, { line_hl_group = "PiCheckpointWaiting" })
  end
end

function M.refresh()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  session.request("list_chunks", nil, function(err, chunks)
    if err then
      return vim.notify("pi: " .. err, vim.log.levels.ERROR)
    end
    list = chunks or {}
    expanded, stats = {}, {}
    generation = generation + 1
    render()
  end)
end

local function cursor_info()
  return lines_info[vim.api.nvim_win_get_cursor(0)[1]]
end

local function toggle_details()
  local info = cursor_info()
  if not info then
    return
  end
  local n = info.n
  expanded[n] = not expanded[n] or nil
  if expanded[n] and stats[n] == nil then
    stats[n] = "loading"
    local mine = generation
    session.request("get_chunk", { n = n }, function(err, result)
      if mine ~= generation then
        return
      end
      if err then
        stats[n] = {}
        return vim.notify("pi: " .. err, vim.log.levels.ERROR)
      end
      stats[n] = result.stats or {}
      render()
    end)
  end
  render()
end

local function ensure_buf()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "pi://panel")
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
  vim.keymap.set("n", "a", function()
    show_recorded = not show_recorded
    render()
  end, vim.tbl_extend("force", opts, { desc = "pi: toggle per-turn records" }))
  vim.keymap.set("n", "r", M.refresh, vim.tbl_extend("force", opts, { desc = "pi: refresh panel" }))
  vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", opts, { desc = "pi: close panel" }))
  return buf
end

function M.open()
  session.ensure(function()
    local win = panel_win()
    if not win then
      local previous = vim.api.nvim_get_current_win()
      vim.cmd("topleft vertical " .. PANEL_WIDTH .. "split")
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, ensure_buf())
      vim.wo[win].winfixwidth = true
      vim.wo[win].number = false
      vim.wo[win].relativenumber = false
      vim.wo[win].wrap = false
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
