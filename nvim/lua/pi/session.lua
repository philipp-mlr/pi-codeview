-- The connection to one pi session and its cached status.
local annotations = require("pi.annotations")
local badge = require("pi.badge")
local client = require("pi.client")
local discover = require("pi.discover")
local live = require("pi.live")
local pi_text = require("pi.text")

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

-- Badge state from the cached status; nil when not attached.
local function update_badge()
  local cached = M.cached
  if not M.connected() or not cached then
    return badge.update(nil)
  end
  local activity = type(cached.activity) == "table" and cached.activity or {}
  badge.update({
    busy = cached.busy,
    tool = activity.tool,
    target = activity.target,
    chunk = type(cached.openChunk) == "table" and cached.openChunk.n or nil,
  })
end

local function redraw()
  update_badge()
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
      pi_text.notify_fit({ "pi: saving drafts failed: " .. err, "pi: saving drafts failed" }, vim.log.levels.WARN)
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

-- Directory of buf's file; nil for buffers without a file on disk (panel, scratch, pi://).
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

-- "now", "5m ago", "2h ago", "3d ago" for a duration in ms.
local function age_text(ms)
  local minutes = math.floor(math.max(ms, 0) / 60000)
  if minutes < 1 then
    return "now"
  elseif minutes < 60 then
    return minutes .. "m ago"
  elseif minutes < 60 * 24 then
    return math.floor(minutes / 60) .. "h ago"
  end
  return math.floor(minutes / (60 * 24)) .. "d ago"
end

-- Picker row: "<label> · <worktree> · <state>[ · checkpoints][ · <age>]". The age is left out when
-- the extension is too old to send `lastActive`. now_ms is epoch ms (default: the current time).
function M.describe(status, now_ms)
  local state = status.busy and "working" or "idle"
  if type(status.openChunk) == "table" then
    state = "checkpoint " .. status.openChunk.n .. " waiting"
  end
  local parts = { M.label(status), vim.fs.basename(tostring(status.root or "")), state }
  if status.mode == "checkpoints" then
    parts[#parts + 1] = "checkpoints"
  end
  if type(status.lastActive) == "number" then
    parts[#parts + 1] = age_text((now_ms or os.time() * 1000) - status.lastActive)
  end
  return table.concat(parts, " · ")
end

-- Orders candidates for the picker: named sessions first, then checkpoint mode on, then most recent
-- activity first (missing last); sessions equal on all of these keep their order.
function M.sort_candidates(live)
  local ranked = {}
  for i, c in ipairs(live) do
    local st = c.status
    local named = type(st.name) == "string" and st.name ~= ""
    ranked[i] = {
      c = c,
      i = i,
      named = named,
      checkpoints = st.mode == "checkpoints",
      active = type(st.lastActive) == "number" and st.lastActive or -math.huge,
    }
  end
  table.sort(ranked, function(a, b)
    if a.named ~= b.named then
      return a.named
    elseif a.checkpoints ~= b.checkpoints then
      return a.checkpoints
    elseif a.active ~= b.active then
      return a.active > b.active
    end
    return a.i < b.i
  end)
  return vim.tbl_map(function(r)
    return r.c
  end, ranked)
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
      pi_text.notify_fit({ "pi: disconnected from pi", "pi: disconnected" }, vim.log.levels.WARN)
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
  live = M.sort_candidates(live)
  vim.ui.select(live, { prompt = prompt, format_item = function(c) return M.describe(c.status) end }, on_choice)
end

-- Calls cb(conn, root) once attached to a pi session for the worktree of opts.buf (default: current
-- buffer). Only sessions running in that worktree count. When already attached to another worktree's
-- session and the buffer is a file in this one, it switches. With opts.quiet nothing is reported and
-- no picker is shown: the attach happens only when exactly one session matches. Leaving an attached
-- session for another worktree's says `pi: switched to <label> (<worktree>)` once, also when quiet
-- (Philipp must know where his next send goes); the first attach says nothing.
function M.ensure(cb, opts)
  opts = opts or {}
  local function fail(msg)
    if not opts.quiet then
      pi_text.notify_fit(msg, vim.log.levels.ERROR)
    end
  end
  local switching = false
  if M.connected() then
    local fdir = file_dir(opts.buf)
    local froot = fdir and discover.root(fdir)
    if not froot or froot == M.root then
      return cb(M.conn, M.root)
    end
    M.detach()
    switching = true
  end
  local dir = dir_of_buffer(opts.buf)
  local root = discover.root(dir)
  if not root then
    return fail("pi: not inside a git repository")
  end
  local function attached(conn, r)
    if switching then
      pi_text.notify_fit({ ("pi: switched to %s (%s)"):format(M.label(M.cached), vim.fs.basename(r)), "pi: switched to " .. M.label(M.cached) })
    end
    cb(conn, r)
  end
  collect(dir, root, function(live)
    if #live == 0 then
      return fail({ ("pi: no pi session for %s — start pi in that worktree"):format(vim.fs.basename(root)), "pi: no pi session for this worktree" })
    end
    if #live == 1 then
      return pick_from(live, live[1], root, attached)
    end
    if opts.quiet then
      return pick_from(live, nil, root, attached)
    end
    select_session(live, "pi: attach to which pi session?", function(choice)
      pick_from(live, choice, root, attached)
    end)
  end)
end

-- Picks the session on purpose: lists the pi sessions for the current buffer's worktree (with name,
-- mode and state) and attaches to the chosen one, replacing the current attachment.
function M.choose(cb)
  local dir = dir_of_buffer(0)
  local root = discover.root(dir)
  if not root then
    return vim.notify("pi: not inside a git repository", vim.log.levels.ERROR)
  end
  collect(dir, root, function(live)
    if #live == 0 then
      return pi_text.notify_fit({ ("pi: no pi session for %s — start pi in that worktree"):format(vim.fs.basename(root)), "pi: no pi session for this worktree" }, vim.log.levels.ERROR)
    end
    select_session(live, "pi: attach to which pi session?", function(choice)
      if not choice then
        return pick_from(live, nil, root, function() end)
      end
      M.detach()
      pick_from(live, choice, root, function(conn, r)
        pi_text.notify_fit("pi: attached to " .. M.label(choice.status))
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
        vim.notify("pi: " .. err, vim.log.levels.ERROR)
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
    return "checkpoint " .. open_chunk.n
  end
  if M.cached.busy then
    return "working"
  end
  return "idle"
end

-- Statusline pieces { text, hl } ({} when not attached); hl is nil for plain text. The waiting
-- checkpoint carries PiCheckpointWaiting. Reads the cache only.
function M.statusline_parts()
  if not M.connected() or not M.cached then
    return {}
  end
  local open_chunk = M.cached.openChunk
  local current = M.cached.activity
  -- The checkpoint number already says checkpoint mode is on, so "[checkpoints]" is left out then.
  local waiting = type(open_chunk) == "table"
  local mode = (M.cached.mode == "checkpoints" and not waiting) and " [checkpoints]" or ""
  local head = ("pi: %s%s · "):format(M.label(M.cached), mode)
  if waiting then
    return { { text = head }, { text = "checkpoint " .. open_chunk.n, hl = "PiCheckpointWaiting" } }
  end
  local state
  if type(current) == "table" and current.tool then
    -- The tool says the agent works, so "working" is left out; a path shows as its file name.
    local target = pi_text.short_target(current.target)
    state = target ~= "" and (current.tool .. " " .. target) or current.tool
  elseif M.cached.busy then
    state = "working"
  else
    state = "idle"
  end
  return { { text = head .. state } }
end

-- Statusline text: "pi: <label>[ [checkpoints]] · <state>", state being "<tool> <file name>",
-- "working", "checkpoint N" or "idle"; "" when not attached. Reads the cache only.
function M.statusline()
  local text = {}
  for _, part in ipairs(M.statusline_parts()) do
    text[#text + 1] = part.text
  end
  return table.concat(text)
end

-- Label of the attached session for the statusline; "" when not attached.
function M.attached_label()
  if not M.connected() or not M.cached then
    return ""
  end
  return M.label(M.cached)
end

return M
