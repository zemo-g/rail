/// Rail agent module — multi-turn tool-use loops for AI agents.
/// This is Rail's core differentiation: agents as first-class language constructs.

use crate::interpreter::{Value, RuntimeError};
use crate::ai;

/// Maximum tool-use iterations (configurable via RAIL_AGENT_MAX_TURNS)
fn max_turns() -> usize {
    std::env::var("RAIL_AGENT_MAX_TURNS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(20)
}

/// Run an agent loop: LLM decides which tool to call, Rail executes it,
/// result is fed back. Loop until LLM says "DONE:" or max turns reached.
///
/// tools: list of (name, description) pairs
/// tool_fns: parallel list of Rail closures
/// system: system prompt
/// user: initial user message
///
/// Returns the final LLM response (after DONE:)
pub fn run_agent_loop(
    system: &str,
    tools: &[(String, String)],
    user: &str,
    apply_fn: &dyn Fn(&Value, Value) -> Result<Value, RuntimeError>,
    tool_fns: &[Value],
) -> Result<(String, Vec<(String, String, String)>), RuntimeError> {
    let config = ai::AiConfig::from_env();
    let max = max_turns();

    // Build tool descriptions for the system prompt
    let tool_desc: String = tools.iter()
        .map(|(name, desc)| format!("  - {}: {}", name, desc))
        .collect::<Vec<_>>()
        .join("\n");

    let augmented_system = format!(
        "{}\n\nYou have access to these tools:\n{}\n\n\
         To use a tool, respond with exactly: TOOL: <tool_name>\nARG: <argument>\n\
         To finish, respond with: DONE: <final_answer>\n\
         You must use DONE: when you have the final answer.",
        system, tool_desc
    );

    let mut messages: Vec<(String, String)> = vec![];
    messages.push(("user".to_string(), user.to_string()));

    let mut history: Vec<(String, String, String)> = vec![]; // (tool, input, output)

    for turn in 0..max {
        // Build conversation for LLM
        let conversation = messages.iter()
            .map(|(role, content)| format!("[{}]: {}", role, content))
            .collect::<Vec<_>>()
            .join("\n\n");

        let response = ai::call_llm(&config, &augmented_system, &conversation)
            .map_err(|e| RuntimeError(format!("agent_loop turn {}: {}", turn, e)))?;

        messages.push(("assistant".to_string(), response.clone()));

        // Check for DONE:
        if let Some(done_pos) = response.find("DONE:") {
            let answer = response[done_pos + 5..].trim().to_string();
            return Ok((answer, history));
        }

        // Check for TOOL:
        if let Some(tool_pos) = response.find("TOOL:") {
            let after_tool = response[tool_pos + 5..].trim();
            let tool_name = after_tool.lines().next().unwrap_or("").trim().to_string();

            let arg = if let Some(arg_pos) = response.find("ARG:") {
                response[arg_pos + 4..].trim().to_string()
            } else {
                String::new()
            };

            // Find the tool function
            let tool_idx = tools.iter().position(|(name, _)| *name == tool_name);
            if let Some(idx) = tool_idx {
                let tool_result = apply_fn(&tool_fns[idx], Value::Str(arg.clone()))?;
                let result_str = format!("{}", tool_result);
                history.push((tool_name.clone(), arg, result_str.clone()));
                messages.push(("user".to_string(),
                    format!("Tool '{}' returned: {}", tool_name, result_str)));
            } else {
                messages.push(("user".to_string(),
                    format!("Error: unknown tool '{}'. Available tools: {}",
                        tool_name,
                        tools.iter().map(|(n, _)| n.as_str()).collect::<Vec<_>>().join(", "))));
            }
        } else {
            // LLM didn't use a tool or say DONE — prompt it to continue
            messages.push(("user".to_string(),
                "Please use a TOOL: or respond with DONE: <answer>.".to_string()));
        }
    }

    // Max turns reached — return last assistant message
    let last_response = messages.iter()
        .rev()
        .find(|(role, _)| role == "assistant")
        .map(|(_, content)| content.clone())
        .unwrap_or_else(|| "[agent loop: max turns reached]".to_string());

    Ok((last_response, history))
}

/// Conversation context — a list of messages for multi-turn conversations.
#[derive(Clone)]
pub struct ConversationContext {
    pub system: String,
    pub messages: Vec<(String, String)>, // (role, content)
}

impl ConversationContext {
    pub fn new(system: &str) -> Self {
        ConversationContext {
            system: system.to_string(),
            messages: vec![],
        }
    }

    pub fn push(&mut self, role: &str, content: &str) {
        self.messages.push((role.to_string(), content.to_string()));
    }

    /// Send the conversation to the LLM and get a response.
    /// Appends the response as an assistant message.
    pub fn prompt(&mut self, user_message: &str) -> Result<String, String> {
        self.messages.push(("user".to_string(), user_message.to_string()));

        let config = ai::AiConfig::from_env();

        // Build conversation string
        let conversation = self.messages.iter()
            .map(|(role, content)| format!("[{}]: {}", role, content))
            .collect::<Vec<_>>()
            .join("\n\n");

        let response = ai::call_llm(&config, &self.system, &conversation)?;
        self.messages.push(("assistant".to_string(), response.clone()));
        Ok(response)
    }

    /// Convert to a Rail Value (Record with system and messages)
    pub fn to_value(&self) -> Value {
        let msgs: Vec<Value> = self.messages.iter()
            .map(|(role, content)| Value::Tuple(vec![
                Value::Str(role.clone()),
                Value::Str(content.clone()),
            ]))
            .collect();

        Value::Record(vec![
            ("system".to_string(), Value::Str(self.system.clone())),
            ("messages".to_string(), Value::List(msgs)),
        ])
    }

    /// Reconstruct from a Rail Value
    pub fn from_value(val: &Value) -> Result<Self, String> {
        match val {
            Value::Record(fields) => {
                let system = fields.iter()
                    .find(|(k, _)| k == "system")
                    .and_then(|(_, v)| match v { Value::Str(s) => Some(s.clone()), _ => None })
                    .ok_or("context missing 'system' field")?;

                let messages = fields.iter()
                    .find(|(k, _)| k == "messages")
                    .and_then(|(_, v)| match v { Value::List(msgs) => Some(msgs), _ => None })
                    .ok_or("context missing 'messages' field")?;

                let mut ctx = ConversationContext::new(&system);
                for msg in messages {
                    match msg {
                        Value::Tuple(parts) if parts.len() == 2 => {
                            if let (Value::Str(role), Value::Str(content)) = (&parts[0], &parts[1]) {
                                ctx.push(role, content);
                            }
                        }
                        _ => return Err("invalid message format in context".to_string()),
                    }
                }
                Ok(ctx)
            }
            _ => Err("context_prompt: expected context record".to_string()),
        }
    }
}
