// src/ai/openai.rs — OpenAI GPT streaming backend and model list fetching

use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use reqwest::Client;
use serde_json::{Value, json};

use crate::ai::{AiBackend, ModelInfo, TokenStream};
use crate::error::{McpError, Result};
use crate::ipc::message::ChatMessage;

pub struct OpenAiBackend {
    api_key: String,
    client: Client,
    base_url: String,
}

impl OpenAiBackend {
    pub fn new(api_key: &str) -> Self {
        Self {
            api_key: api_key.to_string(),
            client: Client::new(),
            base_url: "https://api.openai.com".into(),
        }
    }

    pub fn new_with_base(api_key: &str, base_url: &str) -> Self {
        Self {
            api_key: api_key.to_string(),
            client: Client::new(),
            base_url: base_url.trim_end_matches('/').to_string(),
        }
    }
}

#[async_trait]
impl AiBackend for OpenAiBackend {
    fn name(&self) -> &'static str {
        "openai"
    }

    async fn list_models(&self) -> Result<Vec<ModelInfo>> {
        let url = format!("{}/v1/models", self.base_url);

        let resp = tokio::time::timeout(
            Duration::from_secs(8),
            self.client.get(&url).bearer_auth(&self.api_key).send(),
        )
        .await
        .map_err(|_| McpError::Timeout { seconds: 8 })?
        .map_err(|e| {
            if e.status().map(|s| s.as_u16()) == Some(401) {
                McpError::InvalidApiKey {
                    provider: "openai".into(),
                }
            } else {
                McpError::ModelFetchFailed {
                    provider: "openai".into(),
                    reason: e.to_string(),
                }
            }
        })?;

        if resp.status().as_u16() == 401 {
            return Err(McpError::InvalidApiKey {
                provider: "openai".into(),
            });
        }

        let body: Value = resp.json().await.map_err(|e| McpError::ModelFetchFailed {
            provider: "openai".into(),
            reason: e.to_string(),
        })?;

        let mut models: Vec<ModelInfo> = body["data"]
            .as_array()
            .unwrap_or(&vec![])
            .iter()
            .filter(|m| {
                let id = m["id"].as_str().unwrap_or("");
                id.starts_with("gpt-")
                    || id.starts_with("o1")
                    || id.starts_with("o3")
                    || id.starts_with("o4")
            })
            .map(|m| {
                let id = m["id"].as_str().unwrap_or("").to_string();
                ModelInfo {
                    display: id.clone(),
                    id,
                    context_len: None,
                }
            })
            .collect();

        models.sort_by(|a, b| b.id.cmp(&a.id));
        Ok(models)
    }

    async fn stream(&self, messages: Vec<ChatMessage>, model: &str) -> Result<TokenStream> {
        let url = format!("{}/v1/chat/completions", self.base_url);

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
            .bearer_auth(&self.api_key)
            .json(&body)
            .send()
            .await
            .map_err(|e| {
                if e.status().map(|s| s.as_u16()) == Some(401) {
                    McpError::InvalidApiKey {
                        provider: "openai".into(),
                    }
                } else {
                    McpError::AiBackend {
                        backend: "openai".into(),
                        message: e.to_string(),
                    }
                }
            })?;

        if resp.status().as_u16() == 401 {
            return Err(McpError::InvalidApiKey {
                provider: "openai".into(),
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
                            backend: "openai".into(),
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

                    if let Some(content) = parsed["choices"][0]["delta"]["content"].as_str()
                        && !content.is_empty()
                    {
                        yield Ok(content.to_string());
                    }

                    if parsed["choices"][0]["finish_reason"] == "stop" {
                        return;
                    }
                }
            }
        };

        Ok(Box::pin(stream))
    }
}
