-- lua/nvim-mcp/context_sync.lua — context sync: team + personal context management

local M = {}

-- Get project root (look for .git or .mcp directory)
local function get_project_root()
  local cwd = vim.fn.getcwd()
  local path = vim.fs.find({ ".git", ".mcp" }, { upward = true, path = cwd })
  if #path > 0 then
    return vim.fn.fnamemodify(path[1], ":h")
  end
  return cwd
end

-- Add a new context entry
function M.add(scope)
  scope = scope or "personal"  -- "team" or "personal"
  local bridge = require("nvim-mcp.bridge")

  -- Step 1: Pick category
  local categories = {
    { label = "Convention — coding standards, style rules", value = "convention" },
    { label = "Architecture — system design, structure decisions", value = "architecture" },
    { label = "Pattern — code patterns, best practices", value = "pattern" },
    { label = "Instruction — specific instructions for AI", value = "instruction" },
  }

  local picker = require("nvim-mcp.ui.picker")
  picker.open({
    title = " Context Category ",
    items = categories,
    on_select = function(cat)
      -- Step 2: Input title
      vim.ui.input({ prompt = "Context title: " }, function(title)
        if not title or title == "" then return end

        -- Step 3: Input content (open a scratch buffer for multi-line)
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].filetype = "markdown"
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
          "# Enter context content below (save with <leader>s)",
          "# Lines starting with # will be removed",
          "",
        })

        local width = math.min(80, vim.o.columns - 4)
        local height = math.min(20, math.floor(vim.o.lines * 0.6))
        local win = vim.api.nvim_open_win(buf, true, {
          relative  = "editor",
          width     = width,
          height    = height,
          row       = math.floor((vim.o.lines - height) / 2),
          col       = math.floor((vim.o.columns - width) / 2),
          border    = "rounded",
          title     = string.format(" %s Context: %s ", scope:sub(1, 1):upper() .. scope:sub(2), title),
          title_pos = "center",
          style     = "minimal",
        })

        vim.bo[buf].modifiable = true

        -- Step 4: Priority picker + tags input after content, then save
        vim.keymap.set("n", "<leader>s", function()
          local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          -- Filter out comment lines
          local content_lines = {}
          for _, l in ipairs(lines) do
            if not l:match("^#") then
              table.insert(content_lines, l)
            end
          end
          local content = table.concat(content_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")

          if content == "" then
            vim.notify("nvim-mcp: context content is empty", vim.log.levels.WARN)
            return
          end

          vim.api.nvim_win_close(win, true)

          -- Pick priority
          vim.ui.select({ "high", "medium", "low" }, {
            prompt = "Priority:",
          }, function(priority)
            priority = priority or "medium"

            -- Input tags
            vim.ui.input({ prompt = "Tags (comma-separated, optional): " }, function(tags_str)
              local tags = {}
              if tags_str and tags_str ~= "" then
                for tag in tags_str:gmatch("[^,]+") do
                  table.insert(tags, tag:gsub("^%s+", ""):gsub("%s+$", ""))
                end
              end

              -- Send to backend
              bridge.request("context_add", {
                scope        = scope,
                category     = cat.value,
                title        = title,
                content      = content,
                author       = vim.fn.hostname() .. "/" .. (vim.env.USER or vim.env.USERNAME or "unknown"),
                tags         = tags,
                priority     = priority,
                project_root = get_project_root(),
              }, function(data, err)
                if err then
                  vim.notify("nvim-mcp: failed to add context: " .. err, vim.log.levels.ERROR)
                else
                  vim.notify(string.format("nvim-mcp: [%s] context '%s' added ✓", scope, title), vim.log.levels.INFO)
                end
              end)
            end)
          end)
        end, { buffer = buf, desc = "Save context" })

        vim.notify("nvim-mcp: write content, then <leader>s to save", vim.log.levels.INFO)
      end)
    end,
  })
end

-- List context entries
function M.list(scope)
  local bridge = require("nvim-mcp.bridge")
  local picker = require("nvim-mcp.ui.picker")

  bridge.request("context_list", {
    scope        = scope,  -- nil = both, "team", or "personal"
    project_root = get_project_root(),
  }, function(data, err)
    if err then
      vim.notify("nvim-mcp: " .. err, vim.log.levels.ERROR)
      return
    end

    if type(data) ~= "table" or #data == 0 then
      vim.notify("nvim-mcp: no context entries found", vim.log.levels.INFO)
      return
    end

    local items = {}
    for _, entry in ipairs(data) do
      local scope_icon = entry.scope == "team" and "👥" or "👤"
      local prio_icon = entry.priority == "high" and "🔴" or (entry.priority == "medium" and "🟡" or "🟢")
      table.insert(items, {
        label = string.format("%s %s [%s] %s", scope_icon, prio_icon, entry.category, entry.title),
        hint  = entry.author or "",
        value = entry,
      })
    end

    picker.open({
      title = " Context Entries ",
      items = items,
      on_select = function(item)
        M.view_entry(item.value)
      end,
    })
  end)
end

-- View a single context entry with options
function M.view_entry(entry)
  local lines = {
    "# " .. entry.title,
    "",
    "**Scope:** " .. (entry.scope or "unknown"),
    "**Category:** " .. (entry.category or "unknown"),
    "**Priority:** " .. (entry.priority or "medium"),
    "**Author:** " .. (entry.author or "unknown"),
    "**Created:** " .. (entry.created_at or "unknown"),
    "",
    "---",
    "",
  }
  for _, l in ipairs(vim.split(entry.content or "", "\n", { plain = true })) do
    table.insert(lines, l)
  end
  if entry.tags and #entry.tags > 0 then
    table.insert(lines, "")
    table.insert(lines, "**Tags:** " .. table.concat(entry.tags, ", "))
  end
  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "Press `d` to delete, `q` to close")

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
    title     = " Context Detail ",
    title_pos = "center",
    style     = "minimal",
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
  vim.keymap.set("n", "d", function()
    vim.api.nvim_win_close(win, true)
    M.remove(entry)
  end, { buffer = buf, desc = "Delete context entry" })
end

-- Remove a context entry with confirmation
function M.remove(entry)
  local bridge = require("nvim-mcp.bridge")

  vim.ui.select({ "Yes — Delete", "No — Cancel" }, {
    prompt = string.format("Delete context '%s' (%s)?", entry.title, entry.scope or "unknown"),
  }, function(choice)
    if not choice or choice:match("^No") then
      vim.notify("nvim-mcp: delete cancelled", vim.log.levels.INFO)
      return
    end

    bridge.request("context_remove", {
      id           = entry.id,
      scope        = entry.scope or "personal",
      project_root = get_project_root(),
    }, function(data, err)
      if err then
        vim.notify("nvim-mcp: " .. err, vim.log.levels.ERROR)
      else
        vim.notify(string.format("nvim-mcp: context '%s' deleted ✓", entry.title), vim.log.levels.INFO)
      end
    end)
  end)
end

-- Show merged context preview (what AI will see)
function M.preview()
  local bridge = require("nvim-mcp.bridge")

  bridge.request("context_get", {
    project_root = get_project_root(),
  }, function(data, err)
    if err then
      vim.notify("nvim-mcp: " .. err, vim.log.levels.ERROR)
      return
    end

    local lines = {
      "# Context Sync Preview",
      "",
      string.format("**Team entries:** %d", data.team_count or 0),
      string.format("**Personal entries:** %d", data.personal_count or 0),
      "",
      "---",
      "",
      "## What AI will see:",
      "",
    }

    local merged = data.merged_context or "(empty)"
    for _, l in ipairs(vim.split(merged, "\n", { plain = true })) do
      table.insert(lines, l)
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
      title     = " Context Preview (AI sees this) ",
      title_pos = "center",
      style     = "minimal",
    })

    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].conceallevel = 2
    vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
    vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
  end)
end

return M
