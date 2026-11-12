-- Default highlight links for pi's groups. `:colorscheme` runs `:hi clear`, which drops them, so
-- setup() calls this again from a ColorScheme autocmd.
local M = {}

local LINKS = {
  PiBadge = "PmenuSel",
  PiAnnotation = "DiagnosticInfo",
  PiAnnotationSign = "DiagnosticSignInfo",
  PiCheckpointWaiting = "DiagnosticWarn",
  PiLive = "CursorLine",
  PiLiveSignAdd = "DiagnosticHint",
  PiLiveSignChange = "DiagnosticInfo",
  PiLiveSignDelete = "DiagnosticWarn",
}

function M.define()
  for name, target in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { default = true, link = target })
  end
end

return M
