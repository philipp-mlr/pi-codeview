-- Text that has to fit: cut with "…", wrapped at spaces, and notices that fit the message line.
local M = {}

-- `text` cut to at most `width` display cells, ending in "…" when cut.
function M.fit(text, width)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local chars = vim.fn.strchars(text)
  while chars > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, chars)) > width - 1 do
    chars = chars - 1
  end
  return vim.fn.strcharpart(text, 0, chars) .. "…"
end

-- `text` broken at spaces into lines of at most `width` cells; longer words are cut.
function M.wrap(text, width)
  width = math.max(width, 1)
  local out, current = {}, ""
  for word in text:gmatch("%S+") do
    while vim.fn.strdisplaywidth(word) > width do
      if current ~= "" then
        out[#out + 1] = current
        current = ""
      end
      local chars = vim.fn.strchars(word)
      while chars > 1 and vim.fn.strdisplaywidth(vim.fn.strcharpart(word, 0, chars)) > width do
        chars = chars - 1
      end
      out[#out + 1] = vim.fn.strcharpart(word, 0, chars)
      word = vim.fn.strcharpart(word, chars)
    end
    if current == "" then
      current = word
    elseif vim.fn.strdisplaywidth(current) + 1 + vim.fn.strdisplaywidth(word) <= width then
      current = current .. " " .. word
    else
      out[#out + 1] = current
      current = word
    end
  end
  if current ~= "" then
    out[#out + 1] = current
  end
  return out
end

local TARGET_MAX_WIDTH = 40

-- A tool target for the statusline and badge: a path becomes its file name; a command (it has
-- spaces) stays; either is cut to 40 cells followed by "…". "" for no target.
function M.short_target(target)
  if type(target) ~= "string" or target == "" then
    return ""
  end
  if not target:find("%s") and target:find("/") then
    local tail = vim.fs.basename((target:gsub("/+$", "")))
    target = tail ~= "" and tail or target
  end
  if vim.fn.strdisplaywidth(target) > TARGET_MAX_WIDTH then
    target = M.fit(target .. "…", TARGET_MAX_WIDTH + 1)
  end
  return target
end

-- Shows the first of `variants` (a string or a list, longest first) that fits the message line
-- (`v:echospace`), so no notice wraps into a "Press ENTER" prompt; the last one is cut with "…"
-- when none fits.
function M.notify_fit(variants, level)
  if type(variants) == "string" then
    variants = { variants }
  end
  local room = vim.v.echospace
  for _, msg in ipairs(variants) do
    if vim.fn.strdisplaywidth(msg) <= room then
      return vim.notify(msg, level)
    end
  end
  vim.notify(M.fit(variants[#variants], room), level)
end

return M
