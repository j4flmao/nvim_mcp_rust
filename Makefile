BINARY  := nvim-mcp
RELEASE := target/release/$(BINARY)
INSTALL := $(HOME)/.local/share/nvim/$(BINARY)/bin/$(BINARY)

.PHONY: all build install clean fmt lint test check debug

all: build

build:
	cargo build --release

install: build
	mkdir -p $(dir $(INSTALL))
	cp $(RELEASE) $(INSTALL)
	@echo "Installed -> $(INSTALL)"

check:
	cargo check

fmt:
	cargo fmt --all

lint:
	cargo clippy -- -D warnings

test:
	cargo test --workspace

clean:
	cargo clean

debug:
	cargo build
	mkdir -p $(dir $(INSTALL))
	cp target/debug/$(BINARY) $(dir $(INSTALL))$(BINARY)

cross-linux:   ; cross build --release --target x86_64-unknown-linux-gnu
cross-mac-x86: ; cross build --release --target x86_64-apple-darwin
cross-mac-arm: ; cross build --release --target aarch64-apple-darwin
cross-win:     ; cross build --release --target x86_64-pc-windows-msvc
