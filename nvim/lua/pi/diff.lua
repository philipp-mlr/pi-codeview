-- Chunk diff view: one tabpage per chunk, one file at a time, `fromSha` against the live file
-- (open chunk) or against `toSha` (past chunks).
local keys = require("pi.keys")
local session = require("pi.session")

local M = {}
local NOTE_MAX_CHARS = 200 -- virt_lines do not wrap

local views = {} -- tabpage -> { key, n, chunk, root, files, index, left, right }
local viewed = {} -- chunk key -> true once one of its files was shown in this nvim

-- Chunk numbers restart in every pi session, so views and viewed marks are keyed by session too.
local function chunk_key(n)
  local session_id = session.cached and session.cached.sessionId or ""
  return session_id .. ":" .. tostring(n)
end

local function git_show(root, sha, path)
  local result = vim.system({ "git", "show", sha .. ":" .. path }, { cwd = root, text = true }):wait()
  if result.code ~= 0 then
    return {}
  end
  local lines = vim.split(result.stdout, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

local function scratch(name, lines, path)
  for _, existing in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(existing) == name then
      vim.api.nvim_buf_delete(existing, { force = true })
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  local ft = vim.filetype.match({ filename = path, buf = buf })
  if ft then
    vim.bo[buf].filetype = ft
  end
  return buf
end

local function files_of(chunk)
  local files, label = {}, {}
  for _, path in ipairs(chunk.agentFiles or {}) do
    if not label[path] then
      files[#files + 1] = path
    end
    label[path] = "agent"
  end
  for _, path in ipairs(chunk.humanFiles or {}) do
    if not label[path] then
      files[#files + 1] = path
      label[path] = "human"
    elseif label[path] == "agent" then
      label[path] = "agent+human"
    end
  end
  table.sort(files)
  return vim.tbl_map(function(path)
    return { path = path, label = label[path] }
  end, files)
end

local function current_view()
  for tab, view in pairs(views) do
    if not vim.api.nvim_tabpage_is_valid(tab) then
      views[tab] = nil
    end
  end
  return views[vim.api.nvim_get_current_tabpage()]
end

local function step(delta)
  local view = current_view()
  if not view then
    return
  end
  local index = view.index + delta
  if index < 1 or index > #view.files then
    return
  end
  M.show(view, index)
end

-- Closes the chunk tab and returns to the tab it was opened from; the last tab is never closed.
local function back()
  local tab = vim.api.nvim_get_current_tabpage()
  local view = current_view()
  if view and #vim.api.nvim_list_tabpages() > 1 then
    views[tab] = nil
    local origin = view.origin
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab))
    if origin and vim.api.nvim_tabpage_is_valid(origin) then
      vim.api.nvim_set_current_tabpage(origin)
    end
  end
  M.cleanup()
end

local mapped = {} -- buf -> { ["<Tab>"] = user map dict or false, ... } while it carries the pi view keys

-- Removes the view keys from every buffer no live diff window shows any more, so they do not
-- linger on the user's real file buffers.
function M.cleanup()
  local shown = {}
  for tab, view in pairs(views) do
    if vim.api.nvim_tabpage_is_valid(tab) then
      for _, win in ipairs({ view.left, view.right }) do
        if vim.api.nvim_win_is_valid(win) then
          shown[vim.api.nvim_win_get_buf(win)] = true
        end
      end
    end
  end
  for buf in pairs(mapped) do
    if not shown[buf] then
      if vim.api.nvim_buf_is_valid(buf) then
        for lhs, saved in pairs(mapped[buf]) do
          pcall(vim.keymap.del, "n", lhs, { buffer = buf })
          if saved then
            vim.api.nvim_buf_call(buf, function()
              vim.fn.mapset("n", false, saved)
            end)
          end
        end
      end
      mapped[buf] = nil
    end
  end
end

local function map_file_keys(buf)
  mapped[buf] = mapped[buf] or {}
  for _, lhs in ipairs({ "<Tab>", "<S-Tab>", "q" }) do
    if mapped[buf][lhs] == nil then
      local existing = vim.api.nvim_buf_call(buf, function()
        return vim.fn.maparg(lhs, "n", false, true)
      end)
      local user_owned = existing.buffer == 1 and not vim.startswith(existing.desc or "", "pi:")
      mapped[buf][lhs] = user_owned and existing or false
    end
  end
  vim.keymap.set("n", "<Tab>", function()
    step(1)
  end, { buffer = buf, desc = "pi: next file in chunk" })
  vim.keymap.set("n", "<S-Tab>", function()
    step(-1)
  end, { buffer = buf, desc = "pi: previous file in chunk" })
  vim.keymap.set("n", "q", back, { buffer = buf, desc = "pi: back from chunk view" })
end

function M.show(view, index)
  view.index = index
  local file = view.files[index]
  local chunk = view.chunk
  for _, win in ipairs({ view.left, view.right }) do
    vim.api.nvim_win_call(win, function()
      vim.cmd("diffoff")
    end)
  end

  local left = scratch(("pi://%d/%s@from"):format(chunk.n, file.path), git_show(view.root, chunk.fromSha, file.path), file.path)
  vim.api.nvim_win_set_buf(view.left, left)

  if chunk.status == "open" then
    vim.api.nvim_win_call(view.right, function()
      vim.cmd("hide edit " .. vim.fn.fnameescape(view.root .. "/" .. file.path))
    end)
  else
    local right = scratch(("pi://%d/%s@to"):format(chunk.n, file.path), git_show(view.root, chunk.toSha, file.path), file.path)
    vim.api.nvim_win_set_buf(view.right, right)
  end

  local ns = vim.api.nvim_create_namespace("pi_why")
  -- virt_lines neither wrap nor span lines: one line each, whitespace collapsed, note capped.
  local function one_line(text)
    return (vim.trim((text or ""):gsub("%s+", " ")))
  end
  local virt = {}
  local note = one_line(chunk.note)
  if vim.fn.strchars(note) > NOTE_MAX_CHARS then
    note = vim.fn.strcharpart(note, 0, NOTE_MAX_CHARS) .. "…"
  end
  if note ~= "" then
    virt[#virt + 1] = { { "  " .. note, "Title" } }
  end
  local why = one_line(chunk.why and chunk.why[file.path])
  if why ~= "" then
    virt[#virt + 1] = { { "  why: " .. why, "Comment" } }
  end
  if #virt > 0 then
    vim.api.nvim_buf_set_extmark(left, ns, 0, 0, { virt_lines = virt, virt_lines_above = true })
  end

  local winbar = ("chunk %d · %d/%d · %s · %s   <Tab> next · %s annotate · %s send · q back"):format(
    chunk.n, index, #view.files, file.path, file.label,
    keys.label("annotate", ":PiAnnotate"), keys.label("send", ":PiSendAnnotations")
  )
  for _, win in ipairs({ view.left, view.right }) do
    vim.wo[win].winbar = winbar:gsub("%%", "%%%%")
    map_file_keys(vim.api.nvim_win_get_buf(win))
    vim.api.nvim_win_call(win, function()
      vim.cmd("diffthis")
    end)
  end
  -- diffthis resets the view, so the explanation is scrolled into sight only afterwards.
  if #virt > 0 then
    vim.api.nvim_win_call(view.left, function()
      vim.fn.winrestview({ topline = 1, topfill = #virt })
    end)
  end
  M.cleanup()
  viewed[view.key] = true
end

-- Opens chunk n in its own tabpage (or switches to the existing one).
function M.open(n)
  current_view()
  for tab, view in pairs(views) do
    if view.key == chunk_key(n) then
      vim.api.nvim_set_current_tabpage(tab)
      return
    end
  end
  session.request("get_chunk", { n = n }, function(err, result)
    if err then
      return vim.notify("pi: " .. err, vim.log.levels.ERROR)
    end
    local chunk = result.chunk
    local files = files_of(chunk)
    if #files == 0 then
      return vim.notify(("pi: chunk %d changes no files"):format(n), vim.log.levels.WARN)
    end
    local origin = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    vim.bo.bufhidden = "wipe"
    local left = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit")
    local right = vim.api.nvim_get_current_win()
    local view = { key = chunk_key(n), n = n, chunk = chunk, root = session.root, files = files, index = 1, origin = origin, left = left, right = right }
    views[vim.api.nvim_get_current_tabpage()] = view
    M.show(view, 1)
    vim.api.nvim_set_current_win(right)
  end)
end

function M.viewed(n)
  return viewed[chunk_key(n)] == true
end

-- Closes the diff tab of chunk n (it shows a state that no longer exists once the chunk was
-- reviewed), so opening the chunk again fetches it fresh.
function M.forget(n)
  for tab, view in pairs(views) do
    if view.key == chunk_key(n) then
      views[tab] = nil
      if vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
        pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab))
      end
    end
  end
  M.cleanup()
end

function M.is_diff_window(win)
  for tab, view in pairs(views) do
    if vim.api.nvim_tabpage_is_valid(tab) and (view.left == win or view.right == win) then
      return true
    end
  end
  return false
end

return M
