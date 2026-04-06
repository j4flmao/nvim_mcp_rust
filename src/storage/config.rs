// src/storage/config.rs — persist connections and active provider

use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

use crate::ipc::message::SetProviderParams;

const APP_NAME: &str = "nvim-mcp";

#[derive(Serialize, Deserialize, Default, Debug)]
pub struct Config {
    pub connections: Vec<Connection>,
    pub active_connection: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Connection {
    pub connection_id: String,
    pub provider: String,
    pub model: String,
    pub api_key: Option<String>,
    pub host: Option<String>,
    pub display_name: String,
}

impl Config {
    pub fn load() -> Self {
        let path = Self::config_path();
        if path.exists() {
            match fs::read_to_string(&path) {
                Ok(content) => {
                    return serde_json::from_str(&content).unwrap_or_default();
                }
                Err(e) => {
                    tracing::warn!("failed to read config: {}", e);
                }
            }
        }
        Self::default()
    }

    pub fn save(&self) -> Result<(), String> {
        let path = Self::config_path();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let content = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        fs::write(&path, content).map_err(|e| e.to_string())?;
        tracing::info!("config saved to {:?}", path);
        Ok(())
    }

    fn config_path() -> PathBuf {
        ProjectDirs::from("com", "nvim-mcp", APP_NAME)
            .map(|dirs| dirs.config_dir().join("config.json"))
            .unwrap_or_else(|| PathBuf::from("config.json"))
    }

    pub fn add_connection(&mut self, params: SetProviderParams) {
        self.connections
            .retain(|c| c.connection_id != params.connection_id);
        self.connections.push(Connection {
            connection_id: params.connection_id,
            provider: params.provider,
            model: params.model,
            api_key: params.api_key,
            host: params.host,
            display_name: params.display_name,
        });
    }

    pub fn remove_connection(&mut self, id: &str) {
        self.connections.retain(|c| c.connection_id != id);
        if self.active_connection.as_deref() == Some(id) {
            self.active_connection = None;
        }
    }

    pub fn set_active(&mut self, id: &str) {
        if self.connections.iter().any(|c| c.connection_id == id) {
            self.active_connection = Some(id.to_string());
        }
    }

    pub fn get_active(&self) -> Option<&Connection> {
        self.active_connection
            .as_ref()
            .and_then(|id| self.connections.iter().find(|c| c.connection_id == *id))
    }
}
