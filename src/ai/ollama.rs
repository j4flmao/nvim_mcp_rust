// src/ai/ollama.rs — Ollama local API: NDJSON streaming and model list

use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use reqwest::Client;
use serde_json::{Value, json};

use crate::ai::{AiBackend, ModelInfo, TokenStream};
use crate::error::{McpError, Result};
use crate::ipc::message::ChatMessage;

pub struct OllamaBackend {
    host: String,
    client: Client,
}

impl OllamaBackend {
    pub fn new(host: &str) -> Self {
        Self {
            host: host.trim_end_matches('/').to_string(),
            client: Client::new(),
        }
    }
}

#[async_trait]
impl AiBackend for OllamaBackend {
    fn name(&self) -> &'static str {
        "ollama"
    }

    async fn list_models(&self) -> Result<Vec<ModelInfo>> {
        let url = format!("{}/api/tags", self.host);

        let resp = tokio::time::timeout(Duration::from_secs(8), self.client.get(&url).send())
            .await
            .map_err(|_| McpError::ModelFetchFailed {
                provider: "ollama".into(),
                reason: format!("Cannot reach Ollama at {}: connection timed out", self.host),
            })?
            .map_err(|e| McpError::ModelFetchFailed {
                provider: "ollama".into(),
                reason: format!("Cannot reach Ollama at {}: {}", self.host, e),
            })?;

        let body: Value = resp.json().await.map_err(|e| McpError::ModelFetchFailed {
            provider: "ollama".into(),
            reason: e.to_string(),
        })?;

        let models = body["models"]
            .as_array()
            .unwrap_or(&vec![])
            .iter()
            .map(|m| {
                let name = m["name"].as_str().unwrap_or("").to_string();
                ModelInfo {
                    display: name.clone(),
                    id: name,
                    context_len: None,
                }
            })
            .collect();

        Ok(models)
    }

    async fn stream(&self, messages: Vec<ChatMessage>, model: &str) -> Result<TokenStream> {
        let url = format!("{}/api/chat", self.host);

        let api_messages: Vec<serde_json::Value> = messages
            .iter()
            .map(|m| json!({ "role": m.role, "content": m.content }))
            .collect();

        let body = json!({
            "model": model,
            "stream": true,
            "messages": api_messages
        });

        let resp = self
            .client
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(|e| McpError::AiBackend {
                backend: "ollama".into(),
                message: format!("Cannot reach Ollama at {}: {}", self.host, e),
            })?;

        let mut byte_stream = resp.bytes_stream();

        let stream = async_stream::stream! {
            let mut buffer = String::new();

            while let Some(chunk_result) = byte_stream.next().await {
                let chunk = match chunk_result {
                    Ok(c) => c,
                    Err(e) => {
                        yield Err(McpError::AiBackend {
                            backend: "ollama".into(),
                            message: e.to_string(),
                        });
                        return;
                    }
                };

                buffer.push_str(&String::from_utf8_lossy(&chunk));

                while let Some(line_end) = buffer.find('\n') {
                    let line = buffer[..line_end].to_string();
                    buffer = buffer[line_end + 1..].to_string();

                    let line = line.trim();
                    if line.is_empty() {
                        continue;
                    }

                    let parsed: Value = match serde_json::from_str(line) {
                        Ok(v) => v,
                        Err(_) => continue,
                    };

                    if parsed["done"] == true {
                        return;
                    }

                    if let Some(content) = parsed["message"]["content"].as_str()
                        && !content.is_empty()
                    {
                        yield Ok(content.to_string());
                    }
                }
            }
        };

        Ok(Box::pin(stream))
    }
}
