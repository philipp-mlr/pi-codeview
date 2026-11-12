-- Peek: the full note, the file's why and the annotations behind the previews at the cursor, in a
-- wrapping float that closes like LSP hover.
local annotations = require("pi.annotations")
local diff = require("pi.diff")
local pi_text = require("pi.text")

local M = {}

-- Peek width: from the editor, not the window peek is called from (a diff or file panel can be
-- 20 columns wide).
local PEEK_MAX_WIDTH = 80

-- The peek text pre-wrapped at spaces to `width`, so nothing breaks a word at "." or "/"
-- ('breakat'); blank lines stay, "---" becomes a rule.
local function peek_text(lines, width)
  local out = {}
  for _, line in ipairs(lines) do
    if line == "---" then
      out[#out + 1] = ("─"):rep(width)
    elseif vim.trim(line) == "" then
      out[#out + 1] = ""
    else
      vim.list_extend(out, pi_text.wrap(line, width))
    end
  end
  return out
end

-- Editor position for a float of width x height (plus border) next to the cursor: below it when
-- it fits, else above; shifted left so it stays on screen.
local function peek_position(width, height)
  local origin = vim.fn.win_screenpos(0)
  local cursor_row = origin[1] - 1 + vim.fn.winline() - 1
  local cursor_col = origin[2] - 1 + vim.fn.wincol() - 1
  local bottom = vim.o.lines - vim.o.cmdheight
  local row = cursor_row + 1
  if row + height + 2 > bottom then
    row = math.max(0, cursor_row - height - 2)
  end
  local col = math.max(0, math.min(cursor_col, vim.o.columns - width - 2))
  return row, col
end

-- Shows the full text behind the previews at the cursor: the checkpoint note and the file's why in
-- a checkpoint diff, then every annotation of the cursor line. Closes like LSP hover.
function M.open()
  local lines = diff.peek_lines() or {}
  for _, item in ipairs(annotations.at_cursor()) do
    if #lines > 0 then
      vim.list_extend(lines, { "", "---", "" })
    end
    vim.list_extend(lines, vim.split(item.note, "\n", { plain = true }))
  end
  if #lines == 0 then
    return pi_text.notify_fit("pi: nothing to peek here")
  end
  local room = math.max(1, math.min(PEEK_MAX_WIDTH, vim.o.columns - 4))
  local wrapped = peek_text(lines, room)
  local width = 1
  for _, line in ipairs(wrapped) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local height = math.max(1, math.min(#wrapped, vim.o.lines - vim.o.cmdheight - 3))
  -- A second peek focuses the float; there q (mapped by nvim) and <Esc> close it.
  local float_buf, float_win = vim.lsp.util.open_floating_preview(wrapped, "markdown", {
    border = "rounded",
    width = width,
    height = height,
    wrap = false,
    focus_id = "pi_peek",
  })
  if not vim.api.nvim_win_is_valid(float_win) or vim.api.nvim_get_current_win() == float_win then
    return
  end
  -- open_floating_preview caps the width at the current window's and may drop blank lines; size
  -- and place it against the editor.
  height = math.max(1, math.min(vim.api.nvim_buf_line_count(float_buf), vim.o.lines - vim.o.cmdheight - 3))
  local row, col = peek_position(width, height)
  vim.api.nvim_win_set_config(float_win, { relative = "editor", anchor = "NW", row = row, col = col, width = width, height = height })
  vim.keymap.set("n", "<Esc>", "<cmd>bdelete<CR>", { buffer = float_buf, nowait = true, desc = "pi: close peek" })
end

return M
