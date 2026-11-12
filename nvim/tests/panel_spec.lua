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
local function open_panel(list, get_chunk, columns)
  vim.o.columns = columns or 200
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

-- Runs the WinResized autocmds of `group` as nvim would after `windows` changed size; headless
-- `-l` runs have no main loop, so nvim itself never fires WinResized here.
local function win_resized(group, windows)
  local real = vim.v
  vim.v = { event = { windows = windows } }
  local ok, err = pcall(function()
    for _, au in ipairs(vim.api.nvim_get_autocmds({ group = group, event = "WinResized" })) do
      au.callback({})
    end
  end)
  vim.v = real
  assert(ok, err)
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

M["panel: help line, filetype, buffer name and width"] = function()
  local buf, win = open_panel({})
  assert(vim.bo[buf].filetype == "pi-checkpoints")
  assert(vim.api.nvim_buf_get_name(buf) == "pi://checkpoints", vim.api.nvim_buf_get_name(buf))
  assert(vim.api.nvim_win_get_width(win) == 60, vim.api.nvim_win_get_width(win))
  local l = lines(buf)
  assert(l[1] == " pi checkpoints — <CR> open · za more · g? keys", l[1])
  assert(l[2] == "no checkpoints yet", l[2])
end

M["panel: window options leave the whole width to text"] = function()
  local _, win = open_panel({})
  local wo = vim.wo[win]
  assert(wo.signcolumn == "no" and wo.foldcolumn == "0" and not wo.number and not wo.relativenumber, vim.inspect({ wo.signcolumn, wo.foldcolumn, wo.number }))
  assert(wo.cursorline and wo.winfixwidth, "cursorline/winfixwidth not set")
  assert(vim.fn.getwininfo(win)[1].textoff == 0, vim.fn.getwininfo(win)[1].textoff)
end

M["panel: width is 35% of the columns, between 40 and 60"] = function()
  for columns, want in pairs({ [200] = 60, [120] = 42, [100] = 40 }) do
    local _, win = open_panel({}, nil, columns)
    local width = vim.api.nvim_win_get_width(win)
    assert(width == want, columns .. " columns: width " .. tostring(width))
  end
  vim.o.columns = 200
end

M["panel: help line drops its prefix, then cuts with … to fit"] = function()
  local buf, win = open_panel({}, nil, 120)
  assert(lines(buf)[1] == " <CR> open · za more · g? keys", lines(buf)[1])
  vim.api.nvim_win_set_width(win, 20)
  win_resized("PiPanelResize", { win })
  local help = lines(buf)[1]
  assert(vim.fn.strdisplaywidth(help) == 20 and vim.endswith(help, "…") and vim.startswith(help, " <CR> open"), help)
  vim.o.columns = 200
end

M["panel: rows and details fit the text width, also with a sign column"] = function()
  local list = { chunk(1, "reviewed", { title = ("x"):rep(80), note = NOTE }) }
  local buf, win = open_panel(list)
  vim.wo[win].signcolumn = "yes:2"
  vim.api.nvim_win_set_width(win, 45)
  win_resized("PiPanelResize", { win })
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  press("za")
  local room = 45 - vim.fn.getwininfo(win)[1].textoff
  assert(room == 41, room)
  for _, line in ipairs(lines(buf)) do
    assert(vim.fn.strdisplaywidth(line) <= room, line)
  end
end

M["panel: VimResized resizes the panel to the new columns"] = function()
  local _, win = open_panel({})
  vim.o.columns = 120
  vim.api.nvim_exec_autocmds("VimResized", {})
  assert(vim.api.nvim_win_get_width(win) == 42, vim.api.nvim_win_get_width(win))
  vim.o.columns = 200
end

M["panel: g? lists every key in a float that q and <Esc> close"] = function()
  keys_state.mapped = { continue = "<leader>pc", peek = "<leader>pk" }
  local _, win = open_panel({})
  for _, close in ipairs({ "q", "<Esc>" }) do
    vim.api.nvim_set_current_win(win)
    press("g?")
    local float = vim.api.nvim_get_current_win()
    local cfg = vim.api.nvim_win_get_config(float)
    assert(cfg.relative ~= "" and cfg.title, vim.inspect(cfg))
    assert(vim.deep_equal(cfg.border, { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }), vim.inspect(cfg.border))
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    for _, key in ipairs({ "<CR>", "za", "a", "r", "q", "g?", "<leader>pc", "<leader>pk" }) do
      assert(text:find("\n" .. vim.pesc(key) .. " ") or text:find("^" .. vim.pesc(key) .. " "), key .. " missing:\n" .. text)
    end
    for _, w in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      assert(vim.fn.strdisplaywidth(w) <= cfg.width, w)
    end
    press(close)
    assert(not vim.api.nvim_win_is_valid(float), close .. " did not close the help")
    assert(vim.api.nvim_get_current_win() == win)
  end
  keys_state.mapped = {}
  press("g?")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(text:find(":PiContinue", 1, true) and text:find(":PiPeek", 1, true), text)
  press("q")
end

M["panel: a without recorded turns says so"] = function()
  local buf = open_panel({ chunk(2, "reviewed") })
  local notes, notify = {}, vim.notify
  vim.notify = function(msg) notes[#notes + 1] = msg end
  press("a")
  vim.notify = notify
  assert(vim.deep_equal(notes, { "pi: no recorded turns" }), vim.inspect(notes))
  assert(#lines(buf) == 2)
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
  assert(l[2] == "● 4 waiting  Fourth  1 file", l[2])
  assert(l[3] == "✓ 5 reviewed  Fifth  2 files", l[3])
  assert(l[4] == "✓ 3 reviewed  Added parser.  2 files", l[4])
  assert(l[5] == "✗ 2 discarded  Second  2 files", l[5])
  for i = 2, #l do assert(vim.fn.strdisplaywidth(l[i]) <= 60, l[i]) end
  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
  local groups = {}
  for _, m in ipairs(marks) do groups[m[2]] = m[4].line_hl_group end
  assert(groups[0] == "Comment" and groups[1] == "PiCheckpointWaitingRow" and groups[2] == nil, vim.inspect(groups))
  -- At 42 columns the title gets everything but the icon, number, status and count (20 cells).
  vim.o.columns = 120
  local narrow = open_panel({ chunk(1, "open", { title = "Extract session discovery into discover.lua" }) }, nil, 120)
  vim.api.nvim_win_set_width(vim.fn.bufwinid(narrow), 42)
  panel.refresh()
  local row = lines(narrow)[2]
  assert(row == "● 1 waiting  Extract session dis…  2 files", row)
  local long = open_panel({ chunk(1, "reviewed", { title = ("x"):rep(60) }) })
  row = lines(long)[2]
  assert(vim.fn.strdisplaywidth(row) <= 60 and row:find("…", 1, true), row)
end

M["panel: recorded checkpoints are hidden until a is pressed"] = function()
  local buf = open_panel({ chunk(1, "recorded"), chunk(2, "reviewed") })
  assert(#lines(buf) == 2)
  press("a")
  local l = lines(buf)
  assert(#l == 3 and l[3]:match("^· 1 recorded  "), vim.inspect(l))
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

M["panel: files only you changed show (you), agent files keep counts"] = function()
  local list = { chunk(1, "reviewed", { agentFiles = { "a.txt", "b.txt" }, humanFiles = { "b.txt", "c.txt" } }) }
  local buf = open_panel(list, function()
    return { chunk = list[1], stats = { { path = "a.txt", added = 0, removed = 0 }, { path = "b.txt", added = 2, removed = 1 }, { path = "c.txt", added = 4, removed = 4 } } }
  end)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  press("za")
  local l = lines(buf)
  assert(l[4] == "    a.txt  +0 −0", vim.inspect(l))
  assert(l[5] == "    b.txt  +2 −1", vim.inspect(l))
  assert(l[6] == "    c.txt  (you)", vim.inspect(l))
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

M["panel: a failed get_chunk shows ? for the counts"] = function()
  local list = { chunk(1, "reviewed") }
  local buf = open_panel(list)
  local notified = vim.notify
  vim.notify = function() end
  session.request = function(_, _, cb) cb("boom") end
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  press("za")
  vim.notify = notified
  local l = lines(buf)
  assert(l[4] == "    a.txt  ?" or l[3] == "    a.txt  ?", vim.inspect(l))
  for _, line in ipairs(l) do assert(not line:find("+0 −0", 1, true), line) end
end

M["panel: refresh keeps details and the cursor's checkpoint, drops stats of changed ones"] = function()
  local list = { chunk(1, "reviewed"), chunk(2, "reviewed"), chunk(3, "open") }
  local requested = {}
  local buf = open_panel(list, function(n)
    requested[#requested + 1] = n
    return { chunk = list[1], stats = { { path = "a.txt", added = n, removed = 0 } } }
  end)
  -- order: 3 open, 2, 1. Expand 1, then 2.
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  press("za")
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  press("za")
  assert(lines(buf)[5]:match("a%.txt  %+2 −0"), vim.inspect(lines(buf)))
  -- a new checkpoint arrives and 3 is reviewed: 2 and 1 stay expanded, cursor stays on checkpoint 2's detail line
  local next_list = { chunk(1, "reviewed"), chunk(2, "reviewed"), chunk(3, "reviewed"), chunk(4, "open") }
  local stub = session.request
  session.request = function(type, payload, cb)
    if type == "list_chunks" then cb(nil, next_list) else stub(type, payload, cb) end
  end
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  local before = #requested
  panel.refresh()
  local l = lines(buf)
  assert(l[2]:match("^● 4 "), vim.inspect(l))
  local row = vim.api.nvim_win_get_cursor(0)[1]
  assert(l[row]:match("^✓ 2 "), "cursor on " .. l[row])
  assert(l[row + 1]:match("note 2") and l[row + 2]:match("%+2 −0"), vim.inspect(l))
  assert(#requested == before, "stats of unchanged checkpoints refetched")
end

M["panel: za on a detail line collapses and moves the cursor to the checkpoint line"] = function()
  local list = { chunk(1, "reviewed") }
  local buf = open_panel(list)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  press("za")
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  press("za")
  assert(#lines(buf) == 2, vim.inspect(lines(buf)))
  assert(vim.api.nvim_win_get_cursor(0)[1] == 2, vim.api.nvim_win_get_cursor(0)[1])
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
  local left_bar = vim.wo[vim.fn.win_getid(1)].winbar
  assert(left_bar:find("2/2", 1, true) and left_bar:find("b.txt", 1, true), left_bar)
  vim.cmd("tabclose")
  diff.cleanup()
end

M["panel: empty text names the mode key when checkpoint mode is off"] = function()
  keys_state.mapped = { mode = "<leader>pm" }
  session.cached = { mode = "off" }
  local buf = open_panel({})
  assert(lines(buf)[2] == "checkpoint mode is off — <leader>pm to turn it on", lines(buf)[2])
  keys_state.mapped = {}
  buf = open_panel({})
  assert(lines(buf)[2] == "checkpoint mode is off — :PiCheckpointMode to turn it on", lines(buf)[2])
  session.cached = { mode = "checkpoints" }
  buf = open_panel({})
  assert(lines(buf)[2] == "no checkpoints yet", lines(buf)[2])
  session.cached = nil
  panel.close()
end

return M
