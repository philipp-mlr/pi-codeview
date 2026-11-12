local session = require("pi.session")
local diff = require("pi.diff")
local panel = require("pi.panel")
local keys_state = require("pi.keys")

local M = {}

local NOTE = "Added the parser and wired it into the loader. It reads every file once and caches the result for later runs of the tool."

local function chunk(n, status, extra)
  return vim.tbl_extend("force", {
    n = n, status = status, note = "note " .. n, fromSha = "a", toSha = "b",
    agentFiles = { "a.txt", "b.txt" }, humanFiles = {}, annotations = {},
  }, extra or {})
end

-- Opens the panel against a stubbed session; returns its buffer and window.
local function open_panel(list, get_chunk)
  vim.o.columns = 200
  vim.cmd("only")
  vim.cmd("enew")
  session.ensure = function(cb) cb() end
  session.request = function(type, payload, cb)
    if type == "list_chunks" then
      cb(nil, list)
    else
      cb(nil, get_chunk and get_chunk(payload.n) or { chunk = list[1], stats = {} })
    end
  end
  if panel.visible() then panel.close() end
  panel.open()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if panel.is_panel_window(win) then
      vim.api.nvim_set_current_win(win)
      return vim.api.nvim_win_get_buf(win), win
    end
  end
  error("panel not visible")
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

M["panel: help line, filetype and width"] = function()
  keys_state.mapped = { continue = "<leader>pc" }
  local buf, win = open_panel({})
  assert(vim.bo[buf].filetype == "pi-checkpoints")
  assert(vim.api.nvim_win_get_width(win) == 60, vim.api.nvim_win_get_width(win))
  local l = lines(buf)
  assert(l[1] == "pi checkpoints — <CR> open · za details · a all · <leader>pc continue", l[1])
  assert(l[2] == "no checkpoints yet", l[2])
  keys_state.mapped = {}
  buf = open_panel({})
  assert(lines(buf)[1]:find("a all · :PiContinue continue", 1, true), lines(buf)[1])
end

M["panel: open checkpoint first, then newest first, title falls back to the note's first sentence"] = function()
  local list = {
    chunk(1, "recorded"),
    chunk(2, "discarded", { title = "Second" }),
    chunk(3, "reviewed", { note = "Added parser. " .. NOTE }),
    chunk(4, "open", { title = "Fourth", agentFiles = { "a.txt" } }),
    chunk(5, "reviewed", { title = "Fifth" }),
  }
  local buf = open_panel(list)
  local l = lines(buf)
  assert(#l == 5, vim.inspect(l)) -- help + 4, recorded hidden
  assert(l[2] == "● 4  waiting   Fourth   1 file", l[2])
  assert(l[3]:match("^✓ 5  reviewed  Fifth%s+2 files$"), l[3])
  assert(l[4]:match("^✓ 3  reviewed  Added parser%.%s+2 files$"), l[4])
  assert(l[5]:match("^✗ 2  discarded Second%s+2 files$"), l[5])
  for i = 2, #l do assert(vim.fn.strdisplaywidth(l[i]) <= 60, l[i]) end
  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
  local groups = {}
  for _, m in ipairs(marks) do groups[m[2]] = m[4].line_hl_group   local long = open_panel({ chunk(1, "reviewed", { title = ("x"):rep(60) }) })
  local row = lines(long)[2]
  assert(vim.fn.strdisplaywidth(row) <= 60 and row:find("…", 1, true), row)
end
  assert(groups[0] == "Comment" and groups[1] == "PiCheckpointWaiting" and groups[2] == nil, vim.inspect(groups))
end

M["panel: recorded checkpoints are hidden until a is pressed"] = function()
  local buf = open_panel({ chunk(1, "recorded"), chunk(2, "reviewed") })
  assert(#lines(buf) == 2)
  press("a")
  local l = lines(buf)
  assert(#l == 3 and l[3]:match("^· 1  recorded"), vim.inspect(l))
  press("a")
  assert(#lines(buf) == 2)
end

M["panel: za expands note, files with counts and annotations, and collapses again"] = function()
  local list = {
    chunk(1, "reviewed", {
      note = NOTE,
      annotations = { { path = "a.txt", startLine = 2, endLine = 4, note = "why this?" } },
    }),
  }
  local buf = open_panel(list, function()
    return { chunk = list[1], stats = { { path = "a.txt", added = 3, removed = 1 }, { path = "b.txt", added = 0, removed = 7 } } }
  end)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  press("za")
  local l = lines(buf)
  assert(l[3]:match("^    Added the parser"), vim.inspect(l))
  local first_file
  for i, line in ipairs(l) do
    assert(i == 1 or vim.fn.strdisplaywidth(line) <= 60, line)
    if line == "    a.txt  +3 −1" then first_file = i end
  end
  assert(first_file, vim.inspect(l))
  assert(l[first_file + 1] == "    b.txt  +0 −7", vim.inspect(l))
  assert(l[first_file + 2] == "    ✎ L2-4 a.txt: why this?", vim.inspect(l))
  assert(#l == first_file + 2, vim.inspect(l))
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  press("za")
  assert(#lines(buf) == 2, vim.inspect(lines(buf)))
end

M["panel: za shows … while the counts load"] = function()
  local list = { chunk(1, "reviewed") }
  local pending
  local buf = open_panel(list)
  session.request = function(_, _, cb) pending = cb end
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  press("za")
  assert(lines(buf)[4] == "    a.txt  …", vim.inspect(lines(buf)))
  pending(nil, { chunk = list[1], stats = { { path = "a.txt", added = 1, removed = 2 }, { path = "b.txt", added = 0, removed = 0 } } })
  assert(lines(buf)[4] == "    a.txt  +1 −2", vim.inspect(lines(buf)))
end

M["panel: <CR> on a checkpoint line opens it, on a file line opens it at that file"] = function()
  local list = { chunk(1, "reviewed") }
  local buf = open_panel(list)
  local opened = {}
  local original = diff.open
  diff.open = function(n, path) opened[#opened + 1] = { n, path } end
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  press("<CR>")
  press("za")
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  assert(lines(buf)[4]:match("b%.txt") or lines(buf)[4]:match("a%.txt"), vim.inspect(lines(buf)))
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  press("<CR>")
  diff.open = original
  assert(vim.deep_equal(opened[1], { 1, nil }), vim.inspect(opened))
  assert(opened[2][1] == 1 and opened[2][2] == "b.txt", vim.inspect(opened))
end

M["panel: <CR> on a file line opens the built-in view at that file"] = function()
  vim.cmd("only")
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local function sh(...) assert(vim.system({ "git", "-C", root, ... }, { text = true }):wait().code == 0) end
  sh("init", "-q")
  sh("config", "user.email", "t@t")
  sh("config", "user.name", "t")
  vim.fn.writefile({ "one" }, root .. "/a.txt")
  vim.fn.writefile({ "two" }, root .. "/b.txt")
  sh("add", ".")
  sh("commit", "-q", "-m", "init")
  local sha = vim.trim(vim.system({ "git", "-C", root, "rev-parse", "HEAD" }, { text = true }):wait().stdout)
  session.root = vim.uv.fs_realpath(root)
  session.cached = { sessionId = "s1" }
  diff.mode = "builtin"
  local c = chunk(1, "open", { fromSha = sha })
  local buf = open_panel({ c }, function() return { chunk = c, stats = { { path = "a.txt", added = 1, removed = 0 }, { path = "b.txt", added = 1, removed = 0 } } } end)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  press("za")
  local row
  for i, line in ipairs(lines(buf)) do
    if line:match("^    b%.txt") then row = i end
  end
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  press("<CR>")
  assert(vim.wo.winbar:find("2/2", 1, true) and vim.wo.winbar:find("b.txt", 1, true), vim.wo.winbar)
  vim.cmd("tabclose")
  diff.cleanup()
end

return M
