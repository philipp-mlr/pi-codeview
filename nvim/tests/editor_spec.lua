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
  assert(vim.bo[got.buf].filetype == "markdown" and vim.bo[got.buf].buftype == "nofile" and vim.bo[got.buf].bufhidden == "wipe")
  type_text("<Esc>q")
  assert(vim.api.nvim_get_current_win() == origin)
end

M["editor height grows with the text from 3 up to 15 lines"] = function()
  local five = open({ text = "1\n2\n3\n4\n5" })
  assert(vim.api.nvim_win_get_height(five.win) == 5)
  type_text("<Esc>q")
  local many = open({ text = ("x\n"):rep(30) .. "x" })
  assert(vim.api.nvim_win_get_height(many.win) == 15)
  type_text("<Esc>q")
  local grows = open()
  type_text("a<CR>b<CR>c<CR>d<Esc>")
  settle()
  assert(vim.api.nvim_win_get_height(grows.win) == 4, vim.api.nvim_win_get_height(grows.win))
  press("q")
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
    leave = function() vim.api.nvim_set_current_win(origin) end,
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
end

M["a second open focuses the first editor"] = function()
  -- Leaving the editor cancels it, so the second open comes from inside it (e.g. <leader>pa there).
  local live = open({ text = "live" })
  local second = { submitted = {} }
  editor.open({ title = " other ", on_submit = function(t) second.submitted[#second.submitted + 1] = t end })
  assert(vim.api.nvim_get_current_win() == live.win, "second open did not focus the first")
  local floats = vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_list_wins())
  assert(#floats == 1, "two editors open")
  type_text("<Esc><C-s>")
  assert(vim.deep_equal(live.submitted, { "live" }) and #second.submitted == 0, vim.inspect({ live.submitted, second.submitted }))
end

return M
