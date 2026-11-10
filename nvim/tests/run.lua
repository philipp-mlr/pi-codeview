local tests_dir = vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
package.path = vim.fs.dirname(tests_dir) .. "/lua/?.lua;" .. package.path

local failed = 0
local specs = vim.fn.sort(vim.fn.glob(tests_dir .. "/*_spec.lua", false, true))

for _, file in ipairs(specs) do
  local spec_name = vim.fn.fnamemodify(file, ":t:r")
  local loaded, spec = pcall(dofile, file)
  if not loaded then
    failed = failed + 1
    print(("FAIL %s <load>: %s"):format(spec_name, tostring(spec)))
  else
    local names = vim.tbl_keys(spec)
    table.sort(names)
    for _, name in ipairs(names) do
      local ok, err = xpcall(spec[name], debug.traceback)
      if ok then
        print(("ok %s %s"):format(spec_name, name))
      else
        failed = failed + 1
        print(("FAIL %s %s: %s"):format(spec_name, name, tostring(err)))
      end
    end
  end
end

os.exit(failed > 0 and 1 or 0)
