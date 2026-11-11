local log = require("codeview.log")

local M = {}

local function lines()
  return vim.api.nvim_buf_get_lines(vim.fn.bufnr("codeview://log"), 0, -1, false)
end

local function fresh()
  log.close()
  log.clear()
end

M["append renders each kind"] = function()
  fresh()
  log.append({
    { seq = 1, kind = "prompt", text = "fix it" },
    { seq = 2, kind = "text", text = "looking" },
    { seq = 3, kind = "tool", text = "edit a.ts", tool = "edit", target = "a.ts" },
    { seq = 4, kind = "tool", text = "bash", tool = "bash" },
    { seq = 5, kind = "checkpoint", text = "add a" },
    { seq = 6, kind = "settled", text = "" },
  })
  assert(
    vim.deep_equal(lines(), {
      "",
      "prompt  ▸ fix it",
      "agent   │ looking",
      "tool    ▸ edit a.ts",
      "tool    ▸ bash",
      "ckpt    ✓ add a",
      "done    ─ run settled",
    }),
    vim.inspect(lines())
  )
end

M["multi-line text is joined with a return symbol"] = function()
  fresh()
  log.append({ { seq = 1, kind = "text", text = "a\nb\r\nc" } })
  assert(lines()[1] == "agent   │ a ⏎ b ⏎ c", vim.inspect(lines()))
end

M["buffer is not modifiable after append"] = function()
  fresh()
  log.append({ { seq = 1, kind = "text", text = "x" } })
  local buf = vim.fn.bufnr("codeview://log")
  assert(not vim.bo[buf].modifiable)
  assert(vim.bo[buf].buftype == "nofile" and vim.bo[buf].filetype == "codeview-log")
end

M["already appended seqs are skipped"] = function()
  fresh()
  log.append({ { seq = 1, kind = "text", text = "x" }, { seq = 2, kind = "text", text = "y" } })
  log.append({ { seq = 2, kind = "text", text = "y" }, { seq = 3, kind = "text", text = "z" } })
  assert(#lines() == 3, vim.inspect(lines()))
end

M["toggle opens and closes the log window"] = function()
  fresh()
  assert(not log.visible())
  log.toggle()
  assert(log.visible())
  assert(vim.api.nvim_win_get_height(vim.api.nvim_get_current_win()) == 12)
  log.toggle()
  assert(not log.visible())
end

M["auto-scrolls only when the cursor is on the last line"] = function()
  fresh()
  log.append({ { seq = 1, kind = "text", text = "a" }, { seq = 2, kind = "text", text = "b" } })
  log.open()
  local win = vim.api.nvim_get_current_win()
  assert(vim.api.nvim_win_get_cursor(win)[1] == 2)
  log.append({ { seq = 3, kind = "text", text = "c" } })
  assert(vim.api.nvim_win_get_cursor(win)[1] == 3, "did not follow")
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  log.append({ { seq = 4, kind = "text", text = "d" } })
  assert(vim.api.nvim_win_get_cursor(win)[1] == 1, "moved the cursor")
  log.close()
end

return M
