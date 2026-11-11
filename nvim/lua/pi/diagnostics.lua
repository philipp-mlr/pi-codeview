-- LSP diagnostics of a buffer in the shape the pi extension takes as context.
local M = {}

local LIMIT = 20
local MESSAGE_CHARS = 200
local NAMES = { [vim.diagnostic.severity.ERROR] = "error", [vim.diagnostic.severity.WARN] = "warning" }

local function collapse(message)
  local text = vim.trim((message or ""):gsub("%s+", " ") .. "")
  if vim.fn.strchars(text) > MESSAGE_CHARS then
    return vim.fn.strcharpart(text, 0, MESSAGE_CHARS) .. "…"
  end
  return text
end

-- ERROR and WARN diagnostics of buf, limited to lines line1..line2 (1-based) when given: errors first,
-- then by line, at most 20. Returns {} when there are none.
function M.collect(buf, line1, line2)
  local found = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    local severity = NAMES[d.severity]
    local line = d.lnum + 1
    if severity and (line1 == nil or (line >= line1 and line <= (line2 or line1))) then
      found[#found + 1] = { line = line, severity = severity, message = collapse(d.message), source = d.source }
    end
  end
  table.sort(found, function(a, b)
    if a.severity ~= b.severity then
      return a.severity == "error"
    end
    return a.line < b.line
  end)
  return vim.list_slice(found, 1, LIMIT)
end

return M
