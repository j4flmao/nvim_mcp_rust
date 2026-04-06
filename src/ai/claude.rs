// src/ai/claude.rs — Anthropic Claude API: SSE streaming and model list

use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use reqwest::Client;
use serde_json::{Value, json};

use crate::ai::{AiBackend, ModelInfo, TokenStream};
use crate::error::{McpError, Result};
use crate::ipc::message::ChatMessage;

pub struct ClaudeBackend {
    api_key: String,
    client: Client,
}

impl ClaudeBackend {
    pub fn new(api_key: &str) -> Self {
        Self {
            api_key: api_key.to_string(),
            client: Client::new(),
        }
    }
}

#[async_trait]
impl AiBackend for ClaudeBackend {
    fn name(&self) -> &'static str {
        "claude"
    }

    async fn list_models(&self) -> Result<Vec<ModelInfo>> {
        let resp = tokio::time::timeout(
            Duration::from_secs(8),
            self.client
                .get("https://api.anthropic.com/v1/models")
                .header("x-api-key", &self.api_key)
                .header("anthropic-version", "2023-06-01")
                .send(),
        )
        .await
        .map_err(|_| McpError::Timeout { seconds: 8 })?
        .map_err(|e| {
            if e.status().map(|s| s.as_u16()) == Some(401) {
                McpError::InvalidApiKey {
                    provider: "claude".into(),
                }
            } else {
                McpError::ModelFetchFailed {
                    provider: "claude".into(),
                    reason: e.to_string(),
                }
            }
        })?;

        if resp.status().as_u16() == 401 {
            return Err(McpError::InvalidApiKey {
                provider: "claude".into(),
            });
        }

        let body: Value = resp.json().await.map_err(|e| McpError::ModelFetchFailed {
            provider: "claude".into(),
            reason: e.to_string(),
        })?;

        let models = body["data"]
            .as_array()
            .unwrap_or(&vec![])
            .iter()
            .map(|m| ModelInfo {
                id: m["id"].as_str().unwrap_or("").into(),
                display: m["display_name"]
                    .as_str()
                    .unwrap_or(m["id"].as_str().unwrap_or(""))
                    .into(),
                context_len: None,
            })
            .collect();

        Ok(models)
    }

    async fn stream(&self, messages: Vec<ChatMessage>, model: &str) -> Result<TokenStream> {
        let api_messages: Vec<serde_json::Value> = messages
            .iter()
            .map(|m| json!({ "role": m.role, "content": m.content }))
            .collect();

        let body = json!({
            "model": model,
            "max_tokens": 4096,
            "stream": true,
            "messages": api_messages
        });

        let resp = self
            .client
            .post("https://api.anthropic.com/v1/messages")
            .header("x-api-key", &self.api_key)
            .header("anthropic-version", "2023-06-01")
            .header("content-type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|e| {
                if e.status().map(|s| s.as_u16()) == Some(401) {
                    McpError::InvalidApiKey {
                        provider: "claude".into(),
                    }
                } else {
                    McpError::AiBackend {
                        backend: "claude".into(),
                        message: e.to_string(),
                    }
                }
            })?;

        if resp.status().as_u16() == 401 {
            return Err(McpError::InvalidApiKey {
                provider: "claude".into(),
            });
        }

        let mut byte_stream = resp.bytes_stream();

        let stream = async_stream::stream! {
            let mut buffer = String::new();

            while let Some(chunk_result) = byte_stream.next().await {
                let chunk = match chunk_result {
                    Ok(c) => c,
                    Err(e) => {
                        yield Err(McpError::AiBackend {
                            backend: "claude".into(),
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
                    if !line.starts_with("data: ") {
                        continue;
                    }
                    let json_str = &line[6..];
                    if json_str == "[DONE]" {
                        return;
                    }

                    let parsed: Value = match serde_json::from_str(json_str) {
                        Ok(v) => v,
                        Err(_) => continue,
                    };

                    if parsed["type"] == "content_block_delta" {
                        if let Some(text) = parsed["delta"]["text"].as_str()
                            && !text.is_empty()
                        {
                            yield Ok(text.to_string());
                        }
                    } else if parsed["type"] == "message_stop" {
                        return;
                    }
                }
            }
        };

        Ok(Box::pin(stream))
    }
}
