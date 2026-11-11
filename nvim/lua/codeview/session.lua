-- The connection to one pi session and its cached status.
local annotations = require("codeview.annotations")
local client = require("codeview.client")
local discover = require("codeview.discover")
local live = require("codeview.live")

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

local function redraw()
  pcall(vim.cmd, "redrawstatus!")
end

function M.on_event(fn)
  event_handler = fn
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

-- Reloads and marks the open buffers against the status' mark base (after a status refresh, since
-- it moves when a chunk is reviewed or a run starts). Older extensions send only `baseline`.
function M.refresh_live()
  M.refresh_status(function(err, status)
    local base = not err and (status.markBase or status.baseline)
    if M.root and type(base) == "string" then
      live.refresh(M.root, base)
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

-- Directory of buf's file; nil for buffers without a file on disk (panel, scratch, codeview://).
local function file_dir(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  local real = name ~= "" and vim.uv.fs_realpath(name) or nil
  return real and vim.fs.dirname(real) or nil
end

local function dir_of_buffer(buf)
  return file_dir(buf) or vim.uv.cwd()
end

-- Short human label for a session status: its pi session name, else the first 8 chars of the id.
function M.label(status)
  if type(status) ~= "table" then
    return ""
  end
  if type(status.name) == "string" and status.name ~= "" then
    return status.name
  end
  return tostring(status.sessionId or "?"):sub(1, 8)
end

local function describe(status)
  local state = status.busy and "working" or "idle"
  if type(status.openChunk) == "table" then
    state = "review " .. status.openChunk.n
  end
  return ("%s  [%s, %s]  %s"):format(M.label(status), status.mode, state, status.root)
end

-- Drops the current attachment without the disconnect warning; pending drafts are saved first.
function M.detach()
  if not M.connected() then
    return
  end
  M.flush()
  local conn = M.conn
  M.conn, M.root, M.cached = nil, nil, nil
  live.clear()
  conn:close()
  redraw()
end

-- Opens a connection whose events and close reach this module only while it is the attached one.
local function open(path)
  local conn
  local err
  conn, err = client.connect(path, function(name, data)
    if conn == M.conn then
      if name == "activity_current" and M.cached and type(data) == "table" then
        M.cached.activity = data.current
        if data.busy ~= nil then
          M.cached.busy = data.busy
        end
        redraw()
      end
      M.refresh_status()
      event_handler(name, data)
    end
  end, function()
    if conn == M.conn then
      M.conn, M.cached = nil, nil
      live.clear()
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
  live.schedule(M.refresh_live)
  cb(conn, root)
end

-- Connects to every live socket of dir's repo and calls done(candidates) with those whose session
-- runs in this worktree (root); each candidate is { conn, status }. Candidates that don't match are
-- closed here; the caller closes the ones it doesn't attach.
local function collect(dir, root, done)
  local all = {}
  for _, path in ipairs(discover.sockets(dir)) do
    local conn = open(path)
    if conn then
      all[#all + 1] = { conn = conn }
    end
  end
  if #all == 0 then
    return done({})
  end
  local remaining = #all
  for _, c in ipairs(all) do
    c.conn:request("status", nil, function(err, result)
      if not err then
        c.status = result
      end
      remaining = remaining - 1
      if remaining == 0 then
        local live = {}
        for _, cand in ipairs(all) do
          local r = cand.status and cand.status.root
          if type(r) == "string" and (vim.uv.fs_realpath(r) or r) == root then
            live[#live + 1] = cand
          else
            cand.conn:close()
          end
        end
        done(live)
      end
    end)
  end
end

local function pick_from(live, choice, root, cb)
  for _, c in ipairs(live) do
    if c ~= choice then
      c.conn:close()
    end
  end
  if choice then
    attach(choice.conn, root, choice.status, cb)
  end
end

local function select_session(live, prompt, on_choice)
  vim.ui.select(live, { prompt = prompt, format_item = function(c) return describe(c.status) end }, on_choice)
end

-- Calls cb(conn, root) once attached to a pi session for the worktree of opts.buf (default: current
-- buffer). Only sessions running in that worktree count. When already attached to another worktree's
-- session and the buffer is a file in this one, it switches. With opts.quiet nothing is reported and
-- no picker is shown: the attach happens only when exactly one session matches.
function M.ensure(cb, opts)
  opts = opts or {}
  local function fail(msg)
    if not opts.quiet then
      vim.notify(msg, vim.log.levels.ERROR)
    end
  end
  if M.connected() then
    local fdir = file_dir(opts.buf)
    local froot = fdir and discover.root(fdir)
    if not froot or froot == M.root then
      return cb(M.conn, M.root)
    end
    M.detach()
  end
  local dir = dir_of_buffer(opts.buf)
  local root = discover.root(dir)
  if not root then
    return fail("codeview: not inside a git repository")
  end
  collect(dir, root, function(live)
    if #live == 0 then
      return fail("codeview: no pi session with codeview for " .. root)
    end
    if #live == 1 then
      return pick_from(live, live[1], root, cb)
    end
    if opts.quiet then
      return pick_from(live, nil, root, cb)
    end
    select_session(live, "codeview: attach to which pi session?", function(choice)
      pick_from(live, choice, root, cb)
    end)
  end)
end

-- Picks the session on purpose: lists the pi sessions for the current buffer's worktree (with name,
-- mode and state) and attaches to the chosen one, replacing the current attachment.
function M.choose(cb)
  local dir = dir_of_buffer(0)
  local root = discover.root(dir)
  if not root then
    return vim.notify("codeview: not inside a git repository", vim.log.levels.ERROR)
  end
  collect(dir, root, function(live)
    if #live == 0 then
      return vim.notify("codeview: no pi session with codeview for " .. root, vim.log.levels.ERROR)
    end
    select_session(live, "codeview: attach to which pi session?", function(choice)
      if not choice then
        return pick_from(live, nil, root, function() end)
      end
      M.detach()
      pick_from(live, choice, root, function(conn, r)
        vim.notify("codeview: attached to " .. M.label(choice.status))
        if cb then
          cb(conn, r)
        end
      end)
    end)
  end)
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

-- Statusline state from the cached status; never blocks.
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

-- Statusline text: "codeview: <label> · <state>"; "" when not attached. Reads the cache only.
function M.statusline()
  if not M.connected() or not M.cached then
    return ""
  end
  local state
  local open_chunk = M.cached.openChunk
  local current = M.cached.activity
  if type(open_chunk) == "table" then
    state = "review " .. open_chunk.n
  elseif type(current) == "table" and current.tool then
    local target = current.target
    state = "working · " .. current.tool
    if type(target) == "string" and target ~= "" then
      state = state .. " " .. (vim.fn.strchars(target) > 40 and vim.fn.strcharpart(target, 0, 40) or target)
    end
  elseif M.cached.busy then
    state = "working"
  else
    state = "idle"
  end
  local mode = type(M.cached.mode) == "string" and (" [" .. M.cached.mode .. "]") or ""
  return ("codeview: %s%s · %s"):format(M.label(M.cached), mode, state)
end

-- Label of the attached session for the statusline; "" when not attached.
function M.attached_label()
  if not M.connected() or not M.cached then
    return ""
  end
  return M.label(M.cached)
end

return M
