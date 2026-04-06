// src/handler.rs — request router: dispatches IPC methods to async handlers

use std::sync::Arc;

use futures::Stream;
use serde_json::{Value, json};
use tokio::sync::Mutex;

use crate::ai::provider::ProviderHub;
use crate::ipc::message::{
    AskParams, ChatMessage, FetchModelsParams, Method, RemoveConnectionParams, Response,
    SetProviderParams,
};
use crate::mcp::manager::McpManager;
use crate::storage::{Config, History};

pub async fn dispatch(
    id: u64,
    method: Method,
    params: Value,
    hub: Arc<Mutex<ProviderHub>>,
    mcp: Arc<Mutex<McpManager>>,
    storage: Arc<Mutex<Config>>,
    history: Arc<Mutex<History>>,
) -> impl Stream<Item = Response> {
    async_stream::stream! {
        match method {
            Method::Ping => {
                yield Response::Result {
                    id,
                    data: json!("pong"),
                };
            }

            Method::Shutdown => {
                yield Response::Result {
                    id,
                    data: json!({"ok": true}),
                };
                tracing::info!("shutdown requested, exiting");
                std::process::exit(0);
            }

            Method::FetchModels => {
                let p: FetchModelsParams = match serde_json::from_value(params) {
                    Ok(p) => p,
                    Err(e) => {
                        yield Response::Error {
                            id,
                            code:    "invalid_params".into(),
                            message: e.to_string(),
                        };
                        return;
                    }
                };

                tracing::debug!("fetch_models for provider: {}", p.provider);

                match ProviderHub::fetch_models(&p).await {
                    Ok(models) => {
                        yield Response::Result {
                            id,
                            data: serde_json::to_value(&models)
                                .unwrap_or(json!([])),
                        };
                    }
                    Err(e) => {
                        let code = match &e {
                            crate::error::McpError::InvalidApiKey { .. } => "invalid_api_key",
                            crate::error::McpError::ModelFetchFailed { .. } => "model_fetch_failed",
                            _ => "backend_error",
                        };
                        yield Response::Error {
                            id,
                            code:    code.into(),
                            message: e.to_string(),
                        };
                    }
                }
            }

            Method::SetProvider => {
                let p: SetProviderParams = match serde_json::from_value(params) {
                    Ok(p) => p,
                    Err(e) => {
                        yield Response::Error {
                            id,
                            code:    "invalid_params".into(),
                            message: e.to_string(),
                        };
                        return;
                    }
                };

                tracing::info!("set_provider: {} / {}", p.provider, p.model);

                let mut hub_lock = hub.lock().await;
                match hub_lock.set(p.clone()) {
                    Ok(()) => {
                        let mut storage_lock = storage.lock().await;
                        storage_lock.add_connection(p.clone());
                        storage_lock.set_active(&p.connection_id);
                        let _ = storage_lock.save();

                        yield Response::Result {
                            id,
                            data: json!({"ok": true}),
                        };
                    }
                    Err(e) => {
                        yield Response::Error {
                            id,
                            code:    "backend_error".into(),
                            message: e.to_string(),
                        };
                    }
                }
            }

            Method::Ask => {
                let p: AskParams = match serde_json::from_value(params) {
                    Ok(p) => p,
                    Err(e) => {
                        yield Response::Error {
                            id,
                            code:    "invalid_params".into(),
                            message: e.to_string(),
                        };
                        return;
                    }
                };

                let session_id = p.session_id.clone().unwrap_or_else(|| "default".to_string());

                let hub_lock = hub.lock().await;

                if !hub_lock.has_active() {
                    yield Response::Error {
                        id,
                        code:    "no_provider".into(),
                        message: "No active provider. Run :MCPProvider to configure one.".into(),
                    };
                    return;
                }

                let mut messages = if let Some(ref msgs) = p.messages
                    && !msgs.is_empty()
                {
                    msgs.clone()
                } else {
                    Vec::new()
                };

                let user_msg = ChatMessage {
                    role: "user".to_string(),
                    content: p.query.clone(),
                };
                messages.push(user_msg.clone());

                let input_chars: usize = messages.iter().map(|m| m.content.len()).sum();
                let mut output_chars: usize = 0;
                let mut full_response = String::new();

                let token_stream = match hub_lock.stream(messages.clone()).await {
                    Ok(s) => s,
                    Err(e) => {
                        let code = match &e {
                            crate::error::McpError::InvalidApiKey { .. } => "invalid_api_key",
                            crate::error::McpError::NoActiveProvider => "no_provider",
                            _ => "backend_error",
                        };
                        yield Response::Error {
                            id,
                            code:    code.into(),
                            message: e.to_string(),
                        };
                        return;
                    }
                };

                // Drop the lock before streaming
                drop(hub_lock);

                use futures::StreamExt;
                futures_util::pin_mut!(token_stream);

                while let Some(chunk) = token_stream.next().await {
                    match chunk {
                        Ok(text) => {
                            output_chars += text.len();
                            full_response.push_str(&text);
                            yield Response::Stream {
                                id,
                                chunk: text,
                                done: false,
                            };
                        }
                        Err(e) => {
                            yield Response::Error {
                                id,
                                code:    "stream_error".into(),
                                message: e.to_string(),
                            };
                            return;
                        }
                    }
                }

                yield Response::Stream {
                    id,
                    chunk: String::new(),
                    done: true,
                };

                // Save to history
                {
                    let mut history_lock = history.lock().await;
                    history_lock.add_message(&session_id, user_msg);
                    history_lock.add_message(&session_id, ChatMessage {
                        role: "assistant".to_string(),
                        content: full_response.clone(),
                    });
                    let _ = history_lock.save();
                }

                // Estimate tokens (~4 chars per token for English)
                let input_tokens = input_chars / 4;
                let output_tokens = output_chars / 4;

                // Get model info from hub
                let hub_lock2 = hub.lock().await;
                let provider_name = hub_lock2.active_provider_name()
                    .unwrap_or("unknown").to_string();
                let model_name = hub_lock2.active_model()
                    .unwrap_or("unknown").to_string();
                drop(hub_lock2);

                let context_window = estimate_context_window(&model_name);
                let total_tokens = input_tokens + output_tokens;
                let context_pct = if context_window > 0 {
                    (total_tokens as f64 / context_window as f64 * 100.0) as u32
                } else {
                    0
                };

                let cost = estimate_cost(&provider_name, &model_name, input_tokens, output_tokens);

                let rendered_ui = crate::markdown::render_to_ui(full_response.clone());

                yield Response::Event {
                    name: "usage".into(),
                    data: json!({
                        "input_tokens": input_tokens,
                        "output_tokens": output_tokens,
                        "total_tokens": total_tokens,
                        "input_chars": input_chars,
                        "output_chars": output_chars,
                        "context_window": context_window,
                        "context_pct": context_pct,
                        "cost_usd": cost,
                        "provider": provider_name,
                        "model": model_name,
                        "session_input_tokens": input_tokens,
                        "session_output_tokens": output_tokens,
                        "session_total_tokens": total_tokens,
                        "session_cost_usd": cost,
                        "rendered": rendered_ui,
                    }),
                };
            }

            Method::Context => {
                yield Response::Result {
                    id,
                    data: json!({"ok": true}),
                };
            }

            Method::ListServers => {
                let mcp_lock = mcp.lock().await;
                let status = mcp_lock.server_status();
                yield Response::Result {
                    id,
                    data: serde_json::to_value(&status).unwrap_or(json!([])),
                };
            }

            Method::ListTools => {
                let mcp_lock = mcp.lock().await;
                let tools = mcp_lock.list_all_tools();
                yield Response::Result {
                    id,
                    data: serde_json::to_value(&tools).unwrap_or(json!([])),
                };
            }

            Method::ListConnections => {
                let storage_lock = storage.lock().await;
                let connections: Vec<_> = storage_lock.connections.iter().map(|c| {
                    serde_json::json!({
                        "connection_id": c.connection_id,
                        "provider": c.provider,
                        "model": c.model,
                        "display_name": c.display_name,
                        "is_active": storage_lock.active_connection.as_deref() == Some(&c.connection_id),
                    })
                }).collect();
                yield Response::Result {
                    id,
                    data: serde_json::to_value(connections).unwrap_or(json!([])),
                };
            }

            Method::RemoveConnection => {
                let p: RemoveConnectionParams = match serde_json::from_value(params) {
                    Ok(p) => p,
                    Err(e) => {
                        yield Response::Error {
                            id,
                            code:    "invalid_params".into(),
                            message: e.to_string(),
                        };
                        return;
                    }
                };

                let mut storage_lock = storage.lock().await;
                storage_lock.remove_connection(&p.connection_id);
                let _ = storage_lock.save();

                yield Response::Result {
                    id,
                    data: json!({"ok": true}),
                };
            }

            Method::GetHistory => {
                let history_lock = history.lock().await;
                let sessions: Vec<_> = history_lock.sessions.iter().map(|s| {
                    serde_json::json!({
                        "id": s.id,
                        "messages": s.messages,
                        "created_at": s.created_at,
                    })
                }).collect();
                yield Response::Result {
                    id,
                    data: serde_json::to_value(sessions).unwrap_or(json!([])),
                };
            }
        }
    }
}

fn build_messages(params: &AskParams) -> Vec<ChatMessage> {
    if let Some(ref msgs) = params.messages
        && !msgs.is_empty()
    {
        return msgs.clone();
    }

    let mut parts = Vec::new();

    if let Some(ref file) = params.file {
        parts.push(format!("File: {}", file));
    }

    if let Some(ref cursor) = params.cursor {
        parts.push(format!("Cursor: line {}, col {}", cursor[0], cursor[1]));
    }

    if let Some(ref selection) = params.selection {
        parts.push(format!("Selected code:\n```\n{}\n```", selection));
    }

    if let Some(ref content) = params.content {
        parts.push(format!("File context:\n```\n{}\n```", content));
    }

    parts.push(format!("Question: {}", params.query));

    vec![ChatMessage {
        role: "user".into(),
        content: parts.join("\n\n"),
    }]
}

fn estimate_context_window(model: &str) -> usize {
    match model {
        // Claude
        m if m.contains("claude-3-5")
            || m.contains("claude-sonnet-4")
            || m.contains("claude-opus-4") =>
        {
            200_000
        }
        m if m.contains("claude-3") => 200_000,
        m if m.contains("claude") => 100_000,
        // OpenAI
        m if m.starts_with("gpt-4o") => 128_000,
        m if m.starts_with("gpt-4-turbo") => 128_000,
        m if m.starts_with("gpt-4") => 8_192,
        m if m.starts_with("o1") || m.starts_with("o3") || m.starts_with("o4") => 200_000,
        // Gemini
        m if m.contains("gemini-2") => 1_000_000,
        m if m.contains("gemini-1.5-pro") => 2_000_000,
        m if m.contains("gemini-1.5") => 1_000_000,
        m if m.contains("gemini") => 32_000,
        // Local - default
        _ => 8_192,
    }
}

fn estimate_cost(provider: &str, model: &str, input_tokens: usize, output_tokens: usize) -> f64 {
    let (input_price, output_price) = match provider {
        "claude" => match model {
            m if m.contains("opus") => (15.0, 75.0),
            m if m.contains("sonnet") => (3.0, 15.0),
            m if m.contains("haiku") => (0.25, 1.25),
            _ => (3.0, 15.0),
        },
        "openai" => match model {
            m if m.starts_with("gpt-4o-mini") => (0.15, 0.60),
            m if m.starts_with("gpt-4o") => (2.50, 10.0),
            m if m.starts_with("gpt-4-turbo") => (10.0, 30.0),
            m if m.starts_with("gpt-4") => (30.0, 60.0),
            m if m.starts_with("o1") => (15.0, 60.0),
            m if m.starts_with("o3") => (10.0, 40.0),
            _ => (2.50, 10.0),
        },
        "gemini" => match model {
            m if m.contains("pro") => (1.25, 5.0),
            m if m.contains("flash") => (0.075, 0.30),
            _ => (0.50, 1.50),
        },
        // Local providers are free
        "ollama" | "lmstudio" => (0.0, 0.0),
        _ => (0.0, 0.0),
    };

    // Prices are per 1M tokens
    (input_tokens as f64 * input_price / 1_000_000.0)
        + (output_tokens as f64 * output_price / 1_000_000.0)
}
