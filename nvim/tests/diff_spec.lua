local session = require("pi.session")
local diff = require("pi.diff")

local M = {}

local function sh(root, ...)
  local r = vim.system({ "git", "-C", root, ... }, { text = true }):wait()
  assert(r.code == 0, r.stderr)
  return vim.trim(r.stdout)
end

local function chunk_repo()
  local root = vim.uv.fs_realpath(vim.fn.tempname() .. "") or vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  root = vim.uv.fs_realpath(root)
  sh(root, "init", "-q")
  sh(root, "config", "user.email", "t@t")
  sh(root, "config", "user.name", "t")
  vim.fn.writefile({ "one" }, root .. "/a.txt")
  sh(root, "add", ".")
  sh(root, "commit", "-q", "-m", "init")
  return root, sh(root, "rev-parse", "HEAD")
end

local function open_chunk(root, sha, session_id)
  session.root = root
  session.cached = { sessionId = session_id or "s1" }
  local original = session.request
  session.request = function(_, _, cb)
    cb(nil, { chunk = { n = 1, status = "open", fromSha = sha, agentFiles = { "a.txt" }, humanFiles = {} } })
  end
  diff.open(1)
  session.request = original
end

local function press(key)
  vim.api.nvim_feedkeys(vim.keycode(key), "x", false)
end

local function buffer_map(buf, lhs)
  return vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg(lhs, "n", false, true)
  end)
end

M["user buffer-local file keys are restored after the diff tab closes"] = function()
  local root, sha = chunk_repo()
  local buf = vim.fn.bufadd(root .. "/a.txt")
  vim.fn.bufload(buf)
  vim.keymap.set("n", "<Tab>", "<Nop>", { buffer = buf, desc = "user" })
  vim.keymap.set("n", "q", "<Nop>", { buffer = buf, desc = "user q" })
  open_chunk(root, sha)
  assert(buffer_map(buf, "<Tab>").desc ~= "user", "pi did not map <Tab>")
  assert(buffer_map(buf, "q").desc ~= "user q", "pi did not map q")
  vim.cmd("tabclose")
  diff.cleanup()
  assert(buffer_map(buf, "<Tab>").desc == "user", vim.inspect(buffer_map(buf, "<Tab>")))
  assert(buffer_map(buf, "q").desc == "user q", vim.inspect(buffer_map(buf, "q")))
  assert(vim.tbl_isempty(buffer_map(buf, "<S-Tab>")), "<S-Tab> leaked: " .. vim.inspect(buffer_map(buf, "<S-Tab>")))
end

local function why_text(buf)
  local ns = vim.api.nvim_create_namespace("pi_why")
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local out = {}
  for _, mark in ipairs(marks) do
    for _, line in ipairs(mark[4].virt_lines or {}) do
      out[#out + 1] = line[1][1]
    end
  end
  return out
end

M["diff view shows the note and why above the left buffer and updates on <Tab>"] = function()
  local root, sha = chunk_repo()
  vim.fn.writefile({ "two" }, root .. "/b.txt")
  session.root = root
  session.cached = { sessionId = "why" }
  local original = session.request
  session.request = function(_, _, cb)
    cb(nil, {
      chunk = {
        n = 1, status = "open", fromSha = sha, note = "did things", humanFiles = {},
        agentFiles = { "a.txt", "b.txt" }, why = { ["a.txt"] = "because a" },
      },
    })
  end
  diff.open(1)
  session.request = original
  local view_left = vim.fn.win_getid(1, vim.fn.tabpagenr())
  local function topfill()
    vim.cmd("redraw")
    return vim.api.nvim_win_call(view_left, function()
      return vim.fn.winsaveview().topfill
    end)
  end
  assert(topfill() == 2, "explanation not visible, topfill=" .. topfill())
  local left = vim.api.nvim_win_get_buf(view_left)
  assert(vim.deep_equal(why_text(left), { "  did things", "  why: because a" }), vim.inspect(why_text(left)))
  press("<Tab>")
  assert(topfill() == 1, "explanation not visible after <Tab>, topfill=" .. topfill())
  left = vim.api.nvim_win_get_buf(view_left)
  assert(vim.deep_equal(why_text(left), { "  did things" }), vim.inspect(why_text(left)))
  vim.cmd("tabclose")
  session.cached = nil
end

local function open_two_files()
  local root, sha = chunk_repo()
  vim.fn.writefile({ "two" }, root .. "/b.txt")
  session.root = root
  session.cached = { sessionId = "keys" }
  local original = session.request
  session.request = function(_, _, cb)
    cb(nil, { chunk = { n = 1, status = "open", fromSha = sha, humanFiles = {}, agentFiles = { "a.txt", "b.txt" } } })
  end
  diff.open(1)
  session.request = original
  return root
end

local function shown_path()
  return vim.api.nvim_buf_get_name(0):match("[^/]+$")
end

M["<Tab> and <S-Tab> move between files and stop at the ends"] = function()
  open_two_files()
  assert(shown_path() == "a.txt")
  press("<Tab>")
  assert(shown_path() == "b.txt", shown_path())
  press("<Tab>")
  assert(shown_path() == "b.txt", "wrapped: " .. shown_path())
  press("<S-Tab>")
  assert(shown_path() == "a.txt", shown_path())
  press("<S-Tab>")
  assert(shown_path() == "a.txt", "wrapped back: " .. shown_path())
  vim.cmd("tabclose")
  session.cached = nil
end

M["q closes the chunk tab and returns to the origin tab"] = function()
  vim.cmd("tabnew")
  local origin = vim.api.nvim_get_current_tabpage()
  local count = #vim.api.nvim_list_tabpages()
  open_two_files()
  assert(#vim.api.nvim_list_tabpages() == count + 1)
  press("q")
  assert(#vim.api.nvim_list_tabpages() == count, "chunk tab not closed")
  assert(vim.api.nvim_get_current_tabpage() == origin, "not back on origin tab")
  vim.cmd("tabclose")
  session.cached = nil
end

M["q with the origin tab gone just closes the chunk tab"] = function()
  vim.cmd("tabnew")
  local count = #vim.api.nvim_list_tabpages()
  open_two_files()
  local chunk_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabprevious")
  vim.cmd("tabclose")
  vim.api.nvim_set_current_tabpage(chunk_tab)
  press("q")
  assert(#vim.api.nvim_list_tabpages() == count - 1, "chunk tab not closed")
  session.cached = nil
end

M["q on the last tab does nothing"] = function()
  while #vim.api.nvim_list_tabpages() > 1 do
    vim.cmd("tabclose")
  end
  open_two_files()
  vim.cmd("tabprevious")
  vim.cmd("tabclose")
  assert(#vim.api.nvim_list_tabpages() == 1)
  local ok, err = pcall(press, "q")
  assert(ok, err)
  assert(#vim.api.nvim_list_tabpages() == 1)
  session.cached = nil
end

M["winbar shows the help line with keys or commands"] = function()
  local keys = require("pi.keys")
  local saved = keys.mapped
  vim.cmd("tabnew")
  vim.cmd("tabnew")
  keys.mapped = { annotate = "<leader>pn", send = "<leader>pr" }
  open_two_files()
  assert(vim.wo.winbar:find("chunk 1 · 1/2 · a.txt · agent   <Tab> next · <leader>pn annotate · <leader>pr send · q back", 1, true), vim.wo.winbar)
  vim.cmd("tabclose")
  keys.mapped = {}
  open_two_files()
  assert(vim.wo.winbar:find("<Tab> next · :PiAnnotate annotate · :PiSendAnnotations send · q back", 1, true), vim.wo.winbar)
  vim.cmd("tabclose")
  keys.mapped = saved
  session.cached = nil
end

local function open_with_note(note, why)
  local root, sha = chunk_repo()
  vim.fn.writefile({ "two" }, root .. "/a.txt")
  session.root = root
  session.cached = { sessionId = "oneline" }
  local original = session.request
  session.request = function(_, _, cb)
    cb(nil, {
      chunk = {
        n = 1, status = "open", fromSha = sha, note = note, humanFiles = {},
        agentFiles = { "a.txt" }, why = why and { ["a.txt"] = why } or nil,
      },
    })
  end
  diff.open(1)
  session.request = original
  local win = vim.fn.win_getid(1, vim.fn.tabpagenr())
  vim.cmd("redraw")
  local topfill = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().topfill
  end)
  local text = why_text(vim.api.nvim_win_get_buf(win))
  vim.cmd("tabclose")
  session.cached = nil
  return text, topfill
end

M["multi-line note and why render as one line each"] = function()
  local text, topfill = open_with_note("first line\nsecond line", "a\n  b")
  assert(vim.deep_equal(text, { "  first line second line", "  why: a b" }), vim.inspect(text))
  assert(topfill == 2, "topfill=" .. topfill)
end

M["long note is cut to 200 characters with an ellipsis"] = function()
  local text = open_with_note(("x"):rep(300), nil)
  assert(vim.deep_equal(text, { "  " .. ("x"):rep(200) .. "…" }), vim.inspect(text))
end

M["viewed is per pi session, not per chunk number"] = function()
  local root, sha = chunk_repo()
  open_chunk(root, sha, "first")
  assert(diff.viewed(1), "chunk 1 of the first session not viewed")
  vim.cmd("tabclose")
  session.cached = { sessionId = "second" }
  assert(not diff.viewed(1), "chunk 1 of another session counts as viewed")
  session.cached = nil
end

M["forget closes the diff tab of a reviewed chunk"] = function()
  local root, sha = chunk_repo()
  open_chunk(root, sha, "forget")
  assert(#vim.api.nvim_list_tabpages() == 2, "diff tab not open")
  diff.forget(1)
  assert(#vim.api.nvim_list_tabpages() == 1, "diff tab still open")
  local fetched = false
  local original = session.request
  session.request = function(_, _, cb)
    fetched = true
    cb(nil, { chunk = { n = 1, status = "reviewed", fromSha = sha, toSha = sha, agentFiles = { "a.txt" }, humanFiles = {} } })
  end
  diff.open(1)
  session.request = original
  assert(fetched, "open reused a stale view instead of fetching the chunk")
  vim.cmd("tabclose")
  session.cached = nil
end

return M
