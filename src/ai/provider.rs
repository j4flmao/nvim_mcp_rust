// src/ai/provider.rs — ProviderHub: owns the active backend, routes stream() and fetch_models()

use crate::ai::claude::ClaudeBackend;
use crate::ai::gemini::GeminiBackend;
use crate::ai::lmstudio::LmStudioBackend;
use crate::ai::ollama::OllamaBackend;
use crate::ai::openai::OpenAiBackend;
use crate::ai::{AiBackend, ModelInfo, TokenStream};
use crate::error::{McpError, Result};
use crate::ipc::message::{ChatMessage, FetchModelsParams, SetProviderParams};

pub struct ProviderHub {
    active: Option<ActiveProvider>,
}

struct ActiveProvider {
    connection_id: String,
    provider: String,
    model: String,
    backend: Box<dyn AiBackend>,
}

impl ProviderHub {
    pub fn new() -> Self {
        Self { active: None }
    }

    pub fn set(&mut self, params: SetProviderParams) -> Result<()> {
        let backend: Box<dyn AiBackend> = match params.provider.as_str() {
            "claude" => Box::new(ClaudeBackend::new(params.api_key.as_deref().unwrap_or(""))),
            "openai" => Box::new(OpenAiBackend::new(params.api_key.as_deref().unwrap_or(""))),
            "gemini" => Box::new(GeminiBackend::new(params.api_key.as_deref().unwrap_or(""))),
            "ollama" => Box::new(OllamaBackend::new(
                params.host.as_deref().unwrap_or("http://localhost:11434"),
            )),
            "lmstudio" => Box::new(LmStudioBackend::new(
                params.host.as_deref().unwrap_or("http://localhost:1234"),
            )),
            other => {
                return Err(McpError::AiBackend {
                    backend: other.into(),
                    message: "unknown provider".into(),
                });
            }
        };

        tracing::info!(
            "provider set: {} (model: {})",
            params.provider,
            params.model
        );

        self.active = Some(ActiveProvider {
            connection_id: params.connection_id,
            provider: params.provider,
            model: params.model,
            backend,
        });

        Ok(())
    }

    pub fn active_provider_name(&self) -> Option<&str> {
        self.active.as_ref().map(|a| a.provider.as_str())
    }

    pub fn active_model(&self) -> Option<&str> {
        self.active.as_ref().map(|a| a.model.as_str())
    }

    pub fn has_active(&self) -> bool {
        self.active.is_some()
    }

    pub async fn stream(&self, messages: Vec<ChatMessage>) -> Result<TokenStream> {
        let active = self.active.as_ref().ok_or(McpError::NoActiveProvider)?;
        active.backend.stream(messages, &active.model).await
    }

    pub async fn fetch_models(params: &FetchModelsParams) -> Result<Vec<ModelInfo>> {
        match params.provider.as_str() {
            "claude" => {
                ClaudeBackend::new(params.api_key.as_deref().unwrap_or(""))
                    .list_models()
                    .await
            }
            "openai" => {
                OpenAiBackend::new(params.api_key.as_deref().unwrap_or(""))
                    .list_models()
                    .await
            }
            "gemini" => {
                GeminiBackend::new(params.api_key.as_deref().unwrap_or(""))
                    .list_models()
                    .await
            }
            "ollama" => {
                OllamaBackend::new(params.host.as_deref().unwrap_or("http://localhost:11434"))
                    .list_models()
                    .await
            }
            "lmstudio" => {
                LmStudioBackend::new(params.host.as_deref().unwrap_or("http://localhost:1234"))
                    .list_models()
                    .await
            }
            other => Err(McpError::AiBackend {
                backend: other.into(),
                message: "unknown provider".into(),
            }),
        }
    }
}
