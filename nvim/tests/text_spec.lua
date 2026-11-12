local text = require("pi.text")

local M = {}

local function capture(fn)
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

local function with_columns(columns, fn)
  local saved = vim.o.columns
  vim.o.columns = columns
  local ok, err = pcall(fn)
  vim.o.columns = saved
  assert(ok, err)
end

M["wrap breaks at spaces only, never at . or /"] = function()
  local lines = text.wrap("call discover.collect(root) from session.lua and nvim/lua/pi/init.lua", 24)
  assert(vim.deep_equal(lines, { "call", "discover.collect(root)", "from session.lua and", "nvim/lua/pi/init.lua" }), vim.inspect(lines))
  -- A word wider than the line is cut at the width.
  assert(vim.deep_equal(text.wrap("abcdef", 4), { "abcd", "ef" }))
  assert(vim.deep_equal(text.wrap("ééé ééé", 3), { "ééé", "ééé" }))
end

M["notify_fit shows the first variant that fits v:echospace"] = function()
  with_columns(80, function()
    local room = vim.v.echospace
    local long = "pi: " .. ("x"):rep(room)
    local fits = "pi: short"
    local notes = capture(function() text.notify_fit({ long, fits }, vim.log.levels.WARN) end)
    assert(#notes == 1 and notes[1].msg == fits and notes[1].level == vim.log.levels.WARN, vim.inspect(notes))
    notes = capture(function() text.notify_fit(fits) end)
    assert(notes[1].msg == fits, vim.inspect(notes))
  end)
end

M["notify_fit cuts the last variant with … when none fits"] = function()
  with_columns(80, function()
    local room = vim.v.echospace
    local notes = capture(function() text.notify_fit({ ("a "):rep(80), ("b "):rep(80) }) end)
    assert(vim.fn.strdisplaywidth(notes[1].msg) <= room, notes[1].msg)
    assert(vim.startswith(notes[1].msg, "b b") and vim.endswith(notes[1].msg, "…"), notes[1].msg)
  end)
end

M["short_target keeps the file name of a path, commands stay, long ones end in …"] = function()
  assert(text.short_target("src/discover.lua") == "discover.lua")
  assert(text.short_target("/abs/path/to/session.lua") == "session.lua")
  assert(text.short_target("npm test -- --run") == "npm test -- --run")
  assert(text.short_target(("é"):rep(50)) == ("é"):rep(40) .. "…")
  assert(text.short_target("") == "" and text.short_target(nil) == "")
end

return M
