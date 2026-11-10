-- Chunk list in a left vertical split.
local diff = require("codeview.diff")
local session = require("codeview.session")

local M = {}

local PANEL_WIDTH = 50

local buf = nil
local chunks = {} -- line number -> chunk n

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

local function format(chunk)
  local files = {}
  for _, path in ipairs(chunk.agentFiles or {}) do
    files[#files + 1] = path
  end
  for _, path in ipairs(chunk.humanFiles or {}) do
    if not vim.tbl_contains(files, path) then
      files[#files + 1] = path
    end
  end
  local comments = #(chunk.annotations or {})
  return ("#%d [%s] %s — %s (%d comment%s)"):format(
    chunk.n,
    chunk.status,
    chunk.note,
    #files > 0 and table.concat(files, ", ") or "no files",
    comments,
    comments == 1 and "" or "s"
  )
end

local function render(list)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local lines = {}
  chunks = {}
  for _, chunk in ipairs(list) do
    lines[#lines + 1] = format(chunk)
    chunks[#lines] = chunk.n
  end
  if #lines == 0 then
    lines = { "no chunks yet" }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function M.refresh()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  session.request("list_chunks", nil, function(err, list)
    if err then
      return vim.notify("codeview: " .. err, vim.log.levels.ERROR)
    end
    render(list)
  end)
end

local function ensure_buf()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "codeview://panel")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "codeview"
  local opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "<CR>", function()
    local n = chunks[vim.api.nvim_win_get_cursor(0)[1]]
    if n then
      diff.open(n)
    end
  end, vim.tbl_extend("force", opts, { desc = "codeview: open chunk diff" }))
  vim.keymap.set("n", "r", M.refresh, vim.tbl_extend("force", opts, { desc = "codeview: refresh panel" }))
  vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", opts, { desc = "codeview: close panel" }))
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
