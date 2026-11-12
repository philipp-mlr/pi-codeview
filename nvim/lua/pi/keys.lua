-- Keys setup actually mapped, by name; shared by the run-end notice and the checkpoint view help line.
local M = {}

M.mapped = {}
M.skipped = nil -- "<lhs> (<mode>)" of default keys left alone because taken; nil until setup() ran

-- The mapped key of `name`, or `command` when that key is unmapped or was skipped.
function M.label(name, command)
  return M.mapped[name] or command
end

return M
