-- lua/nvim-mcp/config.lua — schema validation, defaults, merge

local M = {}

M.defaults = {
  binary = nil,

  servers = {
    {
      name    = "filesystem",
      type    = "stdio",
      command = "npx",
      args    = { "-y", "@modelcontextprotocol/server-filesystem", "." },
      env     = {},
    },
  },

  context = {
    lines_around_cursor = 50,
    include_selection   = true,
    include_diagnostics = true,
    max_bytes           = 8192,
  },

  ui = {
    border       = "rounded",
    width_ratio  = 0.85,
    height_ratio = 0.80,
    tools_ratio  = 0.28,
    title        = "MCP",
  },

  keys = {
    ask      = "<leader>ma",
    context  = "<leader>mc",
    provider = "<leader>mp",
    swap     = "<leader>ms",
    new_chat = "<leader>mn",
    model    = "<leader>mm",
    pick     = "<leader>my",
  },

  log = {
    level = "info",
    file  = nil,
  },
}

function M.validate(opts)
  vim.validate({
    binary    = { opts.binary,  "string",  true },
    servers   = { opts.servers, "table",   true },
    context   = { opts.context, "table",   true },
    ui        = { opts.ui,      "table",   true },
    keys      = { opts.keys,    "table",   true },
    log       = { opts.log,     "table",   true },
  })
end

function M.merge(user_opts)
  local opts = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
  M.validate(opts)
  return opts
end

return M
