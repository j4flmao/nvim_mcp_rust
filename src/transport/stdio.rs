// src/transport/stdio.rs — MCP over stdio: spawn child process, JSON-RPC communication

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter};
use tokio::process::{Child, Command};
use tokio::sync::{Mutex, oneshot};

use crate::error::{McpError, Result};
use crate::transport::McpTransport;

pub struct StdioTransport {
    writer: Arc<Mutex<BufWriter<tokio::process::ChildStdin>>>,
    pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>,
    next_id: AtomicU64,
    alive: Arc<AtomicBool>,
    name: String,
    _child: Arc<Mutex<Child>>,
}

impl StdioTransport {
    pub async fn spawn(
        name: &str,
        command: &str,
        args: &[String],
        env: HashMap<String, String>,
    ) -> Result<Self> {
        let mut cmd = Command::new(command);
        cmd.args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);

        for (k, v) in &env {
            cmd.env(k, v);
        }

        let mut child = cmd.spawn()?;

        let stdin = child.stdin.take().ok_or_else(|| McpError::McpServer {
            server: name.into(),
            message: "failed to capture stdin".into(),
        })?;

        let stdout = child.stdout.take().ok_or_else(|| McpError::McpServer {
            server: name.into(),
            message: "failed to capture stdout".into(),
        })?;

        let writer = Arc::new(Mutex::new(BufWriter::new(stdin)));
        let pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let alive = Arc::new(AtomicBool::new(true));

        // Background reader task
        let pending_clone = Arc::clone(&pending);
        let alive_clone = Arc::clone(&alive);
        let server_name = name.to_string();

        tokio::spawn(async move {
            let reader = BufReader::new(stdout);
            let mut lines = reader.lines();

            while let Ok(Some(line)) = lines.next_line().await {
                let parsed: Value = match serde_json::from_str(&line) {
                    Ok(v) => v,
                    Err(e) => {
                        tracing::warn!("MCP server '{}': malformed JSON: {}", server_name, e);
                        continue;
                    }
                };

                if let Some(id) = parsed.get("id").and_then(|v| v.as_u64()) {
                    let mut map = pending_clone.lock().await;
                    if let Some(tx) = map.remove(&id) {
                        let result = parsed.get("result").cloned().unwrap_or(Value::Null);
                        let _ = tx.send(result);
                    }
                }
            }

            alive_clone.store(false, Ordering::SeqCst);
            tracing::warn!("MCP server '{}': stdout closed", server_name);

            // Resolve all pending with error
            let mut map = pending_clone.lock().await;
            for (_, tx) in map.drain() {
                let _ = tx.send(Value::Null);
            }
        });

        Ok(Self {
            writer,
            pending,
            next_id: AtomicU64::new(1),
            alive,
            name: name.to_string(),
            _child: Arc::new(Mutex::new(child)),
        })
    }
}

#[async_trait]
impl McpTransport for StdioTransport {
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

        {
            let json_line = serde_json::to_string(&request)?;
            let mut w = self.writer.lock().await;
            w.write_all(json_line.as_bytes()).await?;
            w.write_all(b"\n").await?;
            w.flush().await?;
        }

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

        let json_line = serde_json::to_string(&request)?;
        let mut w = self.writer.lock().await;
        w.write_all(json_line.as_bytes()).await?;
        w.write_all(b"\n").await?;
        w.flush().await?;
        Ok(())
    }

    fn is_alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }

    fn server_name(&self) -> &str {
        &self.name
    }
}
