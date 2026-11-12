local pi = require("pi")
local annotations = require("pi.annotations")

local M = {}

local KEYS = { "<leader>pa", "<leader>ps", "<leader>pn", "<leader>px", "<leader>pe", "<leader>pi", "<leader>pv", "<leader>pm", "<leader>pc", "<leader>pk" }

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
    continue = "<leader>pc",
    stop = "<leader>ps",
    annotate = "<leader>pn",
    edit = "<leader>pe",
    remove = "<leader>px",
    checkpoints = "<leader>pv",
    mode = "<leader>pm",
    session = "<leader>pi",
    peek = "<leader>pk",
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
  }
  for _, w in ipairs(want) do
    local desc = vim.fn.maparg(w[2], w[1], false, true).desc
    assert(desc == w[3], ("%s (%s): %s"):format(w[2], w[1], tostring(desc)))
  end
  for _, name in ipairs({ "PiAsk", "PiContinue", "PiStop", "PiAnnotate", "PiAnnotationEdit", "PiAnnotationRemove", "PiCheckpoints", "PiCheckpointMode", "PiSession", "PiPeek" }) do
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
  assert(vim.api.nvim_get_hl(0, { name = "PiAnnotation" }).link == "DiagnosticInfo")
  assert(vim.api.nvim_get_hl(0, { name = "PiLive" }).link == "CursorLine")
  assert(vim.api.nvim_get_hl(0, { name = "PiLiveSignAdd" }).link == "DiagnosticHint")
  assert(vim.api.nvim_get_hl(0, { name = "PiLiveSignChange" }).link == "DiagnosticInfo")
  assert(vim.api.nvim_get_hl(0, { name = "PiLiveSignDelete" }).link == "DiagnosticWarn")
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
    if cb then cb(nil, { openChunk = open_chunk }) end
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
  assert(#notes == 1 and notes[1].msg == "pi: continuing — checkpoint 4 reviewed", vim.inspect(notes))
end

M["continue with a checkpoint open and annotations counts them and clears them"] = function()
  local notes, requests, remaining = continue_with({ n = 4 }, 1)
  assert(#requests[1].payload.annotations == 1 and requests[1].payload.note == "", vim.inspect(requests))
  assert(notes[1].msg == "pi: continuing — checkpoint 4 reviewed with 1 annotation", vim.inspect(notes))
  assert(remaining == 0, "annotations not cleared")
  notes = continue_with({ n = 5 }, 2)
  assert(notes[1].msg == "pi: continuing — checkpoint 5 reviewed with 2 annotations", vim.inspect(notes))
end

M["continue without a checkpoint sends annotations as a prompt, or says nothing to send"] = function()
  local notes, requests = continue_with(nil, 2)
  assert(#requests == 1 and #requests[1].payload.annotations == 2, vim.inspect(requests))
  assert(#notes == 1 and notes[1].msg == "pi: 2 annotations sent", vim.inspect(notes))
  notes = continue_with(nil, 1)
  assert(notes[1].msg == "pi: 1 annotation sent", vim.inspect(notes))
  notes, requests = continue_with(nil, 0)
  assert(#requests == 0 and #notes == 1 and notes[1].msg == "pi: nothing to send", vim.inspect(notes))
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
  assert(line == "pi: x [checkpoints] · checkpoint 3", line)
  assert(short == "checkpoint 3", short)
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
  assert(notes[1].msg == "pi: the agent is editing files outside /work/a — checkpoint mode can't show them; start pi in that worktree", notes[1].msg)
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
  assert(text:find(long, 1, true) and text:find("second\nparagraph", 1, true), text)
  assert(vim.wo[win].wrap and vim.api.nvim_win_get_width(win) <= 80, vim.api.nvim_win_get_width(win))
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

return M
