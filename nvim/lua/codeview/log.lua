-- Activity log of the agent in a bottom split (buffer codeview://log).
local M = {}

local LOG_HEIGHT = 12
local PREFIX = {
  prompt = "prompt  ▸ ",
  text = "agent   │ ",
  tool = "tool    ▸ ",
  checkpoint = "ckpt    ✓ ",
}

local buf = nil
local line_count = 0
local last_seq = 0

local function one_line(text)
  return (tostring(text or ""):gsub("\r?\n", " ⏎ "))
end

local function render(item)
  if item.kind == "settled" then
    return { "done    ─ run settled" }
  end
  local text = item.text
  if item.kind == "tool" then
    text = item.tool and (item.target and item.target ~= "" and (item.tool .. " " .. item.target) or item.tool) or item.text
  end
  local line = (PREFIX[item.kind] or PREFIX.text) .. one_line(text)
  if item.kind == "prompt" then
    return { "", line }
  end
  return { line }
end

local function ensure_buf()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "codeview://log")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "codeview-log"
  vim.bo[buf].modifiable = false
  vim.keymap.set("n", "q", M.close, { buffer = buf, desc = "codeview: close log" })
  line_count = 0
  return buf
end

local function log_win()
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
  return log_win() ~= nil
end

local function set_lines(b, first, last, lines)
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, first, last, false, lines)
  vim.bo[b].modifiable = false
end

-- Appends activity items (oldest first); items whose seq was already appended are skipped.
function M.append(items)
  local lines = {}
  for _, item in ipairs(items or {}) do
    if not item.seq or item.seq > last_seq then
      last_seq = item.seq or last_seq
      vim.list_extend(lines, render(item))
    end
  end
  if #lines == 0 then
    return
  end
  local b = ensure_buf()
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == b then
      wins[win] = vim.api.nvim_win_get_cursor(win)[1] >= line_count
    end
  end
  if line_count == 0 then
    set_lines(b, 0, -1, lines)
  else
    set_lines(b, line_count, line_count, lines)
  end
  line_count = line_count + #lines
  for win, follow in pairs(wins) do
    if follow then
      vim.api.nvim_win_set_cursor(win, { line_count, 0 })
    end
  end
end

function M.open()
  if M.visible() then
    return
  end
  local b = ensure_buf()
  vim.cmd(("botright %dsplit"):format(LOG_HEIGHT))
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, b)
  vim.wo[win].winfixheight = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = true
  vim.api.nvim_win_set_cursor(win, { math.max(line_count, 1), 0 })
end

function M.close()
  local win = log_win()
  if win then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

function M.toggle()
  if M.visible() then
    M.close()
  else
    M.open()
  end
end

-- Empties the buffer (a new session starts a new log).
function M.clear()
  last_seq = 0
  line_count = 0
  if buf and vim.api.nvim_buf_is_valid(buf) then
    set_lines(buf, 0, -1, {})
  end
end

return M
