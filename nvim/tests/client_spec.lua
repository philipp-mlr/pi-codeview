local client = require("pi.client")

local uv = vim.uv
local M = {}

local function short_dir()
  local dir = "/tmp/cv" .. tostring(uv.hrtime() % 1000000000)
  vim.fn.mkdir(dir, "p")
  return dir
end

-- handler(msg, write) is called for every non-hello request line
local function start_server(handler)
  local path = short_dir() .. "/s.sock"
  local server = uv.new_pipe(false)
  assert(server:bind(path))
  local peers = {}
  assert(server:listen(8, function()
    local peer = uv.new_pipe(false)
    server:accept(peer)
    peers[#peers + 1] = peer
    local buf = ""
    local function write(s) if not peer:is_closing() then peer:write(s) end end
    peer:read_start(function(err, data)
      if err or not data then return end
      buf = buf .. data
      while true do
        local nl = buf:find("\n", 1, true)
        if not nl then break end
        local msg = vim.json.decode(buf:sub(1, nl - 1))
        buf = buf:sub(nl + 1)
        if msg.type == "hello" then
          write(vim.json.encode({ id = msg.id, ok = true, result = { version = msg.version } }) .. "\n")
        else
          handler(msg, write, peer)
        end
      end
    end)
  end))
  return path, function()
    for _, p in ipairs(peers) do if not p:is_closing() then p:close() end end
    server:close()
  end
end

M["request/response by id"] = function()
  local path, stop = start_server(function(msg, write)
    write(vim.json.encode({ id = msg.id, ok = true, result = { echo = msg.text, type = msg.type } }) .. "\n")
  end)
  local conn, err = client.connect(path, function() end)
  assert(conn, err)
  local got = {}
  conn:request("status", { text = "a" }, function(e, r) got[1] = { e, r } end)
  conn:request("list_chunks", { text = "b" }, function(e, r) got[2] = { e, r } end)
  assert(vim.wait(1000, function() return got[1] and got[2] end))
  assert(got[1][1] == nil and got[1][2].echo == "a" and got[1][2].type == "status")
  assert(got[2][2].echo == "b" and got[2][2].type == "list_chunks")
  conn:close()
  stop()
end

M["request error is passed to callback"] = function()
  local path, stop = start_server(function(msg, write)
    write(vim.json.encode({ id = msg.id, ok = false, error = "boom" }) .. "\n")
  end)
  local conn = assert(client.connect(path, function() end))
  local e, r, done
  conn:request("status", {}, function(err, res) e, r, done = err, res, true end)
  assert(vim.wait(1000, function() return done end))
  assert(e == "boom" and r == nil)
  conn:close()
  stop()
end

M["events reach on_event"] = function()
  local path, stop = start_server(function(_, write)
    write(vim.json.encode({ event = "chunk", data = { n = 3 } }) .. "\n")
  end)
  local name, data
  local conn = assert(client.connect(path, function(n, d) name, data = n, d end))
  conn:request("status", {}, function() end)
  assert(vim.wait(1000, function() return name end))
  assert(name == "chunk" and data.n == 3)
  conn:close()
  stop()
end

M["split lines are reassembled"] = function()
  local path, stop = start_server(function(msg, write)
    local line = vim.json.encode({ id = msg.id, ok = true, result = { s = "héllo" } }) .. "\n"
    local cut = 12
    write(line:sub(1, cut))
    vim.defer_fn(function() write(line:sub(cut + 1)) end, 50)
  end)
  local conn = assert(client.connect(path, function() end))
  local r
  conn:request("status", {}, function(_, res) r = res end)
  assert(vim.wait(1000, function() return r end))
  assert(r.s == "héllo")
  conn:close()
  stop()
end

M["connect to a dead path returns an error, not a throw"] = function()
  local conn, err = client.connect(short_dir() .. "/none.sock", function() end)
  assert(conn == nil and type(err) == "string")
end

M["connect times out without a hello response"] = function()
  local path = short_dir() .. "/s.sock"
  local server = uv.new_pipe(false)
  assert(server:bind(path))
  local peer = uv.new_pipe(false)
  server:listen(8, function() server:accept(peer) end)
  local conn, err = client.connect(path, function() end)
  assert(conn == nil and type(err) == "string")
  peer:close()
  server:close()
end

M["hello version error returns an error"] = function()
  local path = short_dir() .. "/s.sock"
  local server = uv.new_pipe(false)
  assert(server:bind(path))
  local peer = uv.new_pipe(false)
  server:listen(8, function()
    server:accept(peer)
    peer:read_start(function(_, d)
      if d then peer:write('{"id":0,"ok":false,"error":"protocol version mismatch: server 2, client 1"}\n') end
    end)
  end)
  local conn, err = client.connect(path, function() end)
  assert(conn == nil and err:find("mismatch"))
  peer:close()
  server:close()
end

M["close and server drop fail pending callbacks with disconnected"] = function()
  local path, stop = start_server(function() end)
  local closed = 0
  local conn = assert(client.connect(path, function() end, function() closed = closed + 1 end))
  local e
  conn:request("status", {}, function(err) e = err end)
  conn:close()
  assert(vim.wait(1000, function() return e end))
  assert(e == "disconnected" and conn.closed)
  assert(vim.wait(1000, function() return closed == 1 end))
  local late
  conn:request("status", {}, function(err) late = err end)
  assert(vim.wait(1000, function() return late end))
  assert(late == "disconnected")
  stop()

  local path2, stop2 = start_server(function(_, _, peer) peer:close() end)
  local dropped = 0
  local conn2 = assert(client.connect(path2, function() end, function() dropped = dropped + 1 end))
  local e2
  conn2:request("status", {}, function(err) e2 = err end)
  assert(vim.wait(1000, function() return e2 end))
  assert(e2 == "disconnected" and conn2.closed)
  assert(vim.wait(1000, function() return dropped == 1 end))
  stop2()
end

return M
