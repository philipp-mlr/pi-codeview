local annotations = require("pi.annotations")

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
  assert(#list == 2, vim.inspect(list))
  assert(list[1].path == "d.txt" and list[1].startLine == 2 and list[1].endLine == 4 and list[1].note == "r", vim.inspect(list))
  assert(vim.deep_equal(list[2], { path = "missing.txt", startLine = 1, endLine = 1, note = "gone" }), vim.inspect(list))
  annotations.clear()
end

M["restore is idempotent, keeps unplaced, fires on_change only on news"] = function()
  annotations.clear()
  local root = temp_root()
  file_buf(root, "f.txt", numbered(8))
  local drafts = {
    { path = "f.txt", startLine = 2, endLine = 4, note = "r" },
    { path = "missing.txt", startLine = 1, endLine = 1, note = "gone" },
  }
  annotations.restore(drafts, root)
  annotations.restore(drafts, root)
  assert(annotations.count(root) == 2, annotations.count(root))
  assert(#annotations.list(root) == 2, vim.inspect(annotations.list(root)))
  local fired = 0
  annotations.on_change(function() fired = fired + 1 end)
  annotations.restore(drafts, root)
  vim.wait(50, function() return fired > 0 end)
  assert(fired == 0, "fired " .. fired)
  annotations.on_change(nil)
  annotations.clear()
  assert(annotations.count() == 0 and #annotations.list(root) == 0)
end

M["restore dedupes out-of-range drafts that were clamped"] = function()
  annotations.clear()
  local root = temp_root()
  file_buf(root, "o.txt", numbered(8))
  local drafts = { { path = "o.txt", startLine = 20, endLine = 22, note = "far" } }
  annotations.restore(drafts, root)
  annotations.restore(drafts, root)
  local list = annotations.list(root)
  assert(#list == 1, vim.inspect(list))
  annotations.clear()
end

M["restore places a previously unplaced draft once its file exists"] = function()
  annotations.clear()
  local root = temp_root()
  local drafts = { { path = "late.txt", startLine = 2, endLine = 3, note = "late" } }
  annotations.restore(drafts, root)
  assert(#annotations.list(root) == 1)
  file_buf(root, "late.txt", numbered(8))
  annotations.restore(drafts, root)
  annotations.restore(drafts, root)
  local list = annotations.list(root)
  assert(#list == 1, vim.inspect(list))
  assert(list[1].startLine == 2 and list[1].endLine == 3, vim.inspect(list))
  assert(annotations.count() == 1, annotations.count())
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

M["clear_root drops only the annotations and unplaced drafts of that root"] = function()
  annotations.clear()
  local root, other = temp_root(), temp_root()
  annotations.add(file_buf(root, "a.txt", numbered(3)), 1, 1, "sent")
  annotations.add(file_buf(other, "b.txt", numbered(3)), 1, 1, "kept")
  annotations.restore({ { path = "gone.txt", startLine = 1, endLine = 1, note = "sent too" } }, root)
  annotations.restore({ { path = "gone.txt", startLine = 1, endLine = 1, note = "kept too" } }, other)
  annotations.clear_root(root)
  assert(#annotations.list(root) == 0, vim.inspect(annotations.list(root)))
  local left = vim.tbl_map(function(a) return a.note end, annotations.list(other))
  assert(vim.deep_equal(left, { "kept", "kept too" }), vim.inspect(left))
  annotations.clear()
end

M["list with diagnostics attaches those on the annotation's current lines"] = function()
  local dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  vim.fn.writefile({ "a", "b", "c", "d" }, dir .. "/x.lua")
  local buf = vim.fn.bufadd(dir .. "/x.lua")
  vim.fn.bufload(buf)
  annotations.clear()
  local ns = vim.api.nvim_create_namespace("pi_test_ann_diag")
  vim.diagnostic.set(ns, buf, {
    { lnum = 1, col = 0, severity = vim.diagnostic.severity.ERROR, message = "bad" },
    { lnum = 3, col = 0, severity = vim.diagnostic.severity.ERROR, message = "elsewhere" },
  })
  annotations.add(buf, 2, 3, "note")
  -- A line inserted above moves the annotation to 3-4; the diagnostic on line 2 moves with it only when set again.
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new" })
  local plain = annotations.list(dir)
  assert(plain[1].diagnostics == nil, vim.inspect(plain))
  local list = annotations.list(dir, { diagnostics = true })
  assert(list[1].startLine == 3 and list[1].endLine == 4, vim.inspect(list))
  assert(#list[1].diagnostics == 1 and list[1].diagnostics[1].message == "elsewhere", vim.inspect(list))
  annotations.clear()
  vim.api.nvim_buf_delete(buf, { force = true })
end

local function marks(buf)
  local ns = vim.api.nvim_create_namespace("pi_annotations")
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

local function virt_line_marks(buf)
  return vim.tbl_filter(function(m) return m[4].virt_lines ~= nil end, marks(buf))
end

M["annotation text is a virt_lines mark on the last line, single line, and follows inserted lines"] = function()
  annotations.clear()
  local root = temp_root()
  local buf = file_buf(root, "v.txt", numbered(10))
  annotations.add(buf, 3, 5, "multi\nline   note")
  local v = virt_line_marks(buf)
  assert(#v == 1 and v[1][2] == 4, vim.inspect(v))
  assert(v[1][4].virt_lines[1][1][1] == "  ✎ multi line note", vim.inspect(v))
  assert(v[1][4].virt_lines[1][1][2] == "PiAnnotation")
  assert(not v[1][4].virt_lines_above)
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "x", "y" })
  v = virt_line_marks(buf)
  assert(v[1][2] == 6, vim.inspect(v))
  annotations.clear()
  vim.api.nvim_buf_delete(buf, { force = true })
end

M["sign has priority 200, above live marks, and the number highlight covers every line of the range"] = function()
  annotations.clear()
  local root = temp_root()
  local buf = file_buf(root, "n.txt", numbered(10))
  annotations.add(buf, 3, 5, "note")
  local signs, numbered_rows = {}, {}
  for _, m in ipairs(marks(buf)) do
    if m[4].sign_text then signs[#signs + 1] = m end
    if m[4].number_hl_group == "PiAnnotationSign" then numbered_rows[#numbered_rows + 1] = m[2] end
  end
  table.sort(numbered_rows)
  assert(#signs == 1 and signs[1][4].priority == 200 and vim.trim(signs[1][4].sign_text) == "✎", vim.inspect(signs))
  assert(vim.deep_equal(numbered_rows, { 2, 3, 4 }), vim.inspect(numbered_rows))
  annotations.clear()
  vim.api.nvim_buf_delete(buf, { force = true })
end

M["live marks use a lower sign priority than annotations"] = function()
  annotations.clear()
  local live = require("pi.live")
  local root = temp_root()
  local function git(...)
    local r = vim.system({ "git", ... }, { cwd = root, text = true }):wait()
    assert(r.code == 0, r.stderr)
    return vim.trim(r.stdout)
  end
  git("init", "-q")
  git("config", "user.email", "t@example.com")
  git("config", "user.name", "t")
  git("config", "commit.gpgsign", "false")
  vim.fn.writefile(numbered(5), root .. "/l.txt")
  git("add", "l.txt")
  git("commit", "-q", "-m", "base")
  local base = git("rev-parse", "HEAD")
  local buf = file_buf(root, "l.txt", numbered(5))
  vim.bo[buf].buflisted = true
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "changed" })
  vim.bo[buf].modified = false
  live.refresh(root, base)
  local live_ns = vim.api.nvim_create_namespace("pi_live")
  local live_marks = {}
  vim.wait(3000, function()
    live_marks = vim.api.nvim_buf_get_extmarks(buf, live_ns, 0, -1, { details = true })
    return #live_marks > 0
  end)
  assert(#live_marks > 0, "live.lua placed no mark")
  annotations.add(buf, 2, 2, "note")
  local sign
  for _, m in ipairs(marks(buf)) do
    if m[4].sign_text then sign = m end
  end
  assert(live_marks[1][4].priority < sign[4].priority, vim.inspect({ live_marks[1][4], sign[4] }))
  live.clear()
  annotations.clear()
  vim.api.nvim_buf_delete(buf, { force = true })
end

local function wait_for(cond, what)
  assert(vim.wait(1000, cond, 10), "timed out: " .. what)
end

local function number_rows(buf)
  local rows = {}
  for _, m in ipairs(marks(buf)) do
    if m[4].number_hl_group == "PiAnnotationSign" then rows[#rows + 1] = m[2] end
  end
  table.sort(rows)
  return rows
end

M["text mark stays on the last row when a line is inserted at the last row"] = function()
  annotations.clear()
  local root = temp_root()
  local buf = file_buf(root, "i.txt", numbered(10))
  annotations.add(buf, 3, 5, "note")
  vim.api.nvim_buf_set_lines(buf, 4, 4, false, { "new" }) -- like `O` on the last line
  wait_for(function()
    local v = virt_line_marks(buf)
    return #v == 1 and v[1][2] == 5 and #number_rows(buf) == 4
  end, "marks rebuilt on the grown range")
  assert(vim.deep_equal(number_rows(buf), { 2, 3, 4, 5 }), vim.inspect(number_rows(buf)))
  local list = annotations.list(root)
  assert(list[1].startLine == 3 and list[1].endLine == 6, vim.inspect(list))
  annotations.clear()
  vim.api.nvim_buf_delete(buf, { force = true })
end

M["number marks cover a line inserted in the middle of the range"] = function()
  annotations.clear()
  local root = temp_root()
  local buf = file_buf(root, "m.txt", numbered(10))
  annotations.add(buf, 3, 5, "note")
  vim.api.nvim_buf_set_lines(buf, 3, 3, false, { "mid" })
  wait_for(function() return #number_rows(buf) == 4 end, "four number marks")
  assert(vim.deep_equal(number_rows(buf), { 2, 3, 4, 5 }), vim.inspect(number_rows(buf)))
  annotations.clear()
  vim.api.nvim_buf_delete(buf, { force = true })
end

M["deleting the last line of the range leaves marks only on remaining rows"] = function()
  annotations.clear()
  local root = temp_root()
  local buf = file_buf(root, "d2.txt", numbered(10))
  annotations.add(buf, 3, 5, "note")
  vim.api.nvim_buf_set_lines(buf, 4, 5, false, {})
  wait_for(function()
    local v = virt_line_marks(buf)
    return #v == 1 and v[1][2] == 4 and #number_rows(buf) == 3
  end, "marks rebuilt on the range after the deletion")
  -- The range end sits at column 0 of the following line, so deleting the last line pulls it up to that line.
  local list = annotations.list(root)
  assert(list[1].startLine == 3 and list[1].endLine == 5, vim.inspect(list))
  assert(vim.deep_equal(number_rows(buf), { 2, 3, 4 }), vim.inspect(number_rows(buf)))
  annotations.clear()
  assert(#marks(buf) == 0, vim.inspect(marks(buf)))
  vim.api.nvim_buf_delete(buf, { force = true })
end

M["remove deletes the sign, number and text marks"] = function()
  annotations.clear()
  local root = temp_root()
  local buf = file_buf(root, "r.txt", numbered(10))
  annotations.add(buf, 3, 5, "note")
  assert(#marks(buf) > 0)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  assert(annotations.remove_at_cursor() == 1)
  assert(#marks(buf) == 0, vim.inspect(marks(buf)))
  vim.api.nvim_buf_delete(buf, { force = true })
end

return M
