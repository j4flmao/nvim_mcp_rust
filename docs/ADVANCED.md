# Advanced Configuration

This document covers optional and advanced features. For basic setup, see [README.md](README.md).

## Table of Contents

- [Custom Binary Path](#custom-binary-path)
- [Custom MCP Servers](#custom-mcp-servers)
- [Context Configuration](#context-configuration)
- [UI Customization](#ui-customization)
- [Logging Configuration](#logging-configuration)
- [API Key Security](#api-key-security)

---

## Custom Binary Path

By default, the plugin auto-detects the binary. You can specify a custom path:

```lua
require("nvim-mcp").setup({
  -- Use pre-built binary from GitHub Releases
  binary = vim.fn.stdpath("data") .. "/nvim-mcp/bin/nvim-mcp.exe",
  
  -- Or use local build
  -- binary = "D:/projects/nvim-mcp/target/release/nvim-mcp.exe",
})
```

### Auto-download Script

To automatically download the latest binary on first run, add this to your config:

```lua
-- Auto-download binary if not exists
local bin_dir = vim.fn.stdpath("data") .. "/nvim-mcp/bin"
local bin_path = bin_dir .. "/nvim-mcp.exe"

if vim.fn.has("win32") == 1 and vim.fn.filereadable(bin_path) == 0 then
  vim.fn.mkdir(bin_dir, "p")
  vim.notify("Downloading nvim-mcp binary...", vim.log.levels.INFO)
  local url = "https://github.com/j4flmao/nvim_mcp_rust/releases/latest/download/nvim-mcp-x86_64-pc-windows-msvc.exe"
  vim.fn.system(string.format(
    "powershell -Command \"Invoke-WebRequest -Uri '%s' -OutFile '%s'\"",
    url, bin_path
  ))
end

require("nvim-mcp").setup({
  binary = bin_path,
})
```

---

## Custom MCP Servers

Connect to custom MCP servers for additional tools:

```lua
require("nvim-mcp").setup({
  servers = {
    -- Filesystem access
    {
      name    = "filesystem",
      type    = "stdio",
      command = "npx",
      args    = { "-y", "@modelcontextprotocol/server-filesystem", "." },
      env     = {},
    },
    
    -- Git operations
    {
      name    = "git",
      type    = "stdio",
      command = "npx",
      args    = { "-y", "@modelcontextprotocol/server-git", "." },
      env     = {},
    },
    
    -- GitHub integration
    {
      name    = "github",
      type    = "stdio",
      command = "npx",
      args    = { "-y", "@modelcontextprotocol/server-github" },
      env     = { GITHUB_TOKEN = os.getenv("GITHUB_TOKEN") or "" },
    },
    
    -- Custom SSE server
    {
      name = "custom-sse",
      type = "sse",
      url  = "http://localhost:8080/sse",
      headers = {
        Authorization = "Bearer " .. os.getenv("API_TOKEN"),
      },
    },
  },
})
```

### MCP Server Types

| Type | Description | Config |
|------|-------------|--------|
| `stdio` | Child process via stdin/stdout | `command`, `args`, `env` |
| `sse` | HTTP SSE connection | `url`, `headers` |

---

## Context Configuration

Control what context is sent with each question:

```lua
require("nvim-mcp").setup({
  context = {
    lines_around_cursor = 100,  -- More context around cursor
    include_selection   = true,  -- Include visual selection
    include_diagnostics = true,  -- Include LSP diagnostics
    max_bytes          = 16384, -- 16KB max context
  },
})
```

### Context Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `lines_around_cursor` | number | 50 | Lines of code above/below cursor |
| `include_selection` | boolean | true | Include visual selection if active |
| `include_diagnostics` | boolean | true | Include LSP diagnostic messages |
| `max_bytes` | number | 8192 | Truncate context beyond this size |

---

## UI Customization

Customize the UI appearance:

```lua
require("nvim-mcp").setup({
  ui = {
    border       = "rounded",    -- "rounded", "single", "double", "none"
    width_ratio  = 0.90,         -- 90% of editor width
    height_ratio = 0.85,        -- 85% of editor height
    tools_ratio  = 0.25,        -- 25% of UI for tools panel
    title        = "MCP",
  },
})
```

### Border Styles

```
rounded  → ╭──────╮
single   → ┌──────┐
double   → ╔══════╗
none     → (no border)
```

---

## Logging Configuration

Enable detailed logging for debugging:

```lua
require("nvim-mcp").setup({
  log = {
    level = "debug",                           -- "debug", "info", "warn", "error"
    file  = vim.fn.stdpath("log") .. "/nvim-mcp.log",  -- Log to file
  },
})
```

### Log Levels

| Level | Description |
|-------|-------------|
| `debug` | Detailed debug info (for development) |
| `info` | General information |
| `warn` | Warnings only |
| `error` | Errors only |

### View Logs

```bash
:MCPLog
```

Or in terminal:
```bash
tail -f ~/.local/share/nvim/log/nvim-mcp.log
```

---

## API Key Security

API keys are stored locally in `connections.json`. For extra security:

### Option 1: Environment Variables

```lua
require("nvim-mcp").setup({
  providers = {
    claude = {
      api_key = os.getenv("ANTHROPIC_API_KEY"),
    },
  },
})
```

### Option 2: Use a secrets manager

Store API keys in a secrets manager and load them in your Neovim config:

```lua
-- Load API key from bitwarden-cli
local function get_secret(name)
  local result = vim.fn.system("bw get item " .. name)
  if vim.v.shell_error == 0 then
    local item = vim.json.decode(result)
    return item.login.password
  end
  return nil
end

require("nvim-mcp").setup({
  -- API key will be requested securely when setting up provider
})
```

### File Permissions

Ensure your connections file has proper permissions:

```bash
# Linux/macOS
chmod 600 ~/.local/share/nvim-mcp/connections.json

# Windows (via PowerShell)
icacls "$env:LOCALAPPDATA\nvim-mcp\connections.json" /inheritance:r /grant:r "$env:USERNAME:R"
```

---

## Full Configuration Example

```lua
require("nvim-mcp").setup({
  -- Binary location
  binary = vim.fn.stdpath("data") .. "/nvim-mcp/bin/nvim-mcp.exe",

  -- MCP servers
  servers = {
    {
      name    = "filesystem",
      type    = "stdio",
      command = "npx",
      args    = { "-y", "@modelcontextprotocol/server-filesystem", "." },
      env     = {},
    },
  },

  -- Context settings
  context = {
    lines_around_cursor = 50,
    include_selection   = true,
    include_diagnostics = true,
    max_bytes          = 8192,
  },

  -- UI settings
  ui = {
    border       = "rounded",
    width_ratio  = 0.85,
    height_ratio = 0.80,
    tools_ratio  = 0.28,
  },

  -- Keybindings
  keys = {
    ask      = "<leader>ma",
    context  = "<leader>mc",
    provider = "<leader>mp",
    swap     = "<leader>ms",
    new_chat = "<leader>mn",
    model    = "<leader>mm",
  },

  -- Logging
  log = {
    level = "info",
    file  = nil,
  },
})
```

---

## Troubleshooting

### Debug Mode

Enable debug logging to troubleshoot issues:

```lua
require("nvim-mcp").setup({
  log = {
    level = "debug",
    file  = "/tmp/nvim-mcp-debug.log",
  },
})
```

### Check Binary Location

```lua
-- Print binary path
vim.cmd([[ lua print(vim.fn.stdpath("data") .. "/nvim-mcp/bin/nvim-mcp.exe") ]])
```

### Reset Configuration

To reset all settings:

```bash
# Remove all data
rm -rf ~/.local/share/nvim-mcp/

# Or on Windows
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\nvim-mcp"
```

Then restart Neovim and run `:MCPProvider` to reconfigure.
