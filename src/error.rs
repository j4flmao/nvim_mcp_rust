// src/error.rs — unified error type for nvim-mcp

use thiserror::Error;

#[derive(Error, Debug)]
pub enum McpError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("HTTP error: {0}")]
    Http(#[from] reqwest::Error),

    #[error("MCP server '{server}' error: {message}")]
    McpServer { server: String, message: String },

    #[error("AI backend '{backend}' error: {message}")]
    AiBackend { backend: String, message: String },

    #[error("Provider '{provider}': invalid API key or unauthorized")]
    InvalidApiKey { provider: String },

    #[error("Provider '{provider}': failed to fetch model list: {reason}")]
    ModelFetchFailed { provider: String, reason: String },

    #[error("No active provider configured. Run :MCPProvider to set one.")]
    NoActiveProvider,

    #[error("Transport closed unexpectedly")]
    TransportClosed,

    #[error("Request timed out after {seconds}s")]
    Timeout { seconds: u64 },

    #[error("Unknown method: {0}")]
    UnknownMethod(String),
}

pub type Result<T> = std::result::Result<T, McpError>;
