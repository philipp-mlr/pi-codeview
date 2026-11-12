-- Checkpoint diff view: one tabpage per checkpoint, one file at a time, `fromSha` against the live file
-- (open chunk) or against `toSha` (past chunks).
local keys = require("pi.keys")
local session = require("pi.session")
local diffview = require("pi.diffview")

local M = {}
local NOTE_MAX_CHARS = 200 -- virt_lines do not wrap

M.mode = "auto" -- "auto" | "diffview" | "builtin", set by setup({ diff = ... })
local warned_missing_diffview = false

-- tabpage -> { key, n, chunk, root, files, index, left, right } (kind nil: built-in view) or
-- { key, n, chunk, root, files, kind = "diffview" }
local views = {}
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
  local view = views[vim.api.nvim_get_current_tabpage()]
  return view and view.kind ~= "diffview" and view or nil
end

local mapped = {} -- buf -> { ["<Tab>"] = user map dict or false, ... } while it carries the pi view keys

local function feed(keys_text, remap)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys_text, true, false, true), remap and "m" or "n", false)
end

-- Outside the chunk tab the pi key must act as if it were not mapped: run the user's own
-- buffer-local map for lhs if there was one, otherwise the plain key.
local function global_map(lhs)
  local wanted = vim.keycode(lhs)
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    if vim.keycode(map.lhs) == wanted then
      return map
    end
  end
end

local function passthrough(buf, lhs)
  local count = vim.v.count > 0 and tostring(vim.v.count1) or ""
  local saved = mapped[buf] and mapped[buf][lhs] or global_map(lhs)
  if saved then
    if saved.callback then
      local value = saved.callback()
      if saved.expr == 1 and type(value) == "string" then
        return feed(count .. value, saved.noremap ~= 1)
      end
      return value
    end
    local rhs = saved.rhs or ""
    if saved.expr == 1 then
      local ok, value = pcall(vim.api.nvim_eval, rhs)
      if not ok then
        return feed(count .. lhs, false)
      end
      rhs = value
    end
    return feed(count .. rhs, saved.noremap ~= 1)
  end
  feed(count .. lhs, false)
end

local function step(buf, lhs, delta)
  local view = current_view()
  if not view then
    return passthrough(buf, lhs)
  end
  local index = view.index + delta
  if index < 1 or index > #view.files then
    return
  end
  M.show(view, index)
end

-- Closes the chunk tab and returns to the tab it was opened from; the last tab is never closed.
-- The view stays registered until the tab is really gone (an unsaved real file blocks :tabclose).
local function back(buf)
  local tab = vim.api.nvim_get_current_tabpage()
  local view = current_view()
  if not view then
    return passthrough(buf, "q")
  end
  if #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab))
    if vim.api.nvim_tabpage_is_valid(tab) then
      return vim.notify("pi: save your changes first (:w), then q", vim.log.levels.WARN)
    end
    views[tab] = nil
    local origin = view.origin
    if origin and vim.api.nvim_tabpage_is_valid(origin) then
      vim.api.nvim_set_current_tabpage(origin)
    end
  end
  M.cleanup()
end

-- Removes the view keys from every buffer no live diff window shows any more, so they do not
-- linger on the user's real file buffers.
function M.cleanup()
  local shown = {}
  for tab, view in pairs(views) do
    if vim.api.nvim_tabpage_is_valid(tab) and view.kind ~= "diffview" then
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
    step(buf, "<Tab>", 1)
  end, { buffer = buf, desc = "pi: next file in checkpoint" })
  vim.keymap.set("n", "<S-Tab>", function()
    step(buf, "<S-Tab>", -1)
  end, { buffer = buf, desc = "pi: previous file in checkpoint" })
  vim.keymap.set("n", "q", function()
    back(buf)
  end, { buffer = buf, desc = "pi: back from checkpoint view" })
end

-- Puts the chunk note and the file's why as virt_lines above line 1 of `buf`; returns them.
function M.place_why(buf, chunk, path)
  local ns = vim.api.nvim_create_namespace("pi_why")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
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
  local why = one_line(chunk.why and chunk.why[path])
  if why ~= "" then
    virt[#virt + 1] = { { "  why: " .. why, "Comment" } }
  end
  if #virt > 0 then
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { virt_lines = virt, virt_lines_above = true })
  end
  return virt
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

  local virt = M.place_why(left, chunk, file.path)

  local winbar = ("checkpoint %d · %d/%d · %s · %s   <Tab> next · %s annotate · %s continue · q back"):format(
    chunk.n, index, #view.files, file.path, file.label,
    keys.label("annotate", ":PiAnnotate"), keys.label("continue", ":PiContinue")
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

local function use_diffview()
  if M.mode == "builtin" then
    return false
  end
  if diffview.available() then
    return true
  end
  if M.mode == "diffview" and not warned_missing_diffview then
    warned_missing_diffview = true
    vim.notify("pi: diffview.nvim not found, using the built-in view", vim.log.levels.WARN)
  end
  return false
end

-- The diffview chunk being opened: its tab does not exist yet when :DiffviewOpen starts firing
-- events, so the handler adopts a new, unregistered tab for it.
local pending = nil -- { key, chunk, files, origin }

local function diffview_entry()
  local tab = vim.api.nvim_get_current_tabpage()
  local entry = views[tab]
  if entry then
    return entry.kind == "diffview" and entry or nil
  end
  return pending and tab ~= pending.origin and pending or nil
end

-- diffview reuses one buffer per (revision, path) across views, so a buffer that is the left side
-- of one chunk tab can be the right side of another. Only the visible tab matters: clear the
-- explanation from every buffer shown in `tab`, then place this chunk's on the left one.
local function place_tab_explanation(tab, entry, left_buf)
  local ns = vim.api.nvim_create_namespace("pi_why")
  local wins = vim.api.nvim_tabpage_list_wins(tab)
  for _, win in ipairs(wins) do
    vim.api.nvim_buf_clear_namespace(vim.api.nvim_win_get_buf(win), ns, 0, -1)
  end
  if not left_buf then
    for _, win in ipairs(wins) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.startswith(vim.api.nvim_buf_get_name(buf), "diffview://") and diffview.is_left_window(win) then
        left_buf = buf
      end
    end
  end
  if not left_buf then
    return
  end
  local name = vim.api.nvim_buf_get_name(left_buf)
  local best
  for _, file in ipairs(entry.files) do
    if vim.endswith(name, "/" .. file.path) and (not best or #file.path > #best) then
      best = file.path
    end
  end
  if best then
    M.place_why(left_buf, entry.chunk, best)
  end
end

vim.api.nvim_create_autocmd("TabEnter", {
  group = vim.api.nvim_create_augroup("PiDiffChunkTabs", { clear = false }),
  callback = function()
    local tab = vim.api.nvim_get_current_tabpage()
    local entry = views[tab]
    if entry and entry.kind == "diffview" then
      place_tab_explanation(tab, entry)
    end
  end,
})

local diffview_handlers = {
  on_left = function(buf)
    local entry = diffview_entry()
    if entry then
      place_tab_explanation(vim.api.nvim_get_current_tabpage(), entry, buf)
    end
  end,
  -- The buffer may carry another chunk's explanation (shared per revision and path), and diffview
  -- places it in its window only after the left one, so the tab-entry clear cannot catch it.
  on_right = function(buf)
    if diffview_entry() then
      vim.api.nvim_buf_clear_namespace(buf, vim.api.nvim_create_namespace("pi_why"), 0, -1)
    end
  end,
  on_closed = function()
    for registered in pairs(views) do
      if not vim.api.nvim_tabpage_is_valid(registered) then
        views[registered] = nil
      end
    end
  end,
}

-- Opens the chunk in diffview and registers its tab; false (nothing left open) on any failure.
local function open_in_diffview(n, chunk, files, selected)
  local paths = vim.tbl_map(function(file)
    return file.path
  end, files)
  local range = chunk.status == "open" and chunk.fromSha or (chunk.fromSha .. ".." .. chunk.toSha)
  local root = session.root
  local key = chunk_key(n)
  pending = { key = key, chunk = chunk, files = files, origin = vim.api.nvim_get_current_tabpage() }
  local ok, tab = pcall(diffview.open, { range = range, root = root, files = paths, selected = selected }, diffview_handlers)
  pending = nil
  if not ok then
    error(tab, 0)
  end
  if not tab then
    return false
  end
  views[tab] = { key = key, n = n, chunk = chunk, root = root, files = files, kind = "diffview" }
  viewed[key] = true
  vim.notify(("pi: checkpoint %d — <Tab> next file · %s annotate · %s continue · :DiffviewClose to go back"):format(
    n, keys.label("annotate", ":PiAnnotate"), keys.label("continue", ":PiContinue")
  ))
  return true
end

local function index_of(files, path)
  for i, file in ipairs(files) do
    if file.path == path then
      return i
    end
  end
  return 1
end

-- Opens chunk n in its own tabpage (or switches to the existing one). With `path`, the view starts
-- at that file; an already open built-in view moves to it, an open diffview is only switched to.
function M.open(n, path)
  current_view()
  for tab, view in pairs(views) do
    if view.key == chunk_key(n) then
      vim.api.nvim_set_current_tabpage(tab)
      if path and view.kind ~= "diffview" and view.index then
        M.show(view, index_of(view.files, path))
      end
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
      return vim.notify(("pi: checkpoint %d changes no files"):format(n), vim.log.levels.WARN)
    end
    local origin = vim.api.nvim_get_current_tabpage()
    if use_diffview() and open_in_diffview(n, chunk, files, path) then
      return
    end
    vim.cmd("tabnew")
    vim.bo.bufhidden = "wipe"
    local left = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit")
    local right = vim.api.nvim_get_current_win()
    local view = { key = chunk_key(n), n = n, chunk = chunk, root = session.root, files = files, index = index_of(files, path), origin = origin, left = left, right = right }
    views[vim.api.nvim_get_current_tabpage()] = view
    M.show(view, view.index)
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
      if view.kind == "diffview" then
        if vim.api.nvim_tabpage_is_valid(tab) then
          diffview.close(tab)
        end
      elseif vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
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
