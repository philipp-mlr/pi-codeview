local annotations = require("codeview.annotations")

local M = {}

local function temp_root()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return vim.uv.fs_realpath(dir)
end

local function file_buf(root, name, lines)
  local path = root .. "/" .. name
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  return buf
end

local function numbered(n)
  local lines = {}
  for i = 1, n do lines[i] = "line " .. i end
  return lines
end

M["annotation follows inserted lines above it"] = function()
  annotations.clear()
  local root = temp_root()
  local buf = file_buf(root, "a.txt", numbered(10))
  annotations.add(buf, 5, 6, "hello")
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "x", "y" })
  local list = annotations.list(root)
  assert(#list == 1, "count " .. #list)
  assert(list[1].startLine == 7 and list[1].endLine == 8, vim.inspect(list))
  assert(list[1].path == "a.txt" and list[1].note == "hello", vim.inspect(list))
  annotations.clear()
end

M["annotations across two buffers are all listed"] = function()
  annotations.clear()
  local root = temp_root()
  local b1 = file_buf(root, "b.txt", numbered(5))
  local b2 = file_buf(root, "sub/a.txt", numbered(5))
  local other = file_buf(temp_root(), "z.txt", numbered(5))
  annotations.add(b1, 3, 3, "one")
  annotations.add(b2, 2, 4, "two")
  annotations.add(other, 1, 1, "outside")
  local list = annotations.list(root)
  assert(#list == 2, vim.inspect(list))
  assert(list[1].path == "b.txt" and list[2].path == "sub/a.txt", vim.inspect(list))
  assert(annotations.count() == 3)
  annotations.clear()
  assert(annotations.count() == 0)
end

M["buffer text is unchanged"] = function()
  annotations.clear()
  local root = temp_root()
  local lines = numbered(5)
  local buf = file_buf(root, "c.txt", lines)
  annotations.add(buf, 2, 3, "note")
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines))
  assert(not vim.bo[buf].modified)
  annotations.clear()
end

M["restore places drafts"] = function()
  annotations.clear()
  local root = temp_root()
  file_buf(root, "d.txt", numbered(8))
  annotations.restore({
    { path = "d.txt", startLine = 2, endLine = 4, note = "r" },
    { path = "missing.txt", startLine = 1, endLine = 1, note = "gone" },
  }, root)
  local list = annotations.list(root)
  assert(#list == 1, vim.inspect(list))
  assert(list[1].startLine == 2 and list[1].endLine == 4 and list[1].note == "r", vim.inspect(list))
  annotations.clear()
end

M["remove_at_cursor removes containing range and on_change fires"] = function()
  annotations.clear()
  local root = temp_root()
  local buf = file_buf(root, "e.txt", numbered(8))
  vim.api.nvim_set_current_buf(buf)
  local fired = 0
  annotations.on_change(function() fired = fired + 1 end)
  annotations.add(buf, 2, 4, "a")
  annotations.add(buf, 7, 7, "b")
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  assert(annotations.remove_at_cursor() == 1)
  assert(annotations.count() == 1)
  vim.wait(100, function() return fired >= 2 end)
  assert(fired >= 2, "fired " .. fired)
  annotations.on_change(nil)
  annotations.clear()
end

return M
