// src/storage/history.rs — persist chat history

use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

use crate::ipc::message::ChatMessage;

const APP_NAME: &str = "nvim-mcp";

#[derive(Serialize, Deserialize, Default, Debug)]
pub struct History {
    pub sessions: Vec<Session>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Session {
    pub id: String,
    pub messages: Vec<ChatMessage>,
    pub created_at: i64,
}

impl History {
    pub fn load() -> Self {
        let path = Self::history_path();
        if path.exists() {
            match fs::read_to_string(&path) {
                Ok(content) => {
                    return serde_json::from_str(&content).unwrap_or_default();
                }
                Err(e) => {
                    tracing::warn!("failed to read history: {}", e);
                }
            }
        }
        Self::default()
    }

    pub fn save(&self) -> Result<(), String> {
        let path = Self::history_path();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let content = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        fs::write(&path, content).map_err(|e| e.to_string())?;
        tracing::info!("history saved to {:?}", path);
        Ok(())
    }

    fn history_path() -> PathBuf {
        ProjectDirs::from("com", "nvim-mcp", APP_NAME)
            .map(|dirs| dirs.data_dir().join("history.json"))
            .unwrap_or_else(|| PathBuf::from("history.json"))
    }

    pub fn add_message(&mut self, session_id: &str, msg: ChatMessage) {
        if let Some(session) = self.sessions.iter_mut().find(|s| s.id == session_id) {
            session.messages.push(msg);
        } else {
            self.sessions.push(Session {
                id: session_id.to_string(),
                messages: vec![msg],
                created_at: std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0),
            });
        }
    }

    pub fn get_session(&self, session_id: &str) -> Option<&Session> {
        self.sessions.iter().find(|s| s.id == session_id)
    }

    pub fn clear(&mut self) {
        self.sessions.clear();
    }
}
