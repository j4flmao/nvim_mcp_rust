// src/main.rs — entry point: init tracing (stderr only), start IPC loop

#![allow(dead_code)]

mod ai;
mod error;
mod handler;
mod ipc;
mod markdown;
mod mcp;
mod storage;
mod transport;

use std::sync::Arc;
use tokio::sync::Mutex;

use crate::storage::{Config, History};

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(std::env::var("NVIM_MCP_LOG").unwrap_or_else(|_| "nvim_mcp=info".into()))
        .with_writer(std::io::stderr)
        .without_time()
        .init();

    tracing::info!("nvim-mcp v{} starting", env!("CARGO_PKG_VERSION"));

    let config = Config::load();
    tracing::info!(
        "loaded {} connections from config",
        config.connections.len()
    );

    let history = History::load();
    tracing::info!("loaded {} sessions from history", history.sessions.len());

    let _args: Vec<String> = std::env::args().collect();

    let hub = Arc::new(Mutex::new(ai::provider::ProviderHub::new()));
    let mcp = Arc::new(Mutex::new(mcp::manager::McpManager::new()));
    let storage = Arc::new(Mutex::new(config));
    let history = Arc::new(Mutex::new(history));

    ipc::r#loop::run(hub, mcp, storage, history).await;
}
