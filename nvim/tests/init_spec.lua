local codeview = require("codeview")
local annotations = require("codeview.annotations")

local M = {}

local function reset_maps()
  for _, lhs in ipairs({ "<leader>cv", "<leader>cp", "<leader>ca", "<leader>cc", "<leader>cx", "<leader>cs" }) do
    pcall(vim.keymap.del, "n", lhs)
    pcall(vim.keymap.del, "x", lhs)
  end
end

local function capture_notify(fn)
  local notes = {}
  local original = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = original
  assert(ok, err)
  return notes
end

M["prompt defaults to <leader>cp, clear of the LSP code action key"] = function()
  reset_maps()
  assert(codeview.default_keys.prompt == "<leader>cp", codeview.default_keys.prompt)
  local notes = capture_notify(function() codeview.setup() end)
  assert(vim.fn.maparg("<leader>cp", "n") ~= "", "prompt key not mapped")
  assert(vim.fn.maparg("<leader>ca", "n") == "", "<leader>ca mapped")
  assert(#notes == 0, vim.inspect(notes))
  reset_maps()
end

M["setup keeps existing mappings for default keys and lists them in one INFO notify"] = function()
  reset_maps()
  vim.keymap.set("n", "<leader>cc", "<cmd>echo 'mine'<CR>", { desc = "mine" })
  vim.keymap.set("x", "<leader>cs", "<Nop>")
  local notes = capture_notify(function() codeview.setup() end)
  assert(vim.fn.maparg("<leader>cc", "n", false, true).desc == "mine", "default key replaced a user mapping")
  assert(vim.fn.maparg("<leader>cc", "x", false, true).desc == "codeview: annotate selection", "x mode not mapped")
  assert(vim.fn.maparg("<leader>cs", "n", false, true).desc == "codeview: send", "n mode send not mapped")
  assert(#notes == 1 and notes[1].level == vim.log.levels.INFO, vim.inspect(notes))
  assert(notes[1].msg:find("<leader>cc (n)", 1, true), notes[1].msg)
  -- setup() twice does not count its own mappings as foreign.
  assert(#capture_notify(function() codeview.setup() end) == 1)
  -- An explicit key overrides a user mapping.
  capture_notify(function() codeview.setup({ keys = { annotate = "<leader>cc" } }) end)
  assert(vim.fn.maparg("<leader>cc", "n", false, true).desc == "codeview: annotate line")
  reset_maps()
end

M["annotate keeps the note when no pi session is reachable"] = function()
  annotations.clear()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  assert(vim.system({ "git", "init", "-q" }, { cwd = dir }):wait().code == 0)
  vim.fn.writefile({ "one", "two" }, dir .. "/a.txt")
  local old_env = vim.env.XDG_RUNTIME_DIR
  vim.env.XDG_RUNTIME_DIR = dir .. "/run"
  local buf = vim.fn.bufadd(dir .. "/a.txt")
  vim.fn.bufload(buf)
  vim.api.nvim_set_current_buf(buf)
  capture_notify(function() codeview.annotate(buf, 2, 2, "keep me") end)
  vim.env.XDG_RUNTIME_DIR = old_env
  local list = annotations.list(dir)
  assert(#list == 1 and list[1].note == "keep me" and list[1].startLine == 2, vim.inspect(list))
  annotations.clear()
end

return M
