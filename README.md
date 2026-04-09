# nvim-mcp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Neovim](https://img.shields.io/badge/Neovim-0.9+-blueviolet.svg)](https://neovim.io/)
[![Rust](https://img.shields.io/badge/Rust-1.94+-orange.svg)](https://www.rust-lang.org/)
[![Release](https://img.shields.io/github/v/release/j4flmao/nvim_mcp_rust?include_prereleases&label=release)](https://github.com/j4flmao/nvim_mcp_rust/releases)

> Neovim AI assistant powered by a Rust binary core. Multi-provider, streaming responses, Telescope-style UI.

No Node.js. No Python. Just a single Rust binary and Lua.

---

## Table of Contents

- [Features](#features)
- [Quick Start](#quick-start)
- [Installation](#installation)
- [Commands](#commands)
- [Keymaps](#keymaps)
- [Provider Setup](#provider-setup)
- [Session Management](#session-management)
- [Usage Tracking](#usage-tracking)
- [Troubleshooting](#troubleshooting)
- [Documentation](#documentation)
- [License](#license)

---

## Features

| Feature | Description |
|---------|-------------|
| **5 AI Providers** | Claude, GPT, Gemini, Ollama, LM Studio |
| **Streaming** | Real-time token responses |
| **Session History** | Persistent chat, revert, load old sessions |
| **Usage Tracking** | Token count, cost estimation |
| **MCP Servers** | Connect to Model Context Protocol servers |
| **Auto-recovery** | Binary auto-restarts on crash |
| **3-Window UI** | Prompt, tools, response layout |

---

## Quick Start

```bash
# 1. Add to Neovim config (see Installation below)

# 2. Open Neovim and setup provider
:MCPProvider

# 3. Ask a question
:MCPAsk explain this code
# or press <leader>ma
```

---

## Installation

### Using lazy.nvim (Recommended)

```lua
-- Minimal setup - commands work via :MCP* (optional)
return {
  "j4flmao/nvim_mcp_rust",
  event = "VeryLazy",
  config = function()
    require("nvim-mcp").setup({})
  end,
}
```

If your plugin manager stores the plugin in a different folder name (e.g., `nvim_mcp_rust` instead of `j4flmao_nvim_mcp_rust`), set the binary URL manually:

```lua
return {
  "j4flmao/nvim_mcp_rust",
  event = "VeryLazy",
  config = function()
    require("nvim-mcp").setup({
      binary = "https://github.com/j4flmao/nvim_mcp_rust/releases/latest/nvim-mcp.exe"
    })
  end,
}
```

```lua
-- With keymaps (optional)
return {
  "j4flmao/nvim_mcp_rust",
  event = "VeryLazy",
  keys = {
    { "<leader>ma", function() require("nvim-mcp").ask() end,         desc = "MCP Ask",      mode = { "n", "v" } },
    { "<leader>mc", function() require("nvim-mcp").context() end,     desc = "MCP Context" },
    { "<leader>mp", "<cmd>MCPProvider<cr>",                           desc = "MCP Provider" },
    { "<leader>ms", "<cmd>MCPSwitch<cr>",                             desc = "MCP Switch" },
    { "<leader>mn", "<cmd>MCPNew<cr>",                               desc = "MCP New" },
    { "<leader>mm", "<cmd>MCPModel<cr>",                             desc = "MCP Model" },
    { "<leader>my", "<cmd>MCPPick<cr>",                              desc = "MCP Pick" },
  },
  config = function()
    require("nvim-mcp").setup({})
  end,
}
```

**No need to build!** The binary is pre-built in GitHub Releases.

### Manual Installation

```bash
# Clone to plugin directory
git clone https://github.com/j4flmao/nvim_mcp_rust.git \
  ~/.local/share/nvim/site/pack/plugins/start/nvim-mcp

# Build binary manually (requires Rust 1.94+)
cargo build --release
cp target/release/nvim-mcp ~/.cargo/bin/
```

---

## Commands

| Command | Description |
|---------|-------------|
| `:MCPAsk [text]` | Ask AI (opens UI if no text) |
| `:MCPProvider` | Add, switch, or remove providers |
| `:MCPSwitch` | Quick-switch between connections |
| `:MCPModel` | Change model for active provider |
| `:MCPContext` | Show context, tokens, cost |
| `:MCPSession` | Show session info and stats |
| `:MCPHistory` | View and load old sessions |
| `:MCPRevert` | Revert to a previous message |
| `:MCPNew` | Start new chat (saves current) |
| `:MCPPick` | Pick session to continue chatting |
| `:MCPStatus` | Show full status |
| `:MCPServers` | List MCP servers |
| `:MCPRestart` | Restart binary |
| `:MCPLog` | Open log file |

---

## Keymaps

| Key | Action |
|-----|--------|
| `<leader>ma` | Open Ask UI |
| `<leader>mc` | Show Context |
| `<leader>mp` | Provider Manager |
| `<leader>ms` | Switch Connection |
| `<leader>mn` | New Chat |
| `<leader>mm` | Switch Model |
| `<leader>my` | Pick Session |

**In UI:**

| Key | Action |
|-----|--------|
| `<CR>` | Submit |
| `<Esc>` / `q` | Close |
| `<Tab>` | Cycle focus |
| `<C-y>` | Yank response |

---

## Provider Setup

### Cloud Providers (need API key)

| Provider | Website |
|----------|---------|
| **Claude** | [console.anthropic.com](https://console.anthropic.com/) |
| **OpenAI** | [platform.openai.com](https://platform.openai.com/) |
| **Gemini** | [aistudio.google.com](https://aistudio.google.com/) |

### Local Providers (no API key)

| Provider | Default Host |
|----------|-------------|
| **Ollama** | http://localhost:11434 |
| **LM Studio** | http://localhost:1234 |

### Setup Flow

```
:MCPProvider
  → + Add new connection
    → Select provider
      → Enter API key (cloud) or host URL (local)
        → Select model
          → Name your connection
```

---

## Session Management

### Auto-save

Sessions save automatically when:
- Closing UI (`q` or `<Esc>`)
- Starting new chat (`:MCPNew`)
- Quitting Neovim

### Pick Session (Continue Chatting)

```bash
:MCPPick        -- Pick session to continue or view history
```

When you pick a session, you'll be prompted to choose:
- **Continue Chatting** — Load the session and continue from where you left off
- **View History** — Browse messages in that session

### Other Commands

```bash
:MCPHistory    -- View and load old sessions
:MCPRevert     -- Revert to a previous message
:MCPNew        -- Start fresh (current saved)
:MCPSession    -- Show session info, tokens, cost stats
```

---

## Usage Tracking

Each response shows:
- **Input tokens** — sent to API
- **Output tokens** — received from API
- **Total tokens** — input + output
- **Context %** — of model's window used
- **Est. cost** — based on provider pricing

View with `:MCPContext` or `:MCPSession`.

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Binary not found | Restart Neovim or run `:MCPRestart` |
| No active provider | Run `:MCPProvider` to setup |
| Invalid API key | Remove connection and re-add |
| Ollama/LM unreachable | Start the server |
| Response empty | Check internet, restart: `:MCPRestart` |
| History not saving | Check write permission to `~/.local/share/nvim-mcp/` |

```bash
# View logs
:MCPLog

# Restart binary
:MCPRestart

# Clear history
rm ~/.local/share/nvim-mcp/history.json
```

---

## Documentation

| Document | Description |
|----------|-------------|
| [docs/ADVANCED.md](docs/ADVANCED.md) | Custom MCP servers, UI, logging, API keys |
| [docs/DEVELOP.md](docs/DEVELOP.md) | Architecture, adding providers, IPC protocol |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contribution guidelines |
| [AGENTS.md](AGENTS.md) | Developer notes (for contributors) |
---

## License

MIT License - see [LICENSE](LICENSE) file.

---

<p align="center">
  Built with Rust &amp; Lua | <a href="https://github.com/j4flmao/nvim_mcp_rust">GitHub</a>
</p>
