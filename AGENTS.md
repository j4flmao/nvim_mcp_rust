# AGENTS.md — nvim-mcp

## Project Overview

**nvim-mcp** is a Neovim plugin with a Rust backend that integrates AI providers (Claude, OpenAI, Gemini, Ollama, LM Studio) and MCP (Model Context Protocol) servers into Neovim. The Rust binary communicates with the Lua frontend via JSON-Lines IPC over stdin/stdout.

## Architecture

```
lua/nvim-mcp/    — Neovim Lua plugin (UI, commands, bridge to binary)
plugin/          — Vim plugin loader
src/             — Rust binary (all backend logic)
  ai/            — AI provider backends (claude, openai, gemini, ollama, lmstudio)
  ipc/           — JSON-Lines IPC loop and message types (stdin/stdout)
  mcp/           — MCP client, manager, and protocol types
  transport/     — MCP transport layer (stdio, SSE)
  storage/       — Config and history persistence
  error.rs       — Unified error type (McpError via thiserror)
  handler.rs     — Request router: dispatches IPC methods to async handlers
  markdown.rs    — Markdown parsing utilities
  main.rs        — Entry point: init tracing, start IPC loop
```

## Tech Stack

- **Rust edition**: 2024 (minimum `rustc 1.94`)
- **Toolchain**: Pinned in `rust-toolchain.toml` to `1.94.1`
- **Async runtime**: Tokio (full features)
- **HTTP client**: reqwest with `rustls-tls` (no OpenSSL)
- **Error handling**: `thiserror` for `McpError` enum, custom `Result<T>` alias
- **Serialization**: serde + serde_json
- **Logging**: `tracing` + `tracing-subscriber` (stderr only, **never stdout**)
- **Lua side**: Pure Neovim Lua (UI only, no business logic)

## Critical Rules

### stdout is sacred
The Rust binary communicates with Neovim via stdout JSON-Lines. **Never** use `println!`, `print!`, `dbg!`, or write anything to stdout except valid JSON responses. All logging goes to stderr via `tracing`.

### Boundary between Lua and Rust
- **Lua** handles UI, commands, user interaction, and sending IPC requests.
- **Rust** handles all I/O, AI calls, MCP protocol, storage, and business logic.
- Never put business logic in Lua. Never put UI logic in Rust.

### Error handling
- All errors use `McpError` in `src/error.rs`. Never use `anyhow` for error types (it's in deps but not used for the main error path).
- Handler functions must always return `Response::Error` on failure, never panic.
- Use the project's `Result<T>` alias (`crate::error::Result`), not `std::result::Result`.

### IPC protocol
- JSON-Lines over stdin/stdout (one JSON object per line).
- Request: `{ "id": u64, "method": "snake_case", "params": {} }`
- Response variants: `Result`, `Stream`, `Error`, `Event` (see `src/ipc/message.rs`).
- New IPC methods must be added to the `Method` enum in `src/ipc/message.rs` and handled in `src/handler.rs`.

## Code Conventions

### Rust
- Run `cargo fmt` before committing. CI enforces `cargo fmt --check`.
- Run `cargo clippy -- -D warnings`. CI treats all warnings as errors.
- Module files use the comment header pattern: `// src/path/file.rs — short description`
- Use `async_trait` for async trait definitions.
- Struct fields use standard rustfmt alignment (no manual column-alignment).
- Import order: std → external crates → `crate::` imports, separated by blank lines.
- Keep `use serde_json::{Value, json};` (alphabetical order per rustfmt).

### Lua
- All plugin Lua code lives in `lua/nvim-mcp/`.
- Entry point is `lua/nvim-mcp/init.lua`.
- Follow existing patterns for module structure.

### Commit messages
Use conventional commits: `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`.

## Build & Test Commands

```bash
cargo check              # Type-check without building
cargo build --release    # Release build (LTO, stripped)
cargo fmt                # Format all Rust code
cargo fmt --check        # Check formatting (CI uses this)
cargo clippy -- -D warnings  # Lint (CI uses this)
cargo test --workspace   # Run all tests (CI uses this)
make install             # Build release + install to ~/.local/share/nvim/nvim-mcp/bin/
```

## Adding a New AI Provider

1. Create `src/ai/<name>.rs` implementing the `AiBackend` trait from `src/ai/mod.rs`.
2. Register it in `src/ai/provider.rs` (`ProviderHub::set` and `ProviderHub::fetch_models`).
3. Add the model listing logic in `src/ai/models.rs` if needed.
4. The `AiBackend` trait requires: `stream()`, `name()`, `list_models()`.

## Adding a New IPC Method

1. Add the variant to `Method` enum in `src/ipc/message.rs`.
2. Add the params struct if needed in the same file.
3. Add the handler branch in `src/handler.rs` `dispatch()` function.
4. Add the corresponding Lua-side call in `lua/nvim-mcp/bridge.lua`.

## CI

CI runs on every push and PR (`.github/workflows/ci.yml`):
1. `cargo fmt --check`
2. `cargo clippy -- -D warnings`
3. `cargo test --workspace`

All three must pass. The CI uses toolchain `1.94.1` on `ubuntu-latest`.

## Cross-compilation

Supported targets (defined in `rust-toolchain.toml`):
- `x86_64-unknown-linux-gnu`
- `x86_64-apple-darwin`
- `aarch64-apple-darwin`
- `x86_64-pc-windows-msvc`

Use `make cross-linux`, `make cross-mac-x86`, `make cross-mac-arm`, or `make cross-win`.
