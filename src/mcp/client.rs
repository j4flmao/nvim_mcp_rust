// src/mcp/client.rs — McpClient: wraps transport, handles MCP handshake and tool calls

use serde_json::{Value, json};

use crate::error::{McpError, Result};
use crate::mcp::types::{
    ClientInfo, ContentBlock, InitializeParams, InitializeResult, Tool, ToolCallParams,
    ToolCallResult, ToolsListResult,
};
use crate::transport::McpTransport;

pub struct McpClient {
    transport: Box<dyn McpTransport>,
    tools: Vec<Tool>,
}

impl McpClient {
    pub fn new(transport: Box<dyn McpTransport>) -> Self {
        Self {
            transport,
            tools: Vec::new(),
        }
    }

    pub async fn initialize(&mut self) -> Result<()> {
        let params = InitializeParams {
            protocol_version: "2024-11-05".into(),
            client_info: ClientInfo {
                name: "nvim-mcp".into(),
                version: "0.2.0".into(),
            },
        };

        let result_val = self
            .transport
            .call("initialize", serde_json::to_value(params)?)
            .await?;

        let _result: InitializeResult =
            serde_json::from_value(result_val).map_err(|e| McpError::McpServer {
                server: self.transport.server_name().into(),
                message: format!("invalid initialize response: {}", e),
            })?;

        self.transport
            .notify("notifications/initialized", json!({}))
            .await?;

        self.refresh_tools().await?;

        tracing::info!(
            "MCP server '{}' initialized ({} tools)",
            self.transport.server_name(),
            self.tools.len()
        );

        Ok(())
    }

    pub async fn refresh_tools(&mut self) -> Result<()> {
        let result_val = self.transport.call("tools/list", json!({})).await?;

        let list: ToolsListResult =
            serde_json::from_value(result_val).map_err(|e| McpError::McpServer {
                server: self.transport.server_name().into(),
                message: format!("invalid tools/list response: {}", e),
            })?;

        self.tools = list.tools;
        Ok(())
    }

    pub async fn call_tool(&self, name: &str, arguments: Value) -> Result<Vec<ContentBlock>> {
        let params = ToolCallParams {
            name: name.into(),
            arguments,
        };

        let result_val = self
            .transport
            .call("tools/call", serde_json::to_value(params)?)
            .await?;

        let result: ToolCallResult =
            serde_json::from_value(result_val).map_err(|e| McpError::McpServer {
                server: self.transport.server_name().into(),
                message: format!("invalid tool call response: {}", e),
            })?;

        Ok(result.content)
    }

    pub fn tools(&self) -> &[Tool] {
        &self.tools
    }

    pub fn is_alive(&self) -> bool {
        self.transport.is_alive()
    }

    pub fn server_name(&self) -> &str {
        self.transport.server_name()
    }
}
