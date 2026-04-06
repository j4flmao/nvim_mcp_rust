-- lua/nvim-mcp/init.lua — public API: setup(), ask(), context(), _schedule_setup()

local M = {}

M.config = nil

function M.setup(opts)
  local cfg_mod = require("nvim-mcp.config")
  M.config = cfg_mod.merge(opts)

  local bridge = require("nvim-mcp.bridge")
  bridge.init(M.config)

  local commands = require("nvim-mcp.commands")
  commands.register()

  -- Set up keymaps
  if M.config.keys then
    local keys = M.config.keys
    if keys.ask then
      vim.keymap.set({ "n", "v" }, keys.ask, function()
        M.ask()
      end, { desc = "MCP Ask" })
    end
    if keys.context then
      vim.keymap.set("n", keys.context, function()
        M.context()
      end, { desc = "MCP Context" })
    end
    if keys.provider then
      vim.keymap.set("n", keys.provider, "<cmd>MCPProvider<cr>", { desc = "MCP Provider" })
    end
    if keys.swap then
      vim.keymap.set("n", keys.swap, "<cmd>MCPSwap<cr>", { desc = "MCP Swap" })
    end
    if keys.new_chat then
      vim.keymap.set("n", keys.new_chat, function()
        M.new_chat()
      end, { desc = "MCP New Chat" })
    end
    if keys.model then
      vim.keymap.set("n", keys.model, "<cmd>MCPModel<cr>", { desc = "MCP Switch Model" })
    end
  end

  -- VimLeavePre: kill the binary and save session
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      local session = require("nvim-mcp.session")
      session.clear()
      bridge.stop()
    end,
  })
end

function M.ask(query)
  local ui = require("nvim-mcp.ui")
  local bridge = require("nvim-mcp.bridge")
  local util = require("nvim-mcp.util")
  local store = require("nvim-mcp.store")
  local session = require("nvim-mcp.session")

  if not bridge.is_running() then
    vim.notify("nvim-mcp: binary not running. Try :MCPRestart", vim.log.levels.ERROR)
    return
  end

  local active = store.get_active()
  if not active then
    vim.notify("nvim-mcp: no active provider. Run :MCPProvider to set one.", vim.log.levels.WARN)
    return
  end

  local ctx_opts = M.config and M.config.context or {}
  local ctx = util.collect_context(ctx_opts)

  local function do_ask(q)
    session.add_user_message(q)

    local params = {
      query      = q,
      file       = ctx.file,
      cursor     = ctx.cursor,
      selection  = ctx.selection,
      content    = util.truncate(ctx.content, ctx_opts.max_bytes or 8192),
      messages   = session.get_messages(),
      session_id = session.get() and session.get().id,
    }

    ui.start_streaming()

    -- Wire up usage event handler
    local bridge_ref = bridge
    bridge_ref.on_usage = function(usage_data)
      ui.update_usage(usage_data)
    end

    local response_text = ""

    bridge.request_stream("ask", params,
      function(chunk)
        response_text = response_text .. chunk
        ui.stream(chunk, false)
      end,
      function(_, err)
        if err then
          ui.stream("\n\n**Error:** " .. err, false)
          response_text = response_text .. "\n\n**Error:** " .. err
        end
        ui.stream(nil, true)
        -- Save assistant response to session
        if response_text ~= "" then
          session.add_assistant_message(response_text)
        end
        -- Save response buffer lines for restore
        ui.save_response_to_session()
        bridge_ref.on_usage = nil
      end
    )
  end

  if query then
    session.ensure()
    ui.open(function() end, session.get())
    do_ask(query)
  else
    session.ensure()
    ui.open(function(q)
      do_ask(q)
    end, session.get())
  end
end

function M.new_chat()
  local session = require("nvim-mcp.session")
  local ui = require("nvim-mcp.ui")
  if ui.is_open() then
    ui.close()
  end
  session.clear()
  vim.notify("nvim-mcp: new chat session", vim.log.levels.INFO)
end

function M.context()
  local util = require("nvim-mcp.util")
  local store = require("nvim-mcp.store")
  local bridge = require("nvim-mcp.bridge")
  local session = require("nvim-mcp.session")
  local ctx_opts = M.config and M.config.context or {}
  local ctx = util.collect_context(ctx_opts)
  local active = store.get_active()
  local usage = bridge.get_usage()

  local lines = {
    "# MCP Status",
    "",
    "## Provider",
    (active and ("**" .. active.display_name .. "** (" .. active.provider .. " · " .. active.model .. ")")) or "*(none)*",
    "",
    "## Context",
    "**File:** " .. (ctx.file or "(no file)"),
    "**Cursor:** line " .. (ctx.cursor and ctx.cursor[1] or "?") .. ", col " .. (ctx.cursor and ctx.cursor[2] or "?"),
    "**Content size:** " .. (ctx.content and #ctx.content or 0) .. " bytes",
    "",
  }

  if ctx.selection then
    table.insert(lines, "**Selection:** `" .. #ctx.selection .. " chars`")
    table.insert(lines, "")
  end

  table.insert(lines, "## Session Stats")
  local sess = session.get()
  if sess and sess.messages then
    local msg_count = #sess.messages
    local user_msgs = 0
    local asst_msgs = 0
    for _, m in ipairs(sess.messages) do
      if m.role == "user" then user_msgs = user_msgs + 1
      elseif m.role == "assistant" then asst_msgs = asst_msgs + 1 end
    end
    table.insert(lines, "**Messages:** " .. msg_count .. " (user: " .. user_msgs .. ", assistant: " .. asst_msgs .. ")")
  else
    table.insert(lines, "**Messages:** 0")
  end
  table.insert(lines, "")

  table.insert(lines, "## Total Usage (this session)")
  table.insert(lines, "**Input tokens:** " .. usage.input_tokens)
  table.insert(lines, "**Output tokens:** " .. usage.output_tokens)
  table.insert(lines, "**Total tokens:** " .. usage.total_tokens)

  if usage.cost_usd > 0 then
    table.insert(lines, "**Estimated cost:** $" .. string.format("%.4f", usage.cost_usd))
  else
    table.insert(lines, "**Estimated cost:** $0.00")
  end
  table.insert(lines, "")

  if ctx.content then
    table.insert(lines, "## File Context (first 30 lines)")
    table.insert(lines, "```")
    local content_lines = vim.split(ctx.content, "\n", { plain = true })
    for i = 1, math.min(30, #content_lines) do
      table.insert(lines, content_lines[i])
    end
    if #content_lines > 30 then
      table.insert(lines, "... (" .. (#content_lines - 30) .. " more lines)")
    end
    table.insert(lines, "```")
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width = math.min(80, vim.o.columns - 4)
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.85))
  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = math.floor((vim.o.lines - height) / 2),
    col       = math.floor((vim.o.columns - width) / 2),
    border    = "rounded",
    title     = " MCP Context ",
    title_pos = "center",
    style     = "minimal",
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true, desc = "Close" })
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true, desc = "Close" })
  vim.keymap.set("n", "r", function()
    vim.api.nvim_win_close(win, true)
    M.context()
  end, { buffer = buf, nowait = true, desc = "Refresh" })
end

function M.session_info()
  local session = require("nvim-mcp.session")
  local bridge = require("nvim-mcp.bridge")
  local sess = session.get()
  local usage = bridge.get_usage()
  local history_list = session.get_history_list()

  local lines = {
    "# MCP Session Info",
    "",
  }

  if sess and sess.messages and #sess.messages > 0 then
    local user_msgs = 0
    local asst_msgs = 0
    for _, m in ipairs(sess.messages) do
      if m.role == "user" then user_msgs = user_msgs + 1
      elseif m.role == "assistant" then asst_msgs = asst_msgs + 1 end
    end
    table.insert(lines, "## Current Session")
    table.insert(lines, "**Messages:** " .. #sess.messages .. " (user: " .. user_msgs .. ", asst: " .. asst_msgs .. ")")
    table.insert(lines, "**Created:** " .. (sess.created_at or "unknown"))
  else
    table.insert(lines, "## Current Session")
    table.insert(lines, "*(empty)*")
  end

  table.insert(lines, "")
  table.insert(lines, "## Token Usage")
  table.insert(lines, "**Input:** " .. usage.input_tokens)
  table.insert(lines, "**Output:** " .. usage.output_tokens)
  table.insert(lines, "**Total:** " .. usage.total_tokens)

  if usage.cost_usd > 0 then
    table.insert(lines, "**Cost:** $" .. string.format("%.4f", usage.cost_usd))
  else
    table.insert(lines, "**Cost:** $0.00")
  end

  if #history_list > 0 then
    table.insert(lines, "")
    table.insert(lines, "## History (" .. #history_list .. " sessions)")
    for i, h in ipairs(history_list) do
      table.insert(lines, i .. ". " .. h.created_at .. " - " .. h.preview)
    end
  end

  table.insert(lines, "")
  table.insert(lines, "Commands: q=close | h=history | r=redo last")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width = 60
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = math.floor((vim.o.lines - height) / 2),
    col       = math.floor((vim.o.columns - width) / 2),
    border    = "rounded",
    title     = " Session Info ",
    title_pos = "center",
    style     = "minimal",
  })

  vim.wo[win].wrap = true
  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
  vim.keymap.set("n", "h", function()
    vim.api.nvim_win_close(win, true)
    M.show_history()
  end, { buffer = buf, nowait = true })
end

function M.show_history()
  local session = require("nvim-mcp.session")
  local picker = require("nvim-mcp.ui.picker")
  local history_list = session.get_history_list()

  if #history_list == 0 then
    vim.notify("nvim-mcp: no history yet", vim.log.levels.INFO)
    return
  end

  local items = {}
  for i, h in ipairs(history_list) do
    local preview = h.preview or "(no preview)"
    table.insert(items, {
      label = "[" .. h.created_at .. "] " .. preview,
      value = i,
      hint  = #h.messages .. " messages",
    })
  end

  picker.open({
    title = " MCP History ",
    items = items,
    on_select = function(item)
      local loaded = session.load_session(item.value)
      if loaded then
        vim.notify("nvim-mcp: loaded session from " .. loaded.created_at, vim.log.levels.INFO)
        M.ask()
      end
    end,
  })
end

function M.revert()
  local session = require("nvim-mcp.session")
  local picker = require("nvim-mcp.ui.picker")
  local ui = require("nvim-mcp.ui")
  
  local messages = session.get_messages_for_display()
  
  if #messages == 0 then
    vim.notify("nvim-mcp: no messages to revert", vim.log.levels.INFO)
    return
  end

  picker.open({
    title = " MCP Revert - Select message to revert to ",
    items = messages,
    on_select = function(item)
      local content = session.revert_to(item.index)
      if content then
        vim.notify("nvim-mcp: reverted to message " .. item.index, vim.log.levels.INFO)
        if ui.is_open() then
          ui.close()
        end
        M.ask(content)
      end
    end,
  })
end

function M.status()
  local store = require("nvim-mcp.store")
  local bridge = require("nvim-mcp.bridge")
  local session = require("nvim-mcp.session")
  local active = store.get_active()
  local usage = bridge.get_usage()
  local sess = session.get()

  local msg_count = 0
  if sess and sess.messages then
    msg_count = #sess.messages
  end

  local lines = {
    "# MCP Status",
    "",
  }

  if active then
    table.insert(lines, "**Provider:** " .. active.display_name)
    table.insert(lines, "**Backend:** " .. active.provider)
    table.insert(lines, "**Model:** " .. active.model)
  else
    table.insert(lines, "**Provider:** *(none — run :MCPProvider)*")
  end

  table.insert(lines, "")
  table.insert(lines, "**Session messages:** " .. msg_count)
  table.insert(lines, "")
  table.insert(lines, "## Token Usage (this session)")
  table.insert(lines, "**In:** " .. usage.input_tokens .. " tokens")
  table.insert(lines, "**Out:** " .. usage.output_tokens .. " tokens")
  table.insert(lines, "**Total:** " .. usage.total_tokens .. " tokens")

  if usage.cost_usd > 0 then
    table.insert(lines, "**Cost:** $" .. string.format("%.4f", usage.cost_usd))
  else
    table.insert(lines, "**Cost:** $0.00")
  end
  table.insert(lines, "")
  table.insert(lines, "Press `r` to refresh, `q` to close")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width = 45
  local height = #lines
  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = math.floor((vim.o.lines - height) / 2),
    col       = math.floor((vim.o.columns - width) / 2),
    border    = "rounded",
    title     = " MCP Status ",
    title_pos = "center",
    style     = "minimal",
  })

  vim.wo[win].wrap = true
  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
  vim.keymap.set("n", "r", function()
    vim.api.nvim_win_close(win, true)
    M.status()
  end, { buffer = buf })
end

function M._schedule_setup()
  if not M.config then
    M.setup({})
  end

  local bridge = require("nvim-mcp.bridge")
  bridge.start()

  vim.defer_fn(function()
    local store = require("nvim-mcp.store")
    local active = store.get_active()
    if active then
      bridge.set_provider(active, function(_, err)
        if err then
          vim.notify(
            string.format(
              'nvim-mcp: could not restore "%s": %s\nRun :MCPProvider to reconfigure.',
              active.display_name, err
            ),
            vim.log.levels.WARN
          )
        else
          vim.g.nvim_mcp_active_provider = active.display_name
        end
      end)
    end
  end, 200)
end

return M
