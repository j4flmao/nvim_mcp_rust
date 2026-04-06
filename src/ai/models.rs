// src/ai/models.rs — shared model-list parsing helpers

use serde_json::Value;

use crate::ai::ModelInfo;

pub fn parse_openai_models(body: &Value) -> Vec<ModelInfo> {
    let mut models: Vec<ModelInfo> = body["data"]
        .as_array()
        .unwrap_or(&vec![])
        .iter()
        .filter(|m| {
            let id = m["id"].as_str().unwrap_or("");
            id.starts_with("gpt-")
                || id.starts_with("o1")
                || id.starts_with("o3")
                || id.starts_with("o4")
        })
        .map(|m| {
            let id = m["id"].as_str().unwrap_or("").to_string();
            ModelInfo {
                display: id.clone(),
                id,
                context_len: None,
            }
        })
        .collect();

    models.sort_by(|a, b| b.id.cmp(&a.id));
    models
}

pub fn parse_gemini_models(body: &Value) -> Vec<ModelInfo> {
    body["models"]
        .as_array()
        .unwrap_or(&vec![])
        .iter()
        .filter(|m| {
            m["displayName"]
                .as_str()
                .map(|d| d.contains("Gemini"))
                .unwrap_or(false)
                && m["supportedGenerationMethods"]
                    .as_array()
                    .map(|a| a.iter().any(|v| v == "generateContent"))
                    .unwrap_or(false)
        })
        .map(|m| {
            let full = m["name"].as_str().unwrap_or("");
            let id = full.strip_prefix("models/").unwrap_or(full).to_string();
            ModelInfo {
                display: m["displayName"].as_str().unwrap_or(&id).into(),
                id,
                context_len: None,
            }
        })
        .collect()
}

pub fn parse_ollama_models(body: &Value) -> Vec<ModelInfo> {
    body["models"]
        .as_array()
        .unwrap_or(&vec![])
        .iter()
        .map(|m| {
            let name = m["name"].as_str().unwrap_or("").to_string();
            ModelInfo {
                display: name.clone(),
                id: name,
                context_len: None,
            }
        })
        .collect()
}

pub fn parse_lmstudio_models(body: &Value) -> Vec<ModelInfo> {
    body["data"]
        .as_array()
        .unwrap_or(&vec![])
        .iter()
        .map(|m| {
            let id = m["id"].as_str().unwrap_or("").to_string();
            ModelInfo {
                display: id.clone(),
                id,
                context_len: None,
            }
        })
        .collect()
}

pub fn parse_claude_models(body: &Value) -> Vec<ModelInfo> {
    body["data"]
        .as_array()
        .unwrap_or(&vec![])
        .iter()
        .map(|m| ModelInfo {
            id: m["id"].as_str().unwrap_or("").into(),
            display: m["display_name"]
                .as_str()
                .unwrap_or(m["id"].as_str().unwrap_or(""))
                .into(),
            context_len: None,
        })
        .collect()
}
