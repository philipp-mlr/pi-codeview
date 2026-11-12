-- Floating editor for text sent to pi (ask, annotation notes): a wrapping markdown float, centred,
-- that sends with <C-s>. q or <Esc> in normal mode, :q and wiping its buffer cancel; moving focus
-- elsewhere (a panel opening, another window or tab) leaves it open. Text that is cancelled or fails
-- to send is kept as a draft under the editor's `draft` key and comes back in the next editor with
-- that key, its footer saying "restored". One editor at a time.
local M = {}

local MAX_WIDTH, MIN_HEIGHT, MAX_HEIGHT = 80, 3, 15
local FOOTER = " <C-s> send · q cancel "
local RESTORED_FOOTER = " restored · <C-s> send · q cancel "

local current = nil -- { win, buf } of the open editor
local drafts = {} -- key -> unsent text of a cancelled editor, restored by the next open with that key

-- Forgets the draft of key: its text reached pi, or what it belonged to is gone. With `text`, only
-- while the draft is still that text (a newer one, typed while the send was in flight, stays).
function M.discard_draft(key, text)
  if text == nil or drafts[key] == text then
    drafts[key] = nil
  end
end

local function blank(text)
  return text == nil or text:match("^%s*$") ~= nil
end

-- Keeps text (when not blank) for the next open with key.
function M.stash(key, text)
  if key and not blank(text) then
    drafts[key] = text
  end
end

-- Size and position for a float showing `rows` screen lines, centred in the editor.
local function layout(rows)
  local width = math.min(MAX_WIDTH, vim.o.columns - 4)
  local height = math.max(MIN_HEIGHT, math.min(MAX_HEIGHT, rows))
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2) - 1),
  }
end

-- opts = { title, text?, draft?, on_submit(text), on_cancel? }; draft is the key for unsent text. Starts in insert mode at the end of text.
-- Sending trims trailing whitespace; empty text, q/<Esc> in normal mode, :q, <C-w>c or wiping the
-- buffer cancel.
function M.open(opts)
  if current and vim.api.nvim_win_is_valid(current.win) then
    vim.api.nvim_set_current_win(current.win)
    vim.notify("pi: finish or cancel the open note first")
    return
  end
  local prefill = opts.text
  local key = opts.draft
  local restored = key ~= nil and drafts[key] ~= nil
  if restored then
    opts = vim.tbl_extend("force", opts, { text = drafts[key] })
    drafts[key] = nil
  end
  local origin = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  local lines = vim.split(opts.text or "", "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local config = layout(#lines)
  config.style = "minimal"
  config.border = "rounded"
  config.title = opts.title
  config.title_pos = "center"
  -- Said in the footer, not as a notice: it would stack on a switch notice into a "Press ENTER".
  config.footer = restored and RESTORED_FOOTER or FOOTER
  config.footer_pos = "right"
  local win = vim.api.nvim_open_win(buf, true, config)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.bo[buf].filetype = "markdown"
  current = { win = win, buf = buf }

  local group = vim.api.nvim_create_augroup("PiEditor", { clear = true })
  local done = false
  local last_text = opts.text or "" -- the buffer's text as it was unloaded, for a wipe
  local function buffer_text()
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
    return last_text
  end
  -- Closes the editor once; text nil cancels. Runs the callback from the window it was opened in.
  local function finish(text)
    if done then
      return
    end
    done = true
    current = nil
    if not text then
      local text_now = buffer_text()
      if text_now ~= prefill then
        M.stash(key, text_now)
      end
      if key and (blank(text_now) or text_now == prefill) then
        M.discard_draft(key)
      end
    end
    vim.api.nvim_del_augroup_by_id(group)
    local focused = vim.api.nvim_get_current_win() == win
    if focused then
      vim.cmd("stopinsert")
    end
    pcall(vim.api.nvim_win_close, win, true)
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    if focused and vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
    if text then
      opts.on_submit(text)
    elseif opts.on_cancel then
      opts.on_cancel()
    end
  end

  local function submit()
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):gsub("%s+$", "")
    finish(text ~= "" and text or nil)
  end
  local function cancel()
    finish(nil)
  end

  local function map(modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, desc = "pi: " .. desc })
  end
  map({ "n", "i" }, "<C-s>", submit, "send")
  map("n", "<CR>", submit, "send")
  map("n", "q", cancel, "cancel")
  map("n", "<Esc>", cancel, "cancel")

  local function fit()
    if not done and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, layout(vim.api.nvim_win_text_height(win, {}).all))
    end
  end
  -- on_lines rather than TextChanged: the latter waits until no keys are typed ahead.
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if done then
        return true
      end
      vim.schedule(fit)
    end,
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = buf,
    callback = function()
      last_text = buffer_text()
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", { group = group, pattern = tostring(win), callback = vim.schedule_wrap(cancel) })
  vim.api.nvim_create_autocmd("BufWipeout", { group = group, buffer = buf, callback = vim.schedule_wrap(cancel) })

  fit()
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })
  vim.cmd("startinsert!")
end

return M
