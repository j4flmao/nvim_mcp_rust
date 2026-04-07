-- lua/nvim-mcp/commands.lua — all :MCP* user commands

local M = {}

function M.register()
  local mcp = require("nvim-mcp")
  local bridge = require("nvim-mcp.bridge")
  local provider = require("nvim-mcp.provider")

  vim.api.nvim_create_user_command("MCPAsk", function(opts)
    local query = opts.args
    if query == "" then
      query = nil
    end
    mcp.ask(query)
  end, { nargs = "?", desc = "Ask MCP AI a question" })

  vim.api.nvim_create_user_command("MCPContext", function()
    mcp.context()
  end, { desc = "Show context, tokens, cost, session info" })

  vim.api.nvim_create_user_command("MCPProvider", function()
    provider.open_picker()
  end, { desc = "Manage MCP AI providers" })

  vim.api.nvim_create_user_command("MCPSwap", function()
    provider.open_swap_picker()
  end, { desc = "Quick-switch MCP AI provider" })

  vim.api.nvim_create_user_command("MCPSwitch", function()
    provider.open_swap_picker()
  end, { desc = "Switch to another saved connection" })

  vim.api.nvim_create_user_command("MCPProviderStatus", function()
    provider.status()
  end, { desc = "Show active MCP AI provider" })

  vim.api.nvim_create_user_command("MCPServers", function()
    bridge.request("list_servers", {}, function(data, err)
      if err then
        vim.notify("nvim-mcp: " .. err, vim.log.levels.ERROR)
        return
      end
      if type(data) == "table" and #data > 0 then
        local lines = {}
        for _, s in ipairs(data) do
          local icon = s.alive and "●" or "○"
          table.insert(lines, string.format("  %s %s (%d tools)", icon, s.name, s.tool_count or 0))
        end
        vim.notify("nvim-mcp: servers\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
      else
        vim.notify("nvim-mcp: no MCP servers connected", vim.log.levels.INFO)
      end
    end)
  end, { desc = "List MCP servers" })

  vim.api.nvim_create_user_command("MCPModel", function()
    provider.switch_model()
  end, { desc = "Switch model for active provider" })

  vim.api.nvim_create_user_command("MCPNew", function()
    mcp.new_chat()
  end, { desc = "Start a new MCP chat session" })

  vim.api.nvim_create_user_command("MCPSession", function()
    mcp.session_info()
  end, { desc = "Show session info, tokens, cost stats" })

  vim.api.nvim_create_user_command("MCPPick", function()
    mcp.pick_session()
  end, { desc = "Pick a session to load" })

  vim.api.nvim_create_user_command("MCPHistory", function()
    mcp.show_history()
  end, { desc = "Show and load chat history" })

  vim.api.nvim_create_user_command("MCPRevert", function()
    mcp.revert()
  end, { desc = "Revert to a previous message" })

  vim.api.nvim_create_user_command("MCPMessages", function()
    mcp.show_messages()
  end, { desc = "View all messages in current session" })

  vim.api.nvim_create_user_command("MCPStatus", function()
    mcp.status()
  end, { desc = "Show full status: provider, model, tokens, cost" })

  vim.api.nvim_create_user_command("MCPStop", function()
    bridge.stop()
    vim.notify("nvim-mcp: stopped", vim.log.levels.INFO)
  end, { desc = "Stop MCP binary" })

  vim.api.nvim_create_user_command("MCPRestart", function()
    bridge.stop()
    vim.defer_fn(function()
      bridge.start()
      vim.defer_fn(function()
        local store = require("nvim-mcp.store")
        local active = store.get_active()
        if active then
          bridge.set_provider(active, function(_, err)
            if err then
              vim.notify("nvim-mcp: restart failed to restore provider: " .. err,
                vim.log.levels.WARN)
            else
              vim.notify("nvim-mcp: restarted", vim.log.levels.INFO)
            end
          end)
        else
          vim.notify("nvim-mcp: restarted (no active provider)", vim.log.levels.INFO)
        end
      end, 200)
    end, 100)
  end, { desc = "Restart MCP binary" })

  vim.api.nvim_create_user_command("MCPLog", function()
    local log_file = vim.fn.stdpath("log") .. "/nvim-mcp.log"
    vim.cmd("split " .. vim.fn.fnameescape(log_file))
  end, { desc = "Open MCP log file" })
end

return M
