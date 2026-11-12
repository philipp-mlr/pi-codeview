-- :checkhealth pi
local client = require("pi.client")
local discover = require("pi.discover")
local diff = require("pi.diff")
local diffview = require("pi.diffview")
local keys_state = require("pi.keys")
local session = require("pi.session")

local M = {}

local STATUS_TIMEOUT_MS = 500

-- Label and mode of the session behind socket `path`, or nil, error text. Never blocks for long.
local function probe(path)
  local conn, err = client.connect(path, function() end)
  if not conn then
    return nil, err
  end
  local done, status = false, nil
  conn:request("status", nil, function(request_err, result)
    status = not request_err and result or nil
    done = true
  end)
  vim.wait(STATUS_TIMEOUT_MS, function()
    return done
  end, 5)
  conn:close()
  return status or {}
end

local function check_environment()
  vim.health.start("pi.nvim: environment")
  if vim.fn.has("nvim-0.10") == 1 then
    local v = vim.version()
    vim.health.ok(("Neovim %d.%d.%d (0.10 or newer needed)"):format(v.major, v.minor, v.patch))
  else
    vim.health.error("Neovim is older than 0.10", "upgrade Neovim")
  end
  if vim.fn.executable("git") == 1 then
    vim.health.ok("git found on PATH")
  else
    vim.health.error("git not found on PATH", "install git; pi.nvim finds sessions through the git worktree")
  end
  local runtime = discover.runtime_dir() .. "/pi-nvim"
  if vim.uv.fs_stat(runtime) then
    vim.health.ok("runtime dir " .. runtime)
  else
    vim.health.warn("runtime dir " .. runtime .. " does not exist", "it appears when pi runs with the pi-nvim extension; run `pi install` for this repository")
  end
end

local function check_sessions()
  vim.health.start("pi.nvim: sessions")
  local dir = vim.uv.cwd()
  local root = discover.root(dir)
  if not root then
    return vim.health.info("not inside a git repository, no sessions to look for")
  end
  local paths = discover.sockets(dir)
  local live = {}
  for _, path in ipairs(paths) do
    local status, err = probe(path)
    if status then
      live[#live + 1] = status
      local mine = type(status.root) == "string" and (vim.uv.fs_realpath(status.root) or status.root) == root
      local label = session.label(status)
      local where = mine and "" or (" (other worktree: %s)"):format(vim.fs.basename(tostring(status.root or "?")))
      vim.health.ok(("%s: protocol %d%s"):format(label, client.PROTOCOL_VERSION, where))
    else
      local server = tostring(err):match("server (%d+)")
      if server then
        vim.health.error(
          ("%s: protocol version mismatch, server %s, plugin %d"):format(vim.fs.basename(path), server, client.PROTOCOL_VERSION),
          "update pi.nvim on both sides (pi install, and the Neovim plugin)"
        )
      else
        vim.health.warn(("%s: could not connect (%s)"):format(vim.fs.basename(path), tostring(err)))
      end
    end
  end
  if #paths == 0 then
    vim.health.info("no pi session with pi-nvim for " .. root .. " — start pi in that worktree")
    return
  end
  local names = {}
  for _, status in ipairs(live) do
    names[#names + 1] = session.label(status)
  end
  vim.health.ok(("%d live pi session%s for this repository: %s"):format(#paths, #paths == 1 and "" or "s", #names > 0 and table.concat(names, ", ") or "none answered"))
end

local function check_setup()
  vim.health.start("pi.nvim: setup")
  if keys_state.skipped == nil then
    vim.health.warn("setup() has not been called", 'call require("pi").setup({}) in your config')
    return
  end
  vim.health.ok("setup() has run")
  if diffview.available() then
    vim.health.ok("diffview.nvim is installed")
  else
    vim.health.info("diffview.nvim is not installed, checkpoints open in the built-in diff (optional)")
  end
  vim.health.info(('diff = "%s"'):format(diff.mode))
  if #keys_state.skipped == 0 then
    vim.health.ok("all default keys are mapped")
  else
    vim.health.warn(
      "keys not mapped because already mapped: " .. table.concat(keys_state.skipped, ", "),
      "pass them in setup({ keys = { ... } }) to map them anyway, or pick other keys"
    )
  end
end

function M.check()
  check_environment()
  check_sessions()
  check_setup()
end

return M
