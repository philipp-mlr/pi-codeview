local session = require("codeview.session")
local diff = require("codeview.diff")

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

local function buffer_map(buf, lhs)
  return vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg(lhs, "n", false, true)
  end)
end

M["user buffer-local file keys are restored after the diff tab closes"] = function()
  local root, sha = chunk_repo()
  local buf = vim.fn.bufadd(root .. "/a.txt")
  vim.fn.bufload(buf)
  vim.keymap.set("n", "]f", "<Nop>", { buffer = buf, desc = "user" })
  open_chunk(root, sha)
  assert(buffer_map(buf, "]f").desc ~= "user", "codeview did not map ]f")
  vim.cmd("tabclose")
  diff.cleanup()
  assert(buffer_map(buf, "]f").desc == "user", vim.inspect(buffer_map(buf, "]f")))
  assert(vim.tbl_isempty(buffer_map(buf, "[f")), "[f leaked: " .. vim.inspect(buffer_map(buf, "[f")))
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
