// src/ipc/loop.rs — async stdin reader, stdout writer for JSON-Lines IPC

use std::sync::Arc;

use tokio::io::{self, AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter};
use tokio::sync::Mutex;
use tokio_stream::StreamExt;

use crate::handler;
use crate::ipc::message::{Request, Response};
use crate::storage::{Config, History};

pub async fn run(
    hub: Arc<Mutex<crate::ai::provider::ProviderHub>>,
    mcp: Arc<Mutex<crate::mcp::manager::McpManager>>,
    storage: Arc<Mutex<Config>>,
    history: Arc<Mutex<History>>,
) {
    let stdin = BufReader::new(io::stdin());
    let stdout = Arc::new(Mutex::new(BufWriter::new(io::stdout())));

    let mut lines = stdin.lines();

    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }

        let request: Request = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!("malformed request: {}", e);
                let err_resp = Response::Error {
                    id: 0,
                    code: "parse_error".into(),
                    message: format!("malformed request: {}", e),
                };
                let stdout_clone = Arc::clone(&stdout);
                let _ = write_response(&stdout_clone, &err_resp).await;
                continue;
            }
        };

        tracing::debug!("received: {:?}", request.method);

        let hub_clone = Arc::clone(&hub);
        let mcp_clone = Arc::clone(&mcp);
        let storage_clone = Arc::clone(&storage);
        let history_clone = Arc::clone(&history);
        let stdout_clone = Arc::clone(&stdout);

        tokio::spawn(async move {
            let response_stream = handler::dispatch(
                request.id,
                request.method,
                request.params,
                hub_clone,
                mcp_clone,
                storage_clone,
                history_clone,
            )
            .await;

            tokio::pin!(response_stream);

            while let Some(resp) = response_stream.next().await {
                if let Err(e) = write_response(&stdout_clone, &resp).await {
                    tracing::error!("failed to write response: {}", e);
                    break;
                }
            }
        });
    }

    tracing::info!("stdin closed, shutting down");
}

async fn write_response(
    stdout: &Arc<Mutex<BufWriter<io::Stdout>>>,
    resp: &Response,
) -> std::result::Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let json = serde_json::to_string(resp)?;
    let mut out = stdout.lock().await;
    out.write_all(json.as_bytes()).await?;
    out.write_all(b"\n").await?;
    out.flush().await?;
    Ok(())
}
