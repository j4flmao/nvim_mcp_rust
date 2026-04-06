-- lua/nvim-mcp/ui/picker.lua — generic reusable floating list picker

local M = {}

function M.open(opts)
  opts = opts or {}
  local items = opts.items or {}
  local on_select = opts.on_select
  local title = opts.title or " Pick "

  if #items == 0 then
    vim.notify("nvim-mcp: no items to pick from", vim.log.levels.WARN)
    return
  end

  local lines = {}
  local max_label = 0
  for _, item in ipairs(items) do
    if #item.label > max_label then max_label = #item.label end
  end

  for _, item in ipairs(items) do
    local line = item.label
    if item.hint then
      local padding = max_label - #item.label + 2
      line = line .. string.rep(" ", padding) .. item.hint
    end
    table.insert(lines, line)
  end

  local width = math.min(math.max(max_label + 20, #title + 4), vim.o.columns - 4)
  local height = math.min(#items + 0, math.floor(vim.o.lines * 0.5))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = math.floor((vim.o.lines - height) / 2),
    col       = math.floor((vim.o.columns - width) / 2),
    border    = "rounded",
    title     = title,
    title_pos = "center",
    style     = "minimal",
  })

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.wo[win].cursorline = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function select()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local idx = cursor[1]
    local item = items[idx]
    close()
    if item and on_select then
      on_select(item)
    end
  end

  vim.keymap.set("n", "<CR>", select, { buffer = buf, nowait = true, desc = "MCP pick select" })
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, desc = "MCP pick close" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, desc = "MCP pick close" })
  vim.keymap.set("n", "j", "j", { buffer = buf, nowait = true, desc = "MCP pick down" })
  vim.keymap.set("n", "k", "k", { buffer = buf, nowait = true, desc = "MCP pick up" })
end

return M
