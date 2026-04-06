// src/ai/gemini.rs — Google Gemini API: SSE streaming and model list

use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use reqwest::Client;
use serde_json::{Value, json};

use crate::ai::{AiBackend, ModelInfo, TokenStream};
use crate::error::{McpError, Result};
use crate::ipc::message::ChatMessage;

pub struct GeminiBackend {
    api_key: String,
    client: Client,
}

impl GeminiBackend {
    pub fn new(api_key: &str) -> Self {
        Self {
            api_key: api_key.to_string(),
            client: Client::new(),
        }
    }
}

#[async_trait]
impl AiBackend for GeminiBackend {
    fn name(&self) -> &'static str {
        "gemini"
    }

    async fn list_models(&self) -> Result<Vec<ModelInfo>> {
        let url = format!(
            "https://generativelanguage.googleapis.com/v1beta/models?key={}",
            self.api_key
        );

        let resp = tokio::time::timeout(Duration::from_secs(8), self.client.get(&url).send())
            .await
            .map_err(|_| McpError::Timeout { seconds: 8 })?
            .map_err(|e| {
                if e.status().map(|s| s.as_u16()) == Some(401)
                    || e.status().map(|s| s.as_u16()) == Some(403)
                {
                    McpError::InvalidApiKey {
                        provider: "gemini".into(),
                    }
                } else {
                    McpError::ModelFetchFailed {
                        provider: "gemini".into(),
                        reason: e.to_string(),
                    }
                }
            })?;

        let status = resp.status().as_u16();
        if status == 401 || status == 403 {
            return Err(McpError::InvalidApiKey {
                provider: "gemini".into(),
            });
        }

        let body: Value = resp.json().await.map_err(|e| McpError::ModelFetchFailed {
            provider: "gemini".into(),
            reason: e.to_string(),
        })?;

        let models = body["models"]
            .as_array()
            .unwrap_or(&vec![])
            .iter()
            .filter(|m| {
                m["displayName"]
                    .as_str()
                    .map(|d| d.contains("Gemini"))
                    .unwrap_or(false)
                    && m["supportedGenerationMethods"]
                        .as_array()
                        .map(|a| a.iter().any(|v| v == "generateContent"))
                        .unwrap_or(false)
            })
            .map(|m| {
                let full = m["name"].as_str().unwrap_or("");
                let id = full.strip_prefix("models/").unwrap_or(full).to_string();
                ModelInfo {
                    display: m["displayName"].as_str().unwrap_or(&id).into(),
                    id,
                    context_len: None,
                }
            })
            .collect();

        Ok(models)
    }

    async fn stream(&self, messages: Vec<ChatMessage>, model: &str) -> Result<TokenStream> {
        let url = format!(
            "https://generativelanguage.googleapis.com/v1beta/models/{}:streamGenerateContent?key={}&alt=sse",
            model, self.api_key
        );

        let contents: Vec<serde_json::Value> = messages
            .iter()
            .map(|m| {
                let role = if m.role == "assistant" {
                    "model"
                } else {
                    &m.role
                };
                json!({ "role": role, "parts": [{ "text": m.content }] })
            })
            .collect();

        let body = json!({
            "contents": contents
        });

        let resp = self
            .client
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(|e| {
                if e.status().map(|s| s.as_u16()) == Some(401)
                    || e.status().map(|s| s.as_u16()) == Some(403)
                {
                    McpError::InvalidApiKey {
                        provider: "gemini".into(),
                    }
                } else {
                    McpError::AiBackend {
                        backend: "gemini".into(),
                        message: e.to_string(),
                    }
                }
            })?;

        let status = resp.status().as_u16();
        if status == 401 || status == 403 {
            return Err(McpError::InvalidApiKey {
                provider: "gemini".into(),
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
                            backend: "gemini".into(),
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

                    let parsed: Value = match serde_json::from_str(json_str) {
                        Ok(v) => v,
                        Err(_) => continue,
                    };

                    if let Some(text) = parsed["candidates"][0]["content"]["parts"][0]["text"].as_str()
                        && !text.is_empty()
                    {
                        yield Ok(text.to_string());
                    }

                    if parsed["candidates"][0]["finishReason"] == "STOP" {
                        return;
                    }
                }
            }
        };

        Ok(Box::pin(stream))
    }
}
