// src/ipc/message.rs — Request, Response, and all params structs for JSON-Lines IPC

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Deserialize, Debug)]
pub struct Request {
    pub id: u64,
    pub method: Method,
    pub params: Value,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "snake_case")]
pub enum Method {
    Ask,
    Context,
    ListServers,
    ListTools,
    ListConnections,
    FetchModels,
    SetProvider,
    RemoveConnection,
    Ping,
    Shutdown,
    GetHistory,
}

#[derive(Serialize, Debug)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Response {
    Result {
        id: u64,
        data: Value,
    },
    Stream {
        id: u64,
        chunk: String,
        done: bool,
    },
    Error {
        id: u64,
        code: String,
        message: String,
    },
    Event {
        name: String,
        data: Value,
    },
}

#[derive(Deserialize, Debug)]
pub struct AskParams {
    pub query: String,
    #[serde(default)]
    pub file: Option<String>,
    #[serde(default)]
    pub cursor: Option<[u32; 2]>,
    #[serde(default)]
    pub selection: Option<String>,
    #[serde(default)]
    pub content: Option<String>,
    #[serde(default)]
    pub provider: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub messages: Option<Vec<ChatMessage>>,
    #[serde(default)]
    pub session_id: Option<String>,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct FetchModelsParams {
    pub provider: String,
    #[serde(default)]
    pub api_key: Option<String>,
    #[serde(default)]
    pub host: Option<String>,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct SetProviderParams {
    pub connection_id: String,
    pub provider: String,
    pub model: String,
    #[serde(default)]
    pub api_key: Option<String>,
    #[serde(default)]
    pub host: Option<String>,
    pub display_name: String,
}

#[derive(Deserialize, Debug)]
pub struct RemoveConnectionParams {
    pub connection_id: String,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}
