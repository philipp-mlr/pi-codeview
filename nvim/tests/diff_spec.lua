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
      out[#out + 1] = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, line))
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

local function open_two_files(session_id)
  local root, sha = chunk_repo()
  vim.fn.writefile({ "two" }, root .. "/b.txt")
  session.root = root
  session.cached = { sessionId = session_id or "keys" }
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

M["a checkpoint tab is named for lualine and the badge leaves it at once"] = function()
  local badge = require("pi.badge")
  badge.enabled = true
  badge.update({ chunk = 1 })
  assert(badge.window() ~= nil, "badge not shown before")
  open_two_files()
  assert(vim.t.tabname == "checkpoint 1", tostring(vim.t.tabname))
  assert(vim.t.pi_checkpoint == 1, tostring(vim.t.pi_checkpoint))
  local hidden = badge.window() == nil
  vim.cmd("tabclose")
  local back = badge.window() ~= nil
  badge.close()
  session.cached = nil
  assert(hidden, "badge still shown in the checkpoint tab")
  assert(back, "badge not back after closing the checkpoint tab")
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
  vim.cmd("tabonly")
  open_two_files()
  vim.cmd("tabprevious")
  vim.cmd("tabclose")
  assert(#vim.api.nvim_list_tabpages() == 1)
  local ok, err = pcall(press, "q")
  assert(ok, err)
  assert(#vim.api.nvim_list_tabpages() == 1)
  session.cached = nil
end

M["q with unsaved edits keeps the chunk tab, its keys and says so; works after :w"] = function()
  vim.cmd("tabnew")
  local count = #vim.api.nvim_list_tabpages()
  local root = open_two_files("unsaved")
  local saved_hidden = vim.o.hidden
  vim.o.hidden = false
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited" })
  local notes, original = {}, vim.notify
  vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
  press("q")
  vim.notify = original
  assert(#vim.api.nvim_list_tabpages() == count + 1, "chunk tab was closed")
  assert(#notes == 1 and notes[1].msg == "pi: save your changes first (:w), then q" and notes[1].level == vim.log.levels.WARN, vim.inspect(notes))
  assert(buffer_map(buf, "q").desc == "pi: back from checkpoint view", "q unmapped")
  assert(buffer_map(buf, "<Tab>").desc == "pi: next file in checkpoint", "<Tab> unmapped")
  vim.cmd("write")
  press("q")
  vim.o.hidden = saved_hidden
  assert(#vim.api.nvim_list_tabpages() == count, "chunk tab not closed after :w")
  vim.cmd("tabclose")
  session.cached = nil
end

M["<Tab> and q on the real file outside the chunk tab keep the user's keys"] = function()
  vim.cmd("tabnew")
  local root = open_two_files("elsewhere")
  local chunk_tab = vim.api.nvim_get_current_tabpage()
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd("tabnew")
  local other = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_win_set_buf(0, buf)
  -- no user map: the plain key is fed
  local fed, original = {}, vim.api.nvim_feedkeys
  vim.api.nvim_feedkeys = function(k, mode, esc)
    if mode == "n" then
      fed[#fed + 1] = { k = k, mode = mode }
    else
      original(k, mode, esc)
    end
  end
  press("<Tab>")
  press("q")
  vim.api.nvim_feedkeys = original
  assert(#fed == 2 and fed[1].k == vim.keycode("<Tab>") and fed[1].mode == "n", vim.inspect(fed))
  assert(fed[2].k == "q" and fed[2].mode == "n", vim.inspect(fed))
  assert(vim.api.nvim_get_current_tabpage() == other and #vim.api.nvim_list_tabpages() >= 3)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_tabpage(chunk_tab)
  vim.cmd("tabclose")
  diff.cleanup()
  vim.cmd("tabclose")
  -- user map: it is called
  vim.cmd("tabnew")
  local buf2 = vim.fn.bufadd(root .. "/a.txt")
  vim.fn.bufload(buf2)
  local calls = 0
  vim.keymap.set("n", "<Tab>", function() calls = calls + 1 end, { buffer = buf2, desc = "user" })
  open_chunk(root, vim.trim(vim.fn.system({ "git", "-C", root, "rev-parse", "HEAD" })))
  local chunk2 = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buf2)
  press("<Tab>")
  assert(calls == 1, "user <Tab> map not run: " .. calls)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_tabpage(chunk2)
  vim.cmd("tabclose")
  vim.cmd("tabclose")
  session.cached = nil
end

M["<Tab> and q outside the chunk tab run global maps; buffer-local wins"] = function()
  vim.cmd("tabnew")
  local root = open_two_files("globals")
  local chunk_tab = vim.api.nvim_get_current_tabpage()
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd("tabnew")
  local other = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_win_set_buf(0, buf)
  local tab_calls, global_q = 0, 0
  vim.keymap.set("n", "<Tab>", function() tab_calls = tab_calls + 1 end, { desc = "global tab" })
  vim.keymap.set("n", "q", "<Cmd>lua _G.pi_global_q = (_G.pi_global_q or 0) + 1<CR>", { desc = "global q" })
  press("<Tab>")
  press("q")
  assert(tab_calls == 1, "global <Tab> not run: " .. tab_calls)
  assert(_G.pi_global_q == 1, "global q not run: " .. tostring(_G.pi_global_q))
  assert(vim.api.nvim_get_current_tabpage() == other)
  vim.keymap.del("n", "<Tab>")
  vim.keymap.del("n", "q")
  _G.pi_global_q = nil
  vim.cmd("tabclose")
  vim.api.nvim_set_current_tabpage(chunk_tab)
  vim.cmd("tabclose")
  diff.cleanup()
  vim.cmd("tabclose")

  -- buffer-local wins over global
  vim.cmd("tabnew")
  local buf2 = vim.fn.bufadd(root .. "/a.txt")
  vim.fn.bufload(buf2)
  local local_calls, global_calls = 0, 0
  vim.keymap.set("n", "<Tab>", function() global_calls = global_calls + 1 end, { desc = "global tab" })
  vim.keymap.set("n", "<Tab>", function() local_calls = local_calls + 1 end, { buffer = buf2, desc = "user" })
  open_chunk(root, vim.trim(vim.fn.system({ "git", "-C", root, "rev-parse", "HEAD" })))
  local chunk2 = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buf2)
  press("<Tab>")
  assert(local_calls == 1 and global_calls == 0, local_calls .. "/" .. global_calls)
  vim.keymap.del("n", "<Tab>")
  vim.cmd("tabclose")
  vim.api.nvim_set_current_tabpage(chunk2)
  vim.cmd("tabclose")
  vim.cmd("tabclose")
  session.cached = nil
end

M["a global expr map with a Lua callback feeds its returned keys outside the chunk tab"] = function()
  vim.cmd("tabnew")
  local root = open_two_files("exprglobal")
  local chunk_tab = vim.api.nvim_get_current_tabpage()
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd("tabnew")
  local other = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_win_set_buf(0, buf)
  vim.keymap.set("n", "q", function()
    return "<Cmd>lua _G.pi_expr_q = (_G.pi_expr_q or 0) + 1<CR>"
  end, { expr = true, desc = "global expr q" })
  press("q")
  assert(_G.pi_expr_q == 1, "expr callback result not fed: " .. tostring(_G.pi_expr_q))
  assert(vim.api.nvim_get_current_tabpage() == other)
  vim.keymap.del("n", "q")
  _G.pi_expr_q = nil
  vim.cmd("tabclose")
  vim.api.nvim_set_current_tabpage(chunk_tab)
  vim.cmd("tabclose")
  diff.cleanup()
  vim.cmd("tabclose")
  session.cached = nil
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

local function winbars()
  local tab = vim.api.nvim_get_current_tabpage()
  local left, right = vim.fn.win_getid(1, vim.fn.tabpagenr()), vim.fn.win_getid(2, vim.fn.tabpagenr())
  assert(vim.api.nvim_win_get_tabpage(left) == tab)
  return vim.wo[left].winbar, vim.wo[right].winbar, left, right
end

M["winbar: file on the left, keys or commands on the right"] = function()
  local keys = require("pi.keys")
  local saved = keys.mapped
  vim.o.columns = 200
  vim.cmd("tabnew")
  keys.mapped = { annotate = "<leader>pn", continue = "<leader>pc", peek = "<leader>pk" }
  open_two_files("winbar")
  local left, right = winbars()
  assert(left == "checkpoint 1 · 1/2 · a.txt (agent)", left)
  assert(right == "<Tab> next · <leader>pn note · <leader>pk peek · <leader>pc continue · q back", right)
  vim.cmd("tabclose")
  keys.mapped = {}
  open_two_files("winbar2")
  left, right = winbars()
  assert(right == "<Tab> next · :PiAnnotate note · :PiPeek peek · :PiContinue continue · q back", right)
  vim.cmd("tabclose")
  keys.mapped = saved
  session.cached = nil
end

M["winbar: agent+you for a file both changed, you for yours"] = function()
  local root, sha = chunk_repo()
  vim.fn.writefile({ "two" }, root .. "/b.txt")
  session.root = root
  session.cached = { sessionId = "labels" }
  local original = session.request
  session.request = function(_, _, cb)
    cb(nil, { chunk = { n = 2, status = "open", fromSha = sha, agentFiles = { "a.txt" }, humanFiles = { "a.txt", "b.txt" } } })
  end
  diff.open(2)
  session.request = original
  local left = winbars()
  assert(left == "checkpoint 2 · 1/2 · a.txt (agent+you)", left)
  press("<Tab>")
  left = winbars()
  assert(left == "checkpoint 2 · 2/2 · b.txt (you)", left)
  vim.cmd("tabclose")
  session.cached = nil
end

M["winbar: each side is cut with … to its window's text width"] = function()
  vim.o.columns = 120
  vim.cmd("tabnew")
  open_two_files("narrow")
  local left, right, lwin, rwin = winbars()
  for _, side in ipairs({ { left, lwin }, { right, rwin } }) do
    local room = vim.api.nvim_win_get_width(side[2])
    assert(vim.fn.strdisplaywidth(side[1]) <= room, side[1] .. " > " .. room)
  end
  vim.api.nvim_win_set_width(rwin, 30)
  win_resized("PiDiffWinbar", { rwin })
  left, right = winbars()
  local room = 30 - vim.fn.getwininfo(rwin)[1].textoff -- diff mode adds a fold column
  assert(vim.fn.strdisplaywidth(right) == room and vim.endswith(right, "…"), room .. ": " .. right)
  assert(vim.startswith(right, "<Tab> next"), right)
  vim.o.columns = 200
  vim.cmd("tabclose")
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

M["long note and why show their first 80 characters, then … and the peek key"] = function()
  local keys = require("pi.keys")
  local saved = keys.mapped
  keys.mapped = { peek = "<leader>pk" }
  local text = open_with_note(("x"):rep(300), ("y"):rep(81))
  assert(vim.deep_equal(text, {
    "  " .. ("x"):rep(80) .. "… <leader>pk",
    "  why: " .. ("y"):rep(80) .. "… <leader>pk",
  }), vim.inspect(text))
  keys.mapped = {}
  text = open_with_note(("x"):rep(80), ("y"):rep(300))
  assert(vim.deep_equal(text, { "  " .. ("x"):rep(80), "  why: " .. ("y"):rep(80) .. "… :PiPeek" }), vim.inspect(text))
  keys.mapped = saved
end

M["peek_lines gives the checkpoint title, full note and the current file's why"] = function()
  local root, sha = chunk_repo()
  vim.fn.writefile({ "two" }, root .. "/b.txt")
  session.root = root
  session.cached = { sessionId = "peek" }
  local original = session.request
  local note = ("long note "):rep(30) .. "\n\nsecond paragraph"
  session.request = function(_, _, cb)
    cb(nil, {
      chunk = {
        n = 3, status = "open", fromSha = sha, title = "Split the parser", note = note, humanFiles = {},
        agentFiles = { "a.txt", "b.txt" }, why = { ["b.txt"] = "b needs it" },
      },
    })
  end
  assert(diff.peek_lines() == nil, "peek outside a checkpoint diff")
  diff.open(3)
  session.request = original
  local lines = diff.peek_lines()
  local want = { "checkpoint 3 — Split the parser", "" }
  vim.list_extend(want, vim.split(note, "\n"))
  assert(vim.deep_equal(lines, want), vim.inspect(lines))
  press("<Tab>")
  lines = diff.peek_lines()
  assert(lines[#lines] == "why: b needs it" and lines[#lines - 1] == "", vim.inspect(lines))
  vim.cmd("tabclose")
  session.cached = nil
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

-- Fake diffview.nvim: :DiffviewOpen records its args and opens a tab with two windows (left a
-- diffview:// buffer, right the real file); :DiffviewClose closes the tab and fires the User event.
local fake = {}

local function install_fake_diffview()
  fake = { calls = {}, closes = 0 }
  require("pi.keys").mapped = {}
  package.preload["diffview"] = function()
    return {}
  end
  vim.api.nvim_create_user_command("DiffviewOpen", function(cmd)
    fake.calls[#fake.calls + 1] = cmd.args
    vim.cmd("tabnew")
    fake.opened = (fake.opened or 0) + 1
    fake.left = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit " .. vim.fn.fnameescape(fake.root .. "/a.txt"))
    fake.right = vim.api.nvim_get_current_win()
    local left = vim.api.nvim_create_buf(false, true)
    vim.bo[left].bufhidden = "wipe"
    vim.api.nvim_buf_set_name(left, "diffview://" .. fake.root .. "/.git/abc" .. fake.opened .. "/a.txt")
    vim.api.nvim_win_set_buf(fake.left, left)
    if fake.share_buffers then
      -- like diffview: one buffer per (revision, path); a chunk's left is another chunk's right
      fake.buffers = fake.buffers or {}
      local function shared(rev)
        if not fake.buffers[rev] or not vim.api.nvim_buf_is_valid(fake.buffers[rev]) then
          local buf = vim.api.nvim_create_buf(false, true)
          vim.api.nvim_buf_set_name(buf, "diffview://" .. fake.root .. "/.git/" .. rev .. "/a.txt")
          fake.buffers[rev] = buf
        end
        return fake.buffers[rev]
      end
      left = shared(fake.revs[1])
      vim.api.nvim_win_set_buf(fake.left, left)
      if fake.revs[2] then
        vim.api.nvim_win_set_buf(fake.right, shared(fake.revs[2]))
      end
    end
    for _, win in ipairs({ fake.left, fake.right }) do
      vim.wo[win].diff = true
    end
    fake.left_buf = left
    fake.tab = vim.api.nvim_get_current_tabpage()
    if fake.fire_inside_open then
      vim.api.nvim_set_current_win(fake.left)
      vim.api.nvim_exec_autocmds("User", { pattern = "DiffviewDiffBufWinEnter" })
    end
    if fake.fire_both then
      -- like diffview: the left window's event first, then the right window's
      for _, win in ipairs({ fake.left, fake.right }) do
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_exec_autocmds("User", { pattern = "DiffviewDiffBufWinEnter" })
      end
    end
  end, { nargs = "*", complete = "file" })
  vim.api.nvim_create_user_command("DiffviewClose", function()
    fake.closes = fake.closes + 1
    if #vim.api.nvim_list_tabpages() == 1 then
      vim.cmd("tabnew")
    end
    vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(fake.tab))
    vim.api.nvim_exec_autocmds("User", { pattern = "DiffviewViewClosed" })
  end, {})
end

local function remove_fake_diffview()
  package.preload["diffview"] = nil
  package.loaded["diffview"] = nil
  pcall(vim.api.nvim_del_user_command, "DiffviewOpen")
  pcall(vim.api.nvim_del_user_command, "DiffviewClose")
  diff.mode = "auto"
  while #vim.api.nvim_list_tabpages() > 1 do
    vim.cmd("tabclose")
  end
  session.cached = nil
end

local function with_fake(fn)
  return function()
    vim.cmd("tabonly")
    local ok, err = xpcall(fn, debug.traceback)
    remove_fake_diffview()
    if not ok then
      error(err, 0)
    end
  end
end

local function fetch(chunk, sessionId)
  session.cached = { sessionId = sessionId or "dv" }
  local original = session.request
  session.request = function(_, _, cb)
    cb(nil, { chunk = chunk })
  end
  diff.open(chunk.n)
  session.request = original
end

local function capture_notify()
  local seen = {}
  local original = vim.notify
  vim.notify = function(msg, level)
    seen[#seen + 1] = { msg = msg, level = level }
  end
  return seen, function()
    vim.notify = original
  end
end

local function fake_repo()
  local root, sha = chunk_repo()
  session.root = root
  fake.root = root
  return root, sha
end

M["auto with diffview opens an open chunk with the exact DiffviewOpen args"] = with_fake(function()
  install_fake_diffview()
  local root, sha = fake_repo()
  vim.fn.writefile({ "x" }, root .. "/b c.txt")
  local seen, restore = capture_notify()
  fetch({ n = 1, status = "open", fromSha = sha, agentFiles = { "b c.txt" }, humanFiles = { "a.txt" } })
  restore()
  local expected = ("%s -C%s -- a.txt b\\ c.txt"):format(sha, vim.fn.fnameescape(root))
  assert(fake.calls[1] == expected, vim.inspect(fake.calls))
  assert(diff.viewed(1), "diffview chunk not viewed")
  assert(vim.t[fake.tab].tabname == "checkpoint 1" and vim.t[fake.tab].pi_checkpoint == 1, "diffview tab not named")
  -- At 80 columns the key list does not fit the message line: the diffview's keys are one g? away.
  assert(seen[1].msg == "pi: checkpoint 1", seen[1].msg)
end)

M["the diffview checkpoint notice lists the keys when they fit the message line"] = with_fake(function()
  install_fake_diffview()
  local _, sha = fake_repo()
  require("pi.keys").mapped = { annotate = "<leader>pn", continue = "<leader>pc" }
  local saved = vim.o.columns
  vim.o.columns = 120
  local seen, restore = capture_notify()
  local ok, err = pcall(fetch, { n = 1, status = "open", fromSha = sha, agentFiles = { "a.txt" }, humanFiles = {} })
  restore()
  vim.o.columns = saved
  require("pi.keys").mapped = {}
  assert(ok, err)
  assert(seen[1].msg == "pi: checkpoint 1 — <Tab> next file · <leader>pn note · <leader>pc continue · q back", seen[1].msg)
end)

M["q in the diffview checkpoint tab closes it and returns to the origin tab"] = with_fake(function()
  install_fake_diffview()
  local root, sha = fake_repo()
  vim.cmd("tabnew")
  local origin = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew") -- the tab right of the checkpoint tab, where :tabclose alone would land
  vim.api.nvim_set_current_tabpage(origin)
  fetch({ n = 1, status = "open", fromSha = sha, agentFiles = { "a.txt" }, humanFiles = {} })
  local tab = fake.tab
  for _, win in ipairs({ fake.left, fake.right }) do
    assert(buffer_map(vim.api.nvim_win_get_buf(win), "q").desc == "pi: back from checkpoint view", "q not mapped in " .. win)
  end
  vim.api.nvim_set_current_win(fake.right)
  press("q")
  assert(fake.closes == 1, "DiffviewClose not used")
  assert(not vim.api.nvim_tabpage_is_valid(tab), "diffview tab still open")
  assert(vim.api.nvim_get_current_tabpage() == origin, "not back on the origin tab")
end)

M["q in the diffview checkpoint tab with unsaved edits warns and stays"] = with_fake(function()
  install_fake_diffview()
  local root, sha = fake_repo()
  vim.cmd("tabnew")
  fetch({ n = 1, status = "open", fromSha = sha, agentFiles = { "a.txt" }, humanFiles = {} })
  local tab = fake.tab
  local saved_hidden = vim.o.hidden
  vim.o.hidden = false
  vim.api.nvim_set_current_win(fake.right)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "edited" })
  local seen, restore = capture_notify()
  press("q")
  restore()
  vim.o.hidden = saved_hidden
  assert(fake.closes == 0, "DiffviewClose ran over unsaved edits")
  assert(vim.api.nvim_tabpage_is_valid(tab) and vim.api.nvim_get_current_tabpage() == tab)
  assert(#seen == 1 and seen[1].msg == "pi: save your changes first (:w), then q" and seen[1].level == vim.log.levels.WARN, vim.inspect(seen))
  vim.cmd("write")
  press("q")
  assert(fake.closes == 1 and not vim.api.nvim_tabpage_is_valid(tab), "q after :w did not close")
end)

M["diffview moving to another file moves q to the new buffers"] = with_fake(function()
  install_fake_diffview()
  local root, sha = fake_repo()
  vim.fn.writefile({ "y" }, root .. "/b.txt")
  vim.cmd("tabnew")
  fetch({ n = 1, status = "open", fromSha = sha, agentFiles = { "a.txt", "b.txt" }, humanFiles = {} })
  local old_right = vim.api.nvim_win_get_buf(fake.right)
  -- like diffview's <Tab>: each window gets its new buffer, then fires its event; left first
  local left = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(left, "diffview://" .. root .. "/.git/abc/b.txt")
  vim.api.nvim_win_set_buf(fake.left, left)
  vim.wo[fake.left].diff = true
  vim.api.nvim_set_current_win(fake.left)
  vim.api.nvim_exec_autocmds("User", { pattern = "DiffviewDiffBufWinEnter" })
  vim.api.nvim_win_call(fake.right, function() vim.cmd("hide edit " .. vim.fn.fnameescape(root .. "/b.txt")) end)
  vim.wo[fake.right].diff = true
  vim.api.nvim_set_current_win(fake.right)
  vim.api.nvim_exec_autocmds("User", { pattern = "DiffviewDiffBufWinEnter" })
  local right = vim.api.nvim_win_get_buf(fake.right)
  assert(buffer_map(left, "q").desc == "pi: back from checkpoint view", "left q")
  assert(buffer_map(right, "q").desc == "pi: back from checkpoint view", "right q")
  assert(vim.tbl_isempty(buffer_map(old_right, "q")), "old right buffer kept q")
end)

M["diffview q leaves the buffers' keys once the tab is gone"] = with_fake(function()
  install_fake_diffview()
  local root, sha = fake_repo()
  vim.cmd("tabnew")
  fetch({ n = 1, status = "open", fromSha = sha, agentFiles = { "a.txt" }, humanFiles = {} })
  local real = vim.api.nvim_win_get_buf(fake.right)
  vim.api.nvim_set_current_win(fake.right)
  press("q")
  assert(vim.tbl_isempty(buffer_map(real, "q")), vim.inspect(buffer_map(real, "q")))
end)

M["auto with diffview opens a past chunk as a revision range"] = with_fake(function()
  install_fake_diffview()
  local root, sha = fake_repo()
  fetch({ n = 2, status = "reviewed", fromSha = sha, toSha = "beefcafe", agentFiles = { "a.txt" }, humanFiles = {} })
  assert(fake.calls[1] == ("%s..beefcafe -C%s -- a.txt"):format(sha, vim.fn.fnameescape(root)), vim.inspect(fake.calls))
end)

M["auto without diffview uses the built-in view"] = with_fake(function()
  local root, sha = chunk_repo()
  open_chunk(root, sha, "nodv")
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(diff.is_diff_window(vim.api.nvim_get_current_win()) and vim.api.nvim_get_current_win() or 0))
  assert(#vim.api.nvim_list_tabpages() == 2 and diff.viewed(1), name)
  assert(vim.wo.diff, "built-in diff not shown")
end)

M["diff = builtin ignores an installed diffview"] = with_fake(function()
  install_fake_diffview()
  local root, sha = fake_repo()
  diff.mode = "builtin"
  open_chunk(root, sha, "forced")
  assert(#fake.calls == 0, "DiffviewOpen was called")
  assert(vim.wo.diff, "built-in diff not shown")
end)

M["diff = diffview without diffview falls back and warns once"] = with_fake(function()
  local root, sha = chunk_repo()
  diff.mode = "diffview"
  local seen, restore = capture_notify()
  open_chunk(root, sha, "warn")
  vim.cmd("tabclose")
  session.cached = nil
  open_chunk(root, sha, "warn2")
  restore()
  local warnings = vim.tbl_filter(function(item)
    return item.msg == "pi: diffview.nvim not found, using the built-in view" and item.level == vim.log.levels.WARN
  end, seen)
  assert(#warnings == 1, "expected exactly one warning, got " .. #warnings)
  assert(vim.wo.diff, "built-in diff not shown")
end)

M["diff = diffview without diffview warns (first time in this nvim)"] = with_fake(function()
  local root, sha = chunk_repo()
  diff.mode = "diffview"
  package.loaded["pi.diff"] = nil
  local fresh = require("pi.diff")
  fresh.mode = "diffview"
  local seen, restore = capture_notify()
  session.root = root
  session.cached = { sessionId = "w" }
  local original = session.request
  session.request = function(_, _, cb)
    cb(nil, { chunk = { n = 1, status = "open", fromSha = sha, agentFiles = { "a.txt" }, humanFiles = {} } })
  end
  fresh.open(1)
  session.request = original
  restore()
  package.loaded["pi.diff"] = diff
  assert(seen[1] and seen[1].msg == "pi: diffview.nvim not found, using the built-in view" and seen[1].level == vim.log.levels.WARN, vim.inspect(seen))
end)

M["a failing :DiffviewOpen falls back to the built-in view"] = with_fake(function()
  install_fake_diffview()
  local root, sha = fake_repo()
  vim.api.nvim_create_user_command("DiffviewOpen", function()
    error("boom")
  end, { nargs = "*" })
  open_chunk(root, sha, "boom")
  assert(vim.wo.diff and vim.api.nvim_buf_get_name(0):match("a.txt$"), "built-in view not shown")
end)

M["diffview left buffer gets the note and why only in the chunk tab"] = with_fake(function()
  install_fake_diffview()
  local root, sha = fake_repo()
  fetch({ n = 1, status = "open", fromSha = sha, note = "the note", why = { ["a.txt"] = "because" }, agentFiles = { "a.txt" }, humanFiles = {} })
  local chunk_tab = fake.tab
  local right_buf = vim.api.nvim_win_get_buf(fake.right)
  vim.api.nvim_set_current_win(fake.right)
  vim.api.nvim_exec_autocmds("User", { pattern = "DiffviewDiffBufWinEnter" })
  assert(#why_text(fake.left_buf) == 0, "right side got the explanation")
  vim.api.nvim_set_current_win(fake.left)
  vim.api.nvim_exec_autocmds("User", { pattern = "DiffviewDiffBufWinEnter" })
  assert(vim.deep_equal(why_text(fake.left_buf), { "  the note", "  why: because" }), vim.inspect(why_text(fake.left_buf)))
  assert(#why_text(right_buf) == 0)
  -- another tab (not the chunk's, e.g. a plain diffview) gets nothing
  vim.cmd("tabnew")
  local other = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(other, "diffview://" .. root .. "/.git/def/a.txt")
  vim.api.nvim_win_set_buf(0, other)
  vim.wo.diff = true
  vim.api.nvim_exec_autocmds("User", { pattern = "DiffviewDiffBufWinEnter" })
  assert(#why_text(other) == 0, "other tab got the explanation")
  assert(vim.api.nvim_tabpage_is_valid(chunk_tab))
end)

M["every diffview chunk tab keeps its explanation"] = with_fake(function()
  install_fake_diffview()
  local root, sha = fake_repo()
  vim.fn.writefile({ "y" }, root .. "/b.txt")
  local function chunk(n, note)
    return { n = n, status = "open", fromSha = sha, note = note, why = { ["a.txt"] = "w" .. n, ["b.txt"] = "wb" .. n }, agentFiles = { "a.txt", "b.txt" }, humanFiles = {} }
  end
  fetch(chunk(1, "note1"))
  local tab1, win1 = fake.tab, fake.left
  vim.cmd("tabprevious")
  fetch(chunk(2, "note2"))
  local tab2, win2 = fake.tab, fake.left
  -- chunk 1's tab moves to its second file
  vim.api.nvim_set_current_tabpage(tab1)
  vim.api.nvim_set_current_win(win1)
  local second = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(second, "diffview://" .. root .. "/.git/abc123/b.txt")
  vim.api.nvim_win_set_buf(win1, second)
  vim.api.nvim_exec_autocmds("User", { pattern = "DiffviewDiffBufWinEnter" })
  assert(vim.deep_equal(why_text(second), { "  note1", "  why: wb1" }), vim.inspect(why_text(second)))
  -- and chunk 2's tab still works
  vim.api.nvim_set_current_tabpage(tab2)
  vim.api.nvim_set_current_win(win2)
  vim.api.nvim_exec_autocmds("User", { pattern = "DiffviewDiffBufWinEnter" })
  assert(vim.deep_equal(why_text(vim.api.nvim_win_get_buf(win2)), { "  note2", "  why: w2" }), vim.inspect(why_text(vim.api.nvim_win_get_buf(win2))))
end)

M["diffview's left-then-right events leave a shared buffer's explanation off the right side"] = with_fake(function()
  install_fake_diffview()
  local root, sha = fake_repo()
  fake.share_buffers = true
  fake.fire_both = true
  local function chunk(n, status, note)
    return { n = n, status = status, fromSha = "S" .. n, toSha = "S" .. (n - 1), note = note, why = { ["a.txt"] = "why" .. n }, agentFiles = { "a.txt" }, humanFiles = {} }
  end
  -- A (open) shows S2 on its left; B (past) shows S1 on its left and the same S2 buffer on its right
  fake.revs = { "S2" }
  fetch(chunk(1, "open", "chunk one"))
  local tab_a, left_a = fake.tab, fake.left_buf
  fake.revs = { "S1", "S2" }
  fetch(chunk(2, "past", "chunk two"))
  local tab_b, win_b_left, win_b_right = fake.tab, fake.left, fake.right
  local left_b, right_b = vim.api.nvim_win_get_buf(win_b_left), vim.api.nvim_win_get_buf(win_b_right)
  assert(right_b == left_a, "fake does not share the buffer")
  assert(vim.deep_equal(why_text(left_b), { "  chunk two", "  why: why2" }), vim.inspect(why_text(left_b)))
  assert(#why_text(right_b) == 0, "right side of B shows A's explanation: " .. vim.inspect(why_text(right_b)))
  vim.api.nvim_set_current_tabpage(tab_a)
  assert(vim.deep_equal(why_text(left_a), { "  chunk one", "  why: why1" }), vim.inspect(why_text(left_a)))
  vim.api.nvim_set_current_tabpage(tab_b)
  assert(vim.deep_equal(why_text(left_b), { "  chunk two", "  why: why2" }), vim.inspect(why_text(left_b)))
  assert(#why_text(right_b) == 0, "right side of B shows A's explanation after switching back")
end)

M["an event fired synchronously inside :DiffviewOpen still places the explanation"] = with_fake(function()
  install_fake_diffview()
  local root, sha = fake_repo()
  fake.fire_inside_open = true
  fetch({ n = 1, status = "open", fromSha = sha, note = "early", why = { ["a.txt"] = "now" }, agentFiles = { "a.txt" }, humanFiles = {} })
  assert(vim.deep_equal(why_text(fake.left_buf), { "  early", "  why: now" }), vim.inspect(why_text(fake.left_buf)))
end)

M["opening the same diffview chunk twice reuses the tab"] = with_fake(function()
  install_fake_diffview()
  local root, sha = fake_repo()
  local chunk = { n = 1, status = "open", fromSha = sha, agentFiles = { "a.txt" }, humanFiles = {} }
  fetch(chunk)
  local tab = fake.tab
  vim.cmd("tabprevious")
  fetch(chunk)
  assert(#fake.calls == 1, "DiffviewOpen ran twice")
  assert(vim.api.nvim_get_current_tabpage() == tab, "did not switch to the diffview tab")
end)

M["forget closes the diffview tab; ViewClosed unregisters it"] = with_fake(function()
  install_fake_diffview()
  local root, sha = fake_repo()
  fetch({ n = 1, status = "open", fromSha = sha, agentFiles = { "a.txt" }, humanFiles = {} })
  assert(#vim.api.nvim_list_tabpages() == 2)
  diff.forget(1)
  assert(fake.closes == 1, "DiffviewClose not used")
  assert(#vim.api.nvim_list_tabpages() == 1, "diffview tab still open")
  -- closed by the user: ViewClosed unregisters, so opening again runs DiffviewOpen again
  fetch({ n = 1, status = "open", fromSha = sha, agentFiles = { "a.txt" }, humanFiles = {} })
  assert(#fake.calls == 2, vim.inspect(fake.calls))
  vim.cmd("DiffviewClose")
  fetch({ n = 1, status = "open", fromSha = sha, agentFiles = { "a.txt" }, humanFiles = {} })
  assert(#fake.calls == 3, vim.inspect(fake.calls))
end)

M["a checkpoint without file changes is an INFO notice naming the continue key"] = function()
  local keys_state = require("pi.keys")
  local root = chunk_repo()
  session.root = root
  session.cached = { sessionId = "empty" }
  local original, notify = session.request, vim.notify
  local notes = {}
  vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
  session.request = function(_, _, cb)
    cb(nil, { chunk = { n = 3, status = "open", agentFiles = {}, humanFiles = {} } })
  end
  keys_state.mapped = { continue = "<leader>pc" }
  diff.open(3)
  keys_state.mapped = {}
  diff.open(3)
  session.request, vim.notify = original, notify
  session.cached = nil
  assert(#notes == 2, vim.inspect(notes))
  assert(notes[1].msg == "pi: checkpoint 3 has no file changes — <leader>pc to continue" and notes[1].level == vim.log.levels.INFO, vim.inspect(notes))
  assert(notes[2].msg == "pi: checkpoint 3 has no file changes — :PiContinue to continue", vim.inspect(notes))
end

return M
