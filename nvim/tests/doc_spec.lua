-- nvim/doc/pi.txt: tags resolve after :helptags and cover every command setup defines.
local M = {}

local spec_path = debug.getinfo(1, "S").source:sub(2)
local plugin_dir = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(spec_path, ":p")))

-- Copies doc/pi.txt to a temp plugin dir and generates its tags; returns the tags file lines.
local function helptags()
  local copy = vim.fn.tempname()
  vim.fn.mkdir(copy .. "/doc", "p")
  assert(vim.uv.fs_copyfile(plugin_dir .. "/doc/pi.txt", copy .. "/doc/pi.txt"), "nvim/doc/pi.txt missing")
  vim.cmd("helptags " .. vim.fn.fnameescape(copy .. "/doc"))
  return copy, vim.fn.readfile(copy .. "/doc/tags")
end

local function has_tag(tags, name)
  for _, line in ipairs(tags) do
    if vim.startswith(line, name .. "\t") then return true end
  end
  return false
end

M["helptags finds pi, :PiContinue and pi-setup, and :help opens them"] = function()
  local copy, tags = helptags()
  for _, name in ipairs({ "pi.txt", "pi", "pi-setup", ":PiContinue", "pi-keys", "pi-highlights", "pi-statusline", "pi-annotations" }) do
    assert(has_tag(tags, name), "no tag " .. name)
  end
  local old = vim.o.runtimepath
  vim.opt.runtimepath:prepend(copy)
  for _, name in ipairs({ "pi", ":PiContinue", "pi-setup" }) do
    local ok, err = pcall(vim.cmd, "help " .. name)
    assert(ok, ("help %s: %s"):format(name, tostring(err)))
    assert(vim.bo.filetype == "help", name)
    vim.cmd("helpclose")
  end
  vim.o.runtimepath = old
  vim.fn.delete(copy, "rf")
end

M["every user command setup defines has a help tag"] = function()
  local pi = require("pi")
  pi.setup()
  local _, tags = helptags()
  local count = 0
  for name in pairs(vim.api.nvim_get_commands({})) do
    if name:match("^Pi") then
      count = count + 1
      assert(has_tag(tags, ":" .. name), "no help tag for :" .. name)
    end
  end
  assert(count >= 10, "expected the Pi commands, got " .. count)
end

M["the modeline is the last line and the highlight groups are documented"] = function()
  local lines = vim.fn.readfile(plugin_dir .. "/doc/pi.txt")
  assert(lines[#lines] == " vim:tw=78:ts=8:ft=help:norl:" or lines[#lines] == "vim:tw=78:ts=8:ft=help:norl:", lines[#lines])
  local text = table.concat(lines, "\n")
  for _, group in ipairs({ "PiBadge", "PiAnnotation", "PiAnnotationSign", "PiCheckpointWaiting", "PiCheckpointWaitingRow", "PiLive", "PiLiveSignAdd", "PiLiveSignChange", "PiLiveSignDelete" }) do
    assert(text:find(group, 1, true), "highlight group not documented: " .. group)
  end
  for i, line in ipairs(lines) do
    assert(vim.fn.strdisplaywidth((line:gsub("%*[^%s*]+%*", ""))) <= 78, ("line %d is wider than 78: %s"):format(i, line))
  end
end

return M
