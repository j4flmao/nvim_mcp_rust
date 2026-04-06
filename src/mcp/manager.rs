// src/mcp/manager.rs — McpManager: holds N MCP clients, routes tool calls

use std::collections::HashMap;

use serde_json::Value;

use crate::error::{McpError, Result};
use crate::mcp::client::McpClient;
use crate::mcp::types::Tool;
use crate::transport::stdio::StdioTransport;

pub struct McpManager {
    clients: HashMap<String, McpClient>,
    tool_index: HashMap<String, String>,
}

impl McpManager {
    pub fn new() -> Self {
        Self {
            clients: HashMap::new(),
            tool_index: HashMap::new(),
        }
    }

    pub async fn connect_stdio(
        &mut self,
        name: &str,
        command: &str,
        args: &[String],
        env: HashMap<String, String>,
    ) -> Result<()> {
        let transport = StdioTransport::spawn(name, command, args, env).await?;
        let mut client = McpClient::new(Box::new(transport));
        client.initialize().await?;

        for tool in client.tools() {
            self.tool_index.insert(tool.name.clone(), name.to_string());
        }

        self.clients.insert(name.to_string(), client);
        Ok(())
    }

    pub async fn call_tool(&self, tool_name: &str, arguments: Value) -> Result<String> {
        let server_name = self
            .tool_index
            .get(tool_name)
            .ok_or_else(|| McpError::McpServer {
                server: "unknown".into(),
                message: format!("tool '{}' not found in any connected server", tool_name),
            })?;

        let client = self
            .clients
            .get(server_name)
            .ok_or_else(|| McpError::McpServer {
                server: server_name.clone(),
                message: "server not connected".into(),
            })?;

        let content = client.call_tool(tool_name, arguments).await?;

        let text = content
            .iter()
            .filter_map(|block| block.as_text())
            .collect::<Vec<_>>()
            .join("\n");

        Ok(text)
    }

    pub fn list_all_tools(&self) -> Vec<Tool> {
        self.clients
            .values()
            .flat_map(|c| c.tools().iter().cloned())
            .collect()
    }

    pub fn server_status(&self) -> Vec<ServerStatus> {
        self.clients
            .iter()
            .map(|(name, client)| ServerStatus {
                name: name.clone(),
                alive: client.is_alive(),
                tool_count: client.tools().len(),
            })
            .collect()
    }
}

#[derive(serde::Serialize, Debug)]
pub struct ServerStatus {
    pub name: String,
    pub alive: bool,
    pub tool_count: usize,
}
