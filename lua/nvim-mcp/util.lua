-- lua/nvim-mcp/util.lua — shared helpers: context, selection, truncate, uuid

local M = {}

function M.collect_context(opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local file = vim.api.nvim_buf_get_name(buf)

  local lines_around = (opts.lines_around_cursor or 50)
  local total = vim.api.nvim_buf_line_count(buf)
  local start_line = math.max(0, cursor[1] - 1 - lines_around)
  local end_line = math.min(total, cursor[1] - 1 + lines_around)
  local content_lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line, false)
  local content = table.concat(content_lines, "\n")

  if opts.max_bytes and #content > opts.max_bytes then
    content = content:sub(1, opts.max_bytes)
  end

  local selection = nil
  if opts.include_selection then
    selection = M.get_visual_selection()
  end

  return {
    file      = file ~= "" and file or nil,
    cursor    = { cursor[1], cursor[2] },
    content   = content,
    selection = selection,
  }
end

function M.get_visual_selection()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    local s = vim.fn.getpos("'<")
    local e = vim.fn.getpos("'>")
    if s[2] == 0 and e[2] == 0 then
      return nil
    end
    local lines = vim.fn.getline(s[2], e[2])
    if #lines == 0 then return nil end
    return table.concat(lines, "\n")
  end

  vim.cmd('noautocmd normal! "vy')
  local text = vim.fn.getreg("v")
  vim.fn.setreg("v", "")
  return (text ~= "") and text or nil
end

function M.truncate(s, max)
  if not s then return s end
  max = max or 8192
  if #s <= max then return s end
  return s:sub(1, max) .. "\n… (truncated)"
end

function M.uuid()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (template:gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end))
end

return M
