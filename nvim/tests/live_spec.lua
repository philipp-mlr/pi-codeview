local live = require("pi.live")

local M = {}
local ns = vim.api.nvim_create_namespace("pi_live")

local function sh(root, ...)
  local r = vim.system({ "git", "-C", root, ... }, { text = true }):wait()
  assert(r.code == 0, r.stderr)
  return vim.trim(r.stdout)
end

local function repo()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  root = vim.uv.fs_realpath(root)
  sh(root, "init", "-q")
  sh(root, "config", "user.email", "t@t")
  sh(root, "config", "user.name", "t")
  vim.fn.writefile({ "one", "two", "three", "four" }, root .. "/a.txt")
  sh(root, "add", ".")
  sh(root, "commit", "-q", "-m", "init")
  return root, sh(root, "rev-parse", "HEAD")
end

local function marks(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    out[#out + 1] = { line = m[2] + 1, sign = vim.trim(m[4].sign_text), hl = m[4].sign_hl_group }
  end
  return out
end

local function open(root, name)
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. name))
  return vim.api.nvim_get_current_buf()
end

local function wait_for(cond)
  assert(vim.wait(5000, cond, 10), "timed out waiting")
end

local function write_later(path, lines)
  -- Distinct mtime from the one nvim saw when it loaded the file.
  vim.wait(1100)
  vim.fn.writefile(lines, path)
end

M["a changed file is reloaded and marked on exactly the changed lines"] = function()
  local root, base = repo()
  local buf = open(root, "a.txt")
  write_later(root .. "/a.txt", { "one", "TWO", "three", "four", "five" })
  live.refresh(root, base)
  wait_for(function() return #marks(buf) == 2 end)
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "one", "TWO", "three", "four", "five" }))
  local got = marks(buf)
  assert(#got == 2, vim.inspect(got))
  assert(got[1].line == 2 and got[1].sign == "▎" and got[1].hl == "PiLiveSignChange", vim.inspect(got))
  assert(got[2].line == 5 and got[2].sign == "▎" and got[2].hl == "PiLiveSignAdd", vim.inspect(got))
  live.clear()
end

M["line_hl places PiLive on changed lines only when enabled"] = function()
  local root, base = repo()
  local buf = open(root, "a.txt")
  write_later(root .. "/a.txt", { "one", "TWO", "three", "four" })
  local function line_hls()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      out[#out + 1] = m[4].line_hl_group or false
    end
    return out
  end
  live.refresh(root, base)
  wait_for(function() return #marks(buf) == 1 end)
  assert(vim.deep_equal(line_hls(), { false }), vim.inspect(line_hls()))
  live.clear()
  live.line_hl = true
  live.refresh(root, base)
  wait_for(function() return #marks(buf) == 1 end)
  local got = line_hls()
  live.line_hl = false
  live.clear()
  assert(vim.deep_equal(got, { "PiLive" }), vim.inspect(got))
end

M["a deleted-only hunk is marked on the line above"] = function()
  local root, base = repo()
  local buf = open(root, "a.txt")
  write_later(root .. "/a.txt", { "one", "three", "four" })
  live.refresh(root, base)
  wait_for(function() return #marks(buf) == 1 end)
  local got = marks(buf)
  assert(#got == 1 and got[1].line == 1 and got[1].sign == "▁" and got[1].hl == "PiLiveSignDelete", vim.inspect(got))
  live.clear()
end

M["a modified buffer is kept and warns once"] = function()
  local root, base = repo()
  local buf = open(root, "a.txt")
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "mine" })
  live.refresh(root, base) -- remember the mtime
  local notes = {}
  local original = vim.notify
  vim.notify = function(msg)
    notes[#notes + 1] = msg
  end
  write_later(root .. "/a.txt", { "one", "agent", "three", "four" })
  live.refresh(root, base)
  live.refresh(root, base)
  vim.notify = original
  assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "mine")
  assert(#notes == 1 and notes[1] == "pi: a.txt changed on disk; your unsaved edits are kept", vim.inspect(notes))
  vim.bo[buf].modified = false
  live.clear()
end

M["clear removes the marks"] = function()
  local root, base = repo()
  local buf = open(root, "a.txt")
  write_later(root .. "/a.txt", { "x", "two", "three", "four" })
  live.refresh(root, base)
  wait_for(function() return #marks(buf) == 1 end)
  live.clear()
  assert(#marks(buf) == 0)
end

M["a file missing from the baseline is all added and a deleted file does not error"] = function()
  local root, base = repo()
  vim.fn.writefile({ "n1", "n2" }, root .. "/new.txt")
  local buf = open(root, "new.txt")
  open(root, "a.txt")
  vim.fn.delete(root .. "/a.txt")
  local ok, err = pcall(live.refresh, root, base)
  assert(ok, err)
  wait_for(function() return #marks(buf) == 2 end)
  assert(#marks(buf) == 2, vim.inspect(marks(buf)))
  live.clear()
end

M["an unchanged second refresh calls no git; a change recomputes only that buffer"] = function()
  local root, base = repo()
  vim.fn.writefile({ "x", "y" }, root .. "/b.txt")
  sh(root, "add", ".")
  sh(root, "commit", "-q", "-m", "b")
  base = sh(root, "rev-parse", "HEAD")
  local a, b = open(root, "a.txt"), open(root, "b.txt")
  local calls = 0
  local system = vim.system
  vim.system = function(cmd, ...)
    if cmd[1] == "git" then
      calls = calls + 1
    end
    return system(cmd, ...)
  end
  local diffs = {}
  local diff = vim.diff
  vim.diff = function(...)
    diffs[#diffs + 1] = true
    return diff(...)
  end
  live.refresh(root, base)
  wait_for(function() return #diffs == 2 end)
  assert(calls == 2, calls)
  live.refresh(root, base)
  vim.wait(200)
  assert(calls == 2 and #diffs == 2, ("calls=%d diffs=%d"):format(calls, #diffs))
  vim.api.nvim_buf_set_lines(a, 0, 1, false, { "ONE" })
  live.refresh(root, base)
  wait_for(function() return #diffs == 3 end)
  vim.wait(100)
  vim.system, vim.diff = system, diff
  assert(#diffs == 3 and calls == 2, ("calls=%d diffs=%d"):format(calls, #diffs))
  assert(#marks(a) == 1 and #marks(b) == 0)
  vim.bo[a].modified = false
  live.clear()
end

M["a file without a trailing newline is not marked when unchanged"] = function()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  root = vim.uv.fs_realpath(root)
  sh(root, "init", "-q")
  sh(root, "config", "user.email", "t@t")
  sh(root, "config", "user.name", "t")
  local f = assert(io.open(root .. "/n.txt", "wb"))
  f:write("one\ntwo")
  f:close()
  sh(root, "add", ".")
  sh(root, "commit", "-q", "-m", "noeol")
  local base = sh(root, "rev-parse", "HEAD")
  local buf = open(root, "n.txt")
  assert(not vim.bo[buf].eol)
  local diffs = 0
  local diff = vim.diff
  vim.diff = function(...)
    diffs = diffs + 1
    return diff(...)
  end
  live.refresh(root, base)
  wait_for(function() return diffs == 1 end)
  vim.diff = diff
  assert(#marks(buf) == 0, vim.inspect(marks(buf)))
  live.clear()
end

return M
