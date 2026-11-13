local pi = require("pi")
local annotations = require("pi.annotations")

local M = {}

local KEYS = { "<leader>pa", "<leader>ps", "<leader>pn", "<leader>px", "<leader>pe", "<leader>pi", "<leader>pv", "<leader>pm", "<leader>pc", "<leader>pk", "<leader>pf" }

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
  local ok, err = pcall(fn, notes) -- fn may wait on the notices collected so far
  vim.notify = original
  assert(ok, err)
  return notes
end

-- Runs fn with the screen `columns` wide; every notice must then fit v:echospace.
local function at_columns(columns, fn)
  local saved = vim.o.columns
  vim.o.columns = columns
  local ok, err = pcall(fn)
  vim.o.columns = saved
  assert(ok, err)
end

local function assert_fits(notes)
  for _, note in ipairs(notes) do
    assert(vim.fn.strdisplaywidth(note.msg) <= vim.v.echospace, ("%q is wider than %d"):format(note.msg, vim.v.echospace))
  end
end

M["default keys live under <leader>p with pi: descriptions"] = function()
  reset_maps()
  assert(vim.deep_equal(pi.default_keys, {
    ask = "<leader>pa",
    continue = "<leader>pc",
    stop = "<leader>ps",
    annotate = "<leader>pn",
    edit = "<leader>pe",
    remove = "<leader>px",
    checkpoints = "<leader>pv",
    mode = "<leader>pm",
    session = "<leader>pi",
    peek = "<leader>pk",
    follow = "<leader>pf",
  }), vim.inspect(pi.default_keys))
  local notes = capture_notify(function() pi.setup() end)
  local want = {
    { "n", "<leader>pa", "pi: ask with file context" },
    { "x", "<leader>pa", "pi: ask with selection context" },
    { "n", "<leader>pc", "pi: continue — review the waiting checkpoint or send annotations" },
    { "n", "<leader>ps", "pi: stop the agent's current run" },
    { "n", "<leader>pn", "pi: annotate line" },
    { "x", "<leader>pn", "pi: annotate selection" },
    { "n", "<leader>pe", "pi: edit annotation" },
    { "n", "<leader>px", "pi: remove annotation" },
    { "n", "<leader>pv", "pi: toggle checkpoint list" },
    { "n", "<leader>pm", "pi: toggle checkpoint mode" },
    { "n", "<leader>pi", "pi: choose pi session" },
    { "n", "<leader>pk", "pi: peek at the full note or annotation" },
    { "n", "<leader>pf", "pi: follow the agent's worktree" },
  }
  for _, w in ipairs(want) do
    local desc = vim.fn.maparg(w[2], w[1], false, true).desc
    assert(desc == w[3], ("%s (%s): %s"):format(w[2], w[1], tostring(desc)))
  end
  for _, name in ipairs({ "PiAsk", "PiContinue", "PiStop", "PiAnnotate", "PiAnnotationEdit", "PiAnnotationRemove", "PiCheckpoints", "PiCheckpointMode", "PiSession", "PiPeek", "PiFollow" }) do
    assert(vim.fn.exists(":" .. name) == 2, "missing command " .. name)
  end
  for _, name in ipairs({ "PiSendAnnotations", "PiCancel", "PiChunks" }) do
    assert(vim.fn.exists(":" .. name) == 0, "removed command still exists: " .. name)
  end
  assert(#notes == 0, vim.inspect(notes))
  reset_maps()
end

M["<leader>pm toggles checkpoint mode and :PiCheckpointMode completes on/off"] = function()
  reset_maps()
  capture_notify(function() pi.setup() end)
  assert(vim.fn.maparg("<leader>pm", "n", false, true).desc == "pi: toggle checkpoint mode", "mode key not mapped")
  local complete = vim.fn.getcompletion("PiCheckpointMode ", "cmdline")
  assert(vim.deep_equal(complete, { "on", "off" }), vim.inspect(complete))
  reset_maps()
end

M["setup keeps existing mappings for default keys and lists them in one INFO notify"] = function()
  reset_maps()
  vim.keymap.set("n", "<leader>pn", "<cmd>echo 'mine'<CR>", { desc = "mine" })
  vim.keymap.set("x", "<leader>pc", "<Nop>")
  local notes = capture_notify(function() pi.setup() end)
  assert(vim.fn.maparg("<leader>pn", "n", false, true).desc == "mine", "default key replaced a user mapping")
  assert(vim.fn.maparg("<leader>pn", "x", false, true).desc == "pi: annotate selection", "x mode not mapped")
  assert(vim.fn.maparg("<leader>pc", "n", false, true).desc ~= nil and vim.fn.maparg("<leader>pc", "n", false, true).desc:find("pi: continue", 1, true), "n mode continue not mapped")
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

M["annotate refuses buffers that are not real files"] = function()
  annotations.clear()
  local dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  vim.fn.writefile({ "one" }, dir .. "/a.txt")
  local session = require("pi.session")
  local old_root = session.root
  session.root = dir
  local notice = "pi: annotate your file — in a diff, the right side"
  local function refused(buf, expected)
    local notes = capture_notify(function() pi.annotate(buf, 1, 1, "x") end)
    assert(#notes == 1 and notes[1].msg == (expected or notice), vim.inspect(notes))
    assert(#annotations.list(dir) == 0, "annotation was added")
  end
  local scratch = vim.api.nvim_create_buf(false, true)
  refused(scratch)
  vim.api.nvim_buf_set_name(scratch, "pi://1/a.txt@from")
  refused(scratch)
  local dv = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(dv, "diffview://x/a.txt")
  refused(dv, "pi: past checkpoints are read-only — annotate the file itself")
  local outside = vim.fn.tempname()
  vim.fn.writefile({ "o" }, outside)
  local out = vim.fn.bufadd(outside)
  vim.fn.bufload(out)
  local old_runtime = vim.env.XDG_RUNTIME_DIR
  vim.env.XDG_RUNTIME_DIR = dir .. "/run"
  local notes_out = capture_notify(function() pi.annotate(out, 1, 1, "elsewhere") end)
  vim.env.XDG_RUNTIME_DIR = old_runtime
  assert(not vim.tbl_contains(vim.tbl_map(function(n) return n.msg end, notes_out), notice), vim.inspect(notes_out))
  assert(#vim.api.nvim_buf_call(out, function() return annotations.at_cursor() end) == 1, "other-worktree annotation missing")
  annotations.clear()
  local old_env = vim.env.XDG_RUNTIME_DIR
  vim.env.XDG_RUNTIME_DIR = dir .. "/run"
  local buf = vim.fn.bufadd(dir .. "/a.txt")
  vim.fn.bufload(buf)
  local notes = capture_notify(function() pi.annotate(buf, 1, 1, "ok") end)
  vim.env.XDG_RUNTIME_DIR = old_env
  assert(not vim.tbl_contains(vim.tbl_map(function(n) return n.msg end, notes), notice))
  assert(#annotations.list(dir) == 1, "real file annotation missing")
  -- A named file that is not on disk yet is still annotatable.
  local fresh = vim.fn.bufadd(dir .. "/new.txt")
  vim.fn.bufload(fresh)
  vim.env.XDG_RUNTIME_DIR = dir .. "/run"
  notes = capture_notify(function() pi.annotate(fresh, 1, 1, "new") end)
  vim.env.XDG_RUNTIME_DIR = old_env
  assert(not vim.tbl_contains(vim.tbl_map(function(n) return n.msg end, notes), notice), vim.inspect(notes))
  local placed = vim.api.nvim_buf_call(fresh, function() return annotations.at_cursor() end)
  assert(#placed == 1, "unsaved new file annotation missing")
  session.root = old_root
  annotations.clear()
end

M["annotate command refuses before asking for the note, with the right message"] = function()
  annotations.clear()
  local read_only = "pi: past checkpoints are read-only — annotate the file itself"
  local own = "pi: annotate your file — in a diff, the right side"
  local function name_buf(name)
    local b = vim.api.nvim_create_buf(false, true)
    if name then vim.api.nvim_buf_set_name(b, name) end
    return b
  end
  local cases = {
    { name_buf(), own },
    { name_buf("pi://2/c.txt@from"), own },
    { name_buf("pi://2/c.txt@to"), read_only },
    { name_buf("diffview://y/c.txt"), read_only },
  }
  local editor = require("pi.editor")
  local original_open = editor.open
  local asked = 0
  editor.open = function() asked = asked + 1 end
  for _, case in ipairs(cases) do
    vim.api.nvim_set_current_buf(case[1])
    local notes = capture_notify(function() vim.cmd("PiAnnotate") end)
    assert(#notes == 1 and notes[1].msg == case[2], vim.inspect(notes))
  end
  assert(asked == 0, "asked for a note before refusing")
  -- A real file is asked.
  local file = vim.fn.tempname()
  vim.fn.writefile({ "x" }, file)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  vim.cmd("PiAnnotate")
  editor.open = original_open
  assert(asked == 1, "real file was not asked")
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

local function set_diagnostics(buf, list)
  local ns = vim.api.nvim_create_namespace("pi_test_diagnostics")
  local E, W, I, H = vim.diagnostic.severity.ERROR, vim.diagnostic.severity.WARN, vim.diagnostic.severity.INFO, vim.diagnostic.severity.HINT
  local items = {}
  for _, d in ipairs(list) do
    local sev = ({ E = E, W = W, I = I, H = H })[d[2]]
    items[#items + 1] = { lnum = d[1] - 1, col = 0, severity = sev, message = d[3], source = d[4] }
  end
  vim.diagnostic.set(ns, buf, items)
  return ns
end

local function scratch_buf(count)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, count do
    lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

M["diagnostics keeps ERROR and WARN only, errors first then by line, with source"] = function()
  local buf = scratch_buf(10)
  set_diagnostics(buf, {
    { 5, "W", "warn five" },
    { 3, "I", "info three" },
    { 7, "E", "error seven", "lsp" },
    { 2, "H", "hint two" },
    { 1, "W", "warn one" },
    { 4, "E", "error four" },
  })
  local got = pi.diagnostics(buf)
  assert(vim.deep_equal(got, {
    { line = 4, severity = "error", message = "error four" },
    { line = 7, severity = "error", message = "error seven", source = "lsp" },
    { line = 1, severity = "warning", message = "warn one" },
    { line = 5, severity = "warning", message = "warn five" },
  }), vim.inspect(got))
  assert(vim.deep_equal(pi.diagnostics(scratch_buf(3)), {}))
  vim.api.nvim_buf_delete(buf, { force = true })
end

M["diagnostics selection keeps the diagnostics inside the lines"] = function()
  local buf = scratch_buf(10)
  set_diagnostics(buf, { { 1, "E", "a" }, { 3, "E", "b" }, { 4, "W", "c" }, { 6, "E", "d" } })
  local got = pi.diagnostics(buf, 3, 5)
  assert(#got == 2 and got[1].message == "b" and got[2].message == "c", vim.inspect(got))
  got = pi.diagnostics(buf, 6)
  assert(#got == 1 and got[1].message == "d", vim.inspect(got))
  vim.api.nvim_buf_delete(buf, { force = true })
end

M["diagnostics takes at most 20, errors first"] = function()
  local buf = scratch_buf(40)
  local list = {}
  for i = 1, 25 do
    list[#list + 1] = { i, "W", "warn " .. i }
  end
  for i = 26, 30 do
    list[#list + 1] = { i, "E", "error " .. i }
  end
  set_diagnostics(buf, list)
  local got = pi.diagnostics(buf)
  assert(#got == 20, #got)
  assert(got[5].severity == "error" and got[6].severity == "warning" and got[6].line == 1, vim.inspect(got))
  vim.api.nvim_buf_delete(buf, { force = true })
end

M["diagnostics collapses whitespace and cuts at 200 characters with an ellipsis"] = function()
  local buf = scratch_buf(3)
  set_diagnostics(buf, {
    { 1, "E", "first\n  second\t\tthird" },
    { 2, "E", string.rep("x", 200) },
    { 3, "E", string.rep("x", 201) },
  })
  local got = pi.diagnostics(buf)
  assert(got[1].message == "first second third", got[1].message)
  assert(got[2].message == string.rep("x", 200), "200 chars stay whole")
  assert(got[3].message == string.rep("x", 200) .. "…", got[3].message)
  vim.api.nvim_buf_delete(buf, { force = true })
end

M["diagnostics cut multibyte messages by characters"] = function()
  local buf = scratch_buf(1)
  set_diagnostics(buf, { { 1, "E", string.rep("ä", 250) } })
  local msg = pi.diagnostics(buf)[1].message
  assert(vim.fn.strchars(msg) == 201 and msg == string.rep("ä", 200) .. "…", vim.fn.strchars(msg))
  assert(vim.fn.strchars(msg) == #vim.fn.split(msg, "\\zs"), "valid utf-8")
  vim.api.nvim_buf_delete(buf, { force = true })
end

M["prompt_context attaches diagnostics: whole file in normal mode, the selection in visual mode"] = function()
  local dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  vim.fn.writefile({ "a", "b", "c", "d" }, dir .. "/x.lua")
  local buf = vim.fn.bufadd(dir .. "/x.lua")
  vim.fn.bufload(buf)
  vim.api.nvim_set_current_buf(buf)
  set_diagnostics(buf, { { 1, "E", "one" }, { 3, "W", "three" } })

  local ctx = pi.prompt_context(buf, dir, { line1 = 2, line2 = 2 })
  assert(#ctx.diagnostics == 2, vim.inspect(ctx))
  assert(ctx.diagnostics[1].line == 1 and ctx.diagnostics[2].line == 3, vim.inspect(ctx))

  vim.cmd("normal! ggjVj\27")
  ctx = pi.prompt_context(buf, dir, { line1 = 2, line2 = 3, visual = true })
  assert(#ctx.diagnostics == 1 and ctx.diagnostics[1].line == 3, vim.inspect(ctx))

  vim.cmd("normal! ggVj\27")
  set_diagnostics(buf, { { 4, "E", "four" } })
  ctx = pi.prompt_context(buf, dir, { line1 = 1, line2 = 2, visual = true })
  assert(ctx.diagnostics == nil, vim.inspect(ctx))
  vim.api.nvim_buf_delete(buf, { force = true })
end

M["highlight links are restored after a colorscheme change"] = function()
  pi.setup({})
  vim.cmd("hi clear")
  vim.cmd("doautocmd ColorScheme")
  assert(vim.api.nvim_get_hl(0, { name = "PiLive" }).link == "DiffChange")
  assert(vim.api.nvim_get_hl(0, { name = "PiLiveSignAdd" }).link == "Added")
  assert(vim.api.nvim_get_hl(0, { name = "PiLiveSignChange" }).link == "Changed")
  assert(vim.api.nvim_get_hl(0, { name = "PiLiveSignDelete" }).link == "Removed")
  assert(vim.api.nvim_get_hl(0, { name = "PiAnnotationSign" }).link == "Special")
  assert(vim.api.nvim_get_hl(0, { name = "PiCheckpointWaiting" }).link == "DiagnosticWarn")
end

M["PiAnnotation is italic in Comment's colour, recomputed on ColorScheme, linked without a Comment fg"] = function()
  pi.setup({})
  vim.api.nvim_set_hl(0, "Comment", { fg = 0x123456 })
  vim.cmd("hi clear PiAnnotation")
  vim.cmd("doautocmd ColorScheme")
  local hl = vim.api.nvim_get_hl(0, { name = "PiAnnotation" })
  assert(hl.italic and hl.fg == 0x123456, vim.inspect(hl))
  vim.api.nvim_set_hl(0, "Comment", { fg = 0x654321 })
  vim.cmd("hi clear PiAnnotation")
  vim.cmd("doautocmd ColorScheme")
  assert(vim.api.nvim_get_hl(0, { name = "PiAnnotation" }).fg == 0x654321)
  vim.api.nvim_set_hl(0, "Comment", { italic = true })
  vim.cmd("hi clear PiAnnotation")
  vim.cmd("doautocmd ColorScheme")
  assert(vim.api.nvim_get_hl(0, { name = "PiAnnotation" }).link == "Comment")
  vim.api.nvim_set_hl(0, "PiAnnotation", { fg = 0xabcdef })
  vim.cmd("doautocmd ColorScheme")
  assert(vim.api.nvim_get_hl(0, { name = "PiAnnotation" }).fg == 0xabcdef, "user definition must survive")
  vim.cmd("hi clear PiAnnotation")
  vim.api.nvim_set_hl(0, "Comment", { fg = 0x808080, italic = true })
end

M["a PiAnnotation defined before setup survives setup"] = function()
  vim.cmd("hi clear PiAnnotation")
  vim.api.nvim_set_hl(0, "PiAnnotation", { fg = 0x112233, bold = true })
  pi.setup({})
  local hl = vim.api.nvim_get_hl(0, { name = "PiAnnotation" })
  vim.cmd("hi clear PiAnnotation")
  pi.setup({})
  assert(hl.fg == 0x112233 and hl.bold and not hl.italic, vim.inspect(hl))
end

M["setup live options set the sign and line highlight"] = function()
  local live = require("pi.live")
  pi.setup({})
  assert(live.sign == "▎" and live.line_hl == false)
  pi.setup({ live = { sign = "┆", line_hl = true } })
  assert(live.sign == "┆" and live.line_hl == true)
  pi.setup({})
end


-- Stubs the picker (choosing item select_choice) and the editor (sending input_value, or
-- cancelling when it is nil).
local function stub_ui(select_choice, input_value)
  local editor = require("pi.editor")
  local saved = { select = vim.ui.select, open = editor.open }
  local seen = {}
  vim.ui.select = function(list, opts, cb)
    seen.select = { n = #list, prompt = opts.prompt, labels = vim.tbl_map(opts.format_item, list) }
    cb(select_choice and list[select_choice] or nil)
  end
  editor.open = function(opts)
    seen.input = opts
    if input_value then
      opts.on_submit(input_value)
    elseif opts.on_cancel then
      opts.on_cancel()
    end
  end
  return seen, function()
    vim.ui.select, editor.open = saved.select, saved.open
  end
end

local function three_on_line_2()
  annotations.clear()
  local dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  vim.fn.writefile({ "l1", "l2", "l3", "l4" }, dir .. "/n.txt")
  local buf = vim.fn.bufadd(dir .. "/n.txt")
  vim.fn.bufload(buf)
  vim.api.nvim_set_current_buf(buf)
  annotations.add(buf, 2, 2, "first")
  annotations.add(buf, 2, 2, "second")
  annotations.add(buf, 1, 3, "range")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  pi.setup()
  return buf, dir
end

local function notes_of(dir)
  return vim.tbl_map(function(a) return a.note end, annotations.list(dir))
end

M["PiAnnotationRemove removes exactly the chosen annotation"] = function()
  local _, dir = three_on_line_2()
  local seen, restore = stub_ui(2)
  vim.cmd("PiAnnotationRemove")
  restore()
  assert(seen.select.prompt == "pi: remove which annotation?", vim.inspect(seen))
  assert(vim.deep_equal(seen.select.labels, { "L1-3: range", "L2-2: first", "L2-2: second" }), vim.inspect(seen.select.labels))
  local left = notes_of(dir)
  table.sort(left)
  assert(vim.deep_equal(left, { "range", "second" }), vim.inspect(left))
  annotations.clear()
end

M["PiAnnotationRemove / Edit with Esc in the picker change nothing"] = function()
  local _, dir = three_on_line_2()
  local seen, restore = stub_ui(nil, "never")
  vim.cmd("PiAnnotationRemove")
  vim.cmd("PiAnnotationEdit")
  restore()
  assert(seen.select and not seen.input, vim.inspect(seen))
  assert(#notes_of(dir) == 3)
  annotations.clear()
end

M["PiAnnotationRemove removes a single annotation without a picker; none gives a message"] = function()
  local buf, dir = three_on_line_2()
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  local seen, restore = stub_ui(nil)
  vim.cmd("PiAnnotationRemove")
  assert(seen.select == nil and #notes_of(dir) == 2, vim.inspect(seen))
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  local notes = capture_notify(function() vim.cmd("PiAnnotationRemove") end)
  restore()
  assert(#notes == 1 and notes[1].msg == "pi: no annotation at the cursor", vim.inspect(notes))
  annotations.clear()
  vim.api.nvim_buf_delete(buf, { force = true })
end

M["PiAnnotationEdit opens the editor prefilled, titled with file and range, and keeps lines"] = function()
  local buf, dir = three_on_line_2()
  local function virt()
    local ns = vim.api.nvim_create_namespace("pi_annotations")
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[4].virt_lines then out[#out + 1] = m[4].virt_lines[1][1][1] end
    end
    return out
  end
  local seen, restore = stub_ui(3, "edited\nsecond paragraph")
  vim.cmd("PiAnnotationEdit")
  assert(seen.select.prompt == "pi: edit which annotation?")
  assert(seen.input.title == " pi edit note · n.txt:2 " and seen.input.text == "second", vim.inspect(seen.input))
  assert(vim.tbl_contains(notes_of(dir), "edited\nsecond paragraph"), vim.inspect(notes_of(dir)))
  assert(vim.tbl_contains(virt(), "  ✎ edited second paragraph"), vim.inspect(virt()))
  assert(not vim.tbl_contains(virt(), "  ✎ second"), vim.inspect(virt()))
  restore()
  local before = notes_of(dir)
  local _, r = stub_ui(1, nil)
  vim.cmd("PiAnnotationEdit")
  r()
  assert(vim.deep_equal(notes_of(dir), before), vim.inspect(notes_of(dir)))
  annotations.clear()
end

M["picker label truncates long text to 80 characters"] = function()
  local buf = three_on_line_2()
  annotations.add(buf, 4, 4, string.rep("x", 100))
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  local label = annotations.label(annotations.at_cursor()[1])
  assert(label == "L4-4: " .. string.rep("x", 80) .. "…", label)
  annotations.clear()
end

local function run_end_notes(data, open_chunk, keys)
  reset_maps()
  capture_notify(function() pi.setup({ keys = keys }) end)
  local session = require("pi.session")
  local real_refresh, real_connected = session.refresh_status, session.connected
  session.connected = function() return true end
  session.refresh_status = function(cb) cb(nil, { openChunk = open_chunk }) end
  local ok, notes = pcall(capture_notify, function() pi.notify_run_end(data) end)
  session.refresh_status, session.connected = real_refresh, real_connected
  assert(ok, notes)
  return notes
end

M["run end: aborted with an open checkpoint names it; aborted without says stopped"] = function()
  local notes = run_end_notes({ aborted = true }, { n = 3 })
  assert(#notes == 1 and notes[1].msg == "pi: stopped — checkpoint 3 waiting", vim.inspect(notes))
  notes = run_end_notes({ aborted = true }, nil)
  assert(#notes == 1 and notes[1].msg == "pi: stopped", vim.inspect(notes))
end

M["run end: the waiting-checkpoint notice names the keys setup mapped, else the commands"] = function()
  local notes = run_end_notes({}, { n = 2 }, { checkpoints = "<leader>zz", continue = "<leader>cc" })
  assert(notes[1].msg == "pi: checkpoint 2 waiting — <leader>zz to look, <leader>cc to continue", notes[1].msg)
  notes = run_end_notes({}, { n = 2 }, { checkpoints = false, continue = false })
  assert(notes[1].msg == "pi: checkpoint 2 waiting — :PiCheckpoints to look, :PiContinue to continue", notes[1].msg)
  reset_maps()
end

M["stop: a stop that took effect shows no notice itself; nothing to stop is reported"] = function()
  local session = require("pi.session")
  local real_request, real_refresh = session.request, session.refresh_status
  session.refresh_status = function() end
  local function cancel_with(result)
    session.request = function(_, _, cb) cb(nil, result) end
    local ok, notes = pcall(capture_notify, function() pi.stop() end)
    session.request, session.refresh_status = real_request, real_refresh
    assert(ok, notes)
    session.refresh_status = function() end
    return notes
  end
  local notes = cancel_with({ cancelled = true })
  assert(#notes == 0, vim.inspect(notes))
  notes = cancel_with({ cancelled = false })
  assert(#notes == 1 and notes[1].msg == "pi: nothing to stop", vim.inspect(notes))
  session.request, session.refresh_status = real_request, real_refresh
end

-- Runs pi.continue() against a fake attached session; returns the notices and the "send" payloads.
local function continue_with(open_chunk, count)
  local session = require("pi.session")
  local real = { ensure = session.ensure, refresh_status = session.refresh_status }
  local requests = {}
  local conn = { request = function(_, method, payload, cb) requests[#requests + 1] = { method = method, payload = payload }; cb(nil, {}) end }
  local root = vim.uv.fs_realpath(vim.fn.tempname() .. "_d") or (function() local d = vim.fn.tempname(); vim.fn.mkdir(d, "p"); return vim.uv.fs_realpath(d) end)()
  session.ensure = function(cb) cb(conn, root) end
  session.refresh_status = function(cb)
    if cb then cb(nil, { openChunk = open_chunk, name = "wt-a" }) end
  end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.fn.writefile({ "a", "b", "c" }, root .. "/probe.txt")
  vim.api.nvim_buf_set_name(buf, root .. "/probe.txt")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
  vim.api.nvim_set_current_buf(buf)
  vim.cmd("silent! write!")
  for i = 1, count do
    annotations.add(buf, i, i, "note " .. i)
  end
  local ok, notes = pcall(capture_notify, function() pi.continue() end)
  session.ensure, session.refresh_status = real.ensure, real.refresh_status
  local remaining = #annotations.list(root)
  annotations.clear()
  vim.fn.delete(root, "rf")
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, notes)
  return notes, requests, remaining
end

M["continue with a checkpoint open sends the review without note or confirm"] = function()
  local real_confirm = vim.fn.confirm
  vim.fn.confirm = function() error("continue must not ask") end
  local ok, notes, requests = pcall(continue_with, { n = 4 }, 0)
  vim.fn.confirm = real_confirm
  assert(ok, notes)
  assert(#requests == 1 and requests[1].method == "send" and requests[1].payload.note == "", vim.inspect(requests))
  assert(#notes == 1 and notes[1].msg == "pi[wt-a]: continuing — checkpoint 4 reviewed", vim.inspect(notes))
end

M["continue with a checkpoint open and annotations counts them and clears them"] = function()
  local notes, requests, remaining = continue_with({ n = 4 }, 1)
  assert(#requests[1].payload.annotations == 1 and requests[1].payload.note == "", vim.inspect(requests))
  assert(notes[1].msg == "pi[wt-a]: continuing — checkpoint 4 reviewed with 1 annotation", vim.inspect(notes))
  assert(remaining == 0, "annotations not cleared")
  notes = continue_with({ n = 5 }, 2)
  assert(notes[1].msg == "pi[wt-a]: continuing — checkpoint 5 reviewed with 2 annotations", vim.inspect(notes))
end

M["continue notices with a long session name fit the message line and keep the label whole"] = function()
  local session = require("pi.session")
  local real_label = session.label
  session.label = function() return "refactor-session-discovery" end
  local ok, err = pcall(at_columns, 80, function()
    local notes = continue_with({ n = 14 }, 2)
    assert_fits(notes)
    assert(notes[1].msg == "pi[refactor-session-discovery]: checkpoint 14 reviewed", notes[1].msg)
    -- A label too long for any wording is cut with "…", never silently.
    session.label = function() return ("very-long-session-name-"):rep(4) end
    notes = continue_with({ n = 14 }, 2)
    assert_fits(notes)
    assert(vim.startswith(notes[1].msg, "pi[very-long-session-name-") and vim.endswith(notes[1].msg, "…"), notes[1].msg)
  end)
  session.label = real_label
  assert(ok, err)
end

M["continue stops with a warning when a buffer cannot be saved; nothing is sent"] = function()
  local session = require("pi.session")
  local real = { ensure = session.ensure, refresh_status = session.refresh_status }
  local requests = {}
  local conn = { request = function(_, method, payload, cb) requests[#requests + 1] = method; cb(nil, {}) end }
  local root = vim.uv.fs_realpath(vim.fn.tempname() .. "_s") or (function() local d = vim.fn.tempname(); vim.fn.mkdir(d, "p"); return vim.uv.fs_realpath(d) end)()
  local path = root .. "/locked.txt"
  vim.fn.writefile({ "old" }, path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "new" })
  annotations.add(buf, 1, 1, "keep me")
  -- The write fails: the buffer's file is now a directory.
  vim.fn.delete(path)
  vim.fn.mkdir(path, "p")
  session.ensure = function(cb) cb(conn, root) end
  session.refresh_status = function(cb) if cb then cb(nil, { openChunk = { n = 2 }, name = "w" }) end end
  local ok, notes = pcall(capture_notify, function() pi.continue() end)
  session.ensure, session.refresh_status = real.ensure, real.refresh_status
  local remaining = #annotations.list(root)
  annotations.clear()
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(root, "rf")
  assert(ok, notes)
  assert(#requests == 0, vim.inspect(requests))
  assert(#notes == 1 and notes[1].level == vim.log.levels.WARN and notes[1].msg == "pi: could not save locked.txt — nothing sent", vim.inspect(notes))
  assert(remaining == 1, "annotations dropped")
end

M["continue without a checkpoint sends annotations as a prompt, or says nothing to send"] = function()
  reset_maps()
  capture_notify(function() pi.setup() end)
  local notes, requests = continue_with(nil, 2)
  assert(#requests == 1 and #requests[1].payload.annotations == 2, vim.inspect(requests))
  assert(#notes == 1 and notes[1].msg == "pi[wt-a]: 2 annotations sent", vim.inspect(notes))
  notes = continue_with(nil, 1)
  assert(notes[1].msg == "pi[wt-a]: 1 annotation sent", vim.inspect(notes))
  notes, requests = continue_with(nil, 0)
  assert(#requests == 0 and #notes == 1 and notes[1].msg == "pi: nothing to send — <leader>pn to annotate, <leader>pa to ask", vim.inspect(notes))
end

-- Buffers for save-scope tests: a modified file buffer in dir.
local function modified_buf(path, listed)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ "old" }, path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = listed ~= false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "new" })
  return buf
end

M["continue saves only modified listed file buffers inside the session root"] = function()
  local session = require("pi.session")
  local real = { ensure = session.ensure, refresh_status = session.refresh_status }
  local base = vim.uv.fs_realpath(vim.fn.tempname() .. "x") or (function() local d = vim.fn.tempname(); vim.fn.mkdir(d, "p"); return vim.uv.fs_realpath(d) end)()
  local root, other = base .. "/proj", base .. "/other"
  local inside = modified_buf(root .. "/a.txt")
  local nested = modified_buf(root .. "/sub/b.txt")
  local outside = modified_buf(other .. "/c.txt")
  local sibling = modified_buf(base .. "/proj2/d.txt") -- shares the root as a string prefix
  local unlisted = modified_buf(root .. "/e.txt", false)
  local virtual = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(virtual, "pi://diff/" .. root)
  vim.api.nvim_buf_set_lines(virtual, 0, -1, false, { "x" })
  vim.bo[virtual].modified = true
  vim.fn.mkdir(root, "p")
  local conn = { request = function(_, _, _, cb) cb(nil, {}) end }
  session.ensure = function(cb) cb(conn, root) end
  session.refresh_status = function(cb) if cb then cb(nil, { openChunk = { n = 1 } }) end end
  local ok, err = pcall(capture_notify, function() pi.continue() end)
  session.ensure, session.refresh_status = real.ensure, real.refresh_status
  local function disk(path) return vim.fn.readfile(path)[1] end
  local results = {
    inside = disk(root .. "/a.txt"), nested = disk(root .. "/sub/b.txt"), outside = disk(other .. "/c.txt"),
    sibling = disk(base .. "/proj2/d.txt"), unlisted = disk(root .. "/e.txt"),
    outside_modified = vim.bo[outside].modified, virtual_modified = vim.bo[virtual].modified,
  }
  for _, b in ipairs({ inside, nested, outside, sibling, unlisted, virtual }) do
    vim.api.nvim_buf_delete(b, { force = true })
  end
  vim.fn.delete(base, "rf")
  assert(ok, err)
  assert(results.inside == "new" and results.nested == "new", vim.inspect(results))
  assert(results.outside == "old" and results.sibling == "old" and results.unlisted == "old", vim.inspect(results))
  assert(results.outside_modified, vim.inspect(results))
end

M["describe renders label, worktree, state, checkpoints and age"] = function()
  local session = require("pi.session")
  local now = 10 * 24 * 3600 * 1000
  local function row(extra)
    return session.describe(vim.tbl_extend("force", { name = "api", root = "/w/feature-x", busy = false }, extra), now)
  end
  assert(row({ lastActive = now - 20000 }) == "api · feature-x · idle · now", row({ lastActive = now - 20000 }))
  assert(row({ busy = true, lastActive = now - 5 * 60000 }) == "api · feature-x · working · 5m ago")
  assert(row({ lastActive = now - 2 * 3600000 - 1000 }) == "api · feature-x · idle · 2h ago")
  assert(row({ lastActive = now - 3 * 86400000 }) == "api · feature-x · idle · 3d ago")
  assert(row({ mode = "checkpoints", openChunk = { n = 4 }, lastActive = now }) == "api · feature-x · checkpoint 4 waiting · checkpoints · now")
  assert(row({}) == "api · feature-x · idle", row({}))
  assert(session.describe({ sessionId = "0123456789ab", root = "/w/r", busy = true }, now) == "01234567 · r · working")
end

M["picker orders named, then checkpoint mode, then newest activity, stable"] = function()
  local session = require("pi.session")
  local function c(id, st) st.sessionId = id; return { id = id, status = st } end
  local live = {
    c("u-old", { lastActive = 100 }),
    c("u-none-1", {}),
    c("u-new", { lastActive = 900 }),
    c("u-none-2", {}),
    c("u-cp", { mode = "checkpoints", lastActive = 50 }),
    c("n-old", { name = "old", lastActive = 10 }),
    c("n-cp", { name = "cp", mode = "checkpoints" }),
    c("n-new", { name = "new", lastActive = 800 }),
  }
  local ids = vim.tbl_map(function(x) return x.id end, session.sort_candidates(live))
  local expected = { "n-cp", "n-new", "n-old", "u-cp", "u-new", "u-old", "u-none-1", "u-none-2" }
  assert(vim.deep_equal(ids, expected), vim.inspect(ids))
end

-- Runs ensure against two fake sessions in a real repo pair; returns notices and attached labels.
M["ensure says switched once per switch, also quiet; silent on first attach"] = function()
  local session = require("pi.session")
  local client, discover = require("pi.client"), require("pi.discover")
  local real = { sockets = discover.sockets, connect = client.connect, root = discover.root }
  local dirs = { vim.uv.fs_realpath(vim.fn.tempname() .. "a") }
  local function mk(name)
    local d = vim.fn.tempname() .. name
    vim.fn.mkdir(d, "p")
    d = vim.uv.fs_realpath(d)
    vim.fn.writefile({ "x" }, d .. "/f.txt")
    return d
  end
  local a, b = mk("wt-a"), mk("wt-b")
  discover.root = function(dir) return dir:find("wt%-a") and a or b end
  discover.sockets = function(dir) return { (dir:find("wt%-a") and a or b) .. "/sock" } end
  client.connect = function(path)
    local root = vim.fs.dirname(path)
    return {
      closed = false,
      close = function(self) self.closed = true end,
      request = function(_, _, _, cb) cb(nil, { root = root, name = vim.fs.basename(root), sessionId = "id", drafts = {} }) end,
    }
  end
  local function ensure_in(root, quiet)
    local buf = vim.fn.bufadd(root .. "/f.txt")
    vim.fn.bufload(buf)
    vim.api.nvim_set_current_buf(buf)
    local attached
    local notes = capture_notify(function() session.ensure(function(_, r) attached = r end, { quiet = quiet }) end)
    return notes, attached
  end
  session.detach()
  local ok, err = pcall(function()
    local notes, attached = ensure_in(a, false)
    assert(attached == a and #notes == 0, "first attach must be silent: " .. vim.inspect(notes))
    notes = ensure_in(a, false)
    assert(#notes == 0, "same worktree: " .. vim.inspect(notes))
    notes, attached = ensure_in(b, false)
    assert(attached == b and #notes == 1 and notes[1].msg == ("pi: switched to %s (%s)"):format(vim.fs.basename(b), vim.fs.basename(b)), vim.inspect(notes))
    notes = ensure_in(b, false)
    assert(#notes == 0, "no second notice: " .. vim.inspect(notes))
    notes, attached = ensure_in(a, true)
    assert(attached == a and #notes == 1 and notes[1].msg == ("pi: switched to %s (%s)"):format(vim.fs.basename(a), vim.fs.basename(a)), "quiet: " .. vim.inspect(notes))
  end)
  session.detach()
  discover.sockets, client.connect, discover.root = real.sockets, real.connect, real.root
  vim.fn.delete(a, "rf")
  vim.fn.delete(b, "rf")
  assert(ok, err)
end

-- Two real worktrees of one repo (a = main, b = linked) for follow specs.
local function worktree_pair()
  local base = vim.uv.fs_realpath(vim.fn.tempname() .. "x") or vim.fn.tempname()
  vim.fn.mkdir(base, "p")
  base = vim.uv.fs_realpath(base)
  local a, b = base .. "/a", base .. "/b"
  vim.fn.mkdir(a, "p")
  local function git(...)
    local r = vim.system(vim.list_extend({ "git", "-C", a }, { ... }), { text = true }):wait()
    assert(r.code == 0, r.stderr)
  end
  git("init", "-q")
  git("-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "i")
  git("worktree", "add", "-q", "-b", "other", b)
  vim.fn.writefile({ "x" }, b .. "/f.txt")
  return base, vim.uv.fs_realpath(a), vim.uv.fs_realpath(b)
end

-- Runs fn with session state faked as attached to a session now running in b while this nvim sits in a.
local function with_followed_state(fn)
  local session = require("pi.session")
  local base, a, b = worktree_pair()
  local real = { connected = session.connected, cached = session.cached, root = session.root, home = session.home, select = vim.ui.select, refresh = session.refresh_live, cwd = vim.fn.getcwd() }
  session.connected = function() return true end
  session.root, session.home, session.cached = a, a, { root = a, name = "s" }
  session.refresh_live = function() end
  vim.cmd("tcd " .. vim.fn.fnameescape(a))
  local handlers = {}
  local real_on = session.on_event
  session.on_event = function(f) handlers[#handlers + 1] = f end
  capture_notify(function() pi.setup() end)
  session.on_event = real_on
  local ok, err = pcall(fn, { session = session, a = a, b = b, event = handlers[#handlers] })
  session.connected, session.cached, session.root, session.home, vim.ui.select, session.refresh_live = real.connected, real.cached, real.root, real.home, real.select, real.refresh
  vim.cmd("silent! only")
  vim.cmd("tcd " .. vim.fn.fnameescape(real.cwd))
  vim.fn.delete(base, "rf")
  assert(ok, err)
end

M["root_changed notifies and prompts Follow / Stay once; Stay and Esc do nothing"] = function()
  with_followed_state(function(c)
    local asked = {}
    vim.ui.select = function(items, opts, on_choice) asked[#asked + 1] = { items = items, prompt = opts.prompt, cb = on_choice } end
    local notes = capture_notify(function() c.session.root = c.b; c.event("root_changed", { root = c.b }); vim.wait(50, function() return #asked > 0 end) end)
    assert(#notes == 1 and notes[1].msg == "pi: following the agent into b — <leader>pf to follow", vim.inspect(notes))
    assert(#asked == 1 and asked[1].prompt == "pi: agent moved to b — follow here?", vim.inspect(asked))
    assert(vim.deep_equal(asked[1].items, { "Follow", "Stay" }))
    asked[1].cb("Stay")
    asked[1].cb(nil)
    assert(vim.fn.getcwd() == c.a, vim.fn.getcwd())
  end)
end

M["root_changed into the worktree nvim already sits in only notifies"] = function()
  with_followed_state(function(c)
    local asked = 0
    vim.ui.select = function() asked = asked + 1 end
    local notes = capture_notify(function() c.event("root_changed", { root = c.a }); vim.wait(50) end)
    assert(#notes == 1 and notes[1].msg == "pi: following the agent into a", vim.inspect(notes))
    assert(asked == 0)
  end)
end

M["Follow does :tcd, opens the agent's current file in a split, and :PiFollow does the same"] = function()
  with_followed_state(function(c)
    local choose
    vim.ui.select = function(_, _, on_choice) choose = on_choice end
    c.session.root = c.b
    c.session.cached.root = c.b
    c.session.cached.activity = { tool = "edit", target = "f.txt" }
    capture_notify(function() c.event("root_changed", { root = c.b }); vim.wait(50, function() return choose ~= nil end) end)
    choose("Follow")
    assert(vim.fn.getcwd() == c.b, vim.fn.getcwd())
    assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) == c.b .. "/f.txt", vim.api.nvim_buf_get_name(0))
    assert(#vim.api.nvim_tabpage_list_wins(0) == 2)
    -- already there: nothing to follow
    local notes = capture_notify(function() vim.cmd("PiFollow") end)
    assert(#notes == 1 and notes[1].msg == "pi: nothing to follow", vim.inspect(notes))
    -- manual: back in a, :PiFollow goes to b again; a missing file opens no split
    vim.cmd("only | tcd " .. vim.fn.fnameescape(c.a))
    c.session.cached.activity = { tool = "edit", target = "gone.txt" }
    capture_notify(function() vim.cmd("PiFollow") end)
    assert(vim.fn.getcwd() == c.b and #vim.api.nvim_tabpage_list_wins(0) == 1, vim.fn.getcwd())
  end)
end

M["PiFollow without a session says so like the other commands"] = function()
  local session = require("pi.session")
  local real = { connected = session.connected, ensure = session.ensure }
  session.connected = function() return false end
  capture_notify(function() pi.setup() end)
  local notes = capture_notify(function() vim.cmd("PiFollow") end)
  session.connected, session.ensure = real.connected, real.ensure
  assert(#notes == 1 and notes[1].level == vim.log.levels.ERROR and notes[1].msg:find("^pi: "), vim.inspect(notes))
end

M["two moves in quick succession open one picker, not two"] = function()
  with_followed_state(function(c)
    local asked = 0
    vim.ui.select = function() asked = asked + 1 end
    capture_notify(function()
      c.session.root = c.b
      c.event("root_changed", { root = c.b })
      c.event("root_changed", { root = c.b })
      vim.wait(100)
    end)
    assert(asked == 1, asked)
  end)
end

M["root_changed clears the live marks of the old worktree"] = function()
  with_followed_state(function(c)
    local live = require("pi.live")
    local real_clear, cleared = live.clear, 0
    live.clear = function() cleared = cleared + 1 end
    capture_notify(function() c.event("root_changed", { root = c.b }); vim.wait(20) end)
    live.clear = real_clear
    assert(cleared == 1, cleared)
  end)
end

M["Follow opens the file the agent last edited, even after its tool ended"] = function()
  with_followed_state(function(c)
    local choose
    vim.ui.select = function(_, _, on_choice) choose = on_choice end
    capture_notify(function()
      c.event("activity_current", { current = { tool = "edit", target = "f.txt" }, mutating = true, busy = true })
      c.session.root = c.b
      c.session.cached.root = c.b
      c.event("root_changed", { root = c.b })
      vim.wait(50, function() return choose ~= nil end)
    end)
    choose("Follow")
    assert(vim.fn.getcwd() == c.b, vim.fn.getcwd())
    assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) == c.b .. "/f.txt", vim.api.nvim_buf_get_name(0))
  end)
end

M["a move back home cancels a pending follow picker"] = function()
  with_followed_state(function(c)
    local asked = 0
    vim.ui.select = function() asked = asked + 1 end
    capture_notify(function()
      c.session.root = c.b
      c.event("root_changed", { root = c.b })
      c.session.root = c.a
      c.event("root_changed", { root = c.a })
      vim.wait(100)
    end)
    assert(asked == 0, asked)
  end)
end

M["Follow leaves a checkpoint diff tab for the tab it was opened from"] = function()
  with_followed_state(function(c)
    local diff = require("pi.diff")
    local panel = require("pi.panel")
    local real = { ensure = c.session.ensure, request = c.session.request, view_of_tab = diff.view_of_tab }
    c.session.ensure = function(cb) cb(nil, c.b) end
    c.session.request = function(_, _, cb) if cb then cb(nil, {}) end end
    -- a fake diff view whose origin is this tab, "opened from" another tab
    local other = vim.api.nvim_get_current_tabpage()
    diff.view_of_tab = function(tabpage)
      if tabpage == other then
        return { origin = other }
      end
      return nil
    end
    c.session.root = c.b
    c.session.cached.root = c.b
    c.session.cached.activity = { tool = "edit", target = "f.txt" }
    local ok, err = pcall(function() vim.cmd("PiFollow") end)
    diff.view_of_tab = real.view_of_tab
    c.session.ensure, c.session.request = real.ensure, real.request
    assert(ok, err)
    assert(vim.fn.getcwd() == c.b, vim.fn.getcwd())
    assert(vim.api.nvim_get_current_tabpage() == other, "left the diff tab")
  end)
end

M["Follow into a worktree that vanished says so instead of erroring"] = function()
  with_followed_state(function(c)
    local choose
    vim.ui.select = function(_, _, on_choice) choose = on_choice end
    capture_notify(function() c.session.root = c.b; c.event("root_changed", { root = c.b }); vim.wait(50, function() return choose ~= nil end) end)
    vim.fn.delete(c.b, "rf")
    local ok, notes = pcall(capture_notify, function() choose("Follow") end)
    assert(ok, notes)
    assert(#notes == 1 and notes[1].msg == "pi: could not follow into b", vim.inspect(notes))
  end)
end

M["Follow from the checkpoint panel lands in a normal window, not the panel split"] = function()
  with_followed_state(function(c)
    local panel = require("pi.panel")
    -- The harness has no real connection; keep panel.open and its refresh quiet.
    local real = { ensure = c.session.ensure, request = c.session.request }
    c.session.ensure = function(cb) cb(nil, c.b) end
    c.session.request = function(_, _, cb) if cb then cb(nil, {}) end end
    panel.open()
    vim.wait(50)
    local panel_win
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if panel.is_panel_window(w) then
        panel_win = w
      end
    end
    assert(panel_win, "no panel window")
    vim.api.nvim_set_current_win(panel_win)
    c.session.root = c.b
    c.session.cached.root = c.b
    c.session.cached.activity = { tool = "edit", target = "f.txt" }
    local ok, notes = pcall(capture_notify, function() vim.cmd("PiFollow") end)
    panel.close()
    c.session.ensure, c.session.request = real.ensure, real.request
    assert(ok, notes)
    assert(vim.fn.getcwd() == c.b, vim.fn.getcwd())
    local file_win
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find("f.txt", 1, true) then
        file_win = w
      end
    end
    assert(file_win, "file window missing")
    assert(not panel.is_panel_window(file_win), "file opened in the panel")
    assert(vim.api.nvim_win_get_width(file_win) > 30, vim.api.nvim_win_get_width(file_win))
  end)
end

M["ensure stays attached for a worktree the session visited, without a switch notice"] = function()
  local session = require("pi.session")
  local base, a, b = worktree_pair()
  local real = { connected = session.connected, cached = session.cached, root = session.root, home = session.home, visited = session.visited }
  session.connected = function() return true end
  -- the agent followed to b and is back in a; nvim sits in b after following along
  session.root, session.home = a, a
  session.visited = { a, b }
  session.cached = { root = a, name = "s", sessionId = "id" }
  vim.fn.writefile({ "x" }, b .. "/g.txt")
  local buf = vim.fn.bufadd(b .. "/g.txt")
  vim.fn.bufload(buf)
  vim.api.nvim_set_current_buf(buf)
  local stayed = false
  local ok, notes = pcall(capture_notify, function()
    session.ensure(function() stayed = true end)
    vim.wait(20)
  end)
  session.connected, session.cached, session.root, session.home, session.visited = real.connected, real.cached, real.root, real.home, real.visited
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(base, "rf")
  assert(ok, notes)
  assert(stayed, "detached instead of staying")
  assert(#notes == 0, vim.inspect(notes))
end

M["continue sends the notes of every visited worktree and clears them all"] = function()
  local session, ann = require("pi.session"), require("pi.annotations")
  local base, a, b = worktree_pair()
  local real = { ensure = session.ensure, refresh_status = session.refresh_status, visited = session.visited, root = session.root }
  local requests = {}
  local conn = { request = function(_, method, payload, cb) requests[#requests + 1] = { method = method, payload = payload }; cb(nil, {}) end }
  vim.fn.writefile({ "x" }, a .. "/ga.txt")
  vim.fn.writefile({ "x" }, b .. "/gb.txt")
  local bufs = {}
  for _, spec in ipairs({ { a, "ga.txt", "note a" }, { b, "gb.txt", "note b" } }) do
    local buf = vim.fn.bufadd(spec[1] .. "/" .. spec[2])
    vim.fn.bufload(buf)
    vim.bo[buf].buflisted = true
    ann.add(buf, 1, 1, spec[3])
    bufs[#bufs + 1] = { buf = buf, root = spec[1], note = spec[3] }
  end
  session.ensure = function(cb) cb(conn, b) end
  session.refresh_status = function(cb) if cb then cb(nil, { openChunk = { n = 3 }, name = "s" }) end end
  session.root = b
  session.visited = { a, b }
  local ok, notes = pcall(capture_notify, function() pi.continue() end)
  local remaining = {}
  for _, e in ipairs(bufs) do
    remaining[#remaining + 1] = #ann.list(e.root)
    vim.api.nvim_buf_delete(e.buf, { force = true })
  end
  session.ensure, session.refresh_status, session.root, session.visited = real.ensure, real.refresh_status, real.root, real.visited
  vim.fn.delete(base, "rf")
  assert(ok, notes)
  assert(#requests == 1 and requests[1].method == "send", vim.inspect(requests))
  local sent = requests[1].payload.annotations
  assert(#sent == 2, vim.inspect(sent))
  assert(remaining[1] == 0 and remaining[2] == 0, vim.inspect(remaining))
  assert(notes[1].msg == "pi[s]: continuing — checkpoint 3 reviewed with 2 annotations", vim.inspect(notes))
end

M["prompt context falls back to a visited worktree when the buffer is not under the session root"] = function()
  local session = require("pi.session")
  local base, a, b = worktree_pair()
  local real = session.visited
  vim.fn.writefile({ "x" }, a .. "/g.txt")
  local buf = vim.fn.bufadd(a .. "/g.txt")
  vim.fn.bufload(buf)
  session.visited = { a, b }
  local ctx = pi.prompt_context(buf, b, { line1 = 1, line2 = 1 })
  session.visited = real
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(base, "rf")
  assert(ctx and ctx.path == "g.txt", vim.inspect(ctx))
end

M["ensure finds a session that followed the agent into another worktree of the repo"] = function()
  local session = require("pi.session")
  local client, discover = require("pi.client"), require("pi.discover")
  local base, a, b = worktree_pair()
  local real = { sockets = discover.sockets, connect = client.connect }
  discover.sockets = function() return { base .. "/s1" } end
  client.connect = function()
    return { closed = false, close = function(self) self.closed = true end,
      request = function(_, _, _, cb) cb(nil, { root = b, startRoot = a, name = "moved", sessionId = "id", drafts = {} }) end }
  end
  local buf = vim.fn.bufadd(a .. "/g.txt")
  vim.fn.writefile({ "x" }, a .. "/g.txt")
  vim.fn.bufload(buf)
  vim.api.nvim_set_current_buf(buf)
  session.detach()
  local attached, root
  local ok, err = pcall(function()
    session.ensure(function(_, r) attached, root = true, r end)
    assert(attached and session.cached.name == "moved", "not attached")
    assert(session.root == b and root == b, tostring(session.root))
    assert(session.home == a, tostring(session.home))
    -- a second command from the start worktree stays attached, does not re-pick
    local again
    session.ensure(function() again = true end, { buf = buf })
    assert(again)
  end)
  session.detach()
  discover.sockets, client.connect = real.sockets, real.connect
  vim.fn.delete(base, "rf")
  assert(ok, err)
end

M["a session in an unrelated repo is not picked up, nor one in the buffer's worktree outranked"] = function()
  local session = require("pi.session")
  local client, discover = require("pi.client"), require("pi.discover")
  local base, a, b = worktree_pair()
  local other = vim.uv.fs_realpath(vim.fn.tempname() .. "o") or vim.fn.tempname() .. "o"
  vim.fn.mkdir(other, "p")
  other = vim.uv.fs_realpath(other)
  vim.system({ "git", "-C", other, "init", "-q" }):wait()
  local roots = { s1 = b, s2 = other, s3 = a }
  local start_roots = { s1 = a, s2 = nil, s3 = nil }
  local real = { sockets = discover.sockets, connect = client.connect }
  discover.sockets = function() return { base .. "/s1", base .. "/s2", base .. "/s3" } end
  client.connect = function(path)
    local id = vim.fs.basename(path)
    return { closed = false, close = function(self) self.closed = true end,
      request = function(_, _, _, cb)
        local status = { root = roots[id], name = id, sessionId = id, drafts = {} }
        if start_roots[id] then
          status.startRoot = start_roots[id]
        end
        cb(nil, status)
      end }
  end
  vim.fn.writefile({ "x" }, a .. "/g.txt")
  vim.api.nvim_set_current_buf(vim.fn.bufadd(a .. "/g.txt"))
  vim.fn.bufload(0)
  session.detach()
  local real_select = vim.ui.select
  -- s3 (running here) and s1 (started here, followed away) both belong to this worktree: the picker asks.
  vim.ui.select = function(items, _, on_choice)
    for _, item in ipairs(items) do
      if item.status and item.status.sessionId == "s3" then
        return on_choice(item)
      end
    end
    on_choice(nil)
  end
  local ok, err = pcall(function()
    session.ensure(function() end)
    assert(session.cached.sessionId == "s3", vim.inspect(session.cached))
    session.detach()
    -- s3 now runs in an unrelated repo; only the followed s1 is left and is attached without asking.
    roots.s3 = other
    session.ensure(function() end)
    assert(session.cached.sessionId == "s1", vim.inspect(session.cached))
  end)
  vim.ui.select = real_select
  session.detach()
  discover.sockets, client.connect = real.sockets, real.connect
  vim.fn.delete(base, "rf")
  vim.fn.delete(other, "rf")
  assert(ok, err)
end

M["a session elsewhere in the repo that never started here is not picked up"] = function()
  local session = require("pi.session")
  local client, discover = require("pi.client"), require("pi.discover")
  local base, a, b = worktree_pair()
  local real = { sockets = discover.sockets, connect = client.connect }
  discover.sockets = function() return { base .. "/s1" } end
  client.connect = function()
    return { closed = false, close = function(self) self.closed = true end,
      request = function(_, _, _, cb) cb(nil, { root = b, name = "elsewhere", sessionId = "s1", drafts = {} }) end }
  end
  vim.fn.writefile({ "x" }, a .. "/g.txt")
  vim.api.nvim_set_current_buf(vim.fn.bufadd(a .. "/g.txt"))
  vim.fn.bufload(0)
  session.detach()
  local ok, notes = pcall(capture_notify, function()
    session.ensure(function() end)
    vim.wait(20)
  end)
  session.detach()
  discover.sockets, client.connect = real.sockets, real.connect
  vim.fn.delete(base, "rf")
  assert(ok, notes)
  assert(#notes == 1 and notes[1].msg:find("^pi: no pi session"), vim.inspect(notes))
end

M["picker row shows the session's own worktree, not the buffer's"] = function()
  local session = require("pi.session")
  local row = session.describe({ name = "n", root = "/w/followed-here", busy = false }, 0)
  assert(row == "n · followed-here · idle", row)
end

M["waiting notice and checkpoint-ready notice name the keys or the commands"] = function()
  reset_maps()
  capture_notify(function() pi.setup() end)
  local notes = capture_notify(function() pi.notify_waiting(4) end)
  assert(notes[1].msg == "pi: checkpoint 4 waiting — <leader>pv to look, <leader>pc to continue", notes[1].msg)
  reset_maps()
end

M["statusline says checkpoint N while a checkpoint waits"] = function()
  local session = require("pi.session")
  local real = { connected = session.connected, cached = session.cached }
  session.connected = function() return true end
  session.cached = { name = "x", openChunk = { n = 3 }, mode = "checkpoints" }
  local line, short = session.statusline(), session.status_line()
  session.connected, session.cached = real.connected, real.cached
  assert(line == "pi: x · checkpoint 3", line)
  assert(short == "checkpoint 3", short)
end

M["statusline_parts colours checkpoint N and leaves other states plain"] = function()
  local session = require("pi.session")
  local real = { connected = session.connected, cached = session.cached }
  session.connected = function() return true end
  session.cached = { name = "x", openChunk = { n = 3 }, mode = "checkpoints" }
  local waiting = pi.statusline_parts()
  session.cached = { name = "x", activity = { tool = "read", target = string.rep("é", 50) }, mode = "checkpoints" }
  local working = pi.statusline_parts()
  local working_line = pi.statusline()
  session.cached = { name = "refactor-discover", activity = { tool = "edit", target = "src/discover.lua" }, busy = true, mode = "checkpoints" }
  local path_line = pi.statusline()
  session.cached = nil
  local detached = pi.statusline_parts()
  session.connected, session.cached = real.connected, real.cached
  assert(vim.deep_equal(waiting, { { text = "pi: x · " }, { text = "checkpoint 3", hl = "PiCheckpointWaiting" } }), vim.inspect(waiting))
  assert(#working == 1 and working[1].hl == nil, vim.inspect(working))
  assert(working_line == "pi: x [checkpoints] · read " .. string.rep("é", 40) .. "…", working_line)
  -- A tool replaces "working"; a path shows as its file name.
  assert(path_line == "pi: refactor-discover [checkpoints] · edit discover.lua", path_line)
  assert(vim.deep_equal(detached, {}))
end

M["outside_worktree event shows the warning text via WARN"] = function()
  local session = require("pi.session")
  local real = session.cached
  session.cached = { root = "/work/a" }
  local handlers = {}
  local real_on = session.on_event
  session.on_event = function(fn) handlers[#handlers + 1] = fn end
  capture_notify(function() pi.setup() end)
  session.on_event = real_on
  local notes = capture_notify(function() handlers[#handlers]("outside_worktree", { path = "/x/y" }) end)
  session.cached = real
  assert(#notes == 1 and notes[1].level == vim.log.levels.WARN, vim.inspect(notes))
  assert(notes[1].msg == "pi: the agent is editing outside a — start pi in that worktree to review it", notes[1].msg)
end

M["notices fit the message line at 80 columns, so nvim never asks to press ENTER"] = function()
  local session = require("pi.session")
  at_columns(80, function()
    -- A long worktree name: the outside-worktree warning drops its advice, then cuts with "…".
    local real = session.cached
    session.cached = { root = "/home/philipp/repos/pi-nvim-feature-long-worktree" }
    local handlers = {}
    local real_on = session.on_event
    session.on_event = function(fn) handlers[#handlers + 1] = fn end
    capture_notify(function() pi.setup() end)
    session.on_event = real_on
    local notes = capture_notify(function() handlers[#handlers]("outside_worktree", { path = "/x/y" }) end)
    session.cached = real
    assert(#notes == 1 and notes[1].level == vim.log.levels.WARN, vim.inspect(notes))
    assert(notes[1].msg == "pi: the agent is editing outside pi-nvim-feature-long-worktree", notes[1].msg)
    assert_fits(notes)
    -- The waiting notice shortens its wording, then keeps only the continue key.
    notes = capture_notify(function() pi.notify_waiting(12) end)
    assert(notes[1].msg == "pi: checkpoint 12 waiting — <leader>pv look, <leader>pc continue", notes[1].msg)
    assert_fits(notes)
    notes = capture_notify(function() pi.setup({ keys = { send = "<leader>pr" } }) end)
    assert_fits(notes)
  end)
  at_columns(64, function()
    local notes = capture_notify(function() pi.notify_waiting(12) end)
    assert(notes[1].msg == "pi: checkpoint 12 waiting — <leader>pc to continue", notes[1].msg)
  end)
  at_columns(200, function()
    local notes = capture_notify(function() pi.notify_waiting(12) end)
    assert(notes[1].msg == "pi: checkpoint 12 waiting — <leader>pv to look, <leader>pc to continue", notes[1].msg)
  end)
  reset_maps()
end

-- Fires chunk_ready (chunk defaults to an open checkpoint 7) through the handler setup(opts)
-- registers, with the list shown when `visible`; returns the notices, whether the panel opened and
-- whether it was refreshed.
local function chunk_ready_with(opts, chunk, visible)
  local session = require("pi.session")
  local panel = require("pi.panel")
  local handlers = {}
  local real_on = session.on_event
  session.on_event = function(fn) handlers[#handlers + 1] = fn end
  capture_notify(function() pi.setup(opts) end)
  session.on_event = real_on
  local diff = require("pi.diff")
  local saved = { open = panel.open, refresh = panel.refresh, visible = panel.visible, live = require("pi.live").schedule, in_diff = diff.is_diff_window }
  local opened, refreshed = false, false
  diff.is_diff_window = function() return false end
  panel.open = function() opened = true end
  panel.refresh = function() refreshed = true end
  panel.visible = function() return visible == true end
  require("pi.live").schedule = function() end
  local notes = capture_notify(function() handlers[#handlers]("chunk_ready", { chunk = chunk or { n = 7, status = "open" } }) end)
  panel.open, panel.refresh, panel.visible, require("pi.live").schedule = saved.open, saved.refresh, saved.visible, saved.live
  diff.is_diff_window = saved.in_diff
  return notes, opened, refreshed
end

M["a recorded chunk_ready neither opens the list nor says a checkpoint waits"] = function()
  reset_maps()
  local recorded = { n = 3, status = "recorded" }
  local notes, opened = chunk_ready_with(nil, recorded, false)
  assert(not opened and #notes == 0, vim.inspect(notes))
  local refreshed
  notes, opened, refreshed = chunk_ready_with(nil, recorded, true)
  assert(not opened and #notes == 0 and refreshed, vim.inspect(notes))
  notes, opened = chunk_ready_with({ panel = { auto_open = false } }, recorded, false)
  assert(not opened and #notes == 0, vim.inspect(notes))
  -- An open one still opens the list.
  notes, opened = chunk_ready_with(nil, { n = 4, status = "open" }, false)
  assert(opened and #notes == 0, vim.inspect(notes))
  capture_notify(function() pi.setup() end)
  reset_maps()
end

M["chunk_ready opens the checkpoint list unless panel.auto_open is false"] = function()
  reset_maps()
  local notes, opened = chunk_ready_with(nil)
  assert(opened and #notes == 0, vim.inspect(notes))
  notes, opened = chunk_ready_with({ panel = { auto_open = false } })
  assert(not opened, "panel opened with auto_open = false")
  assert(#notes == 1 and notes[1].msg:find("^pi: checkpoint 7 waiting"), vim.inspect(notes))
  capture_notify(function() pi.setup() end)
  reset_maps()
end

M["setup notices legacy key names once"] = function()
  reset_maps()
  local notes = capture_notify(function() pi.setup({ keys = { send = "<leader>pr", cancel = "<leader>px", chunks = "<leader>pl" } }) end)
  local renamed = vim.tbl_filter(function(n) return n.msg:find("setup keys renamed", 1, true) end, notes)
  assert(#renamed == 1 and renamed[1].level == vim.log.levels.INFO, vim.inspect(notes))
  assert(renamed[1].msg == "pi: setup keys renamed — send/cancel → continue/stop, chunks → checkpoints, checkpoints (mode) → mode", renamed[1].msg)
  notes = capture_notify(function() pi.setup() end)
  assert(#vim.tbl_filter(function(n) return n.msg:find("renamed", 1, true) end, notes) == 0)
  reset_maps()
end

-- A file buffer in a fresh directory, current in the window; returns buf and dir.
local function file_in_dir(name, lines)
  local dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  vim.fn.writefile(lines, dir .. "/" .. name)
  vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/" .. name))
  return vim.api.nvim_get_current_buf(), dir
end

M["PiAsk opens the editor titled with file, line or range and session, and sends what is written"] = function()
  reset_maps()
  capture_notify(function() pi.setup() end)
  local session = require("pi.session")
  local buf, dir = file_in_dir("ask.lua", { "a", "b", "c", "d" })
  local saved = { ensure = session.ensure, prompt = pi.prompt, root = session.root, label = session.attached_label }
  local sent = {}
  session.root = dir
  session.attached_label = function() return "refactor-discover" end
  session.ensure = function(cb) cb(nil, dir) end
  pi.prompt = function(text, context) sent[#sent + 1] = { text = text, context = context } end
  local seen, restore = stub_ui(nil, "explain\nthis")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd("PiAsk")
  assert(seen.input.title == " pi ask · ask.lua:2 · refactor-discover ", vim.inspect(seen.input))
  assert(#sent == 1 and sent[1].text == "explain\nthis" and sent[1].context.startLine == 2, vim.inspect(sent))
  vim.cmd("2,4PiAsk")
  assert(seen.input.title == " pi ask · ask.lua:2-4 · refactor-discover ", vim.inspect(seen.input))
  restore()
  -- Cancelled: nothing is sent; without an attached session the label is left out.
  session.attached_label = function() return "" end
  seen, restore = stub_ui(nil, nil)
  vim.cmd("PiAsk")
  restore()
  assert(seen.input.title == " pi ask · ask.lua:2 ", vim.inspect(seen.input))
  assert(#sent == 2, vim.inspect(sent))
  session.ensure, pi.prompt, session.root, session.attached_label = saved.ensure, saved.prompt, saved.root, saved.label
  require("pi.editor").discard_draft("ask") -- pi.prompt was stubbed, so nothing confirmed the send
  vim.api.nvim_buf_delete(buf, { force = true })
  reset_maps()
end

M["PiAnnotate opens the editor titled with file and range and places the written note"] = function()
  annotations.clear()
  local buf, dir = file_in_dir("note.txt", { "a", "b", "c" })
  local seen, restore = stub_ui(nil, "long\nnote")
  capture_notify(function() vim.cmd("1,3PiAnnotate") end)
  restore()
  assert(seen.input.title == " pi note · note.txt:1-3 " and seen.input.text == nil, vim.inspect(seen.input))
  local list = annotations.list(dir)
  assert(#list == 1 and list[1].note == "long\nnote" and list[1].endLine == 3, vim.inspect(list))
  annotations.clear()
  vim.api.nvim_buf_delete(buf, { force = true })
end

M["PiAnnotate with the real editor places the note typed and sent with <C-s>"] = function()
  annotations.clear()
  local buf, dir = file_in_dir("real.txt", { "a", "b", "c" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  capture_notify(function()
    vim.cmd("PiAnnotate")
    vim.api.nvim_feedkeys(vim.keycode("<Cmd><CR>typed note<C-s>"), "xt", false)
  end)
  local list = annotations.list(dir)
  assert(#list == 1 and list[1].note == "typed note" and list[1].startLine == 2, vim.inspect(list))
  annotations.clear()
  vim.api.nvim_buf_delete(buf, { force = true })
end

M["PiAsk with the real editor sends the typed prompt as a request"] = function()
  reset_maps()
  capture_notify(function() pi.setup() end)
  local session = require("pi.session")
  local buf, dir = file_in_dir("realask.lua", { "a", "b" })
  local saved = { ensure = session.ensure, request = session.request, mark_busy = session.mark_busy }
  local sent = {}
  session.ensure = function(cb) cb(nil, dir) end
  session.request = function(method, params, cb)
    sent[#sent + 1] = { method = method, params = params }
    cb(nil, {})
  end
  session.mark_busy = function() end
  vim.cmd("PiAsk")
  vim.api.nvim_feedkeys(vim.keycode("<Cmd><CR>why this?<C-s>"), "xt", false)
  session.ensure, session.request, session.mark_busy = saved.ensure, saved.request, saved.mark_busy
  assert(#sent == 1 and sent[1].method == "prompt" and sent[1].params.text == "why this?", vim.inspect(sent))
  assert(sent[1].params.context.path == "realask.lua", vim.inspect(sent))
  vim.api.nvim_buf_delete(buf, { force = true })
  reset_maps()
end

M["PiAsk resolves the session before opening the editor and keeps the text when sending fails"] = function()
  reset_maps()
  capture_notify(function() pi.setup() end)
  local session = require("pi.session")
  local editor = require("pi.editor")
  local buf, dir = file_in_dir("fail.lua", { "a" })
  local saved = { ensure = session.ensure, request = session.request }
  local opened = false
  local real_open = editor.open
  editor.open = function() opened = true end
  session.ensure = function() end -- no session: ensure reports and never calls back
  vim.cmd("PiAsk")
  editor.open = real_open
  assert(not opened, "editor opened without a session")
  session.ensure = function(cb) cb(nil, dir) end
  session.request = function(_, _, cb) cb("boom") end
  capture_notify(function()
    vim.cmd("PiAsk")
    vim.api.nvim_feedkeys(vim.keycode("<Cmd><CR>precious text<C-s>"), "xt", false)
  end)
  session.request = saved.request
  local notes = capture_notify(function()
    vim.cmd("PiAsk")
  end)
  local text = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert(vim.deep_equal(text, { "precious text" }), vim.inspect(text))
  assert(#notes == 0, vim.inspect(notes))
  vim.api.nvim_feedkeys(vim.keycode("<Cmd><CR><Esc>q"), "xt", false)
  require("pi.editor").discard_draft("ask")
  session.ensure = saved.ensure
  vim.api.nvim_buf_delete(buf, { force = true })
  reset_maps()
end

M["a PiAsk send confirmed late keeps a newer ask draft"] = function()
  reset_maps()
  capture_notify(function() pi.setup() end)
  local session = require("pi.session")
  local editor = require("pi.editor")
  local buf, dir = file_in_dir("late.lua", { "a" })
  local saved = { ensure = session.ensure, request = session.request, mark_busy = session.mark_busy }
  local pending
  session.ensure = function(cb) cb(nil, dir) end
  session.request = function(_, _, cb) pending = cb end
  session.mark_busy = function() end
  capture_notify(function()
    vim.cmd("PiAsk")
    vim.api.nvim_feedkeys(vim.keycode("<Cmd><CR>first<C-s>"), "xt", false)
  end)
  -- While the send is in flight the restored draft is changed and cancelled.
  vim.cmd("PiAsk")
  vim.api.nvim_feedkeys(vim.keycode("<Cmd><CR> and more<Esc>q"), "xt", false)
  pending(nil, {})
  vim.cmd("PiAsk")
  local text = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  vim.api.nvim_feedkeys(vim.keycode("<Cmd><CR><Esc>q"), "xt", false)
  session.ensure, session.request, session.mark_busy = saved.ensure, saved.request, saved.mark_busy
  editor.discard_draft("ask")
  vim.api.nvim_buf_delete(buf, { force = true })
  reset_maps()
  assert(vim.deep_equal(text, { "first and more" }), vim.inspect(text))
end

M["removing an annotation drops its edit draft"] = function()
  annotations.clear()
  local editor = require("pi.editor")
  local buf = file_in_dir("gone.txt", { "a" })
  annotations.add(buf, 1, 1, "note")
  local item = annotations.at_cursor()[1]
  editor.stash("edit:" .. item.id, "half edit")
  annotations.remove(item)
  local got
  editor.open({ title = " x ", draft = "edit:" .. item.id, on_submit = function() end })
  got = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  vim.api.nvim_feedkeys(vim.keycode("<Cmd><CR><Esc>q"), "xt", false)
  editor.discard_draft("edit:" .. item.id)
  annotations.clear()
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(vim.deep_equal(got, { "" }), vim.inspect(got))
end

M["a PiAsk send leaves a cancelled PiAnnotate draft alone"] = function()
  reset_maps()
  capture_notify(function() pi.setup() end)
  local session = require("pi.session")
  local editor = require("pi.editor")
  local buf, dir = file_in_dir("keep.lua", { "a" })
  local saved = { ensure = session.ensure, request = session.request, mark_busy = session.mark_busy }
  editor.stash("note", "half a note")
  session.ensure = function(cb) cb(nil, dir) end
  session.request = function(_, _, cb) cb(nil) end
  session.mark_busy = function() end
  capture_notify(function()
    vim.cmd("PiAsk")
    vim.api.nvim_feedkeys(vim.keycode("<Cmd><CR>question<C-s>"), "xt", false)
  end)
  session.ensure, session.request, session.mark_busy = saved.ensure, saved.request, saved.mark_busy
  capture_notify(function() vim.cmd("PiAnnotate") end)
  local text = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert(vim.deep_equal(text, { "half a note" }), vim.inspect(text))
  vim.api.nvim_feedkeys(vim.keycode("<Cmd><CR><Esc><C-s>"), "xt", false)
  editor.discard_draft("note")
  vim.api.nvim_buf_delete(buf, { force = true })
  reset_maps()
end

M["editor titles call an unnamed buffer [No Name]"] = function()
  local session = require("pi.session")
  local real_ensure = session.ensure
  session.ensure = function(cb) cb(nil, vim.uv.cwd()) end
  vim.cmd("enew")
  local seen, restore = stub_ui(nil, nil)
  vim.cmd("PiAsk")
  restore()
  session.ensure = real_ensure
  assert(seen.input.title:find("[No Name]:1", 1, true), seen.input.title)
  vim.cmd("bwipeout!")
end

-- The floating windows of the current tab.
local function floats()
  return vim.tbl_filter(function(w)
    return vim.api.nvim_win_get_config(w).relative ~= ""
  end, vim.api.nvim_tabpage_list_wins(0))
end

local function float_lines()
  local wins = floats()
  assert(#wins == 1, "floats: " .. #wins)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(wins[1]), 0, -1, false)
end

M["PiPeek from a narrow window is sized from the editor, breaks only at spaces and stays on screen"] = function()
  annotations.clear()
  vim.cmd("tabnew")
  local saved = vim.o.columns
  vim.o.columns = 80
  local buf = file_in_dir("narrow.txt", { "a", "b", "c" })
  vim.cmd("vsplit")
  vim.cmd("vertical resize 20")
  local note = "call discover.collect(root) from session.lua then move nvim/lua/pi/session.lua " .. ("word "):rep(30) .. "end"
  annotations.add(buf, 2, 2, note)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd("PiPeek")
  local win = floats()[1]
  local width = vim.api.nvim_win_get_width(win)
  local config = vim.api.nvim_win_get_config(win)
  local lines = float_lines()
  local ok, err = pcall(function()
    assert(width > 20 and width <= 76, "width " .. width)
    assert(not vim.wo[win].wrap, "the float wraps itself")
    for _, line in ipairs(lines) do
      assert(vim.fn.strdisplaywidth(line) <= width, line)
    end
    local joined = table.concat(lines, "\n")
    for _, word in ipairs({ "discover.collect(root)", "session.lua", "nvim/lua/pi/session.lua" }) do
      assert(joined:find(word, 1, true), "word broken: " .. word .. "\n" .. joined)
    end
    local pos = vim.api.nvim_win_get_position(win)
    assert(pos[2] >= 0 and pos[2] + width + 2 <= vim.o.columns, vim.inspect({ pos, width, config }))
  end)
  vim.api.nvim_win_close(win, true)
  vim.o.columns = saved
  annotations.clear()
  vim.api.nvim_buf_delete(buf, { force = true })
  pcall(vim.cmd, "tabclose")
  assert(ok, err)
end

M["PiPeek shows every full annotation of the line in a wrapping float that closes on cursor move"] = function()
  annotations.clear()
  local long = ("word "):rep(60) .. "end"
  vim.cmd("tabnew") -- earlier specs may leave a checkpoint diff tab current
  local buf = file_in_dir("peek.txt", { "a", "b", "c" })
  annotations.add(buf, 2, 2, long)
  annotations.add(buf, 1, 3, "second\nparagraph")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd("PiPeek")
  local win = floats()[1]
  local text = table.concat(float_lines(), "\n")
  assert(text:gsub("%s+", " "):find(long, 1, true) and text:find("second\nparagraph", 1, true), text)
  -- Pre-wrapped at spaces, so nvim never breaks a word: the float itself does not wrap.
  assert(not vim.wo[win].wrap and vim.api.nvim_win_get_width(win) <= 80, vim.api.nvim_win_get_width(win))
  assert(vim.api.nvim_get_current_win() ~= win, "peek took focus")
  -- A second peek focuses the float, where <Esc> closes it.
  vim.cmd("PiPeek")
  assert(vim.api.nvim_get_current_win() == win, "second peek did not focus the float")
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
  assert(vim.wait(500, function() return #floats() == 0 end, 10), "<Esc> did not close the peek")
  vim.cmd("PiPeek")
  -- Headless nvim fires CursorMoved only while waiting for typed keys, so fire it by hand.
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  vim.wait(500, function() return #floats() == 0 end, 10)
  assert(#floats() == 0, "peek did not close on cursor move")
  -- Nothing to peek on a line without annotations, outside a checkpoint diff.
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "d" })
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  local notes = capture_notify(function() vim.cmd("PiPeek") end)
  assert(#notes == 1 and notes[1].msg == "pi: nothing to peek here" and #floats() == 0, vim.inspect(notes))
  annotations.clear()
  vim.api.nvim_buf_delete(buf, { force = true })
  pcall(vim.cmd, "tabclose")
end

M["no session notice names the worktree and the next step"] = function()
  local session = require("pi.session")
  local dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  assert(vim.system({ "git", "init", "-q" }, { cwd = dir }):wait().code == 0)
  vim.fn.writefile({ "x" }, dir .. "/a.txt")
  local old_env = vim.env.XDG_RUNTIME_DIR
  vim.env.XDG_RUNTIME_DIR = dir .. "/run"
  local buf = vim.fn.bufadd(dir .. "/a.txt")
  vim.fn.bufload(buf)
  local notes = capture_notify(function()
    session.ensure(function() error("must not attach") end, { buf = buf })
    session.choose()
  end)
  vim.env.XDG_RUNTIME_DIR = old_env
  local want = "pi: no pi session for " .. vim.fs.basename(dir) .. " — start pi in that worktree"
  assert(#notes >= 1 and notes[1].msg == want and notes[1].level == vim.log.levels.ERROR, vim.inspect(notes))
  vim.api.nvim_buf_delete(buf, { force = true })
end

M["setup remembers the keys it skipped"] = function()
  local keys_state = require("pi.keys")
  reset_maps()
  vim.keymap.set("n", "<leader>pn", "<cmd>echo 'mine'<CR>", { desc = "mine" })
  capture_notify(function() pi.setup() end)
  assert(vim.deep_equal(keys_state.skipped, { "<leader>pn (n)" }), vim.inspect(keys_state.skipped))
  reset_maps()
  capture_notify(function() pi.setup() end)
  assert(vim.deep_equal(keys_state.skipped, {}), vim.inspect(keys_state.skipped))
  reset_maps()
end

local function with_which_key(stub, fn)
  local saved = package.loaded["which-key"]
  local saved_preload = package.preload["which-key"]
  package.loaded["which-key"] = stub
  if stub == nil then
    package.preload["which-key"] = nil
  end
  local ok, err = pcall(fn)
  package.loaded["which-key"] = saved
  package.preload["which-key"] = saved_preload
  assert(ok, err)
end

M["which-key: setup registers the pi group under the keys' common prefix"] = function()
  reset_maps()
  local added = {}
  with_which_key({ add = function(spec) added[#added + 1] = spec end }, function()
    capture_notify(function() pi.setup() end)
  end)
  assert(#added == 1 and vim.deep_equal(added[1], { { "<leader>p", group = "pi" } }), vim.inspect(added))
  -- Custom keys sharing another prefix get that prefix; keys with nothing in common get no group.
  added = {}
  local custom = {}
  for name in pairs(pi.default_keys) do custom[name] = "<leader>r" .. name:sub(1, 2) end
  custom.ask, custom.annotate = "<leader>raa", "<leader>rab"
  with_which_key({ add = function(spec) added[#added + 1] = spec end }, function()
    capture_notify(function() pi.setup({ keys = custom }) end)
  end)
  assert(#added == 1 and added[1][1][1] == "<leader>r", vim.inspect(added))
  added = {}
  with_which_key({ add = function(spec) added[#added + 1] = spec end }, function()
    capture_notify(function() pi.setup({ keys = { ask = "<C-a>", continue = "<C-b>", stop = false, annotate = false, edit = false, remove = false, checkpoints = false, mode = false, session = false, peek = false, follow = false } }) end)
  end)
  assert(#added == 0, vim.inspect(added))
  -- A single mapped key is a key, not a group.
  added = {}
  with_which_key({ add = function(spec) added[#added + 1] = spec end }, function()
    capture_notify(function() pi.setup({ keys = { ask = "<leader>pa", continue = false, stop = false, annotate = false, edit = false, remove = false, checkpoints = false, mode = false, session = false, peek = false, follow = false } }) end)
  end)
  assert(#added == 0, vim.inspect(added))
  for _, lhs in ipairs({ "<C-a>", "<C-b>" }) do pcall(vim.keymap.del, "n", lhs) end
  reset_maps()
  for _, lhs in ipairs({ "<leader>raa", "<leader>rab" }) do pcall(vim.keymap.del, "n", lhs); pcall(vim.keymap.del, "x", lhs) end
end

M["which-key: absent, without add, or failing never breaks setup"] = function()
  reset_maps()
  with_which_key(nil, function()
    assert(#capture_notify(function() pi.setup() end) == 0)
  end)
  with_which_key({}, function()
    assert(#capture_notify(function() pi.setup() end) == 0)
  end)
  with_which_key({ add = function() error("boom") end }, function()
    assert(#capture_notify(function() pi.setup() end) == 0)
  end)
  reset_maps()
end

-- A git worktree with one file; returns its real path.
local function git_root(name)
  local d = vim.fn.tempname() .. name
  vim.fn.mkdir(d, "p")
  d = vim.uv.fs_realpath(d)
  vim.system({ "git", "init", "-q", d }):wait()
  vim.fn.writefile({ "x" }, d .. "/f.txt")
  return d
end

-- Two fake pi sessions ("one", "two") in `root`; returns a restore function and the requests seen.
local function fake_sessions(root)
  local session = require("pi.session")
  local client, discover = require("pi.client"), require("pi.discover")
  local real = { sockets = discover.sockets, connect = client.connect }
  local requests = {}
  discover.sockets = function() return { root .. "/one.sock", root .. "/two.sock" } end
  client.connect = function(path)
    local id = vim.fs.basename(path):gsub("%.sock$", "")
    return {
      closed = false,
      close = function(self) self.closed = true end,
      request = function(_, type, _, cb)
        requests[#requests + 1] = id .. " " .. type
        if not cb then return end
        if type == "status" then
          cb(nil, { root = root, name = id, sessionId = id, drafts = {} })
        elseif type == "list_chunks" then
          cb(nil, { { n = 1, status = "open", note = "add a", fromSha = "a", toSha = "b", agentFiles = { "f.txt" }, humanFiles = {}, annotations = {} } })
        else
          cb(nil, {})
        end
      end,
    }
  end
  return function()
    session.detach()
    discover.sockets, client.connect = real.sockets, real.connect
  end, requests
end

M["review: \"not here\" when neither the cwd nor the current file is in root"] = function()
  local root, elsewhere = git_root("rv-a"), git_root("rv-b")
  local cwd = vim.uv.cwd()
  vim.cmd("enew")
  vim.cmd("cd " .. vim.fn.fnameescape(elsewhere))
  local restore, requests = fake_sessions(root)
  local ok, err = pcall(function()
    assert(pi.review(root, "two") == "not here")
    vim.cmd("edit " .. vim.fn.fnameescape(elsewhere .. "/f.txt"))
    assert(pi.review(root, "two") == "not here", "a file of another worktree is open")
    vim.wait(50)
    assert(#requests == 0, vim.inspect(requests))
  end)
  restore()
  vim.cmd("cd " .. vim.fn.fnameescape(cwd))
  vim.cmd("enew")
  assert(ok, err)
end

M["review: a nested worktree inside root is not root"] = function()
  local root = git_root("rv-n")
  local nested = root .. "/nested"
  vim.fn.mkdir(nested, "p")
  vim.system({ "git", "init", "-q", nested }):wait()
  vim.fn.writefile({ "x" }, nested .. "/g.txt")
  nested = vim.uv.fs_realpath(nested)
  local cwd = vim.uv.cwd()
  vim.cmd("enew")
  vim.cmd("cd " .. vim.fn.fnameescape(nested))
  local restore, requests = fake_sessions(root)
  local ok, err = pcall(function()
    assert(pi.review(root, "two") == "not here", "cwd in a nested worktree matched the main repo")
    vim.cmd("edit " .. vim.fn.fnameescape(nested .. "/g.txt"))
    vim.cmd("cd " .. vim.fn.fnameescape(git_root("rv-m")))
    assert(pi.review(root, "two") == "not here", "a file of a nested worktree matched the main repo")
    vim.wait(50)
    assert(#requests == 0, vim.inspect(requests))
  end)
  restore()
  vim.cmd("cd " .. vim.fn.fnameescape(cwd))
  vim.cmd("enew")
  assert(ok, err)
end

M["toggle_mode: turns the repo mode off when this session can't be reviewed"] = function()
  local session = require("pi.session")
  local real = session.request
  local sent = {}
  session.request = function(type, payload, cb)
    sent[#sent + 1] = type .. (payload and payload.mode and (" " .. payload.mode) or "")
    if type == "status" then
      cb(nil, { mode = "off", modeNote = "checkpoint mode is on for this repo, but this session can't stop for review" })
    else
      cb(nil, { mode = "off" })
    end
  end
  local ok, err = pcall(function()
    capture_notify(function() pi.toggle_mode() end)
  end)
  session.request = real
  assert(ok, err)
  assert(vim.deep_equal(sent, { "status", "set_mode off", "status" }) or vim.deep_equal(sent, { "status", "set_mode off" }), vim.inspect(sent))
end

M["statusline says checkpoints are unavailable when the session can't be reviewed"] = function()
  local session = require("pi.session")
  local real = { connected = session.connected, cached = session.cached }
  session.connected = function() return true end
  session.cached = { name = "x", mode = "off", modeNote = "checkpoint mode is on for this repo, but this session can't stop for review" }
  local line = pi.statusline()
  session.connected, session.cached = real.connected, real.cached
  assert(line == "pi: x [checkpoints unavailable here] · idle", line)
end

M["review: in root it attaches to exactly that session and opens the checkpoint list"] = function()
  local session, panel = require("pi.session"), require("pi.panel")
  local root = git_root("rv-c")
  local cwd = vim.uv.cwd()
  local elsewhere = git_root("rv-e")
  vim.cmd("only")
  -- The cwd is elsewhere; the current file in root is enough.
  vim.cmd("cd " .. vim.fn.fnameescape(elsewhere))
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/f.txt"))
  local restore = fake_sessions(root)
  local ok, err = pcall(function()
    local notes = capture_notify(function()
      assert(pi.review(root, "two") == "ok")
      vim.wait(1000, function() return panel.visible() end)
    end)
    assert(panel.visible(), "panel not open")
    assert(session.connected() and session.cached.sessionId == "two", vim.inspect(session.cached))
    assert(#notes == 0, vim.inspect(notes))
    -- Already attached to "two": asking for "one" moves the attachment there.
    assert(pi.review(root, "one") == "ok")
    vim.wait(1000, function() return session.cached and session.cached.sessionId == "one" end)
    assert(session.cached.sessionId == "one", vim.inspect(session.cached))
  end)
  panel.close()
  restore()
  vim.cmd("cd " .. vim.fn.fnameescape(cwd))
  vim.cmd("enew")
  assert(ok, err)
end

M["review: a session id not running in root says so"] = function()
  local root = git_root("rv-d")
  local cwd = vim.uv.cwd()
  vim.cmd("enew")
  vim.cmd("cd " .. vim.fn.fnameescape(root))
  local restore = fake_sessions(root)
  local ok, err = pcall(function()
    local notes = capture_notify(function(collected)
      assert(pi.review(root, "gone") == "ok")
      vim.wait(2000, function() return #collected > 0 end, 10)
      -- Nothing else follows the one notice.
      vim.wait(50, function() return false end)
    end)
    assert(#notes == 1 and notes[1].msg:find("no pi session gone", 1, true), vim.inspect(notes))
  end)
  restore()
  vim.cmd("cd " .. vim.fn.fnameescape(cwd))
  assert(ok, err)
end

return M
