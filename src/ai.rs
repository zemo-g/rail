/// Rail AI module — LLM integration as first-class language primitives.
/// Supports Anthropic, OpenAI-compatible, local, and mock providers.
/// Uses curl for HTTP (no external Rust dependencies).

use std::env;
use std::sync::atomic::{AtomicU64, Ordering};

// ---- Token tracking (global, thread-safe) ----

static TOTAL_PROMPT_TOKENS: AtomicU64 = AtomicU64::new(0);
static TOTAL_COMPLETION_TOKENS: AtomicU64 = AtomicU64::new(0);
static TOTAL_CALLS: AtomicU64 = AtomicU64::new(0);

/// Record token usage from a response.
pub fn track_usage(prompt_tokens: u64, completion_tokens: u64) {
    TOTAL_PROMPT_TOKENS.fetch_add(prompt_tokens, Ordering::Relaxed);
    TOTAL_COMPLETION_TOKENS.fetch_add(completion_tokens, Ordering::Relaxed);
    TOTAL_CALLS.fetch_add(1, Ordering::Relaxed);
}

/// Get cumulative usage: (prompt_tokens, completion_tokens, total_calls)
pub fn get_usage() -> (u64, u64, u64) {
    (
        TOTAL_PROMPT_TOKENS.load(Ordering::Relaxed),
        TOTAL_COMPLETION_TOKENS.load(Ordering::Relaxed),
        TOTAL_CALLS.load(Ordering::Relaxed),
    )
}

/// Reset usage counters.
pub fn reset_usage() {
    TOTAL_PROMPT_TOKENS.store(0, Ordering::Relaxed);
    TOTAL_COMPLETION_TOKENS.store(0, Ordering::Relaxed);
    TOTAL_CALLS.store(0, Ordering::Relaxed);
}

/// AI configuration — which LLM backend to use
pub struct AiConfig {
    pub provider: String,
    pub api_key: Option<String>,
    pub model: String,
    pub base_url: String,
    pub temperature: f64,
}

impl AiConfig {
    /// Build config from environment variables.
    /// Priority: RAIL_AI_PROVIDER > auto-detect from keys > mock
    pub fn from_env() -> Self {
        let provider = env::var("RAIL_AI_PROVIDER").unwrap_or_default();

        match provider.as_str() {
            "anthropic" => AiConfig {
                provider: "anthropic".into(),
                api_key: env::var("ANTHROPIC_API_KEY").ok()
                    .or_else(|| env::var("RAIL_AI_KEY").ok()),
                model: env::var("RAIL_AI_MODEL")
                    .unwrap_or_else(|_| "claude-sonnet-4-20250514".into()),
                base_url: env::var("RAIL_AI_URL")
                    .unwrap_or_else(|_| "https://api.anthropic.com/v1/messages".into()),
                temperature: env::var("RAIL_AI_TEMP")
                    .ok().and_then(|s| s.parse().ok()).unwrap_or(0.0),
            },
            "openai" => AiConfig {
                provider: "openai".into(),
                api_key: env::var("OPENAI_API_KEY").ok()
                    .or_else(|| env::var("RAIL_AI_KEY").ok()),
                model: env::var("RAIL_AI_MODEL")
                    .unwrap_or_else(|_| "gpt-4o-mini".into()),
                base_url: env::var("RAIL_AI_URL")
                    .unwrap_or_else(|_| "https://api.openai.com/v1/chat/completions".into()),
                temperature: env::var("RAIL_AI_TEMP")
                    .ok().and_then(|s| s.parse().ok()).unwrap_or(0.0),
            },
            "local" => AiConfig {
                provider: "local".into(),
                api_key: env::var("RAIL_AI_KEY").ok(),
                model: env::var("RAIL_AI_MODEL")
                    .unwrap_or_else(|_| "default".into()),
                base_url: env::var("RAIL_AI_URL")
                    .unwrap_or_else(|_| "http://localhost:8080/v1/chat/completions".into()),
                temperature: env::var("RAIL_AI_TEMP")
                    .ok().and_then(|s| s.parse().ok()).unwrap_or(0.0),
            },
            "mock" => AiConfig {
                provider: "mock".into(),
                api_key: None,
                model: "mock".into(),
                base_url: String::new(),
                temperature: 0.0,
            },
            // Auto-detect from available API keys
            _ => {
                if let Ok(key) = env::var("ANTHROPIC_API_KEY") {
                    AiConfig {
                        provider: "anthropic".into(),
                        api_key: Some(key),
                        model: env::var("RAIL_AI_MODEL")
                            .unwrap_or_else(|_| "claude-sonnet-4-20250514".into()),
                        base_url: "https://api.anthropic.com/v1/messages".into(),
                        temperature: 0.0,
                    }
                } else if let Ok(key) = env::var("OPENAI_API_KEY") {
                    AiConfig {
                        provider: "openai".into(),
                        api_key: Some(key),
                        model: env::var("RAIL_AI_MODEL")
                            .unwrap_or_else(|_| "gpt-4o-mini".into()),
                        base_url: "https://api.openai.com/v1/chat/completions".into(),
                        temperature: 0.0,
                    }
                } else {
                    // Default: mock provider for testing
                    AiConfig {
                        provider: "mock".into(),
                        api_key: None,
                        model: "mock".into(),
                        base_url: String::new(),
                        temperature: 0.0,
                    }
                }
            }
        }
    }
}

// ---- LLM Call Dispatch ----

/// Send a prompt to the configured LLM backend.
pub fn call_llm(config: &AiConfig, system: &str, user: &str) -> Result<String, String> {
    let result = match config.provider.as_str() {
        "anthropic" => call_anthropic(config, system, user),
        "openai" | "local" => call_openai_compatible(config, system, user),
        "mock" => Ok(mock_response(system, user)),
        _ => Err(format!("unknown AI provider: {}", config.provider)),
    };
    // Strip thinking tags from all responses
    result.map(|text| strip_thinking_tags(&text))
}

/// Get an embedding vector from the configured backend.
pub fn call_embed(config: &AiConfig, text: &str) -> Result<Vec<f64>, String> {
    match config.provider.as_str() {
        "openai" => call_openai_embed(config, text),
        "mock" => Ok(mock_embedding(text)),
        _ => Err(format!("embed not supported for provider: {} (use openai or mock)", config.provider)),
    }
}

// ---- Anthropic ----

fn call_anthropic(config: &AiConfig, system: &str, user: &str) -> Result<String, String> {
    let api_key = config.api_key.as_ref()
        .ok_or_else(|| "anthropic: no API key (set ANTHROPIC_API_KEY)".to_string())?;

    let system_escaped = escape_json_string(system);
    let user_escaped = escape_json_string(user);

    let body = format!(
        r#"{{"model":"{}","max_tokens":1024,"temperature":{},"system":"{}","messages":[{{"role":"user","content":"{}"}}]}}"#,
        config.model, config.temperature, system_escaped, user_escaped,
    );

    let output = std::process::Command::new("curl")
        .args([
            "-s", "-X", "POST",
            &config.base_url,
            "-H", &format!("x-api-key: {}", api_key),
            "-H", "anthropic-version: 2023-06-01",
            "-H", "content-type: application/json",
            "-d", &body,
        ])
        .output()
        .map_err(|e| format!("curl failed: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("curl error: {}", stderr));
    }

    let response = String::from_utf8_lossy(&output.stdout).to_string();
    extract_usage(&response);
    extract_anthropic_text(&response)
}

fn extract_anthropic_text(json: &str) -> Result<String, String> {
    // Look for "text":"..." in the Anthropic response
    // Response format: {"content":[{"type":"text","text":"..."}],...}
    if let Some(pos) = json.find(r#""text":""#) {
        let start = pos + 8; // skip past "text":"
        if let Some(end) = find_closing_quote(json, start) {
            let text = &json[start..end];
            return Ok(unescape_json_string(text));
        }
    }

    // Check for error
    if let Some(pos) = json.find(r#""error""#) {
        if let Some(msg_pos) = json[pos..].find(r#""message":""#) {
            let start = pos + msg_pos + 11;
            if let Some(end) = find_closing_quote(json, start) {
                return Err(format!("anthropic error: {}", &json[start..end]));
            }
        }
    }

    Err(format!("failed to parse anthropic response: {}", &json[..json.len().min(200)]))
}

// ---- OpenAI-compatible ----

fn call_openai_compatible(config: &AiConfig, system: &str, user: &str) -> Result<String, String> {
    let system_escaped = escape_json_string(system);
    let user_escaped = escape_json_string(user);

    let mut messages = String::new();
    if !system.is_empty() {
        messages.push_str(&format!(
            r#"{{"role":"system","content":"{}"}},{{"role":"user","content":"{}"}}"#,
            system_escaped, user_escaped,
        ));
    } else {
        messages.push_str(&format!(
            r#"{{"role":"user","content":"{}"}}"#,
            user_escaped,
        ));
    }

    let body = format!(
        r#"{{"model":"{}","temperature":{},"max_tokens":4096,"chat_template_kwargs":{{"enable_thinking":false}},"messages":[{}]}}"#,
        config.model, config.temperature, messages,
    );

    let mut cmd = std::process::Command::new("curl");
    cmd.args([
        "-s", "-X", "POST",
        &config.base_url,
        "-H", "content-type: application/json",
    ]);

    if let Some(ref key) = config.api_key {
        cmd.args(["-H", &format!("Authorization: Bearer {}", key)]);
    }

    cmd.args(["-d", &body]);

    let output = cmd.output().map_err(|e| format!("curl failed: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("curl error: {}", stderr));
    }

    let response = String::from_utf8_lossy(&output.stdout).to_string();
    // Extract and track token usage
    extract_usage(&response);
    extract_openai_text(&response)
}

fn extract_openai_text(json: &str) -> Result<String, String> {
    // Response format: {"choices":[{"message":{"content":"...", "reasoning":"..."}}]}
    if let Some(msg_pos) = json.find(r#""message""#) {
        let after_msg = &json[msg_pos..];

        // Try to extract "content" field (with/without space after colon)
        let content_patterns: &[(&str, usize)] = &[
            (r#""content":""#, 11),
            (r#""content": ""#, 12),
        ];
        for &(pat, skip) in content_patterns {
            if let Some(content_pos) = after_msg.find(pat) {
                let start = msg_pos + content_pos + skip;
                if let Some(end) = find_closing_quote(json, start) {
                    let text = unescape_json_string(&json[start..end]);
                    if !text.is_empty() {
                        return Ok(text);
                    }
                }
            }
        }

        // Content empty or null — try "reasoning" field (Qwen3.5 thinking mode)
        let reasoning_patterns: &[(&str, usize)] = &[
            (r#""reasoning":""#, 13),
            (r#""reasoning": ""#, 14),
        ];
        for &(pat, skip) in reasoning_patterns {
            if let Some(pos) = after_msg.find(pat) {
                let start = msg_pos + pos + skip;
                if let Some(end) = find_closing_quote(json, start) {
                    let reasoning = unescape_json_string(&json[start..end]);
                    if !reasoning.is_empty() {
                        // Extract the last substantive content from reasoning
                        // (often the actual answer is at the end of the thinking chain)
                        return Ok(reasoning);
                    }
                }
            }
        }

        // content null
        if after_msg.contains(r#""content":null"#) || after_msg.contains(r#""content": null"#) {
            return Ok(String::new());
        }
    }

    // Check for error
    if let Some(pos) = json.find(r#""error""#) {
        if let Some(msg_pos) = json[pos..].find(r#""message":""#) {
            let start = pos + msg_pos + 11;
            if let Some(end) = find_closing_quote(json, start) {
                return Err(format!("openai error: {}", &json[start..end]));
            }
        }
    }

    Err(format!("failed to parse openai response: {}", &json[..json.len().min(200)]))
}

// ---- OpenAI Embeddings ----

fn call_openai_embed(config: &AiConfig, text: &str) -> Result<Vec<f64>, String> {
    let api_key = config.api_key.as_ref()
        .ok_or_else(|| "openai embed: no API key (set OPENAI_API_KEY)".to_string())?;

    let text_escaped = escape_json_string(text);
    let model = std::env::var("RAIL_AI_EMBED_MODEL")
        .unwrap_or_else(|_| "text-embedding-3-small".into());

    let body = format!(
        r#"{{"model":"{}","input":"{}"}}"#,
        model, text_escaped,
    );

    let output = std::process::Command::new("curl")
        .args([
            "-s", "-X", "POST",
            "https://api.openai.com/v1/embeddings",
            "-H", &format!("Authorization: Bearer {}", api_key),
            "-H", "content-type: application/json",
            "-d", &body,
        ])
        .output()
        .map_err(|e| format!("curl failed: {}", e))?;

    let response = String::from_utf8_lossy(&output.stdout).to_string();
    extract_embedding(&response)
}

fn extract_embedding(json: &str) -> Result<Vec<f64>, String> {
    // Response: {"data":[{"embedding":[0.1, 0.2, ...]}]}
    if let Some(pos) = json.find(r#""embedding":["#) {
        let start = pos + 13;
        if let Some(end_pos) = json[start..].find(']') {
            let numbers_str = &json[start..start + end_pos];
            let nums: Result<Vec<f64>, _> = numbers_str
                .split(',')
                .map(|s| s.trim().parse::<f64>())
                .collect();
            return nums.map_err(|e| format!("failed to parse embedding: {}", e));
        }
    }
    Err(format!("failed to parse embedding response: {}", &json[..json.len().min(200)]))
}

// ---- Mock Provider ----

fn mock_response(system: &str, user: &str) -> String {
    let prompt = user.to_lowercase();

    // Common knowledge patterns
    if prompt.contains("capital") && prompt.contains("france") {
        return "Paris".into();
    }
    if prompt.contains("capital") && prompt.contains("japan") {
        return "Tokyo".into();
    }
    if prompt.contains("capital") && prompt.contains("germany") {
        return "Berlin".into();
    }
    if prompt.contains("2+2") || prompt.contains("2 + 2") {
        return "4".into();
    }

    // JSON extraction pattern
    if system.to_lowercase().contains("extract") || system.to_lowercase().contains("json") {
        if prompt.contains("john") && prompt.contains("30") {
            return r#"{"name": "John", "age": 30}"#.into();
        }
        return r#"{"result": "extracted"}"#.into();
    }

    // Summarization pattern
    if system.to_lowercase().contains("summariz") {
        return format!("[Summary of: {}]", truncate(user, 60));
    }

    // Translation pattern
    if system.to_lowercase().contains("translat") {
        let lang = if system.to_lowercase().contains("spanish") { "Spanish" }
            else if system.to_lowercase().contains("french") { "French" }
            else { "translated" };
        return format!("[{} translation of: {}]", lang, truncate(user, 60));
    }

    // Default: echo back with indicator
    format!("[mock response to: {}]", truncate(user, 80))
}

fn mock_embedding(text: &str) -> Vec<f64> {
    // Generate a deterministic pseudo-embedding from the text.
    // 8 dimensions for testing — real embeddings are 1536+.
    let mut vec = vec![0.0f64; 8];
    for (i, byte) in text.bytes().enumerate() {
        vec[i % 8] += (byte as f64 - 96.0) / 256.0;
    }
    // Normalize
    let norm: f64 = vec.iter().map(|x| x * x).sum::<f64>().sqrt();
    if norm > 0.0 {
        for v in &mut vec {
            *v /= norm;
        }
    }
    vec
}

// ---- JSON Helpers (no serde) ----

/// Escape a string for embedding in JSON.
fn escape_json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for c in s.chars() {
        match c {
            '"' => out.push_str(r#"\""#),
            '\\' => out.push_str(r#"\\"#),
            '\n' => out.push_str(r#"\n"#),
            '\r' => out.push_str(r#"\r"#),
            '\t' => out.push_str(r#"\t"#),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!(r#"\u{:04x}"#, c as u32));
            }
            c => out.push(c),
        }
    }
    out
}

/// Unescape a JSON string value.
fn unescape_json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('"') => out.push('"'),
                Some('\\') => out.push('\\'),
                Some('n') => out.push('\n'),
                Some('r') => out.push('\r'),
                Some('t') => out.push('\t'),
                Some('/') => out.push('/'),
                Some('u') => {
                    let hex: String = chars.by_ref().take(4).collect();
                    if let Ok(code) = u32::from_str_radix(&hex, 16) {
                        if let Some(ch) = char::from_u32(code) {
                            out.push(ch);
                        }
                    }
                }
                Some(other) => { out.push('\\'); out.push(other); }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Find the closing quote of a JSON string starting at `start`.
/// Handles escaped quotes.
fn find_closing_quote(json: &str, start: usize) -> Option<usize> {
    let bytes = json.as_bytes();
    let mut i = start;
    while i < bytes.len() {
        if bytes[i] == b'\\' {
            i += 2; // skip escaped char
        } else if bytes[i] == b'"' {
            return Some(i);
        } else {
            i += 1;
        }
    }
    None
}

/// Extract token usage from any JSON response and track it.
fn extract_usage(json: &str) {
    // Look for "usage":{"prompt_tokens":N,"completion_tokens":N,...}
    // or Anthropic: "usage":{"input_tokens":N,"output_tokens":N}
    if let Some(usage_pos) = json.find(r#""usage""#) {
        let after = &json[usage_pos..];
        let prompt_t = extract_int_field(after, "prompt_tokens")
            .or_else(|| extract_int_field(after, "input_tokens"))
            .unwrap_or(0);
        let completion_t = extract_int_field(after, "completion_tokens")
            .or_else(|| extract_int_field(after, "output_tokens"))
            .unwrap_or(0);
        track_usage(prompt_t, completion_t);
    }
}

/// Extract an integer field value from JSON-like text.
fn extract_int_field(json: &str, field: &str) -> Option<u64> {
    let pattern = format!(r#""{}":"#, field);
    if let Some(pos) = json.find(&pattern) {
        let start = pos + pattern.len();
        let rest = json[start..].trim_start();
        let end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
        rest[..end].parse().ok()
    } else {
        None
    }
}

/// Call LLM with a specific model override (ignores RAIL_AI_MODEL env).
pub fn call_llm_with_model(config: &AiConfig, model: &str, system: &str, user: &str) -> Result<String, String> {
    let mut config = AiConfig {
        provider: config.provider.clone(),
        api_key: config.api_key.clone(),
        model: model.to_string(),
        base_url: config.base_url.clone(),
        temperature: config.temperature,
    };
    // If model looks like a URL or contains localhost, switch to local provider
    if model.contains("localhost") || model.contains("127.0.0.1") {
        let parts: Vec<&str> = model.splitn(2, '|').collect();
        if parts.len() == 2 {
            // Format: "http://localhost:8080|model_id"
            config.base_url = format!("{}/v1/chat/completions", parts[0]);
            config.model = parts[1].to_string();
            config.provider = "local".to_string();
        }
    }
    call_llm(&config, system, user)
}

/// Strip LLM thinking/reasoning tags from output.
/// Case-insensitive. Handles unclosed tags (strips to end).
/// Collects removal ranges on a single lowercased copy, applies once.
fn strip_thinking_tags(s: &str) -> String {
    // Note: positions from lowercased copy index the original. Safe for ASCII/Latin
    // content (byte length preserved). Would break on Turkish İ etc. before a tag.
    let lower = s.to_lowercase();
    // Longest tags first so "thinking" matches before "think"
    let tags = [
        "scratchpad", "reflection", "reasoning", "thinking", "internal",
        "analysis", "thought", "think", "meta", "plan",
    ];

    // Collect byte ranges to remove: (start, end)
    let mut removals: Vec<(usize, usize)> = Vec::new();
    for tag in tags {
        let open = format!("<{}", tag);
        let close = format!("</{}>", tag);
        let mut search_from = 0;
        while search_from < lower.len() {
            let Some(pos) = lower[search_from..].find(&open) else { break };
            let pos = search_from + pos;

            // Ensure exact tag boundary: next char must be > or whitespace
            let after = pos + open.len();
            if after < lower.len() {
                let next = lower.as_bytes()[after];
                if next != b'>' && !next.is_ascii_whitespace() {
                    search_from = pos + 1;
                    continue;
                }
            }

            // Check this range isn't already inside a prior removal
            if removals.iter().any(|&(rs, re)| pos >= rs && pos < re) {
                search_from = pos + 1;
                continue;
            }

            if let Some(end_pos) = lower[pos..].find(&close) {
                let end = pos + end_pos + close.len();
                removals.push((pos, end));
                search_from = end;
            } else {
                // Unclosed tag — strip from open tag to end
                removals.push((pos, s.len()));
                break;
            }
        }
    }

    if removals.is_empty() {
        return s.trim().to_string();
    }

    // Sort by start position and apply removals
    removals.sort_by_key(|&(start, _)| start);
    let mut out = String::with_capacity(s.len());
    let mut cursor = 0;
    for (start, end) in &removals {
        if *start > cursor {
            out.push_str(&s[cursor..*start]);
        }
        cursor = *end;
    }
    if cursor < s.len() {
        out.push_str(&s[cursor..]);
    }
    out.trim().to_string()
}

fn truncate(s: &str, max: usize) -> &str {
    if s.len() <= max { s } else { &s[..max] }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mock_capital() {
        let r = mock_response("", "What is the capital of France?");
        assert_eq!(r, "Paris");
    }

    #[test]
    fn test_mock_math() {
        let r = mock_response("", "What is 2 + 2?");
        assert_eq!(r, "4");
    }

    #[test]
    fn test_mock_json_extract() {
        let r = mock_response("Extract the name and age", "John is 30 years old");
        assert!(r.contains("John"));
        assert!(r.contains("30"));
    }

    #[test]
    fn test_mock_summary() {
        let r = mock_response("Summarize in one sentence", "Some text");
        assert!(r.contains("Summary"));
    }

    #[test]
    fn test_mock_translation() {
        let r = mock_response("Translate to Spanish", "Hello world");
        assert!(r.contains("Spanish"));
    }

    #[test]
    fn test_mock_embedding() {
        let v = mock_embedding("hello");
        assert_eq!(v.len(), 8);
        // Should be normalized (length ~1.0)
        let norm: f64 = v.iter().map(|x| x * x).sum::<f64>().sqrt();
        assert!((norm - 1.0).abs() < 0.01);
    }

    #[test]
    fn test_escape_json() {
        assert_eq!(escape_json_string(r#"say "hello""#), r#"say \"hello\""#);
        assert_eq!(escape_json_string("line1\nline2"), r#"line1\nline2"#);
    }

    #[test]
    fn test_unescape_json() {
        assert_eq!(unescape_json_string(r#"say \"hello\""#), r#"say "hello""#);
        assert_eq!(unescape_json_string(r#"line1\nline2"#), "line1\nline2");
    }

    #[test]
    fn test_extract_anthropic() {
        let json = r#"{"content":[{"type":"text","text":"Paris"}],"model":"claude"}"#;
        assert_eq!(extract_anthropic_text(json).unwrap(), "Paris");
    }

    #[test]
    fn test_extract_openai() {
        let json = r#"{"choices":[{"message":{"role":"assistant","content":"Paris"}}]}"#;
        assert_eq!(extract_openai_text(json).unwrap(), "Paris");
    }

    #[test]
    fn test_strip_thinking_basic() {
        let input = "<analysis>some reasoning here</analysis>The answer is 42.";
        assert_eq!(strip_thinking_tags(input), "The answer is 42.");
    }

    #[test]
    fn test_strip_thinking_case_insensitive() {
        let input = "<Analysis>deep thought</Analysis>Result here.";
        assert_eq!(strip_thinking_tags(input), "Result here.");
        let input2 = "<THINKING>hmm</THINKING>Done.";
        assert_eq!(strip_thinking_tags(input2), "Done.");
    }

    #[test]
    fn test_strip_thinking_unclosed() {
        let input = "Answer is 42.<think>but wait let me reconsider";
        assert_eq!(strip_thinking_tags(input), "Answer is 42.");
    }

    #[test]
    fn test_strip_thinking_multiple() {
        let input = "<think>a</think>Hello <reasoning>b</reasoning>world";
        assert_eq!(strip_thinking_tags(input), "Hello world");
    }

    #[test]
    fn test_strip_thinking_clean_passthrough() {
        let input = "No tags here, just a normal response.";
        assert_eq!(strip_thinking_tags(input), "No tags here, just a normal response.");
    }

    #[test]
    fn test_strip_thinking_mixed_think_thinking() {
        // Both <think> and <thinking> in same output — must strip both correctly
        let input = "<thinking>deep thought</thinking>Answer.<think>wait</think>Done.";
        assert_eq!(strip_thinking_tags(input), "Answer.Done.");
    }

    #[test]
    fn test_strip_thinking_with_attributes() {
        let input = "<analysis type=\"deep\">reasoning here</analysis>Result.";
        assert_eq!(strip_thinking_tags(input), "Result.");
    }

    #[test]
    fn test_strip_thinking_no_false_positive() {
        // <metadata> should NOT be stripped (not in tag list, and "meta" boundary check blocks it)
        let input = "The <metadata>field</metadata> is important.";
        assert_eq!(strip_thinking_tags(input), "The <metadata>field</metadata> is important.");
    }

    #[test]
    fn test_config_defaults_to_mock() {
        // Clear env vars to ensure mock
        unsafe {
            std::env::remove_var("RAIL_AI_PROVIDER");
            std::env::remove_var("ANTHROPIC_API_KEY");
            std::env::remove_var("OPENAI_API_KEY");
        }
        let config = AiConfig::from_env();
        assert_eq!(config.provider, "mock");
    }
}
