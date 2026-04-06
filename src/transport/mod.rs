// src/transport/mod.rs — McpTransport trait definition

pub mod sse;
pub mod stdio;

use async_trait::async_trait;
use serde_json::Value;

use crate::error::Result;

#[async_trait]
pub trait McpTransport: Send + Sync {
    async fn call(&self, method: &str, params: Value) -> Result<Value>;
    async fn notify(&self, method: &str, params: Value) -> Result<()>;
    fn is_alive(&self) -> bool;
    fn server_name(&self) -> &str;
}
