-- lua/nvim-mcp/ui/init.lua — UI coordinator: prompt, tools, response windows

local M = {}

local state = "idle"  -- idle | prompt | streaming | done
local wins = {}
local bufs = {}
local spinner_timer = nil
local spinner_idx = 0
local spinner_chars = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" }
local current_on_submit = nil  -- persisted callback for multi-turn

local function calc_layout()
  local ok, layout = pcall(function()
    local cfg = (require("nvim-mcp").config or {}).ui or {}
    local columns = tonumber(vim.o.columns) or tonumber(vim.api.nvim_get_option("columns")) or 80
    local lines = tonumber(vim.o.lines) or tonumber(vim.api.nvim_get_option("lines")) or 24
    if columns <= 0 then columns = 80 end
    if lines <= 0 then lines = 24 end

    local total_w = math.floor(columns * (cfg.width_ratio or 0.85))
    local total_h = math.floor(lines * (cfg.height_ratio or 0.80))
    total_w = math.max(40, math.min(total_w, columns - 4))
    total_h = math.max(10, math.min(total_h, lines - 4))

    local start_row = math.floor((lines - total_h) / 2)
    local start_col = math.floor((columns - total_w) / 2)
    local prompt_h = 3
    local tools_w = math.floor(total_w * (cfg.tools_ratio or 0.22))
    tools_w = math.max(24, math.min(tools_w, math.floor(total_w * 0.35)))
    local response_w = total_w - tools_w - 1
    local body_h = total_h - prompt_h - 1

    return {
      prompt = {
        width = total_w, height = prompt_h,
        row = start_row, col = start_col,
      },
      tools = {
        width = tools_w, height = body_h,
        row = start_row + prompt_h + 1, col = start_col,
      },
      response = {
        width = response_w, height = body_h,
        row = start_row + prompt_h + 1, col = start_col + tools_w + 1,
      },
    }
  end)

  if not ok or type(layout) ~= "table" then
    return {
      prompt = { width = 80, height = 3, row = 1, col = 1 },
      tools = { width = 23, height = 16, row = 5, col = 1 },
      response = { width = 55, height = 16, row = 5, col = 24 },
    }
  end

  return layout
end

local function make_title(s)
  local provider_name = vim.g.nvim_mcp_active_provider or "no provider"
  if s == "streaming" then
    spinner_idx = (spinner_idx % #spinner_chars) + 1
    return string.format(" MCP [%s] %s ", provider_name, spinner_chars[spinner_idx])
  elseif s == "done" then
    return string.format(" MCP [%s] ✓ ", provider_name)
  else
    return string.format(" MCP [%s] ", provider_name)
  end
end

local function create_buf()
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].buflisted = false
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].swapfile = false
  vim.bo[b].modifiable = true
  return b
end

function M.open(on_submit, sess)
  if state ~= "idle" then
    M.close()
  end

  current_on_submit = on_submit

  local layout = calc_layout()
  local ui_cfg = (require("nvim-mcp").config or {}).ui or {}
  local border = ui_cfg.border or "rounded"

  bufs.prompt   = create_buf()
  bufs.tools    = create_buf()
  bufs.response = create_buf()

  vim.bo[bufs.prompt].filetype = "text"
  vim.bo[bufs.prompt].modifiable = true
  vim.bo[bufs.tools].filetype = "text"
  vim.bo[bufs.tools].modifiable = true
  vim.bo[bufs.response].filetype = "markdown"
  vim.bo[bufs.response].modifiable = true

  -- Enable treesitter markdown rendering for response only
  local ts_ok = pcall(vim.treesitter.start, bufs.response, "markdown")
  if not ts_ok then
    vim.api.nvim_buf_call(bufs.response, function()
      vim.cmd("syntax enable")
    end)
  end

  wins.prompt = vim.api.nvim_open_win(bufs.prompt, true, {
    relative  = "editor",
    width     = layout.prompt.width,
    height    = layout.prompt.height,
    row       = layout.prompt.row,
    col       = layout.prompt.col,
    border    = border,
    title     = make_title("idle"),
    title_pos = "left",
    style     = "minimal",
  })

  wins.tools = vim.api.nvim_open_win(bufs.tools, false, {
    relative  = "editor",
    width     = layout.tools.width,
    height    = layout.tools.height,
    row       = layout.tools.row,
    col       = layout.tools.col,
    border    = border,
    title     = " Tools ",
    title_pos = "center",
    style     = "minimal",
  })

  wins.response = vim.api.nvim_open_win(bufs.response, false, {
    relative  = "editor",
    width     = layout.response.width,
    height    = layout.response.height,
    row       = layout.response.row,
    col       = layout.response.col,
    border    = border,
    title     = " Response ",
    title_pos = "center",
    style     = "minimal",
  })

  -- Enable word wrap and markdown rendering on response window
  vim.wo[wins.response].wrap = true
  vim.wo[wins.response].linebreak = true
  vim.wo[wins.response].breakindent = true
  vim.wo[wins.response].conceallevel = 2
  vim.wo[wins.response].concealcursor = "nvc"
  vim.wo[wins.response].spell = false
  vim.wo[wins.response].number = false
  vim.wo[wins.response].signcolumn = "no"
  vim.wo[wins.response].foldcolumn = "0"
  vim.wo[wins.response].winblend = 0

  vim.wo[wins.tools].wrap = true
  vim.wo[wins.tools].linebreak = true
  vim.wo[wins.tools].number = false
  vim.wo[wins.tools].winblend = 0
  vim.wo[wins.tools].signcolumn = "no"
  vim.wo[wins.tools].foldcolumn = "0"

  vim.wo[wins.prompt].wrap = false
  vim.wo[wins.prompt].number = false
  vim.wo[wins.prompt].winblend = 0
  vim.wo[wins.prompt].cursorline = true
  vim.wo[wins.prompt].concealcursor = "n"  -- avoid prompt transparency / weird insert cursor display

  -- Restore previous conversation if session has history
  if sess and sess.response_lines and #sess.response_lines > 0 then
    vim.bo[bufs.response].modifiable = true
    vim.api.nvim_buf_set_lines(bufs.response, 0, -1, false, sess.response_lines)
    vim.bo[bufs.response].modifiable = false
    M.render_markdown()
    -- Scroll to bottom
    local count = vim.api.nvim_buf_line_count(bufs.response)
    if wins.response and vim.api.nvim_win_is_valid(wins.response) then
      vim.api.nvim_win_set_cursor(wins.response, { count, 0 })
    end
  end

  -- Show provider and session info in tools panel
  local provider_name = vim.g.nvim_mcp_active_provider or "no provider"
  local session_id = sess and sess.id or "new"
  local msg_count = sess and type(sess.messages) == "table" and #sess.messages or 0
  local session_text = string.format("  Session: %s (%d msgs)", session_id, msg_count)

  if bufs.tools and vim.api.nvim_buf_is_valid(bufs.tools) then
    vim.bo[bufs.tools].modifiable = true
    vim.api.nvim_buf_set_lines(bufs.tools, 0, -1, false, {
      "Provider:",
      "  " .. provider_name,
      "",
      "Session:",
      "  " .. session_text,
      "",
      "Controls:",
      "  <CR> Send prompt",
      "  <Tab> Switch panel",
      "  <Esc> / q Close MCP",
      "",
      "Status:",
      "  " .. (state == "streaming" and "Streaming..." or "Ready"),
    })
    vim.bo[bufs.tools].modifiable = false
  end

  if bufs.prompt and vim.api.nvim_buf_is_valid(bufs.prompt) then
    vim.bo[bufs.prompt].modifiable = true
    vim.api.nvim_buf_set_lines(bufs.prompt, 0, -1, false, { "> " })
    vim.bo[bufs.prompt].modifiable = true
  end
  if wins.prompt and vim.api.nvim_win_is_valid(wins.prompt) then
    vim.api.nvim_win_set_cursor(wins.prompt, { 1, 2 })
  end
  vim.cmd("startinsert!")

  state = "prompt"

  -- Keymaps: prompt (works in both "prompt" and "done" states for multi-turn)
  vim.keymap.set("i", "<CR>", function()
    if state ~= "prompt" and state ~= "done" then return end
    local line = vim.api.nvim_buf_get_lines(bufs.prompt, 0, 1, false)[1] or ""
    local query = line:gsub("^>%s*", "")
    if query == "" then return end
    -- Reset prompt for next turn
    vim.bo[bufs.prompt].modifiable = true
    vim.api.nvim_buf_set_lines(bufs.prompt, 0, -1, false, { "> " })
    vim.api.nvim_win_set_cursor(wins.prompt, { 1, 2 })
    state = "prompt"
    if current_on_submit then
      current_on_submit(query)
    end
  end, { buffer = bufs.prompt, nowait = true, desc = "MCP submit" })

  -- Normal mode <CR> in prompt also submits
  vim.keymap.set("n", "<CR>", function()
    if state ~= "prompt" and state ~= "done" then return end
    local line = vim.api.nvim_buf_get_lines(bufs.prompt, 0, 1, false)[1] or ""
    local query = line:gsub("^>%s*", "")
    if query == "" then return end
    vim.bo[bufs.prompt].modifiable = true
    vim.api.nvim_buf_set_lines(bufs.prompt, 0, -1, false, { "> " })
    vim.api.nvim_win_set_cursor(wins.prompt, { 1, 2 })
    state = "prompt"
    if current_on_submit then
      current_on_submit(query)
    end
  end, { buffer = bufs.prompt, nowait = true, desc = "MCP submit" })

  -- Close keymaps for all buffers
  for _, b in pairs(bufs) do
    vim.keymap.set({ "n", "i" }, "<Esc>", function()
      M.close()
    end, { buffer = b, nowait = true, desc = "MCP close" })

    vim.keymap.set("n", "q", function()
      M.close()
    end, { buffer = b, nowait = true, desc = "MCP close" })
  end

  -- Tab cycles focus
  for _, b in pairs(bufs) do
    vim.keymap.set("n", "<Tab>", function()
      local cur = vim.api.nvim_get_current_win()
      if cur == wins.prompt then
        vim.api.nvim_set_current_win(wins.tools)
      elseif cur == wins.tools then
        vim.api.nvim_set_current_win(wins.response)
      else
        vim.api.nvim_set_current_win(wins.prompt)
      end
    end, { buffer = b, nowait = true, desc = "MCP cycle focus" })
  end

  -- Response: yank
  vim.keymap.set("n", "<C-y>", function()
    local lines = vim.api.nvim_buf_get_lines(bufs.response, 0, -1, false)
    vim.fn.setreg('"', table.concat(lines, "\n"))
    vim.notify("nvim-mcp: response yanked", vim.log.levels.INFO)
  end, { buffer = bufs.response, nowait = true, desc = "MCP yank response" })
end

function M.save_response_to_session()
  local session = require("nvim-mcp.session")
  if bufs.response and vim.api.nvim_buf_is_valid(bufs.response) then
    local lines = vim.api.nvim_buf_get_lines(bufs.response, 0, -1, false)
    session.save_response_lines(lines)
  end
end

function M.restore_response_lines(lines)
  if not bufs.response or not vim.api.nvim_buf_is_valid(bufs.response) then
    return
  end
  if not lines or #lines == 0 then
    return
  end

  vim.bo[bufs.response].modifiable = true
  vim.api.nvim_buf_set_lines(bufs.response, 0, -1, false, lines)
  vim.bo[bufs.response].modifiable = false

  if wins.response and vim.api.nvim_win_is_valid(wins.response) then
    local count = vim.api.nvim_buf_line_count(bufs.response)
    vim.api.nvim_win_set_cursor(wins.response, { count, 0 })
  end
end

function M.render_markdown()
  if not bufs.response or not vim.api.nvim_buf_is_valid(bufs.response) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufs.response, 0, -1, false)
  local rendered = {}

  local in_code_block = false
  local code_lang = nil

  local function parse_table(lines, start_idx)
    local rows = {}
    local col_widths = {}
    local i = start_idx

    while i <= #lines do
      local line = lines[i]:gsub("^%s+", ""):gsub("%s+$", "")
      if not line:match("^|") then break end

      local is_sep = true
      local cells = {}
      for cell in line:gmatch("[^|]+") do
        cell = cell:gsub("^%s+", ""):gsub("%s+$", "")
        if cell ~= "" then 
          table.insert(cells, cell)
          if not cell:match("^%-+$") then
            is_sep = false
          end
        end
      end

      if #cells > 0 and not is_sep then
        table.insert(rows, cells)
        for j, cell in ipairs(cells) do
          col_widths[j] = math.max(col_widths[j] or 0, #cell)
        end
      end
      i = i + 1
    end

    return rows, col_widths, i - 1
  end

  local function render_table(rows, col_widths)
    local lines = {}
    if #rows == 0 then return lines end

    local function make_sep()
      local sep = { "| " }
      for j = 1, #col_widths do
        table.insert(sep, string.rep("-", col_widths[j] + 2))
        table.insert(sep, " | ")
      end
      table.insert(sep, "|")
      return table.concat(sep)
    end

    local is_header = true
    for ri, row in ipairs(rows) do
      if ri == 2 and rows[1] and rows[2] and rows[2][1]:match("^%-+$") then
        table.insert(lines, make_sep())
        is_header = false
      else
        local cells = { "| " }
        for j, cell in ipairs(row) do
          table.insert(cells, cell .. string.rep(" ", col_widths[j] - #cell + 2))
          table.insert(cells, " | ")
        end
        table.insert(cells, "|")
        table.insert(lines, table.concat(cells))

        if is_header and ri == 1 then
          table.insert(lines, make_sep())
          is_header = false
        end
      end
    end

    return lines
  end

  local idx = 1
  while idx <= #lines do
    local line = lines[idx]
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")

    if trimmed:match("^|.+|.*$") and not in_code_block then
      local tbl_rows, col_widths, end_idx = parse_table(lines, idx)
      if #tbl_rows > 0 then
        for _, tl in ipairs(render_table(tbl_rows, col_widths)) do
          table.insert(rendered, tl)
        end
        idx = end_idx + 1
      else
        idx = idx + 1
      end
    elseif trimmed:match("^```") then
      if not in_code_block then
        in_code_block = true
        code_lang = trimmed:sub(4)
        if code_lang == "" then code_lang = nil end
        table.insert(rendered, "")
        if code_lang then
          table.insert(rendered, "┌─ " .. code_lang .. " ─")
        else
          table.insert(rendered, "┌─────────────────")
        end
      else
        table.insert(rendered, "└─────────────────")
        table.insert(rendered, "")
        in_code_block = false
        code_lang = nil
      end
    elseif in_code_block then
      table.insert(rendered, "  " .. line)
    elseif trimmed:match("^#%s") then
      local title = trimmed:match("^#%s+(.+)")
      table.insert(rendered, "")
      table.insert(rendered, "█ " .. title)
      table.insert(rendered, string.rep("─", #title + 2))
    elseif trimmed:match("^##%s") then
      local title = trimmed:match("^##%s+(.+)")
      table.insert(rendered, "")
      table.insert(rendered, "▸ " .. title)
    elseif trimmed:match("^###%s") then
      local title = trimmed:match("^###%s+(.+)")
      table.insert(rendered, "  ◆ " .. title)
    elseif trimmed:match("^%*%s") or trimmed:match("^%-%s") or trimmed:match("^%d+%.%s") then
      table.insert(rendered, "  • " .. (trimmed:gsub("^[%*%-%d%.]+%s+", "")))
    elseif trimmed:match("%*%*.+%*%*") then
      table.insert(rendered, (line:gsub("%*%*(.-)%*%*", "%1")))
    elseif trimmed:match("%*.-%*") and not trimmed:match("%*%*") then
      table.insert(rendered, (line:gsub("%*(.-)%*", "%1")))
    elseif trimmed:match("`[^`]+`") then
      table.insert(rendered, (line:gsub("`(.-)`", "%1")))
    elseif trimmed:match("%[.+%]%(.+%)") then
      table.insert(rendered, (line:gsub("%[(.-%)%]%(.+%)", "%1")))
    elseif trimmed ~= "" then
        table.insert(rendered, line)
      end
      idx = idx + 1
    end

  if in_code_block then
    table.insert(rendered, "└─────────────────")
  end

  vim.bo[bufs.response].modifiable = true
  vim.api.nvim_buf_set_lines(bufs.response, 0, -1, false, rendered)
  vim.bo[bufs.response].modifiable = false
end

function M.start_streaming()
  state = "streaming"

  if bufs.response and vim.api.nvim_buf_is_valid(bufs.response) then
    vim.bo[bufs.response].modifiable = true
    local existing = vim.api.nvim_buf_get_lines(bufs.response, 0, -1, false)
    if #existing > 0 and existing[1] ~= "" then
      vim.api.nvim_buf_set_lines(bufs.response, -1, -1, false, { "", "---", "" })
    end
  end

  spinner_timer = vim.uv.new_timer()
  spinner_timer:start(0, 100, function()
    vim.schedule(function()
      if wins.prompt and vim.api.nvim_win_is_valid(wins.prompt) then
        vim.api.nvim_win_set_config(wins.prompt, {
          title     = make_title("streaming"),
          title_pos = "left",
        })
      end
    end)
  end)
end

function M.stream(chunk, done)
  if not bufs.response or not vim.api.nvim_buf_is_valid(bufs.response) then
    return
  end

  if chunk and chunk ~= "" then
    local lines = vim.split(chunk, "\n", { plain = true })
    local last_line_idx = vim.api.nvim_buf_line_count(bufs.response)
    local last_line = vim.api.nvim_buf_get_lines(bufs.response, last_line_idx - 1, last_line_idx, false)[1] or ""

    if #lines > 0 then
      lines[1] = last_line .. lines[1]
      vim.api.nvim_buf_set_lines(bufs.response, last_line_idx - 1, last_line_idx, false, { lines[1] })
      if #lines > 1 then
        vim.api.nvim_buf_set_lines(bufs.response, -1, -1, false, vim.list_slice(lines, 2))
      end
    end

    -- Follow cursor
    if wins.response and vim.api.nvim_win_is_valid(wins.response) then
      local count = vim.api.nvim_buf_line_count(bufs.response)
      vim.api.nvim_win_set_cursor(wins.response, { count, 0 })
    end
  end

  if done then
    M.stop_streaming()
    M.render_markdown()
  end
end

function M.stop_streaming()
  state = "done"

  if spinner_timer then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end

  if bufs.response and vim.api.nvim_buf_is_valid(bufs.response) then
    vim.bo[bufs.response].modifiable = false
  end

  if wins.prompt and vim.api.nvim_win_is_valid(wins.prompt) then
    vim.api.nvim_win_set_config(wins.prompt, {
      title     = make_title("done"),
      title_pos = "left",
    })
  end

  -- Reset prompt for next turn and focus it so user can keep chatting
  if bufs.prompt and vim.api.nvim_buf_is_valid(bufs.prompt) then
    vim.bo[bufs.prompt].modifiable = true
    vim.api.nvim_buf_set_lines(bufs.prompt, 0, -1, false, { "> " })
  end
  if wins.prompt and vim.api.nvim_win_is_valid(wins.prompt) then
    vim.api.nvim_set_current_win(wins.prompt)
    vim.api.nvim_win_set_cursor(wins.prompt, { 1, 2 })
    vim.cmd("startinsert!")
  end
end

function M.append_tool(name, detail)
  if not bufs.tools or not vim.api.nvim_buf_is_valid(bufs.tools) then
    return
  end
  local lines = {
    "▸ " .. name,
  }
  if detail then
    table.insert(lines, "  " .. detail)
  end
  table.insert(lines, "")
  vim.api.nvim_buf_set_lines(bufs.tools, -1, -1, false, lines)
end

function M.update_usage(usage)
  if not bufs.tools or not vim.api.nvim_buf_is_valid(bufs.tools) then
    return
  end

  if usage.rendered and usage.rendered ~= "" then
    vim.schedule(function()
      if bufs.response and vim.api.nvim_buf_is_valid(bufs.response) then
        vim.bo[bufs.response].modifiable = true
        local rendered_lines = vim.split(usage.rendered, "\n", { trimempty = true })
        vim.api.nvim_buf_set_lines(bufs.response, 0, -1, false, rendered_lines)
        vim.bo[bufs.response].modifiable = false
      end
    end)
  end

  local lines = vim.api.nvim_buf_get_lines(bufs.tools, 0, -1, false)

  local pct = usage.context_pct or 0
  local bar_len = 16
  local filled = math.min(bar_len, math.floor((pct / 100) * bar_len))
  local empty = bar_len - filled
  local bar = string.rep("█", filled) .. string.rep("░", empty)
  local bar_line = string.format("  [%s] %d%%", bar, pct)

  local usage_lines = {
    "",
    "Usage",
    "━━━━━━━",
    string.format("  In:  %d", usage.input_tokens or 0),
    string.format("  Out: %d", usage.output_tokens or 0),
    string.format("  Total: %d", usage.total_tokens or 0),
    "",
    "Context Window:",
    bar_line,
    string.format("  %dk / %dk",
      math.max(0, (usage.total_tokens or 0) - (usage.output_tokens or 0)) / 1000,
      (usage.context_window or 0) / 1000),
  }

  if usage.cost_usd and usage.cost_usd > 0 then
    table.insert(usage_lines, "")
    table.insert(usage_lines, "  $" .. string.format("%.4f", usage.cost_usd))
  elseif usage.provider == "ollama" or usage.provider == "lmstudio" then
    table.insert(usage_lines, "")
    table.insert(usage_lines, "  $0.00 (local)")
  end

  local new_lines = {}
  local skip = false
  for _, l in ipairs(lines) do
    if l == "Usage" or l == "Usage Status" then
      skip = true
    elseif skip and l ~= "" and l ~= "━━━━━━━" and not l:match("^  ") and not l:match("^Context") then
      skip = false
      table.insert(new_lines, l)
    elseif not skip then
      table.insert(new_lines, l)
    end
  end

  for _, l in ipairs(usage_lines) do
    table.insert(new_lines, l)
  end

  vim.api.nvim_buf_set_lines(bufs.tools, 0, -1, false, new_lines)
end

function M.close()
  if spinner_timer then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end

  M.save_response_to_session()

  for _, w in pairs(wins) do
    if w and vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_win_close(w, true)
    end
  end

  wins = {}
  bufs = {}
  state = "idle"
  current_on_submit = nil
  vim.cmd("stopinsert")
end

function M.is_open()
  return state ~= "idle"
end

function M.set_prompt(text)
  if not bufs.prompt or not vim.api.nvim_buf_is_valid(bufs.prompt) then
    return
  end
  vim.bo[bufs.prompt].modifiable = true
  vim.api.nvim_buf_set_lines(bufs.prompt, 0, -1, false, { "> " .. text })
  if wins.prompt and vim.api.nvim_win_is_valid(wins.prompt) then
    vim.api.nvim_set_current_win(wins.prompt)
    vim.api.nvim_win_set_cursor(wins.prompt, { 1, #text + 2 })
    vim.cmd("startinsert!")
  end
end

function M.restore_conversation(messages)
  if not bufs.response or not vim.api.nvim_buf_is_valid(bufs.response) then
    return
  end

  local lines = {}
  for _, msg in ipairs(messages) do
    if msg.role == "user" then
      table.insert(lines, "▸ You:")
      for _, l in ipairs(vim.split(msg.content, "\n", { plain = true })) do
        table.insert(lines, "  " .. l)
      end
    else
      table.insert(lines, "")
      for _, l in ipairs(vim.split(msg.content, "\n", { plain = true })) do
        table.insert(lines, l)
      end
    end
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")
  end

  vim.bo[bufs.response].modifiable = true
  vim.api.nvim_buf_set_lines(bufs.response, 0, -1, false, lines)
  vim.bo[bufs.response].modifiable = false

  if wins.response and vim.api.nvim_win_is_valid(wins.response) then
    local count = vim.api.nvim_buf_line_count(bufs.response)
    vim.api.nvim_win_set_cursor(wins.response, { count, 0 })
  end
end

return M
