-- Chunk diff view: one tabpage per chunk, one file at a time, `fromSha` against the live file
-- (open chunk) or against `toSha` (past chunks).
local session = require("codeview.session")

local M = {}

local views = {} -- tabpage -> { n, chunk, root, files, index, left, right }
local viewed = {} -- chunk n -> true once one of its files was shown in this nvim

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
  local index = (view.index - 1 + delta) % #view.files + 1
  M.show(view, index)
end

local mapped = {} -- buf -> true while it carries the codeview file keys

-- Removes the file keys from every buffer no live diff window shows any more, so they do not
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
        pcall(vim.keymap.del, "n", "]f", { buffer = buf })
        pcall(vim.keymap.del, "n", "[f", { buffer = buf })
      end
      mapped[buf] = nil
    end
  end
end

local function map_file_keys(buf)
  mapped[buf] = true
  vim.keymap.set("n", "]f", function()
    step(1)
  end, { buffer = buf, desc = "codeview: next file in chunk" })
  vim.keymap.set("n", "[f", function()
    step(-1)
  end, { buffer = buf, desc = "codeview: previous file in chunk" })
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

  local left = scratch(("codeview://%d/%s@from"):format(chunk.n, file.path), git_show(view.root, chunk.fromSha, file.path), file.path)
  vim.api.nvim_win_set_buf(view.left, left)

  if chunk.status == "open" then
    vim.api.nvim_win_call(view.right, function()
      vim.cmd("hide edit " .. vim.fn.fnameescape(view.root .. "/" .. file.path))
    end)
  else
    local right = scratch(("codeview://%d/%s@to"):format(chunk.n, file.path), git_show(view.root, chunk.toSha, file.path), file.path)
    vim.api.nvim_win_set_buf(view.right, right)
  end

  local winbar = ("chunk %d · %d/%d · %s · %s"):format(chunk.n, index, #view.files, file.path, file.label)
  for _, win in ipairs({ view.left, view.right }) do
    vim.wo[win].winbar = winbar:gsub("%%", "%%%%")
    map_file_keys(vim.api.nvim_win_get_buf(win))
    vim.api.nvim_win_call(win, function()
      vim.cmd("diffthis")
    end)
  end
  M.cleanup()
  viewed[chunk.n] = true
end

-- Opens chunk n in its own tabpage (or switches to the existing one).
function M.open(n)
  current_view()
  for tab, view in pairs(views) do
    if view.n == n then
      vim.api.nvim_set_current_tabpage(tab)
      return
    end
  end
  session.request("get_chunk", { n = n }, function(err, result)
    if err then
      return vim.notify("codeview: " .. err, vim.log.levels.ERROR)
    end
    local chunk = result.chunk
    local files = files_of(chunk)
    if #files == 0 then
      return vim.notify(("codeview: chunk %d changes no files"):format(n), vim.log.levels.WARN)
    end
    vim.cmd("tabnew")
    vim.bo.bufhidden = "wipe"
    local left = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit")
    local right = vim.api.nvim_get_current_win()
    local view = { n = n, chunk = chunk, root = session.root, files = files, index = 1, left = left, right = right }
    views[vim.api.nvim_get_current_tabpage()] = view
    M.show(view, 1)
    vim.api.nvim_set_current_win(right)
  end)
end

function M.viewed(n)
  return viewed[n] == true
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
