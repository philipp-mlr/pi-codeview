-- Checkpoint diff view: one tabpage per checkpoint, one file at a time, `fromSha` against the live file
-- (open chunk) or against `toSha` (past chunks).
local badge = require("pi.badge")
local keys = require("pi.keys")
local session = require("pi.session")
local diffview = require("pi.diffview")
local pi_text = require("pi.text")

local fit = pi_text.fit

local M = {}
local PREVIEW_CHARS = 80 -- virt_lines do not wrap; the full text is one peek away

M.mode = "auto" -- "auto" | "diffview" | "builtin", set by setup({ diff = ... })
local warned_missing_diffview = false

-- tabpage -> { key, n, chunk, root, files, index, origin, left, right } (kind nil: built-in view) or
-- { key, n, chunk, root, files, origin, kind = "diffview" }
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
      label[path] = "you"
    elseif label[path] == "agent" then
      label[path] = "agent+you"
    end
  end
  table.sort(files)
  return vim.tbl_map(function(path)
    return { path = path, label = label[path] }
  end, files)
end

-- Names a checkpoint tab: `t:tabname` is what lualine's tabs component (and :LualineRenameTab)
-- shows instead of the buffer name; `t:pi_checkpoint` tells the badge to stay out of it.
local function name_tab(tab, n)
  vim.t[tab].tabname = "checkpoint " .. n
  vim.t[tab].pi_checkpoint = n
  -- TabEnter came before the mark, and the badge followed into the tab: let it leave again.
  badge.reposition()
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

local SAVE_FIRST = "pi: save your changes first (:w), then q"

-- Whether a diffview tab holds unsaved edits the built-in view's :tabclose would refuse to leave: a
-- modified file shown only in `tab` while 'hidden' is off. diffview sets bufhidden=hide on the files
-- it opens, so that option is not consulted.
local function unsaved_in(tab)
  if vim.o.hidden then
    return false
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].modified and vim.bo[buf].buftype == "" then
      local elsewhere = false
      for _, other in ipairs(vim.fn.win_findbuf(buf)) do
        elsewhere = elsewhere or vim.api.nvim_win_get_tabpage(other) ~= tab
      end
      if not elsewhere then
        return true
      end
    end
  end
  return false
end

-- Closes the chunk tab (built-in or diffview) and returns to the tab it was opened from; the last
-- tab is never closed. The view stays registered until the tab is really gone (an unsaved real file
-- blocks :tabclose).
local function back(buf)
  local tab = vim.api.nvim_get_current_tabpage()
  current_view() -- drops the views of tabs that are gone, so a stale entry cannot match below
  local view = views[tab]
  if not view then
    return passthrough(buf, "q")
  end
  if view.kind == "diffview" then
    if unsaved_in(tab) then
      return pi_text.notify_fit(SAVE_FIRST, vim.log.levels.WARN)
    end
    diffview.close(tab)
    if vim.api.nvim_tabpage_is_valid(tab) then
      return pi_text.notify_fit(SAVE_FIRST, vim.log.levels.WARN)
    end
    views[tab] = nil
    if view.origin and vim.api.nvim_tabpage_is_valid(view.origin) then
      vim.api.nvim_set_current_tabpage(view.origin)
    end
    return M.cleanup()
  end
  if #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab))
    if vim.api.nvim_tabpage_is_valid(tab) then
      return pi_text.notify_fit(SAVE_FIRST, vim.log.levels.WARN)
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
    if vim.api.nvim_tabpage_is_valid(tab) then
      local wins = view.kind == "diffview" and vim.api.nvim_tabpage_list_wins(tab) or { view.left, view.right }
      for _, win in ipairs(wins) do
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

-- Remembers the user's own buffer-local maps of `lhs_list` in `buf`, so cleanup can restore them.
local function save_user_maps(buf, lhs_list)
  mapped[buf] = mapped[buf] or {}
  for _, lhs in ipairs(lhs_list) do
    if mapped[buf][lhs] == nil then
      local existing = vim.api.nvim_buf_call(buf, function()
        return vim.fn.maparg(lhs, "n", false, true)
      end)
      local user_owned = existing.buffer == 1 and not vim.startswith(existing.desc or "", "pi:")
      mapped[buf][lhs] = user_owned and existing or false
    end
  end
end

local function map_back_key(buf)
  vim.keymap.set("n", "q", function()
    back(buf)
  end, { buffer = buf, desc = "pi: back from checkpoint view" })
end

local function map_file_keys(buf)
  save_user_maps(buf, { "<Tab>", "<S-Tab>", "q" })
  vim.keymap.set("n", "<Tab>", function()
    step(buf, "<Tab>", 1)
  end, { buffer = buf, desc = "pi: next file in checkpoint" })
  vim.keymap.set("n", "<S-Tab>", function()
    step(buf, "<S-Tab>", -1)
  end, { buffer = buf, desc = "pi: previous file in checkpoint" })
  map_back_key(buf)
end

-- diffview maps <Tab> and <S-Tab> itself; pi adds only q to the diff windows of its tab.
local function map_diffview_keys(tab)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.wo[win].diff then
      local buf = vim.api.nvim_win_get_buf(win)
      save_user_maps(buf, { "q" })
      map_back_key(buf)
    end
  end
end

local function set_winbar(win, text)
  local info = vim.fn.getwininfo(win)[1]
  vim.wo[win].winbar = fit(text, info.width - info.textoff):gsub("%%", "%%%%")
end

-- Left: which file of which checkpoint and who changed it; right: the keys. Each fits its window.
local function place_winbars(view)
  local file = view.files[view.index]
  set_winbar(view.left, ("checkpoint %d · %d/%d · %s (%s)"):format(view.chunk.n, view.index, #view.files, file.path, file.label))
  set_winbar(view.right, ("<Tab> next · %s note · %s peek · %s continue · q back"):format(
    keys.label("annotate", ":PiAnnotate"), keys.label("peek", ":PiPeek"), keys.label("continue", ":PiContinue")
  ))
end

-- Puts the chunk note and the file's why as virt_lines above line 1 of `buf`; returns them.
function M.place_why(buf, chunk, path)
  local ns = vim.api.nvim_create_namespace("pi_why")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  -- virt_lines neither wrap nor span lines: one line each, whitespace collapsed, cut to the first
  -- 80 characters followed by the peek key.
  local function one_line(text)
    text = vim.trim((text or ""):gsub("%s+", " "))
    if vim.fn.strchars(text) > PREVIEW_CHARS then
      text = vim.fn.strcharpart(text, 0, PREVIEW_CHARS) .. "… " .. keys.label("peek", ":PiPeek")
    end
    return text
  end
  local virt = {}
  local note = one_line(chunk.note)
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

  place_winbars(view)
  for _, win in ipairs({ view.left, view.right }) do
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
    pi_text.notify_fit("pi: diffview.nvim not found, using the built-in view", vim.log.levels.WARN)
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

-- Re-fits the winbars of the built-in views whose windows changed size.
local function refit_winbars(windows)
  for tab, view in pairs(views) do
    if vim.api.nvim_tabpage_is_valid(tab) and view.kind ~= "diffview" and view.index
      and vim.api.nvim_win_is_valid(view.left) and vim.api.nvim_win_is_valid(view.right)
      and (not windows or vim.tbl_contains(windows, view.left) or vim.tbl_contains(windows, view.right)) then
      place_winbars(view)
    end
  end
end

-- Not cleared: a second load of this module (specs do that) must not drop the first one's autocmds.
local winbar_group = vim.api.nvim_create_augroup("PiDiffWinbar", { clear = false })
vim.api.nvim_create_autocmd("WinResized", {
  group = winbar_group,
  callback = function()
    refit_winbars(vim.v.event.windows or {})
  end,
})
vim.api.nvim_create_autocmd("VimResized", {
  group = winbar_group,
  callback = function()
    refit_winbars(nil)
  end,
})

local diffview_handlers = {
  on_left = function(buf)
    local entry = diffview_entry()
    if entry then
      local tab = vim.api.nvim_get_current_tabpage()
      place_tab_explanation(tab, entry, buf)
      map_diffview_keys(tab)
      if views[tab] then
        M.cleanup() -- the buffer diffview just replaced keeps no q
      end
    end
  end,
  -- The buffer may carry another chunk's explanation (shared per revision and path), and diffview
  -- places it in its window only after the left one, so the tab-entry clear cannot catch it.
  on_right = function(buf)
    if diffview_entry() then
      vim.api.nvim_buf_clear_namespace(buf, vim.api.nvim_create_namespace("pi_why"), 0, -1)
      local tab = vim.api.nvim_get_current_tabpage()
      map_diffview_keys(tab)
      if views[tab] then
        M.cleanup()
      end
    end
  end,
  on_closed = function()
    for registered in pairs(views) do
      if not vim.api.nvim_tabpage_is_valid(registered) then
        views[registered] = nil
      end
    end
    M.cleanup()
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
  local pending_origin = vim.api.nvim_get_current_tabpage()
  pending = { key = key, chunk = chunk, files = files, origin = pending_origin }
  local ok, tab = pcall(diffview.open, { range = range, root = root, files = paths, selected = selected }, diffview_handlers)
  pending = nil
  if not ok then
    error(tab, 0)
  end
  if not tab then
    return false
  end
  views[tab] = { key = key, n = n, chunk = chunk, root = root, files = files, origin = pending_origin, kind = "diffview" }
  name_tab(tab, n)
  map_diffview_keys(tab)
  M.cleanup()
  viewed[key] = true
  -- The key list only when it fits the message line; the winbar and diffview's g? show the keys.
  pi_text.notify_fit({
    ("pi: checkpoint %d — <Tab> next file · %s note · %s continue · q back"):format(
      n, keys.label("annotate", ":PiAnnotate"), keys.label("continue", ":PiContinue")
    ),
    ("pi: checkpoint %d"):format(n),
  })
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
      return pi_text.notify_fit({
        ("pi: checkpoint %d has no file changes — %s to continue"):format(n, keys.label("continue", ":PiContinue")),
        ("pi: checkpoint %d has no file changes"):format(n),
      }, vim.log.levels.INFO)
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
    name_tab(vim.api.nvim_get_current_tabpage(), n)
    M.show(view, view.index)
    vim.api.nvim_set_current_win(right)
  end)
end

-- The full text behind the diff previews of the current tab: `checkpoint N — <title>`, the note and
-- `why: …` for the file shown, blank lines between; nil outside a checkpoint diff.
function M.peek_lines()
  current_view()
  local view = views[vim.api.nvim_get_current_tabpage()]
  local win = vim.api.nvim_get_current_win()
  if not view or (view.kind ~= "diffview" and win ~= view.left and win ~= view.right) then
    return nil
  end
  local chunk = view.chunk
  local title = chunk.title
  if not title or title == "" then
    title = vim.trim((chunk.note or ""):match("^%s*([^\n]*)") or "")
  end
  local lines = { ("checkpoint %d%s"):format(chunk.n, title ~= "" and " — " .. title or "") }
  local note = vim.trim(chunk.note or "")
  if note ~= "" then
    lines[#lines + 1] = ""
    vim.list_extend(lines, vim.split(note, "\n", { plain = true }))
  end
  local path
  if view.kind == "diffview" then
    local name = vim.api.nvim_buf_get_name(0)
    for _, file in ipairs(view.files) do
      if vim.endswith(name, "/" .. file.path) and (not path or #file.path > #path) then
        path = file.path
      end
    end
  else
    path = view.files[view.index].path
  end
  local why = path and chunk.why and chunk.why[path]
  if why and vim.trim(why) ~= "" then
    vim.list_extend(lines, { "", "why: " .. vim.trim(why) })
  end
  return lines
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
