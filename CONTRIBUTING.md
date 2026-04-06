# Contributing to nvim-mcp

Thank you for your interest in contributing!

## Quick Links

- [Bug Reports](#bug-reports)
- [Feature Requests](#feature-requests)
- [Pull Requests](#pull-requests)
- [Development](#development)

---

## Bug Reports

Please include:

1. Neovim version: `nvim --version`
2. Rust version: `rustc --version`
3. Error messages from `:MCPLog`
4. Steps to reproduce

## Feature Requests

Open an issue with:
- Clear description of the feature
- Use case / motivation
- Potential implementation approach (optional)

## Pull Requests

### Process

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make changes
4. Run tests: `cargo test`
5. Format code: `cargo fmt`
6. Commit with clear message
7. Push and create PR

### Commit Style

```
feat: add new feature
fix: resolve bug
docs: update documentation
refactor: restructure code
chore: update dependencies
```

## Development

See [docs/DEVELOP.md](docs/DEVELOP.md) for:

- Architecture overview
- Adding new AI providers
- IPC protocol reference
- Development setup

### Quick Dev Setup

```bash
# Clone
git clone https://github.com/j4flmao/nvim_mcp_rust.git
cd nvim_mcp_rust

# Build
cargo build

# Test
cargo test

# Format
cargo fmt
```

### Code Rules

- **Lua**: UI only, no business logic
- **Rust**: All I/O, never log to stdout
- **Errors**: Always return `Response::Error`
- **Tests**: Add tests for new features

---

Questions? Open an issue on GitHub.
