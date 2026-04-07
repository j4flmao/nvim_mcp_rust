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
    if keys.pick then
      vim.keymap.set("n", keys.pick, function()
        M.pick_session()
      end, { desc = "MCP Pick Session" })
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
    if not ui.is_open() then
      ui.open(function(q) do_ask(q) end, session.get())
    end
    do_ask(query)
  else
    session.ensure()
    if not ui.is_open() then
      ui.open(function(q) do_ask(q) end, session.get())
    end
  end
end

function M.new_chat()
  local session = require("nvim-mcp.session")
  local ui = require("nvim-mcp.ui")
  if ui.is_open() then
    ui.close()
  end
  session.clear()
  session.ensure()
  vim.notify("nvim-mcp: new chat session", vim.log.levels.INFO)
end

function M.pick_session()
  local session = require("nvim-mcp.session")
  local picker = require("nvim-mcp.ui.picker")
  local history_list = session.get_history_list()
  local current = session.get()
  local current_id = current and current.id or nil

  local items = {}

  if current and current.messages and #current.messages > 0 then
    local first_msg = ""
    for _, msg in ipairs(current.messages) do
      if msg.role == "user" then
        first_msg = msg.content:sub(1, 50)
        if #msg.content > 50 then first_msg = first_msg .. "..." end
        break
      end
    end
    table.insert(items, {
      label = "★ [CURRENT] " .. first_msg,
      hint  = #current.messages .. " msgs",
      value = { type = "current" },
    })
  end

  for i, h in ipairs(history_list) do
    local preview = h.preview or "(no preview)"
    local is_current = (h.id == current_id)
    if not is_current then
      table.insert(items, {
        label = string.format("[%s] %s", h.created_at or "?", preview),
        hint  = #h.messages .. " msgs",
        value = { type = "saved", index = i },
      })
    end
  end

  if #items == 0 then
    vim.notify("nvim-mcp: no sessions yet. Use :MCPNew to start.", vim.log.levels.INFO)
    return
  end

  picker.open({
    title = " MCP Sessions — pick to load ",
    items = items,
    on_select = function(item)
      local sess_data
      if item.value.type == "current" then
        sess_data = current
      else
        sess_data = history_list[item.value.index]
      end

      if not sess_data then return end

      vim.ui.select({ "Continue Chatting", "View History" }, {
        prompt = "Session: " .. (sess_data.created_at or sess_data.id),
      }, function(choice)
        if not choice then return end

        if choice:match("Continue") then
          if item.value.type == "saved" then
            session.load_session(item.value.index)
          else
            session.ensure()
          end
          local ui = require("nvim-mcp.ui")
          if ui.is_open() then ui.close() end
          ui.open(function(q) M.ask(q) end, session.get())
          local msgs = session.get_messages()
          if #msgs > 0 then
            ui.restore_conversation(msgs)
          end
          local resp_lines = session.get().response_lines
          if resp_lines and #resp_lines > 0 then
            ui.restore_response_lines(resp_lines)
          end
        else
          M._browse_session_messages(sess_data.messages, sess_data.created_at or sess_data.id, item.value.type == "current", item.value.index)
        end
      end)
    end,
  })
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

  -- Mark current session if exists
  local current = session.get()
  local current_id = current and current.id or nil

  if #history_list == 0 and not current_id then
    vim.notify("nvim-mcp: no history yet", vim.log.levels.INFO)
    return
  end

  local items = {}

  -- Show current session first if it has messages
  if current and current.messages and #current.messages > 0 then
    local first_msg = ""
    for _, msg in ipairs(current.messages) do
      if msg.role == "user" then
        first_msg = msg.content:sub(1, 50)
        if #msg.content > 50 then first_msg = first_msg .. "..." end
        break
      end
    end
    table.insert(items, {
      label = "★ [CURRENT] " .. first_msg,
      hint  = #current.messages .. " msgs",
      value = { type = "current" },
    })
  end

  -- Show saved sessions
  for i, h in ipairs(history_list) do
    local preview = h.preview or "(no preview)"
    local is_current = (h.id == current_id)
    if not is_current then
      table.insert(items, {
        label = string.format("[%s] %s", h.created_at or "?", preview),
        hint  = #h.messages .. " msgs",
        value = { type = "saved", index = i },
      })
    end
  end

  if #items == 0 then
    vim.notify("nvim-mcp: no history yet", vim.log.levels.INFO)
    return
  end

  picker.open({
    title = " MCP Sessions — pick to browse ",
    items = items,
    on_select = function(item)
      if item.value.type == "current" then
        M._browse_session_messages(current.messages, "Current Session", true)
      else
        local entry = history_list[item.value.index]
        if entry then
          M._browse_session_messages(entry.messages, entry.created_at or entry.id, false, item.value.index)
        end
      end
    end,
  })
end

-- Browse messages inside a session, then option to load it
function M._browse_session_messages(messages, session_label, is_current, history_index)
  if not messages or #messages == 0 then
    vim.notify("nvim-mcp: session is empty", vim.log.levels.INFO)
    return
  end

  -- Build conversation view in a floating window
  local lines = {
    "# Session: " .. session_label,
    "",
  }

  for i, msg in ipairs(messages) do
    if msg.role == "user" then
      table.insert(lines, string.format("### #%d ▸ You", i))
    else
      table.insert(lines, string.format("### #%d ◂ AI", i))
    end
    table.insert(lines, "")
    for _, l in ipairs(vim.split(msg.content, "\n", { plain = true })) do
      table.insert(lines, l)
    end
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")
  end

  if is_current then
    table.insert(lines, "Press `q` to close, `b` to go back to session list")
  else
    table.insert(lines, "Press `l` to load & continue, `b` to go back, `q` to close")
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width = math.min(90, vim.o.columns - 4)
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.85))
  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = math.floor((vim.o.lines - height) / 2),
    col       = math.floor((vim.o.columns - width) / 2),
    border    = "rounded",
    title     = string.format(" Session: %s (%d msgs) ", session_label, #messages),
    title_pos = "center",
    style     = "minimal",
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })

  -- Back to session list
  vim.keymap.set("n", "b", function()
    vim.api.nvim_win_close(win, true)
    M.show_history()
  end, { buffer = buf, nowait = true, desc = "Back to sessions" })

  -- Load session (only for saved, not current)
  if not is_current and history_index then
    vim.keymap.set("n", "l", function()
      vim.api.nvim_win_close(win, true)
      local session = require("nvim-mcp.session")
      local ui = require("nvim-mcp.ui")
      local loaded = session.load_session(history_index)
      if loaded then
        vim.notify("nvim-mcp: loaded session — continue chatting", vim.log.levels.INFO)
        if ui.is_open() then
          ui.close()
        end
        session.ensure()
        ui.open(function(q) M.ask(q) end, session.get())
        local msgs = session.get_messages()
        if #msgs > 0 then
          ui.restore_conversation(msgs)
        end
        local resp_lines = session.get().response_lines
        if resp_lines and #resp_lines > 0 then
          ui.restore_response_lines(resp_lines)
        end
      end
    end, { buffer = buf, nowait = true, desc = "Load & continue" })
  end
end

function M.revert()
  local session = require("nvim-mcp.session")
  local picker = require("nvim-mcp.ui.picker")
  local ui = require("nvim-mcp.ui")
  
  local all_msgs = session.get_messages_for_display()
  
  -- Only show user messages in picker
  local user_items = {}
  for _, msg in ipairs(all_msgs) do
    if msg.role == "user" then
      table.insert(user_items, msg)
    end
  end

  if #user_items == 0 then
    vim.notify("nvim-mcp: no messages to revert", vim.log.levels.INFO)
    return
  end

  picker.open({
    title = " MCP Revert - Pick your message to undo ",
    items = user_items,
    on_select = function(item)
      local revert_idx = item.index - 1
      local removed = #all_msgs - math.max(revert_idx, 0)
      local preview = item.content:sub(1, 50)
      if #item.content > 50 then preview = preview .. "..." end

      local confirm_msg = string.format(
        "Revert from message #%d?\n\n\"%s\"\n\nThis will DELETE %d message(s) after this point.\nThis action cannot be undone.",
        item.index, preview, removed
      )

      vim.ui.select({ "Yes — Revert", "No — Cancel" }, {
        prompt = confirm_msg,
      }, function(choice)
        if not choice or choice:match("^No") then
          vim.notify("nvim-mcp: revert cancelled", vim.log.levels.INFO)
          return
        end

        if revert_idx < 1 then
          session.revert_to(0)
        else
          session.revert_to(revert_idx)
        end

        vim.notify(
          string.format("nvim-mcp: reverted — removed %d message(s) from #%d onward", removed, item.index),
          vim.log.levels.INFO
        )

        local original_content = item.content

        if ui.is_open() then
          ui.close()
        end
        session.ensure()
        ui.open(function(q) M.ask(q) end, session.get())
        local remaining = session.get_messages()
        if #remaining > 0 then
          ui.restore_conversation(remaining)
        end
        -- Pre-fill prompt with original message so user can edit and re-send
        ui.set_prompt(original_content)
      end)
    end,
  })
end

function M.show_messages()
  local session = require("nvim-mcp.session")
  local messages = session.get_messages_for_display()

  if #messages == 0 then
    vim.notify("nvim-mcp: no messages in current session", vim.log.levels.INFO)
    return
  end

  local lines = { "# Current Session Messages", "" }
  for _, msg in ipairs(messages) do
    local prefix = msg.role == "user" and "▸ You" or "◂ AI"
    local time = msg.hint ~= "" and (" [" .. msg.hint .. "]") or ""
    table.insert(lines, string.format("### #%d %s%s", msg.index, prefix, time))
    table.insert(lines, "")
    for _, l in ipairs(vim.split(msg.content, "\n", { plain = true })) do
      table.insert(lines, l)
    end
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width = math.min(90, vim.o.columns - 4)
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.85))
  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = math.floor((vim.o.lines - height) / 2),
    col       = math.floor((vim.o.columns - width) / 2),
    border    = "rounded",
    title     = string.format(" Messages (%d) ", #messages),
    title_pos = "center",
    style     = "minimal",
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
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
