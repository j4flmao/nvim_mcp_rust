// src/ai/mod.rs — AiBackend trait, ModelInfo struct, TokenStream type alias

pub mod claude;
pub mod gemini;
pub mod lmstudio;
pub mod models;
pub mod ollama;
pub mod openai;
pub mod provider;

use async_trait::async_trait;
use futures::Stream;
use serde::{Deserialize, Serialize};
use std::pin::Pin;

use crate::error::Result;
use crate::ipc::message::ChatMessage;

pub type TokenStream = Pin<Box<dyn Stream<Item = Result<String>> + Send>>;

#[async_trait]
pub trait AiBackend: Send + Sync {
    async fn stream(&self, messages: Vec<ChatMessage>, model: &str) -> Result<TokenStream>;
    fn name(&self) -> &'static str;
    async fn list_models(&self) -> Result<Vec<ModelInfo>>;
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ModelInfo {
    pub id: String,
    pub display: String,
    #[serde(default)]
    pub context_len: Option<u32>,
}
