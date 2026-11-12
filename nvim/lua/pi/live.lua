-- Live view of the agent's changes in open buffers: reloads untouched buffers and marks the lines
-- that differ from the mark base (the open chunk's start, or the start of the run with checkpoints off).
local discover = require("pi.discover")
local pi_text = require("pi.text")

local M = {}

M.sign = "▎" -- setup({ live = { sign = ... } })
M.line_hl = false -- setup({ live = { line_hl = true } }) also highlights changed lines

local DEBOUNCE_MS = 150
local ns = vim.api.nvim_create_namespace("pi_live")

local baseline_text = {} -- baseline .. "\0" .. path -> file text at that commit ("" when absent)
local mtimes = {} -- absolute path -> last seen mtime "sec.nsec"
local warned = {} -- baseline .. "\0" .. path -> true
local computed = {} -- buf -> { baseline, tick, mtime } of the last mark computation
local pending = {} -- baseline .. "\0" .. path -> callbacks waiting for the git fetch
local current_baseline = nil
local generation = 0
local timer = nil

local function mtime_of(real)
  local stat = vim.uv.fs_stat(real)
  return stat and (stat.mtime.sec .. "." .. stat.mtime.nsec) or nil
end

-- Fetches the file text at baseline without blocking, then calls done(text) on the main loop.
-- Concurrent requests for the same file share one git call.
local function fetch_text(root, baseline, path, done)
  local key = baseline .. "\0" .. path
  if baseline_text[key] ~= nil then
    return done(baseline_text[key])
  end
  if pending[key] then
    table.insert(pending[key], done)
    return
  end
  pending[key] = { done }
  local gen = generation
  vim.system({ "git", "show", baseline .. ":" .. path }, { cwd = root, text = true }, function(result)
    vim.schedule(function()
      local waiting = pending[key] or {}
      if gen ~= generation then
        return
      end
      pending[key] = nil
      baseline_text[key] = result.code == 0 and result.stdout or ""
      for _, cb in ipairs(waiting) do
        cb(baseline_text[key])
      end
    end)
  end)
end

local function buffer_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. (vim.bo[buf].eol and "\n" or "")
end

local function mark(buf, line, text, group, line_hl)
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, line - 1, 0, {
    sign_text = text,
    sign_hl_group = group,
    priority = 100, -- below annotation signs (200); the default 4096 would win
    line_hl_group = line_hl,
  })
end

local function place(buf, hunks)
  local count = vim.api.nvim_buf_line_count(buf)
  for _, h in ipairs(hunks) do
    local count_a, start_b, count_b = h[2], h[3], h[4]
    if count_b == 0 then
      mark(buf, math.min(math.max(start_b, 1), count), "▁", "PiLiveSignDelete")
    else
      local group = count_a == 0 and "PiLiveSignAdd" or "PiLiveSignChange"
      for line = start_b, start_b + count_b - 1 do
        mark(buf, line, M.sign, group, M.line_hl and "PiLive" or nil)
      end
    end
  end
end

-- Remembers when a file was last written, so a later change on disk is noticed.
local function remember(args)
  local name = vim.api.nvim_buf_get_name(args.buf)
  local real = name ~= "" and vim.uv.fs_realpath(name) or nil
  if real then
    mtimes[real] = mtime_of(real)
  end
end

local group = vim.api.nvim_create_augroup("pi_live", { clear = true })
vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "FileChangedShellPost" }, { group = group, callback = remember })

function M.clear()
  if timer then
    timer:stop()
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
  baseline_text, mtimes, warned, computed, pending, current_baseline = {}, {}, {}, {}, {}, nil
  generation = generation + 1
end

-- Reloads the unmodified buffers inside root and marks their lines that differ from baseline.
function M.refresh(root, baseline)
  if type(baseline) ~= "string" or baseline == "" then
    return
  end
  if baseline ~= current_baseline then
    current_baseline = baseline
    baseline_text, computed = {}, {}
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    local real = vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted and name ~= "" and not name:match("^pi://")
      and vim.uv.fs_realpath(name) or nil
    local path = real and discover.relpath(root, real)
    if path then
      local seen = mtime_of(real)
      if vim.bo[buf].modified then
        local key = baseline .. "\0" .. path
        if mtimes[real] and seen ~= mtimes[real] and not warned[key] then
          warned[key] = true
          pi_text.notify_fit({
            ("pi: %s changed on disk; your unsaved edits are kept"):format(path),
            ("pi: %s changed on disk; your edits are kept"):format(vim.fs.basename(path)),
          }, vim.log.levels.WARN)
        end
      else
        local autoread = vim.bo[buf].autoread
        vim.bo[buf].autoread = true
        pcall(vim.cmd, "silent! checktime " .. buf)
        vim.bo[buf].autoread = autoread
        seen = mtime_of(real)
      end
      mtimes[real] = seen
      local record = computed[buf]
      if not (record and record.baseline == baseline and record.tick == vim.b[buf].changedtick and record.mtime == seen) then
        fetch_text(root, baseline, path, function(text)
          if not vim.api.nvim_buf_is_valid(buf) or baseline ~= current_baseline then
            return
          end
          computed[buf] = { baseline = baseline, tick = vim.b[buf].changedtick, mtime = mtime_of(real) }
          vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
          place(buf, vim.diff(text, buffer_text(buf), { result_type = "indices" }))
        end)
      end
    end
  end
end

-- Runs fn once after a short pause, however often this is called meanwhile.
function M.schedule(fn)
  timer = timer or vim.uv.new_timer()
  timer:stop()
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(fn))
end

return M
