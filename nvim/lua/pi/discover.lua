local M = {}

local PROBE_TIMEOUT_MS = 200

local function git(dir, args)
  local cmd = vim.list_extend({ "git" }, args)
  local ok, result = pcall(function()
    return vim.system(cmd, { cwd = dir, text = true }):wait()
  end)
  if not ok or result.code ~= 0 then
    return nil
  end
  return (result.stdout:gsub("%s+$", ""))
end

function M.root(dir)
  local top = git(dir, { "rev-parse", "--show-toplevel" })
  if not top or top == "" then
    return nil
  end
  return vim.uv.fs_realpath(top) or top
end

function M.repo_hash(dir)
  local common = git(dir, { "rev-parse", "--git-common-dir" })
  if not common or common == "" then
    return nil
  end
  local resolved = vim.fs.normalize(common:sub(1, 1) == "/" and common or (dir .. "/" .. common))
  local real = vim.uv.fs_realpath(resolved)
  if not real then
    return nil
  end
  return vim.fn.sha256(real):sub(1, 12)
end

function M.runtime_dir()
  local xdg = vim.env.XDG_RUNTIME_DIR
  if xdg and xdg ~= "" then
    return xdg
  end
  return vim.uv.os_tmpdir()
end

local function is_live(path)
  local pipe = vim.uv.new_pipe(false)
  local done, live = false, false
  pipe:connect(path, function(err)
    live = err == nil
    done = true
  end)
  vim.wait(PROBE_TIMEOUT_MS, function()
    return done
  end, 5)
  if not pipe:is_closing() then
    pipe:close()
  end
  return live
end

function M.sockets(dir)
  local hash = M.repo_hash(dir)
  if not hash then
    return {}
  end
  local sock_dir = M.runtime_dir() .. "/pi-nvim/" .. hash
  local entries = {}
  for name, kind in vim.fs.dir(sock_dir) do
    if name:match("%.sock$") and (kind == "socket" or kind == "unknown") then
      local path = sock_dir .. "/" .. name
      local stat = vim.uv.fs_stat(path)
      if stat and is_live(path) then
        table.insert(entries, { path = path, mtime = stat.mtime.sec * 1e9 + stat.mtime.nsec })
      end
    end
  end
  table.sort(entries, function(a, b)
    return a.mtime > b.mtime
  end)
  return vim.tbl_map(function(e)
    return e.path
  end, entries)
end

function M.relpath(root, abspath)
  local base = root:gsub("/+$", "")
  if abspath:sub(1, #base + 1) ~= base .. "/" then
    return nil
  end
  return abspath:sub(#base + 2)
end

return M
