-- Default highlight links for pi's groups. `:colorscheme` runs `:hi clear`, which drops them, so
-- setup() calls this again from a ColorScheme autocmd.
local M = {}

local LINKS = {
  PiBadge = "PmenuSel",
  PiAnnotationSign = "Special",
  PiCheckpointWaiting = "DiagnosticWarn",
  PiLive = "DiffChange",
  PiLiveSignAdd = "Added",
  PiLiveSignChange = "Changed",
  PiLiveSignDelete = "Removed",
}

function M.define()
  for name, target in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { default = true, link = target })
  end
  -- Annotations read like comments but in italic: Comment's colour, copied (a link cannot add italic).
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  if comment.fg then
    vim.api.nvim_set_hl(0, "PiAnnotation", { default = true, italic = true, fg = comment.fg })
  else
    vim.api.nvim_set_hl(0, "PiAnnotation", { default = true, link = "Comment" })
  end
  -- The panel's waiting row: DiagnosticWarn's colour in bold.
  local warn = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false })
  if warn.fg then
    vim.api.nvim_set_hl(0, "PiCheckpointWaitingRow", { default = true, bold = true, fg = warn.fg })
  else
    vim.api.nvim_set_hl(0, "PiCheckpointWaitingRow", { default = true, bold = true })
  end
end

return M
