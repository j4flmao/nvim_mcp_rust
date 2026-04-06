# Developer Guide

This document is for developers who want to extend or contribute to nvim-mcp.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [IPC Protocol](#ipc-protocol)
- [Adding a New AI Provider](#adding-a-new-ai-provider)
- [Adding New IPC Methods](#adding-new-ipc-methods)
- [Development Setup](#development-setup)
- [Testing](#testing)
- [Code Style](#code-style)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                         Neovim (Lua)                        │
├─────────────────────────────────────────────────────────────┤
│  init.lua       → Public API: setup(), ask(), context()   │
│  bridge.lua     → Spawns Rust binary, JSON-Lines IPC      │
│  commands.lua   → :MCP* user commands                     │
│  provider.lua   → Provider picker UI                       │
│  session.lua   → Chat session management                   │
│  store.lua     → Persistent storage (connections.json)    │
│  ui/init.lua   → Floating windows, streaming display       │
│  ui/picker.lua → Reusable floating list picker             │
└─────────────────────────────────────────────────────────────┘
                              ↓ stdout/stdin
┌─────────────────────────────────────────────────────────────┐
│                     Rust Binary (Core)                     │
├─────────────────────────────────────────────────────────────┤
│  main.rs        → Entry point, tracing init              │
│  handler.rs     → Routes IPC methods to handlers          │
│  ipc/loop.rs    → stdin/stdout JSON-Lines reader/writer  │
│  ipc/message.rs → Request/Response structs                 │
│  ai/provider.rs → ProviderHub: owns active backend        │
│  ai/claude.rs   → Anthropic Claude API (SSE)             │
│  ai/openai.rs   → OpenAI API (SSE)                      │
│  ai/gemini.rs   → Google Gemini API (NDJSON)             │
│  ai/ollama.rs   → Ollama local (NDJSON)                 │
│  ai/lmstudio.rs → LM Studio local (NDJSON)              │
│  mcp/manager.rs → MCP server connections, tool routing    │
│  transport/     → stdio.rs (child process), sse.rs (HTTP)│
└─────────────────────────────────────────────────────────────┘
```

### Key Rules

1. **Lua does UI only** — no business logic, no HTTP calls
2. **Rust does I/O** — all HTTP, streaming, MCP protocol
3. **stdout is IPC** — never log to stdout (breaks Lua bridge)
4. **stderr for logs** — use `tracing` for logging
5. **Every error → Response::Error** — never panic in production

---

## IPC Protocol

Communication uses JSON-Lines over stdin/stdout.

### Lua → Rust

```json
{"id":1,"method":"ask","params":{"query":"explain this","file":"/a/b.rs"}}
{"id":2,"method":"fetch_models","params":{"provider":"openai","api_key":"sk-..."}}
{"id":3,"method":"set_provider","params":{"connection_id":"uuid","provider":"openai","model":"gpt-4o"}}
{"id":4,"method":"ping","params":{}}
```

### Rust → Lua

```json
{"type":"stream","id":1,"chunk":"Hello","done":false}
{"type":"stream","id":1,"chunk":"","done":true}
{"type":"result","id":2,"data":[{"id":"gpt-4o","display":"GPT-4o"}]}
{"type":"result","id":3,"data":{"ok":true}}
{"type":"result","id":4,"data":"pong"}
{"type":"error","id":99,"code":"invalid_api_key","message":"OpenAI: 401"}
{"type":"event","name":"usage","data":{"input_tokens":100,"cost_usd":0.001}}
```

### Message Types

| Type | Fields | Description |
|------|--------|-------------|
| `stream` | `id`, `chunk`, `done` | Token stream chunks |
| `result` | `id`, `data` | Successful response |
| `error` | `id`, `code`, `message` | Error response |
| `event` | `name`, `data` | Async events (e.g., `usage`) |

---

## Adding a New AI Provider

### 1. Create Backend Module

Create `src/ai/myprovider.rs`:

```rust
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use futures::Stream;
use std::pin::Pin;

use crate::ai::{AiBackend, ModelInfo, TokenStream};
use crate::error::{McpError, Result};
use crate::ipc::message::ChatMessage;

pub struct MyProviderBackend {
    api_key: String,
    client: reqwest::Client,
}

impl MyProviderBackend {
    pub fn new(api_key: &str) -> Self {
        Self {
            api_key: api_key.to_string(),
            client: reqwest::Client::new(),
        }
    }
}

#[async_trait]
impl AiBackend for MyProviderBackend {
    async fn stream(&self, messages: Vec<ChatMessage>, model: &str) -> Result<TokenStream> {
        // Implementation here
        let stream = async_stream::stream! {
            // Yield tokens
            yield Ok("response chunk".to_string());
        };
        Ok(Box::pin(stream))
    }

    fn name(&self) -> &'static str {
        "myprovider"
    }

    async fn list_models(&self) -> Result<Vec<ModelInfo>> {
        // Fetch models from API
        Ok(vec![
            ModelInfo {
                id: "my-model".to_string(),
                display: "My Model".to_string(),
                context_len: Some(8192),
            },
        ])
    }
}
```

### 2. Register in ProviderHub

Edit `src/ai/provider.rs`:

```rust
use crate::ai::myprovider::MyProviderBackend;

// In `set()` method, add:
"myprovider" => Box::new(MyProviderBackend::new(
    params.api_key.as_deref().unwrap_or(""),
)),

// In `fetch_models()`, add:
"myprovider" => MyProviderBackend::new(params.api_key.as_deref().unwrap_or(""))
    .list_models()
    .await,
```

### 3. Add to Lua Provider List

Edit `lua/nvim-mcp/provider.lua`:

```lua
local PROVIDERS = {
  -- ... existing providers ...
  { id = "myprovider", label = "My Provider", needs_key = true },
}
```

### 4. Add Cost Estimation

Edit `src/handler.rs`, function `estimate_cost()`:

```rust
"myprovider" => match model {
    m if m.contains("advanced") => (10.0, 30.0),
    _ => (5.0, 15.0),
},
```

---

## Adding New IPC Methods

### 1. Add Method Enum

Edit `src/ipc/message.rs`:

```rust
#[derive(Deserialize, Debug)]
#[serde(rename_all = "snake_case")]
pub enum Method {
    // ... existing methods ...
    MyNewMethod,
}
```

### 2. Add Params Struct

```rust
#[derive(Deserialize, Debug)]
pub struct MyNewMethodParams {
    pub param1: String,
    #[serde(default)]
    pub param2: Option<String>,
}
```

### 3. Add Handler

Edit `src/handler.rs`:

```rust
Method::MyNewMethod => {
    let p: MyNewMethodParams = match serde_json::from_value(params) {
        Ok(p) => p,
        Err(e) => {
            yield Response::Error { id, code: "invalid_params".into(), message: e.to_string() };
            return;
        }
    };
    
    // Handle the method
    // ...
    
    yield Response::Result { id, data: serde_json::to_value(result).unwrap() };
}
```

### 4. Add Lua Bridge Method (optional)

Edit `lua/nvim-mcp/bridge.lua`:

```lua
function M.my_new_method(params, callback)
    M.request("my_new_method", params, callback)
end
```

---

## Development Setup

### Prerequisites

- Neovim 0.9+
- Rust 1.94+
- Git

### Clone and Build

```bash
git clone https://github.com/j4flmao/nvim_mcp_rust.git
cd nvim_mcp_rust

# Build
cargo build

# Run tests
cargo test

# Format
cargo fmt

# Lint
cargo clippy
```

### Using Neovim to Test

```bash
# Create symlink to plugin
ln -s "$(pwd)" ~/.local/share/nvim/site/pack/plugins/start/nvim-mcp

# Or copy binary to PATH
cargo build
cp target/debug/nvim-mcp ~/.cargo/bin/

# Start Neovim
nvim
```

### Debug Logging

```lua
-- In Neovim
require("nvim-mcp").setup({
  log = {
    level = "debug",
    file = "/tmp/nvim-mcp-debug.log",
  },
})
```

---

## Testing

### Unit Tests

```bash
cargo test
```

### Integration Tests

```bash
# Test with actual API (requires API key)
export OPENAI_API_KEY="sk-..."
cargo test --test integration
```

### Manual Testing

1. Start Neovim with the plugin
2. Run `:MCPProvider` to set up a provider
3. Run `:MCPAsk hello`
4. Check `:MCPLog` for debug output

---

## Code Style

### Rust

- Run `cargo fmt` before committing
- Run `cargo clippy -- -D warnings`
- Use meaningful variable names
- Document public functions with doc comments

```rust
/// Streams tokens from the AI provider.
///
/// # Arguments
/// * `messages` - Chat history
/// * `model` - Model identifier
///
/// # Returns
/// A stream of text chunks
pub async fn stream(&self, messages: Vec<ChatMessage>, model: &str) -> Result<TokenStream> {
    // ...
}
```

### Lua

- Use snake_case for variables and functions
- Use Neovim builtins only (no plenary)
- Local variables when possible

```lua
local function format_response(text)
  -- Format text for display
  return text:gsub("%*%*(.-)%*%*", "%1")
end
```

### Commit Messages

Follow conventional commits:

```
feat: add Google Gemini provider support
fix: resolve token count overflow issue
docs: update README with new commands
refactor: simplify session management
chore: update dependencies
```

---

## Release Process

1. Update version in `Cargo.toml`
2. Update `CHANGELOG.md`
3. Create git tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

4. GitHub Actions will:
   - Build for all platforms
   - Create GitHub Release
   - Upload binaries as assets

Users can download binaries from the release page or use the auto-download feature.
