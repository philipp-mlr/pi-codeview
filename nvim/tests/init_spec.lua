local pi = require("pi")
local annotations = require("pi.annotations")

local M = {}

local KEYS = { "<leader>pa", "<leader>ps", "<leader>pn", "<leader>px", "<leader>pr", "<leader>pv", "<leader>pm" }

local function reset_maps()
  for _, lhs in ipairs(KEYS) do
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

M["default keys live under <leader>p with pi: descriptions"] = function()
  reset_maps()
  assert(vim.deep_equal(pi.default_keys, {
    ask = "<leader>pa",
    session = "<leader>ps",
    annotate = "<leader>pn",
    remove = "<leader>px",
    send = "<leader>pr",
    chunks = "<leader>pv",
    checkpoints = "<leader>pm",
  }), vim.inspect(pi.default_keys))
  local notes = capture_notify(function() pi.setup() end)
  local want = {
    { "n", "<leader>pa", "pi: ask with file context" },
    { "x", "<leader>pa", "pi: ask with selection context" },
    { "n", "<leader>ps", "pi: choose pi session" },
    { "n", "<leader>pn", "pi: annotate line" },
    { "x", "<leader>pn", "pi: annotate selection" },
    { "n", "<leader>px", "pi: remove annotation" },
    { "n", "<leader>pr", "pi: send annotations" },
    { "n", "<leader>pv", "pi: toggle chunk panel" },
    { "n", "<leader>pm", "pi: toggle checkpoint mode" },
  }
  for _, w in ipairs(want) do
    local desc = vim.fn.maparg(w[2], w[1], false, true).desc
    assert(desc == w[3], ("%s (%s): %s"):format(w[2], w[1], tostring(desc)))
  end
  for _, name in ipairs({ "PiAsk", "PiSession", "PiAnnotate", "PiAnnotationRemove", "PiSendAnnotations", "PiChunks", "PiCheckpoints" }) do
    assert(vim.fn.exists(":" .. name) == 2, "missing command " .. name)
  end
  assert(#notes == 0, vim.inspect(notes))
  reset_maps()
end

M["<leader>pm toggles checkpoint mode and :PiCheckpoints completes on/off"] = function()
  reset_maps()
  capture_notify(function() pi.setup() end)
  assert(vim.fn.maparg("<leader>pm", "n", false, true).desc == "pi: toggle checkpoint mode", "mode key not mapped")
  local complete = vim.fn.getcompletion("PiCheckpoints ", "cmdline")
  assert(vim.deep_equal(complete, { "on", "off" }), vim.inspect(complete))
  reset_maps()
end

M["setup keeps existing mappings for default keys and lists them in one INFO notify"] = function()
  reset_maps()
  vim.keymap.set("n", "<leader>pn", "<cmd>echo 'mine'<CR>", { desc = "mine" })
  vim.keymap.set("x", "<leader>pr", "<Nop>")
  local notes = capture_notify(function() pi.setup() end)
  assert(vim.fn.maparg("<leader>pn", "n", false, true).desc == "mine", "default key replaced a user mapping")
  assert(vim.fn.maparg("<leader>pn", "x", false, true).desc == "pi: annotate selection", "x mode not mapped")
  assert(vim.fn.maparg("<leader>pr", "n", false, true).desc == "pi: send annotations", "n mode send not mapped")
  assert(#notes == 1 and notes[1].level == vim.log.levels.INFO, vim.inspect(notes))
  assert(notes[1].msg:find("<leader>pn (n)", 1, true), notes[1].msg)
  -- setup() twice does not count its own mappings as foreign.
  assert(#capture_notify(function() pi.setup() end) == 1)
  -- An explicit key overrides a user mapping.
  capture_notify(function() pi.setup({ keys = { annotate = "<leader>pn" } }) end)
  assert(vim.fn.maparg("<leader>pn", "n", false, true).desc == "pi: annotate line")
  reset_maps()
end

M["prompt_context sends the cursor line, the exact selection and the unsaved marker"] = function()
  local dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  vim.fn.writefile({ "local a = 1", "local bb = 22", "return a" }, dir .. "/x.lua")
  local buf = vim.fn.bufadd(dir .. "/x.lua")
  vim.fn.bufload(buf)
  vim.api.nvim_set_current_buf(buf)

  -- Normal mode: file and cursor line, no text, saved buffer.
  local ctx = pi.prompt_context(buf, dir, { line1 = 2, line2 = 2 })
  assert(vim.deep_equal(ctx, { path = "x.lua", startLine = 2, endLine = 2 }), vim.inspect(ctx))

  -- Characterwise selection inside one line quotes only the selected part.
  vim.api.nvim_win_set_cursor(0, { 2, 6 })
  vim.cmd("normal! v4l\27")
  ctx = pi.prompt_context(buf, dir, { line1 = 2, line2 = 2, visual = true })
  assert(ctx.text == "bb = ", vim.inspect(ctx))

  -- Linewise selection over two lines, taken from the buffer including an unsaved edit.
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "local a = 100" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal! Vj\27")
  ctx = pi.prompt_context(buf, dir, { line1 = 1, line2 = 2, visual = true })
  assert(ctx.text == "local a = 100\nlocal bb = 22", vim.inspect(ctx))
  assert(ctx.unsaved == true and ctx.startLine == 1 and ctx.endLine == 2, vim.inspect(ctx))

  -- A buffer outside the root gives no context.
  assert(pi.prompt_context(buf, dir .. "/elsewhere", { line1 = 1, line2 = 1 }) == nil)
  vim.api.nvim_buf_delete(buf, { force = true })
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
  capture_notify(function() pi.annotate(buf, 2, 2, "keep me") end)
  vim.env.XDG_RUNTIME_DIR = old_env
  local list = annotations.list(dir)
  assert(#list == 1 and list[1].note == "keep me" and list[1].startLine == 2, vim.inspect(list))
  annotations.clear()
end

-- A git repo with a.txt and b.txt committed and then changed on disk; returns root and the commit.
local function changed_repo()
  local root = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  root = vim.uv.fs_realpath(root)
  local function git(...)
    local r = vim.system({ "git", "-C", root, ... }, { text = true }):wait()
    assert(r.code == 0, r.stderr)
    return vim.trim(r.stdout)
  end
  git("init", "-q")
  git("config", "user.email", "t@t")
  git("config", "user.name", "t")
  vim.fn.writefile({ "one" }, root .. "/a.txt")
  vim.fn.writefile({ "bee" }, root .. "/b.txt")
  git("add", ".")
  git("commit", "-q", "-m", "init")
  local base = git("rev-parse", "HEAD")
  vim.fn.writefile({ "one", "two" }, root .. "/a.txt")
  vim.fn.writefile({ "bee", "sting" }, root .. "/b.txt")
  return root, base
end

-- Pretends to be attached to a session whose `status` returns status.
local function fake_attach(root, status)
  local session = require("pi.session")
  session.conn = { closed = false, request = function(_, type, _, cb) if type == "status" and cb then cb(nil, status) end end }
  session.root = root
  return function()
    session.conn, session.root, session.cached = nil, nil, nil
    require("pi.live").clear()
  end
end

local live_ns = vim.api.nvim_create_namespace("pi_live")

local function live_marks(buf)
  return #vim.api.nvim_buf_get_extmarks(buf, live_ns, 0, -1, {})
end

M["a buffer opened while attached gets marks against markBase without a tool event"] = function()
  reset_maps()
  capture_notify(function() pi.setup() end)
  local root, base = changed_repo()
  -- baseline points elsewhere: the marks must follow markBase.
  local detach = fake_attach(root, { markBase = base, baseline = "0000000000000000000000000000000000000000" })
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/a.txt"))
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.wait(3000, function() return live_marks(buf) == 1 end, 10), "no marks: " .. live_marks(buf))
  detach()
  vim.api.nvim_buf_delete(buf, { force = true })
  reset_maps()
end

M["marks fall back to baseline when the extension sends no markBase"] = function()
  local root, base = changed_repo()
  local detach = fake_attach(root, { baseline = base })
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/b.txt"))
  local buf = vim.api.nvim_get_current_buf()
  require("pi.session").refresh_live()
  assert(vim.wait(3000, function() return live_marks(buf) == 1 end, 10), "no marks: " .. live_marks(buf))
  detach()
  vim.api.nvim_buf_delete(buf, { force = true })
end

return M
