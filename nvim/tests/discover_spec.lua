local discover = require("codeview.discover")

local spec_path = debug.getinfo(1, "S").source:sub(2)
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(spec_path, ":p"))))

local function sh(cwd, cmd)
  local r = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert(r.code == 0, table.concat(cmd, " ") .. ": " .. (r.stderr or ""))
  return r.stdout
end

local function temp_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  sh(dir, { "git", "init", "-q" })
  return dir
end

local M = {}

M["repo_hash matches the TypeScript value"] = function()
  local repo = temp_repo()
  local script = ("import('%s/extensions/git.ts').then(async m => process.stdout.write(await m.repoHash(process.argv[1])))"):format(repo_root)
  local expected = sh(repo_root, { "node", "--experimental-strip-types", "--no-warnings", "-e", script, repo })
  assert(#expected == 12, "bad TS hash: " .. expected)
  assert(discover.repo_hash(repo) == expected, "lua " .. tostring(discover.repo_hash(repo)) .. " ~= ts " .. expected)
  vim.fn.mkdir(repo .. "/sub", "p")
  assert(discover.repo_hash(repo .. "/sub") == expected, "subdir hash differs")
  assert(discover.root(repo .. "/sub") == repo)
  assert(discover.repo_hash("/") == nil)
end

M["sockets skips a stale socket file"] = function()
  local repo = temp_repo()
  local runtime = vim.fn.tempname():gsub("/[^/]*$", "") .. "/cvr" .. tostring(vim.uv.hrtime() % 100000)
  vim.fn.mkdir(runtime, "p")
  local old_env = vim.env.XDG_RUNTIME_DIR
  vim.env.XDG_RUNTIME_DIR = runtime
  local hash = discover.repo_hash(repo)
  local dir = runtime .. "/pi-codeview/" .. hash
  vim.fn.mkdir(dir, "p")

  local live_path = dir .. "/live.sock"
  local server = vim.uv.new_pipe(false)
  assert(server:bind(live_path))
  assert(server:listen(8, function() end))

  -- stale: libuv unlinks on close, so hard-link the bound socket first; the link outlives the listener
  local stale_path = dir .. "/stale.sock"
  local stale_src = dir .. "/stale-src"
  local stale = vim.uv.new_pipe(false)
  assert(stale:bind(stale_src))
  assert(vim.uv.fs_link(stale_src, stale_path))
  stale:close()
  assert(vim.uv.fs_stat(stale_path), "stale socket file missing")
  vim.fn.writefile({ "x" }, dir .. "/notasocket.sock")

  local found = discover.sockets(repo)
  server:close()
  vim.env.XDG_RUNTIME_DIR = old_env
  assert(#found == 1, "expected 1 socket, got " .. #found)
  assert(found[1] == live_path, found[1])
end

M["relpath from a subdirectory buffer"] = function()
  assert(discover.relpath("/r", "/r/a/b.lua") == "a/b.lua")
  assert(discover.relpath("/r/", "/r/b.lua") == "b.lua")
  assert(discover.relpath("/r", "/other/b.lua") == nil)
  assert(discover.relpath("/r", "/rx/b.lua") == nil)
end

return M
