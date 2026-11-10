-- The connection to one pi session and its cached status.
local annotations = require("codeview.annotations")
local client = require("codeview.client")
local discover = require("codeview.discover")

local M = {}

local SAVE_DRAFTS_DEBOUNCE_MS = 300

M.conn = nil
M.root = nil
M.cached = nil -- last `status` result
local event_handler = function() end
local save_timer = nil

function M.connected()
  return M.conn ~= nil and not M.conn.closed
end

function M.on_event(fn)
  event_handler = fn
end

local function redraw()
  pcall(vim.cmd, "redrawstatus!")
end

function M.refresh_status(cb)
  if not M.connected() then
    return
  end
  local conn = M.conn
  conn:request("status", nil, function(err, result)
    if not err and conn == M.conn then
      M.cached = result
      redraw()
    end
    if cb then
      cb(err, result)
    end
  end)
end

local function save_drafts(cb)
  if not M.connected() then
    return
  end
  M.conn:request("save_drafts", { annotations = annotations.list(M.root) }, function(err)
    if cb then
      cb()
    end
    if err then
      vim.notify("codeview: saving drafts failed: " .. err, vim.log.levels.WARN)
    end
  end)
end

-- Saves the drafts with their current extmark positions after a short debounce.
function M.schedule_save()
  save_timer = save_timer or vim.uv.new_timer()
  save_timer:stop()
  save_timer:start(SAVE_DRAFTS_DEBOUNCE_MS, 0, vim.schedule_wrap(save_drafts))
end

-- Sends a pending debounced save now and waits briefly for the reply (used when nvim exits).
function M.flush()
  if not save_timer or not save_timer:is_active() then
    return
  end
  save_timer:stop()
  if not M.connected() then
    return
  end
  local done = false
  save_drafts(function()
    done = true
  end)
  vim.wait(500, function()
    return done
  end, 10)
end

local function dir_of_buffer(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  local real = name ~= "" and vim.uv.fs_realpath(name) or nil
  return real and vim.fs.dirname(real) or vim.uv.cwd()
end

-- Opens a connection whose events and close reach this module only while it is the attached one.
local function open(path)
  local conn
  local err
  conn, err = client.connect(path, function(name, data)
    if conn == M.conn then
      M.refresh_status()
      event_handler(name, data)
    end
  end, function()
    if conn == M.conn then
      M.conn, M.cached = nil, nil
      redraw()
      vim.notify("codeview: disconnected from pi", vim.log.levels.WARN)
    end
  end)
  return conn, err
end

local function attach(conn, root, status, cb)
  M.conn, M.root, M.cached = conn, root, status
  annotations.on_change(M.schedule_save)
  annotations.restore(status.drafts or {}, root)
  -- Annotations added while pi was unreachable reach the extension now.
  if not vim.deep_equal(annotations.list(root), status.drafts or {}) then
    M.schedule_save()
  end
  redraw()
  cb(conn, root)
end

-- Calls cb(conn, root) once attached to a pi session for the repo of opts.buf (default: current buffer).
-- Only sessions whose root is this worktree count. With opts.quiet nothing is reported and no picker
-- is shown: the attach happens only when exactly one session matches.
function M.ensure(cb, opts)
  opts = opts or {}
  if M.connected() then
    return cb(M.conn, M.root)
  end
  local function fail(msg)
    if not opts.quiet then
      vim.notify(msg, vim.log.levels.ERROR)
    end
  end
  local dir = dir_of_buffer(opts.buf)
  local root = discover.root(dir)
  if not root then
    return fail("codeview: not inside a git repository")
  end
  local candidates = {}
  for _, path in ipairs(discover.sockets(dir)) do
    local conn = open(path)
    if conn then
      candidates[#candidates + 1] = { conn = conn }
    end
  end
  if #candidates == 0 then
    return fail("codeview: no pi session with codeview for " .. root)
  end
  local remaining = #candidates
  local function choose()
    local live = vim.tbl_filter(function(c)
      return c.status ~= nil and type(c.status.root) == "string"
        and (vim.uv.fs_realpath(c.status.root) or c.status.root) == root
    end, candidates)
    local function pick(choice)
      for _, c in ipairs(candidates) do
        if c ~= choice then
          c.conn:close()
        end
      end
      if choice then
        attach(choice.conn, root, choice.status, cb)
      end
    end
    if #live == 0 then
      pick(nil)
      return fail("codeview: no pi session with codeview for " .. root)
    end
    if #live == 1 then
      return pick(live[1])
    end
    if opts.quiet then
      return pick(nil)
    end
    vim.ui.select(live, {
      prompt = "codeview: attach to which pi session?",
      format_item = function(c)
        return ("%s (%s) %s"):format(c.status.sessionId, c.status.mode, c.status.root)
      end,
    }, pick)
  end
  for _, c in ipairs(candidates) do
    c.conn:request("status", nil, function(err, result)
      if not err then
        c.status = result
      end
      remaining = remaining - 1
      if remaining == 0 then
        choose()
      end
    end)
  end
end

-- Attaches if needed, then sends one request; cb(err, result) is optional.
function M.request(type, payload, cb)
  M.ensure(function(conn)
    conn:request(type, payload, function(err, result)
      if cb then
        cb(err, result)
      elseif err then
        vim.notify("codeview: " .. err, vim.log.levels.ERROR)
      end
    end)
  end)
end

function M.mark_busy()
  if M.cached then
    M.cached.busy = true
    redraw()
  end
end

-- Statusline text from the cached status; never blocks.
function M.status_line()
  if not M.connected() or not M.cached then
    return ""
  end
  local open_chunk = M.cached.openChunk
  if type(open_chunk) == "table" then
    return "review " .. open_chunk.n
  end
  if M.cached.busy then
    return "working"
  end
  return "idle"
end

return M
