-- Small floating badge in the top-right corner while the agent works or a checkpoint waits for review.
-- Never focusable and never entered; one timer animates the spinner and runs only while it shows.
local keys = require("pi.keys")
local pi_text = require("pi.text")

local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local FRAME_MS = 100

M.enabled = true
local win, buf, timer = nil, nil, nil
local frame = 1
local spinning = false
local label = nil -- the text after the spinner, or the whole text when not spinning

-- A float belongs to the tabpage it was opened in; the badge counts as shown only on the current one.
local function shown()
  return win ~= nil
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
end

local function close_win()
  if win ~= nil and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  win = nil
end

local function text()
  return spinning and (FRAMES[frame] .. " " .. label) or label
end

-- Row 1 while a tabline takes row 0, so the badge does not cover the tab names.
local function row()
  local tabline = vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)
  return tabline and 1 or 0
end

local function config(width)
  return {
    relative = "editor",
    row = row(),
    col = math.max(vim.o.columns - width - 1, 0),
    width = width,
    height = 1,
    focusable = false,
    style = "minimal",
    zindex = 60,
    noautocmd = true,
  }
end

local function stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

-- Never raises: it can run while Philipp types (textlock, cmdline, prompts); a failed open leaves `win` nil, and the next tick, TabEnter/resize or update retries.
-- A checkpoint tab (marked `t:pi_checkpoint` by the diff view) is the checkpoint itself, so the
-- badge stays out of it and comes back on TabEnter elsewhere.
local function draw()
  local line = text()
  local width = vim.fn.strdisplaywidth(line)
  pcall(function()
    if vim.t.pi_checkpoint ~= nil then
      return close_win()
    end
    if not shown() then
      close_win() -- bufhidden=wipe may wipe the buffer, so recreate it below
    end
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "wipe"
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    if shown() then
      vim.api.nvim_win_set_config(win, config(width))
    else
      win = vim.api.nvim_open_win(buf, false, config(width))
      vim.wo[win].winhighlight = "Normal:PiBadge,NormalFloat:PiBadge"
    end
  end)
end

function M.close()
  stop_timer()
  close_win()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  win, buf, label, spinning = nil, nil, nil, false
end

local function start_timer()
  if timer then
    return
  end
  timer = vim.uv.new_timer()
  timer:start(
    FRAME_MS,
    FRAME_MS,
    vim.schedule_wrap(function()
      if timer and spinning and label ~= nil then
        frame = frame % #FRAMES + 1
        draw()
      end
    end)
  )
end

-- Whether the spinner timer is running (for tests).
function M.timer_active()
  return timer ~= nil
end

function M.window()
  return shown() and win or nil
end

-- Keeps the badge at the right edge and below the tabline after the screen or the tabs changed.
function M.reposition()
  if label ~= nil then
    draw()
  end
end

-- state: { busy, tool?, target?, chunk? } or nil. Shows, updates or hides the badge.
function M.update(state)
  if not M.enabled or type(state) ~= "table" then
    return M.close()
  end
  if state.chunk then
    spinning = false
    label = ("pi · ⏸ %s · %s continue"):format(state.chunk, keys.label("continue", ":PiContinue"))
    stop_timer()
  elseif state.busy then
    spinning = true
    if state.tool then
      local target = pi_text.short_target(state.target)
      if target ~= "" then
        label = ("pi · %s %s"):format(state.tool, target)
      else
        label = ("pi · %s"):format(state.tool)
      end
    else
      label = "pi · working"
    end
    start_timer()
  else
    return M.close()
  end
  draw()
end

return M
