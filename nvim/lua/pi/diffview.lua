-- diffview.nvim integration: optional, every call guarded. diff.lua decides when to use it.
local M = {}

local group = vim.api.nvim_create_augroup("PiDiffview", { clear = true })
local registered = false
local handlers = nil -- { on_left = function(buf, win), on_right = function(buf, win), on_closed = function() } set by open()

function M.available()
  return (pcall(require, "diffview")) and vim.fn.exists(":DiffviewOpen") == 2
end

-- Whether `win` is the left (old revision) diff window of its tab: the diff window that is first
-- from the top, then from the left. Both sides of a past chunk are diffview:// buffers, so the
-- buffer name alone cannot tell them apart.
function M.is_left_window(win)
  local best
  for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) do
    if vim.wo[candidate].diff then
      local pos = vim.api.nvim_win_get_position(candidate)
      if not best or pos[1] < best.row or (pos[1] == best.row and pos[2] < best.col) then
        best = { win = candidate, row = pos[1], col = pos[2] }
      end
    end
  end
  return best ~= nil and best.win == win
end

local function ensure_autocmds()
  if registered then
    return
  end
  registered = true
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewDiffBufWinEnter",
    callback = function()
      local win = vim.api.nvim_get_current_win()
      local buf = vim.api.nvim_get_current_buf()
      if not handlers then
        return
      end
      -- The left side is always a diffview:// revision; the right one is the real file for an open chunk.
      if vim.startswith(vim.api.nvim_buf_get_name(buf), "diffview://") and M.is_left_window(win) then
        handlers.on_left(buf, win)
      elseif vim.wo[win].diff and not M.is_left_window(win) then
        handlers.on_right(buf, win)
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewViewClosed",
    callback = function()
      if handlers then
        handlers.on_closed()
      end
    end,
  })
end

-- Runs :DiffviewOpen; returns the new tabpage, or nil (after leaving nothing open) on any failure.
function M.open(spec, on)
  handlers = on
  ensure_autocmds()
  local args = { spec.range }
  args[#args + 1] = vim.fn.fnameescape("-C" .. spec.root)
  if spec.selected then
    args[#args + 1] = vim.fn.fnameescape("--selected-file=" .. spec.root .. "/" .. spec.selected)
  end
  args[#args + 1] = "--"
  for _, path in ipairs(spec.files) do
    args[#args + 1] = vim.fn.fnameescape(path)
  end
  local before = vim.api.nvim_get_current_tabpage()
  local ok = pcall(vim.cmd, "DiffviewOpen " .. table.concat(args, " "))
  if not ok then
    return nil
  end
  local tab = vim.api.nvim_get_current_tabpage()
  return tab ~= before and tab or nil
end

-- Closes the diffview in `tab` the way diffview does (so its own state is disposed), falling back
-- to :tabclose.
function M.close(tab)
  local current = vim.api.nvim_get_current_tabpage()
  if tab ~= current then
    vim.api.nvim_set_current_tabpage(tab)
  end
  pcall(vim.cmd, "DiffviewClose")
  if vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab))
  end
  if tab ~= current and vim.api.nvim_tabpage_is_valid(current) then
    vim.api.nvim_set_current_tabpage(current)
  end
end

return M
