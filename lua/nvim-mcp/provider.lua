-- lua/nvim-mcp/provider.lua — provider picker UI: add, swap, remove connections

local M = {}
local picker = require("nvim-mcp.ui.picker")
local store  = require("nvim-mcp.store")
local bridge = require("nvim-mcp.bridge")
local util   = require("nvim-mcp.util")

local PROVIDERS = {
  { id = "claude",   label = "Anthropic — Claude",  needs_key = true  },
  { id = "openai",   label = "OpenAI — GPT",        needs_key = true  },
  { id = "gemini",   label = "Google — Gemini",      needs_key = true  },
  { id = "ollama",   label = "Ollama (local)",       needs_key = false },
  { id = "lmstudio", label = "LM Studio (local)",    needs_key = false },
}

function M.open_picker()
  local connections = store.load()
  local items = {}

  local active = store.get_active()
  if active then
    table.insert(items, {
      label = "✓ " .. active.display_name,
      value = "__active__",
      hint  = active.provider .. " · " .. active.model,
    })
    table.insert(items, { label = "─────────────────", value = "__sep__" })
  end

  for _, c in ipairs(connections) do
    if not c.active then
      table.insert(items, {
        label = "  " .. c.display_name,
        value = c.connection_id,
        hint  = c.provider .. " · " .. c.model,
      })
    end
  end

  table.insert(items, { label = "─────────────────", value = "__sep__" })
  table.insert(items, { label = "+ Add new connection", value = "__add__" })

  if active then
    table.insert(items, { label = "✕ Remove active connection", value = "__remove__" })
  end

  picker.open({
    title = " MCP Providers ",
    items = items,
    on_select = function(item)
      if item.value == "__sep__" then return end
      if item.value == "__add__" then
        M.pick_provider_type()
      elseif item.value == "__remove__" then
        M.remove_active()
      elseif item.value ~= "__active__" then
        M.swap_to(item.value)
      end
    end,
  })
end

function M.open_swap_picker()
  local connections = store.load()
  if #connections == 0 then
    vim.notify("nvim-mcp: no saved connections. Run :MCPProvider to add one.",
      vim.log.levels.WARN)
    return
  end

  local items = {}
  for _, c in ipairs(connections) do
    table.insert(items, {
      label = (c.active and "✓ " or "  ") .. c.display_name,
      value = c.connection_id,
      hint  = c.provider .. " · " .. c.model,
    })
  end

  picker.open({
    title = " Switch Connection ",
    items = items,
    on_select = function(item)
      M.swap_to(item.value)
    end,
  })
end

function M.swap_to(connection_id)
  store.set_active(connection_id)
  local conn = nil
  for _, c in ipairs(store.load()) do
    if c.connection_id == connection_id then conn = c; break end
  end
  if not conn then return end

  bridge.set_provider(conn, function(_, err)
    if err then
      vim.notify("nvim-mcp: failed to switch provider: " .. err, vim.log.levels.ERROR)
    else
      vim.g.nvim_mcp_active_provider = conn.display_name
      vim.notify("nvim-mcp: switched to " .. conn.display_name, vim.log.levels.INFO)
    end
  end)
end

function M.pick_provider_type()
  picker.open({
    title = " Select Provider ",
    items = vim.tbl_map(function(p)
      return {
        label = p.label,
        value = p.id,
        hint  = p.needs_key and "API key required" or "No key needed",
      }
    end, PROVIDERS),
    on_select = function(item)
      local prov = nil
      for _, p in ipairs(PROVIDERS) do
        if p.id == item.value then prov = p; break end
      end
      if prov then M.prompt_credentials(prov) end
    end,
  })
end

function M.prompt_credentials(provider)
  if provider.needs_key then
    M._prompt_input({
      title     = " " .. provider.label .. " — API Key ",
      hint      = "Paste your API key (input is hidden)",
      masked    = true,
      on_submit = function(key)
        if key == "" then return end
        M.fetch_and_pick_model({ provider = provider.id, api_key = key })
      end,
    })
  else
    local default = provider.id == "ollama"
        and "http://localhost:11434"
        or  "http://localhost:1234"
    M._prompt_input({
      title     = " " .. provider.label .. " — Host URL ",
      hint      = "Press Enter to use default: " .. default,
      masked    = false,
      on_submit = function(host)
        host = (host == "") and default or host
        M.fetch_and_pick_model({ provider = provider.id, host = host })
      end,
    })
  end
end

function M.fetch_and_pick_model(params)
  vim.notify("nvim-mcp: fetching models…", vim.log.levels.INFO)

  bridge.fetch_models(params, function(models, err)
    if err then
      vim.notify("nvim-mcp: " .. err, vim.log.levels.ERROR)
      return
    end
    if not models or #models == 0 then
      vim.notify("nvim-mcp: no models found for this provider", vim.log.levels.WARN)
      return
    end

    picker.open({
      title = " Select Model ",
      items = vim.tbl_map(function(m)
        return { label = m.display, value = m.id }
      end, models),
      on_select = function(item)
        M.prompt_display_name(params, item.value)
      end,
    })
  end)
end

function M.prompt_display_name(cred_params, model_id)
  local default = cred_params.provider .. " / " .. model_id
  M._prompt_input({
    title     = " Connection Name ",
    hint      = 'Press Enter for default: "' .. default .. '"',
    masked    = false,
    on_submit = function(name)
      name = (name == "") and default or name
      local conn = {
        connection_id = util.uuid(),
        provider      = cred_params.provider,
        model         = model_id,
        api_key       = cred_params.api_key,
        host          = cred_params.host,
        display_name  = name,
      }
      store.add(conn)
      bridge.set_provider(conn, function(_, err2)
        if err2 then
          vim.notify("nvim-mcp: saved but failed to activate: " .. err2,
            vim.log.levels.WARN)
        else
          vim.g.nvim_mcp_active_provider = name
          vim.notify('nvim-mcp: active → "' .. name .. '" (' .. model_id .. ")",
            vim.log.levels.INFO)
        end
      end)
    end,
  })
end

function M.remove_active()
  local active = store.get_active()
  if not active then return end
  store.remove(active.connection_id)

  local next_conn = store.get_active()
  if next_conn then
    M.swap_to(next_conn.connection_id)
  else
    vim.g.nvim_mcp_active_provider = nil
    vim.notify("nvim-mcp: removed last connection. Run :MCPProvider to add one.",
      vim.log.levels.WARN)
  end
end

function M._prompt_input(opts)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].buflisted = false
  vim.bo[b].bufhidden = "wipe"

  local W, H = 60, 3
  local win = vim.api.nvim_open_win(b, true, {
    relative  = "editor",
    width     = W,
    height    = H,
    row       = math.floor((vim.o.lines - H) / 2),
    col       = math.floor((vim.o.columns - W) / 2),
    border    = "rounded",
    title     = opts.title,
    title_pos = "center",
    style     = "minimal",
  })

  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "", opts.hint or "" })
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.cmd("startinsert")

  local real_value = ""

  if opts.masked then
    vim.api.nvim_create_autocmd("TextChangedI", {
      buffer   = b,
      callback = function()
        local line = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] or ""
        if #line > #real_value then
          real_value = real_value .. line:sub(#real_value + 1)
        elseif #line < #real_value then
          real_value = real_value:sub(1, #line)
        end
        local masked = string.rep("*", #real_value)
        if masked ~= line then
          vim.api.nvim_buf_set_lines(b, 0, 1, false, { masked })
          vim.api.nvim_win_set_cursor(win, { 1, #masked })
        end
      end,
    })
  end

  vim.keymap.set("i", "<CR>", function()
    local value
    if opts.masked then
      value = real_value
    else
      value = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] or ""
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.cmd("stopinsert")
    opts.on_submit(value)
  end, { buffer = b, nowait = true, desc = "MCP input submit" })

  vim.keymap.set({ "i", "n" }, "<Esc>", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.cmd("stopinsert")
  end, { buffer = b, nowait = true, desc = "MCP input cancel" })
end

function M.switch_model()
  local active = store.get_active()
  if not active then
    vim.notify("nvim-mcp: no active provider. Run :MCPProvider first.", vim.log.levels.WARN)
    return
  end

  local params = {
    provider = active.provider,
    api_key  = active.api_key,
    host     = active.host,
  }

  vim.notify("nvim-mcp: fetching models…", vim.log.levels.INFO)

  bridge.fetch_models(params, function(models, err)
    if err then
      vim.notify("nvim-mcp: " .. err, vim.log.levels.ERROR)
      return
    end
    if not models or #models == 0 then
      vim.notify("nvim-mcp: no models found", vim.log.levels.WARN)
      return
    end

    local items = {}
    for _, m in ipairs(models) do
      table.insert(items, {
        label = (m.id == active.model and "✓ " or "  ") .. m.display,
        value = m.id,
      })
    end

    picker.open({
      title = " Switch Model (" .. active.provider .. ") ",
      items = items,
      on_select = function(item)
        -- Update the connection's model
        local connections = store.load()
        for _, c in ipairs(connections) do
          if c.connection_id == active.connection_id then
            c.model = item.value
            break
          end
        end
        store.save(connections)

        -- Update active provider in Rust
        local updated = store.get_active()
        if updated then
          bridge.set_provider(updated, function(_, err2)
            if err2 then
              vim.notify("nvim-mcp: failed to switch model: " .. err2, vim.log.levels.ERROR)
            else
              vim.g.nvim_mcp_active_provider = updated.display_name
              vim.notify("nvim-mcp: model switched to " .. item.value, vim.log.levels.INFO)
            end
          end)
        end
      end,
    })
  end)
end

function M.status()
  local active = store.get_active()
  if active then
    vim.notify(
      string.format("nvim-mcp: active provider: %s (%s · %s)",
        active.display_name, active.provider, active.model),
      vim.log.levels.INFO
    )
  else
    vim.notify("nvim-mcp: no active provider. Run :MCPProvider to add one.",
      vim.log.levels.WARN)
  end
end

return M
