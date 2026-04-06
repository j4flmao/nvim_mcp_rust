// src/mcp/types.rs — MCP protocol data structures

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[allow(dead_code)]
#[derive(Serialize, Debug)]
pub struct ClientInfo {
    pub name: String,
    pub version: String,
}

#[allow(dead_code)]
#[derive(Serialize, Debug)]
pub struct InitializeParams {
    #[serde(rename = "protocolVersion")]
    pub protocol_version: String,
    #[serde(rename = "clientInfo")]
    pub client_info: ClientInfo,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
pub struct InitializeResult {
    #[serde(default)]
    pub capabilities: Value,
    #[serde(default, rename = "serverInfo")]
    pub server_info: Option<ServerInfo>,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
pub struct ServerInfo {
    pub name: String,
    #[serde(default)]
    pub version: Option<String>,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct Tool {
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default, rename = "inputSchema")]
    pub input_schema: Option<Value>,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
pub struct ToolsListResult {
    pub tools: Vec<Tool>,
}

#[allow(dead_code)]
#[derive(Serialize, Debug)]
pub struct ToolCallParams {
    pub name: String,
    pub arguments: Value,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
pub struct ToolCallResult {
    #[serde(default)]
    pub content: Vec<ContentBlock>,
}

#[allow(dead_code)]
#[derive(Deserialize, Serialize, Debug, Clone)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ContentBlock {
    Text {
        text: String,
    },
    Image {
        #[serde(default)]
        data: Option<String>,
        #[serde(default, rename = "mimeType")]
        mime_type: Option<String>,
    },
    Resource {
        #[serde(default)]
        uri: Option<String>,
        #[serde(default)]
        text: Option<String>,
    },
}

impl ContentBlock {
    pub fn as_text(&self) -> Option<&str> {
        match self {
            ContentBlock::Text { text } => Some(text),
            _ => None,
        }
    }
}
