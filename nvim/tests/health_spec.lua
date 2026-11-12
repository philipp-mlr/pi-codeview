-- :checkhealth pi: runs without error in odd environments and reports what it finds.
local health = require("pi.health")
local keys_state = require("pi.keys")

local M = {}

-- Runs health.check() against a recording stub of vim.health; returns { { kind, msg } ... }.
local function run_check()
  local report = {}
  local real = vim.health
  local function recorder(kind)
    return function(msg) report[#report + 1] = { kind = kind, msg = msg } end
  end
  vim.health = { start = recorder("start"), ok = recorder("ok"), warn = recorder("warn"), error = recorder("error"), info = recorder("info") }
  local ok, err = pcall(health.check)
  vim.health = real
  assert(ok, err)
  return report
end

local function find(report, kind, text)
  for _, r in ipairs(report) do
    if r.kind == kind and r.msg:find(text, 1, true) then return r end
  end
end

local function dump(report)
  return vim.inspect(report)
end

local function temp_repo()
  local dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  assert(vim.system({ "git", "init", "-q" }, { cwd = dir }):wait().code == 0)
  return dir
end

-- Runs fn with XDG_RUNTIME_DIR and the cwd set; restores both.
local function with_env(runtime, cwd, fn)
  local old_env, old_cwd = vim.env.XDG_RUNTIME_DIR, vim.uv.cwd()
  vim.env.XDG_RUNTIME_DIR = runtime
  vim.cmd.cd(vim.fn.fnameescape(cwd))
  local ok, err = pcall(fn)
  vim.env.XDG_RUNTIME_DIR = old_env
  vim.cmd.cd(vim.fn.fnameescape(old_cwd))
  assert(ok, err)
end

M["health runs outside a git repository, without runtime dir and without setup"] = function()
  local saved = { keys_state.mapped, keys_state.skipped }
  keys_state.mapped, keys_state.skipped = {}, nil
  local outside = vim.fn.tempname()
  vim.fn.mkdir(outside, "p")
  vim.cmd("enew") -- no file buffer: the cwd decides
  with_env(outside .. "/no-run", outside, function()
    local report = run_check()
    assert(find(report, "start", "pi.nvim"), dump(report))
    assert(find(report, "ok", "Neovim") or find(report, "error", "Neovim"), dump(report))
    assert(find(report, "ok", "git") or find(report, "error", "git"), dump(report))
    assert(find(report, "warn", "runtime dir") or find(report, "info", "runtime dir"), dump(report))
    assert(find(report, "info", "not inside a git repository"), dump(report))
    assert(find(report, "warn", "setup()"), dump(report))
  end)
  keys_state.mapped, keys_state.skipped = saved[1], saved[2]
end

M["health lists skipped keys and the diff setting"] = function()
  local saved = { keys_state.mapped, keys_state.skipped, require("pi.diff").mode }
  keys_state.mapped, keys_state.skipped = {}, { "<leader>pn (n)", "<leader>pc (n)" }
  require("pi.diff").mode = "builtin"
  local dir = temp_repo()
  with_env(dir .. "/run", dir, function()
    local report = run_check()
    local skipped = find(report, "warn", "<leader>pn (n), <leader>pc (n)")
    assert(skipped and skipped.msg:find("already mapped", 1, true), dump(report))
    assert(find(report, "info", 'diff = "builtin"'), dump(report))
    assert(find(report, "warn", "no pi session") or find(report, "info", "no pi session"), dump(report))
  end)
  keys_state.mapped, keys_state.skipped = saved[1], saved[2]
  require("pi.diff").mode = saved[3]
end

M["health says which view diff = auto uses"] = function()
  local saved = { keys_state.mapped, keys_state.skipped, require("pi.diff").mode }
  keys_state.mapped, keys_state.skipped = {}, {}
  require("pi.diff").mode = "auto"
  local report = run_check()
  keys_state.mapped, keys_state.skipped = saved[1], saved[2]
  require("pi.diff").mode = saved[3]
  local expected = require("pi.diffview").available() and 'diff = "auto" (uses diffview.nvim)' or 'diff = "auto" (uses the built-in view)'
  assert(find(report, "info", expected), dump(report))
end

M["health looks for sessions from the current buffer's directory, not the cwd"] = function()
  local repo = temp_repo()
  local outside = vim.fn.tempname()
  vim.fn.mkdir(outside, "p")
  vim.fn.writefile({ "x" }, repo .. "/f.txt")
  vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/f.txt"))
  local buf = vim.api.nvim_get_current_buf()
  with_env(outside .. "/no-run", outside, function()
    local report = run_check()
    assert(not find(report, "info", "not inside a git repository"), dump(report))
    assert(find(report, "info", "no pi session"), dump(report))
    -- Under :checkhealth the current buffer is health://; the file Philipp came from decides.
    local health_buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(health_buf, "health://")
    vim.api.nvim_set_current_buf(health_buf)
    report = run_check()
    assert(not find(report, "info", "not inside a git repository"), dump(report))
    vim.api.nvim_buf_delete(health_buf, { force = true })
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
end

M["health reports no skipped keys after a clean setup"] = function()
  local saved = { keys_state.mapped, keys_state.skipped }
  keys_state.mapped, keys_state.skipped = { ask = "<leader>pa" }, {}
  local report = run_check()
  assert(find(report, "ok", "keys"), dump(report))
  keys_state.mapped, keys_state.skipped = saved[1], saved[2]
end

-- A listening socket that answers hello with `version` and status with `status`.
local function fake_session(path, version, status)
  local server = vim.uv.new_pipe(false)
  assert(server:bind(path))
  assert(server:listen(8, function()
    local peer = vim.uv.new_pipe(false)
    server:accept(peer)
    local buf = ""
    peer:read_start(function(err, data)
      if err or not data then return end
      buf = buf .. data
      while true do
        local nl = buf:find("\n", 1, true)
        if not nl then break end
        local msg = vim.json.decode(buf:sub(1, nl - 1))
        buf = buf:sub(nl + 1)
        local reply
        if msg.type == "hello" then
          if msg.version == version then
            reply = { id = msg.id, ok = true, result = { version = version } }
          else
            reply = { id = msg.id, ok = false, error = ("protocol version mismatch: server %d, client %d"):format(version, msg.version) }
          end
        else
          reply = { id = msg.id, ok = true, result = status }
        end
        peer:write(vim.json.encode(reply) .. "\n")
      end
    end)
  end))
  return function() server:close() end
end

M["health counts live sessions of this worktree with their labels and versions"] = function()
  local dir = temp_repo()
  local runtime = vim.fn.tempname():gsub("/[^/]*$", "") .. "/hl" .. tostring(vim.uv.hrtime() % 100000)
  vim.fn.mkdir(runtime, "p")
  with_env(runtime, dir, function()
    local hash = require("pi.discover").repo_hash(dir)
    local sock_dir = runtime .. "/pi-nvim/" .. hash
    vim.fn.mkdir(sock_dir, "p")
    local stops = {
      fake_session(sock_dir .. "/a.sock", 2, { name = "refactor", sessionId = "abcdef123456", root = dir, mode = "off" }),
      fake_session(sock_dir .. "/b.sock", 3, { sessionId = "ffff0000eeee", root = dir }),
    }
    local report = run_check()
    for _, stop in ipairs(stops) do stop() end
    assert(find(report, "ok", "2 live pi sessions") or find(report, "ok", "2 live"), dump(report))
    assert(find(report, "ok", "refactor") and find(report, "ok", "protocol 2"), dump(report))
    assert(find(report, "error", "protocol") and find(report, "error", "server 3"), dump(report))
    assert(find(report, "ok", "runtime dir"), dump(report))
  end)
end

M["checkhealth pi renders in a clean nvim"] = function()
  local spec_path = debug.getinfo(1, "S").source:sub(2)
  local plugin_dir = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(spec_path, ":p")))
  local out = vim.fn.tempname()
  local result = vim.system({
    "nvim", "--headless", "--clean", "-c", "set rtp^=" .. plugin_dir, "-c", "checkhealth pi", "-c", "w! " .. out, "-c", "qa!",
  }, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  local text = table.concat(vim.fn.readfile(out), "\n")
  assert(text:find("pi.nvim: environment", 1, true) and text:find("setup() has not been called", 1, true), text)
  assert(not text:find("Failed to run healthcheck", 1, true), text)
end

return M
