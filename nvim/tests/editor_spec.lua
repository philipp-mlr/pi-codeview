local editor = require("pi.editor")

local M = {}

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

-- :startinsert takes effect only once the main loop runs again; a no-op <Cmd> lets it, so the
-- keys after it are typed in insert mode as they would be by hand.
local function type_text(keys)
  press("<Cmd><CR>" .. keys)
end

-- Opens the editor and records what it reports; returns the record.
local function open(opts)
  local got = { submitted = {}, cancelled = 0 }
  opts = opts or {}
  editor.open({
    title = opts.title or " pi test ",
    text = opts.text,
    draft = opts.draft or "test",
    on_submit = function(text)
      got.submitted[#got.submitted + 1] = text
    end,
    on_cancel = function()
      got.cancelled = got.cancelled + 1
    end,
  })
  got.win = vim.api.nvim_get_current_win()
  got.buf = vim.api.nvim_get_current_buf()
  return got
end

local function settle()
  vim.wait(50, function() return false end)
end

-- Sends away any draft a cancelled editor left, so specs do not see each other's text.
local function drain()
  local got = open()
  type_text("<Esc><C-s>")
  for _, key in ipairs({ "test", "ask", "note", "edit:1" }) do
    editor.discard_draft(key)
  end
end

local function bufs()
  return #vim.api.nvim_list_bufs()
end

M["editor is a centred rounded float with title, footer, wrap and markdown"] = function()
  local origin = vim.api.nvim_get_current_win()
  local got = open({ title = " pi ask · a.lua:5 " })
  assert(got.win ~= origin, "editor did not take focus")
  local config = vim.api.nvim_win_get_config(got.win)
  assert(config.relative == "editor", vim.inspect(config))
  assert(config.border[1] == "╭", vim.inspect(config.border))
  assert(config.title[1][1] == " pi ask · a.lua:5 " and config.title_pos == "center", vim.inspect(config.title))
  assert(config.footer[1][1] == " <C-s> send · q cancel " and config.footer_pos == "right", vim.inspect(config.footer))
  assert(config.width == math.min(80, vim.o.columns - 4), config.width)
  assert(config.height == 3, config.height)
  assert(config.col == math.floor((vim.o.columns - config.width) / 2) - 1, config.col)
  assert(vim.wo[got.win].wrap and vim.wo[got.win].linebreak)
  assert(vim.bo[got.buf].filetype == "markdown" and vim.bo[got.buf].buftype == "acwrite" and vim.bo[got.buf].bufhidden == "hide")
  type_text("<Esc>q")
  assert(vim.api.nvim_get_current_win() == origin)
  drain()
end

M["editor height grows with the text from 3 up to 15 lines"] = function()
  local five = open({ text = "1\n2\n3\n4\n5" })
  assert(vim.api.nvim_win_get_height(five.win) == 5)
  type_text("<Esc>q")
  drain()
  local many = open({ text = ("x\n"):rep(30) .. "x" })
  assert(vim.api.nvim_win_get_height(many.win) == 15)
  type_text("<Esc>q")
  drain()
  local grows = open()
  type_text("a<CR>b<CR>c<CR>d<Esc>")
  settle()
  assert(vim.api.nvim_win_get_height(grows.win) == 4, vim.api.nvim_win_get_height(grows.win))
  press("q")
  drain()
end

M["editor starts in insert mode at the end and <C-s> sends with trailing whitespace trimmed"] = function()
  local origin = vim.api.nvim_get_current_win()
  local before = bufs()
  local got = open({ text = "first\nsecond" })
  type_text(" more  <CR><CR><C-s>")
  assert(vim.deep_equal(got.submitted, { "first\nsecond more" }), vim.inspect(got.submitted))
  assert(got.cancelled == 0)
  assert(vim.api.nvim_get_current_win() == origin and vim.api.nvim_get_mode().mode == "n", vim.api.nvim_get_mode().mode)
  assert(not vim.api.nvim_buf_is_valid(got.buf) and bufs() == before, "editor buffer leaked")
end

M["editor sends with <C-s> and <CR> in normal mode"] = function()
  local a = open()
  type_text("hello<Esc><C-s>")
  assert(vim.deep_equal(a.submitted, { "hello" }), vim.inspect(a.submitted))
  local b = open()
  type_text("there<Esc><CR>")
  assert(vim.deep_equal(b.submitted, { "there" }), vim.inspect(b.submitted))
end

M["sending empty or blank text cancels"] = function()
  local got = open()
  type_text("   <CR>  <C-s>")
  assert(#got.submitted == 0 and got.cancelled == 1, vim.inspect(got))
  assert(not vim.api.nvim_win_is_valid(got.win))
end

M["every other way of closing cancels exactly once and leaks no buffer"] = function()
  local origin = vim.api.nvim_get_current_win()
  local ways = {
    q = function() press("q") end,
    esc = function() press("<Esc>") end,
    quit = function() vim.cmd("q") end,
    close = function() press("<C-w>c") end,
    wipe = function(got) vim.api.nvim_buf_delete(got.buf, { force = true }) end,
  }
  for name, close in pairs(ways) do
    local before = bufs()
    local got = open({ text = "kept text" })
    type_text("<Esc>")
    close(got)
    settle()
    assert(#got.submitted == 0, name .. " submitted")
    assert(got.cancelled == 1, name .. " cancelled " .. got.cancelled .. " times")
    assert(not vim.api.nvim_win_is_valid(got.win), name .. " left the window open")
    assert(not vim.api.nvim_buf_is_valid(got.buf) and bufs() == before, name .. " leaked the buffer")
    assert(vim.api.nvim_get_current_win() == origin, name .. " did not return")
  end
  drain()
end

M[":w in the editor sends"] = function()
  local origin = vim.api.nvim_get_current_win()
  local got = open()
  type_text("written<Esc>")
  vim.cmd("w")
  settle()
  assert(vim.deep_equal(got.submitted, { "written" }) and got.cancelled == 0, vim.inspect(got))
  assert(not vim.api.nvim_win_is_valid(got.win) and vim.api.nvim_get_current_win() == origin)
end

M["the editor buffer is modified while it has text, so :qa elsewhere is refused; :q in it cancels"] = function()
  local origin = vim.api.nvim_get_current_win()
  local got = open()
  settle()
  assert(not vim.bo[got.buf].modified, "empty editor is modified")
  type_text("unsent<Esc>")
  settle()
  assert(vim.bo[got.buf].modified, "editor with text is not modified")
  type_text("cc<Esc>")
  settle()
  assert(not vim.bo[got.buf].modified, "emptied editor is still modified")
  type_text("ccunsent again<Esc>")
  settle()
  -- Quitting from another window stops at the editor's unsent text.
  vim.api.nvim_set_current_win(origin)
  local quit = pcall(vim.cmd, "qa")
  assert(not quit and vim.api.nvim_win_is_valid(got.win), ":qa left the unsent text")
  -- :q in the editor cancels and keeps the draft.
  vim.api.nvim_set_current_win(got.win)
  vim.cmd("q")
  settle()
  assert(got.cancelled == 1 and #got.submitted == 0, vim.inspect(got))
  assert(not vim.api.nvim_win_is_valid(got.win) and vim.api.nvim_get_current_win() == origin)
  local back = open()
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(back.buf, 0, -1, false), { "unsent again" }), "draft lost")
  type_text("<Esc>q")
  drain()
end

M["a second open focuses the first editor and says to finish it first"] = function()
  local live = open({ text = "live" })
  local second = { submitted = {} }
  local notes = {}
  local real_notify = vim.notify
  vim.notify = function(msg) notes[#notes + 1] = msg end
  vim.api.nvim_set_current_win(vim.fn.win_getid(1))
  editor.open({ title = " other ", on_submit = function(t) second.submitted[#second.submitted + 1] = t end })
  vim.notify = real_notify
  assert(vim.deep_equal(notes, { "pi: finish or cancel the open note first" }), vim.inspect(notes))
  assert(vim.api.nvim_get_current_win() == live.win, "second open did not focus the first")
  local floats = vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_list_wins())
  assert(#floats == 1, "two editors open")
  type_text("<Esc><C-s>")
  assert(vim.deep_equal(live.submitted, { "live" }) and #second.submitted == 0, vim.inspect({ live.submitted, second.submitted }))
end

M["leaving the editor keeps it open with its text"] = function()
  local origin = vim.api.nvim_get_current_win()
  local got = open({ text = "kept text" })
  vim.api.nvim_set_current_win(origin)
  settle()
  assert(vim.api.nvim_win_is_valid(got.win) and got.cancelled == 0, "leaving closed the editor")
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(got.buf, 0, -1, false), { "kept text" }))
  vim.api.nvim_set_current_win(got.win)
  type_text("<Esc>q")
  settle()
  assert(got.cancelled == 1)
  drain()
end

M["cancelled text comes back on the next open, once, and sending clears it"] = function()
  local first = open()
  type_text("my long note<Esc>q")
  settle()
  assert(first.cancelled == 1)
  local notes = {}
  local real_notify = vim.notify
  vim.notify = function(msg) notes[#notes + 1] = msg end
  local second = open()
  vim.notify = real_notify
  -- The footer says so; a notice would stack on a switch notice and ask to press ENTER.
  assert(#notes == 0, vim.inspect(notes))
  assert(vim.api.nvim_win_get_config(second.win).footer[1][1] == " restored · <C-s> send · q cancel ", vim.inspect(vim.api.nvim_win_get_config(second.win).footer))
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(second.buf, 0, -1, false), { "my long note" }))
  type_text(" more<C-s>")
  assert(vim.deep_equal(second.submitted, { "my long note more" }), vim.inspect(second.submitted))
  local third = open()
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(third.buf, 0, -1, false), { "" }), "draft survived sending")
  assert(vim.api.nvim_win_get_config(third.win).footer[1][1] == " <C-s> send · q cancel ")
  type_text("<Esc>q")
  -- Wiping the buffer keeps the text too.
  local wiped = open()
  type_text("wipe me<Esc>")
  vim.api.nvim_buf_delete(wiped.buf, { force = true })
  settle()
  local back = open()
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(back.buf, 0, -1, false), { "wipe me" }), "wiped text lost")
  type_text("<Esc>q")
  drain()
end

M["cancelling an edit keeps other drafts; changed edit text returns only to that edit"] = function()
  editor.stash("ask", "pending ask")
  editor.stash("note", "pending note")
  local unchanged = open({ text = "old note", draft = "edit:1" })
  type_text("<Esc>q")
  settle()
  assert(unchanged.cancelled == 1)
  local changed = open({ text = "old note", draft = "edit:1" })
  type_text("<Esc>A more<Esc>q")
  settle()
  assert(changed.cancelled == 1)
  local ask = open({ draft = "ask" })
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(ask.buf, 0, -1, false), { "pending ask" }))
  type_text("<Esc>q")
  local note = open({ draft = "note" })
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(note.buf, 0, -1, false), { "pending note" }))
  type_text("<Esc>q")
  local again = open({ text = "old note", draft = "edit:1" })
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(again.buf, 0, -1, false), { "old note more" }), "edit draft lost")
  type_text("<Esc>q")
  local plain = open({ draft = "edit:2" })
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(plain.buf, 0, -1, false), { "" }))
  type_text("<Esc>q")
  drain()
end

M["editors without a draft key keep nothing"] = function()
  local got = editor.open({ title = " x ", on_submit = function() end })
  type_text("lost<Esc>q")
  settle()
  local next_got = open({ draft = "none" })
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(next_got.buf, 0, -1, false), { "" }))
  type_text("<Esc>q")
  drain()
end

M["stash keeps text for the next open"] = function()
  editor.stash("test", "failed send")
  local got = open()
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(got.buf, 0, -1, false), { "failed send" }))
  type_text("<Esc>q")
  drain()
end

M["a restored draft cancelled unchanged stays; blanked, it is gone"] = function()
  editor.stash("edit:1", "half edit")
  local restored = open({ text = "old note", draft = "edit:1" })
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(restored.buf, 0, -1, false), { "half edit" }))
  type_text("<Esc>q")
  settle()
  local again = open({ text = "old note", draft = "edit:1" })
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(again.buf, 0, -1, false), { "half edit" }), "unchanged restored draft lost")
  type_text("<Esc>ggdG")
  type_text("<Esc>q")
  settle()
  local blanked = open({ text = "old note", draft = "edit:1" })
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(blanked.buf, 0, -1, false), { "old note" }), "blanked draft came back")
  type_text("<Esc>q")
  drain()
end

M["discard_draft with text forgets the draft only while it is still that text"] = function()
  editor.stash("ask", "sent text")
  editor.discard_draft("ask", "sent text")
  local first = open({ draft = "ask" })
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(first.buf, 0, -1, false), { "" }))
  type_text("<Esc>q")
  editor.stash("ask", "newer text")
  editor.discard_draft("ask", "sent text")
  local second = open({ draft = "ask" })
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(second.buf, 0, -1, false), { "newer text" }), "newer draft dropped")
  type_text("<Esc>q")
  drain()
end

M["a checkpoint arriving while the editor is open keeps it, its text and the focus, and opens the list"] = function()
  local pi = require("pi")
  local session = require("pi.session")
  local panel = require("pi.panel")
  local live = require("pi.live")
  local saved = { on_event = session.on_event, ensure = session.ensure, request = session.request, schedule = live.schedule }
  local handler
  session.on_event = function(fn) handler = fn end
  local real_notify = vim.notify
  vim.notify = function() end
  pi.setup()
  vim.notify = real_notify
  session.on_event = saved.on_event
  session.ensure = function(cb) cb() end
  session.request = function(_, _, cb) cb(nil, {}) end
  live.schedule = function() end
  local ok, err = pcall(function()
    vim.cmd("only")
    local got = open()
    -- Typed and still in insert mode when the checkpoint arrives.
    local mode
    _G.pi_spec_chunk_ready = function()
      mode = vim.api.nvim_get_mode().mode
      handler("chunk_ready", { chunk = { n = 5, status = "open" } })
    end
    type_text("half a note<Cmd>lua _G.pi_spec_chunk_ready()<CR>")
    _G.pi_spec_chunk_ready = nil
    assert(mode == "i", tostring(mode))
    assert(vim.api.nvim_win_is_valid(got.win) and got.cancelled == 0, "the checkpoint closed the editor")
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(got.buf, 0, -1, false), { "half a note" }), "text lost")
    assert(vim.api.nvim_get_current_win() == got.win, "focus left the editor")
    assert(panel.visible(), "checkpoint list not open")
    type_text("<Esc>q")
    panel.close()
  end)
  session.ensure, session.request, live.schedule = saved.ensure, saved.request, saved.schedule
  vim.api.nvim_clear_autocmds({ group = "pi" })
  drain()
  assert(ok, err)
end

M["`:wq` submits once and closes only the editor"] = function()
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local origin = vim.api.nvim_get_current_win()
  local got = open({ text = "note" })
  type_text("<Esc>")
  vim.cmd("wq")
  settle()
  assert(#got.submitted == 1 and got.submitted[1] == "note", "submitted " .. #got.submitted .. " times")
  assert(vim.api.nvim_win_is_valid(origin), "origin window closed")
  assert(not vim.api.nvim_win_is_valid(got.win), "editor window still open")
  assert(not vim.api.nvim_buf_is_valid(got.buf), "editor buffer still there")
  assert(vim.api.nvim_get_current_win() == origin, "focus not back on origin")
  vim.cmd("tabclose")
  assert(not vim.api.nvim_tabpage_is_valid(tab))
end

return M
