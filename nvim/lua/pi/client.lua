local uv = vim.uv

local M = {}

local PROTOCOL_VERSION = 2
M.PROTOCOL_VERSION = PROTOCOL_VERSION
local HELLO_TIMEOUT_MS = 1000

local Conn = {}
Conn.__index = Conn

local function decode(line)
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if ok and type(msg) == "table" then return msg end
end

function Conn:_dispatch(msg)
  if msg.event ~= nil then
    local data = msg.data
    vim.schedule(function() self.on_event(msg.event, data) end)
    return
  end
  local cb = self.pending[msg.id]
  if not cb then return end
  self.pending[msg.id] = nil
  local err, result
  if msg.ok then
    result = msg.result
  else
    err = msg.error or "request failed"
  end
  vim.schedule(function() cb(err, result) end)
end

function Conn:_shutdown()
  if self.closed then return end
  self.closed = true
  if not self.pipe:is_closing() then
    self.pipe:read_stop()
    self.pipe:close()
  end
  local pending = self.pending
  self.pending = {}
  for _, cb in pairs(pending) do
    vim.schedule(function() cb("disconnected") end)
  end
  if self.on_close then
    local on_close = self.on_close
    vim.schedule(on_close)
  end
end

function Conn:_on_data(chunk)
  self.buf = self.buf .. chunk
  while true do
    local nl = self.buf:find("\n", 1, true)
    if not nl then break end
    local line = self.buf:sub(1, nl - 1)
    self.buf = self.buf:sub(nl + 1)
    local msg = line ~= "" and decode(line) or nil
    if msg then self:_dispatch(msg) end
  end
end

function Conn:_send(payload)
  self.pipe:write(vim.json.encode(payload) .. "\n")
end

---@param type string
---@param payload table|nil
---@param cb fun(err: string|nil, result: any)
function Conn:request(type, payload, cb)
  if self.closed then
    vim.schedule(function() cb("disconnected") end)
    return
  end
  self.next_id = self.next_id + 1
  local id = self.next_id
  self.pending[id] = cb
  local body = vim.tbl_extend("force", payload or {}, { id = id, type = type })
  self:_send(body)
end

function Conn:close()
  self:_shutdown()
end

---@param path string
---@param on_event fun(name: string, data: any)
---@param on_close fun()|nil
---@return table|nil conn
---@return string|nil err
function M.connect(path, on_event, on_close)
  local pipe = uv.new_pipe(false)
  local connect_err, connected
  local started, start_err = pcall(pipe.connect, pipe, path, function(err)
    connect_err, connected = err, true
  end)
  if not started then
    pipe:close()
    return nil, tostring(start_err)
  end
  vim.wait(HELLO_TIMEOUT_MS, function() return connected end, 5)
  if not connected or connect_err then
    if not pipe:is_closing() then pipe:close() end
    return nil, connect_err or "connect timed out"
  end

  local conn = setmetatable({
    pipe = pipe,
    buf = "",
    next_id = 0,
    pending = {},
    closed = false,
    on_event = on_event,
    on_close = on_close,
  }, Conn)

  local hello_done, hello_err
  conn.pending[0] = function(err)
    hello_err, hello_done = err, true
  end
  pipe:read_start(function(err, data)
    if err or not data then
      conn:_shutdown()
    else
      conn:_on_data(data)
    end
  end)
  conn:_send({ id = 0, type = "hello", version = PROTOCOL_VERSION })

  vim.wait(HELLO_TIMEOUT_MS, function() return hello_done or conn.closed end, 5)
  if hello_done and not hello_err then return conn end
  local reason = hello_err or (conn.closed and "disconnected during hello") or "hello timed out"
  conn.on_close = nil
  conn:_shutdown()
  return nil, reason
end

return M
