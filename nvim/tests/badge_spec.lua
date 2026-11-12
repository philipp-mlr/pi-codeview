local badge = require("pi.badge")

local M = {}

local function text()
  local win = badge.window()
  assert(win, "badge is not shown")
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, 1, false)[1]
end

local function float_count()
  local n = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      n = n + 1
    end
  end
  return n
end

local function reset()
  badge.enabled = true
  badge.close()
end

M["shows the tool text with a spinner while busy and hides on idle"] = function()
  reset()
  badge.update({ busy = true, tool = "edit", target = "a.ts" })
  assert(vim.fn.strcharpart(text(), 1) == " pi · edit a.ts", text())
  assert(badge.timer_active())
  badge.update({ busy = false })
  assert(badge.window() == nil and float_count() == 0)
  assert(not badge.timer_active())
end

M["busy without a tool says working; long targets are trimmed to 40 characters"] = function()
  reset()
  badge.update({ busy = true })
  assert(vim.fn.strcharpart(text(), 1) == " pi · working", text())
  badge.update({ busy = true, tool = "read", target = string.rep("é", 60) })
  assert(vim.fn.strcharpart(text(), 1) == " pi · read " .. string.rep("é", 40) .. "…", text())
  badge.close()
end

M["the spinner frame changes over time"] = function()
  reset()
  badge.update({ busy = true, tool = "edit", target = "a.ts" })
  local first = vim.fn.strcharpart(text(), 0, 1)
  assert(vim.wait(2000, function() return vim.fn.strcharpart(text(), 0, 1) ~= first end, 20), "frame did not change")
  badge.close()
end

M["an open checkpoint shows the waiting text without a spinner or timer"] = function()
  reset()
  local mapped = require("pi.keys").mapped
  require("pi.keys").mapped = { continue = "<leader>pc" }
  badge.update({ busy = true, tool = "edit", chunk = 3 })
  assert(text() == "pi · ⏸ 3 · <leader>pc continue", text())
  require("pi.keys").mapped = {}
  badge.update({ busy = true, tool = "edit", chunk = 3 })
  assert(text() == "pi · ⏸ 3 · :PiContinue continue", text())
  require("pi.keys").mapped = mapped
  assert(not badge.timer_active())
  badge.update(nil)
  assert(badge.window() == nil)
end

M["badge = false never opens a window"] = function()
  require("pi").setup({ badge = false })
  badge.update({ busy = true, tool = "edit", target = "a.ts" })
  assert(badge.window() == nil and float_count() == 0 and not badge.timer_active())
  require("pi").setup()
  assert(badge.enabled)
  badge.close()
end

M["VimResized keeps it right-aligned"] = function()
  reset()
  require("pi").setup()
  badge.update({ busy = true, tool = "edit", target = "a.ts" })
  local old = vim.o.columns
  vim.o.columns = old - 10
  vim.api.nvim_exec_autocmds("VimResized", {})
  local cfg = vim.api.nvim_win_get_config(badge.window())
  assert(cfg.col == vim.o.columns - cfg.width - 1 and cfg.row == 0, vim.inspect(cfg))
  vim.o.columns = old
  badge.close()
end

M["sits below a visible tabline and moves when it appears or goes"] = function()
  reset()
  require("pi").setup()
  local saved = vim.o.showtabline
  vim.cmd("tabonly")
  vim.o.showtabline = 1
  badge.update({ busy = true, tool = "edit", target = "a.ts" })
  assert(vim.api.nvim_win_get_config(badge.window()).row == 0, "row with one tab and showtabline=1")
  vim.cmd("tabnew")
  assert(vim.api.nvim_win_get_config(badge.window()).row == 1, "row with two tabs and showtabline=1")
  vim.cmd("tabclose")
  assert(vim.api.nvim_win_get_config(badge.window()).row == 0, "row after TabClosed")
  vim.o.showtabline = 2
  badge.update({ busy = true, tool = "edit", target = "a.ts" })
  assert(vim.api.nvim_win_get_config(badge.window()).row == 1, "row with showtabline=2")
  vim.o.showtabline = 0
  vim.cmd("tabnew")
  assert(vim.api.nvim_win_get_config(badge.window()).row == 0, "row with showtabline=0")
  vim.cmd("tabonly")
  vim.o.showtabline = saved
  badge.close()
end

M["is never focusable and never the current window"] = function()
  reset()
  local before = vim.api.nvim_get_current_win()
  badge.update({ busy = true, tool = "edit", target = "a.ts" })
  local win = badge.window()
  local cfg = vim.api.nvim_win_get_config(win)
  assert(cfg.focusable == false and cfg.zindex == 60 and cfg.height == 1 and cfg.relative == "editor", vim.inspect(cfg))
  assert(vim.api.nvim_get_current_win() == before and win ~= before)
  badge.close()
end

M["follows the current tab and leaves no orphan float behind"] = function()
  reset()
  require("pi").setup()
  local tab1 = vim.api.nvim_get_current_tabpage()
  badge.update({ busy = true, tool = "edit", target = "a.ts" })
  assert(badge.window() and float_count() == 1)
  vim.cmd("tabnew")
  local tab2 = vim.api.nvim_get_current_tabpage()
  assert(badge.window() ~= nil, "TabEnter should show the badge on tab 2")
  assert(vim.api.nvim_win_get_tabpage(badge.window()) == tab2)
  badge.update({ busy = true, tool = "edit", target = "a.ts" })
  assert(float_count() == 1, "orphan float: " .. float_count())
  vim.api.nvim_set_current_tabpage(tab1)
  assert(badge.window() ~= nil and vim.api.nvim_win_get_tabpage(badge.window()) == tab1)
  assert(float_count() == 1)
  vim.cmd("tabnew")
  assert(badge.window() ~= nil)
  vim.cmd("tabclose")
  badge.update({ busy = true, tool = "edit", target = "a.ts" })
  assert(badge.window() ~= nil and float_count() == 1)
  vim.cmd("tabonly")
  badge.close()
end

M["a failing open is swallowed and the next update shows the badge"] = function()
  reset()
  local real = vim.api.nvim_open_win
  local failed = false
  vim.api.nvim_open_win = function(...)
    if not failed then
      failed = true
      error("E565: not allowed")
    end
    return real(...)
  end
  local ok, err = pcall(badge.update, { busy = true, tool = "edit", target = "a.ts" })
  vim.api.nvim_open_win = real
  assert(ok, tostring(err))
  assert(failed and badge.window() == nil)
  badge.update({ busy = true, tool = "edit", target = "a.ts" })
  assert(badge.window() ~= nil)
  badge.close()
end

M["a tick retries after a failed first open, without an update"] = function()
  reset()
  local real = vim.api.nvim_open_win
  local failed = false
  vim.api.nvim_open_win = function(...)
    if not failed then
      failed = true
      error("E11: invalid in cmdline window")
    end
    return real(...)
  end
  badge.update({ busy = true, tool = "edit", target = "a.ts" })
  assert(failed and badge.window() == nil)
  vim.wait(500, function() return badge.window() ~= nil end, 20)
  vim.api.nvim_open_win = real
  assert(badge.window() ~= nil, "the spinner tick should retry the open")
  badge.close()
end

return M
