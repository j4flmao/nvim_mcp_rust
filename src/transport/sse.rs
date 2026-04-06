// src/transport/sse.rs — MCP over HTTP SSE transport (v0.3 placeholder)

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::sync::{Mutex, oneshot};

use crate::error::{McpError, Result};
use crate::transport::McpTransport;

pub struct SseTransport {
    base_url: String,
    client: reqwest::Client,
    pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>,
    next_id: AtomicU64,
    alive: Arc<AtomicBool>,
    name: String,
}

impl SseTransport {
    pub async fn connect(name: &str, url: &str, _headers: HashMap<String, String>) -> Result<Self> {
        let client = reqwest::Client::new();

        let transport = Self {
            base_url: url.to_string(),
            client,
            pending: Arc::new(Mutex::new(HashMap::new())),
            next_id: AtomicU64::new(1),
            alive: Arc::new(AtomicBool::new(true)),
            name: name.to_string(),
        };

        // TODO: v0.3 — establish GET /sse long-poll connection
        // and spawn background reader task

        Ok(transport)
    }
}

#[async_trait]
impl McpTransport for SseTransport {
    async fn call(&self, method: &str, params: Value) -> Result<Value> {
        if !self.alive.load(Ordering::SeqCst) {
            return Err(McpError::TransportClosed);
        }

        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let request = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        });

        let (tx, rx) = oneshot::channel();
        {
            let mut map = self.pending.lock().await;
            map.insert(id, tx);
        }

        let message_url = format!("{}/message", self.base_url);
        self.client
            .post(&message_url)
            .json(&request)
            .send()
            .await
            .map_err(|e| McpError::McpServer {
                server: self.name.clone(),
                message: e.to_string(),
            })?;

        let result = tokio::time::timeout(Duration::from_secs(10), rx)
            .await
            .map_err(|_| McpError::Timeout { seconds: 10 })?
            .map_err(|_| McpError::TransportClosed)?;

        Ok(result)
    }

    async fn notify(&self, method: &str, params: Value) -> Result<()> {
        if !self.alive.load(Ordering::SeqCst) {
            return Err(McpError::TransportClosed);
        }

        let request = json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        });

        let message_url = format!("{}/message", self.base_url);
        self.client
            .post(&message_url)
            .json(&request)
            .send()
            .await
            .map_err(|e| McpError::McpServer {
                server: self.name.clone(),
                message: e.to_string(),
            })?;

        Ok(())
    }

    fn is_alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }

    fn server_name(&self) -> &str {
        &self.name
    }
}
