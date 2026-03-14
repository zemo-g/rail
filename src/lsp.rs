/// Rail LSP — Language Server Protocol implementation.
/// Provides: diagnostics (parse/type errors), hover (types), go-to-definition, completion.
/// Protocol: JSON-RPC over stdio.

use std::io::{self, BufRead, Write};
use std::collections::HashMap;
use crate::lexer::Lexer;
use crate::parser::Parser;
use crate::typechecker::TypeChecker;

/// Run the LSP server on stdio.
pub fn run_lsp() {
    eprintln!("[rail-lsp] starting...");
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = stdin.lock();
    let mut writer = stdout.lock();

    // Document store: uri -> source
    let mut documents: HashMap<String, String> = HashMap::new();

    loop {
        // Read LSP message (Content-Length header + body)
        let msg = match read_message(&mut reader) {
            Ok(m) => m,
            Err(_) => break, // stdin closed
        };

        let parsed = match parse_json_object(&msg) {
            Some(obj) => obj,
            None => continue,
        };

        let method = match parsed.get("method") {
            Some(JsonValue::Str(m)) => m.clone(),
            _ => continue,
        };

        let id = parsed.get("id").cloned();
        let params = match parsed.get("params") {
            Some(p) => p.clone(),
            None => JsonValue::Null,
        };

        match method.as_str() {
            "initialize" => {
                let result = json_obj(&[
                    ("capabilities", json_obj(&[
                        ("textDocumentSync", JsonValue::Num(1.0)), // Full sync
                        ("hoverProvider", JsonValue::Bool(true)),
                        ("completionProvider", json_obj(&[
                            ("triggerCharacters", JsonValue::Array(vec![
                                JsonValue::Str(".".into()),
                            ])),
                        ])),
                        ("definitionProvider", JsonValue::Bool(true)),
                    ])),
                    ("serverInfo", json_obj(&[
                        ("name", JsonValue::Str("rail-lsp".into())),
                        ("version", JsonValue::Str("0.6.0".into())),
                    ])),
                ]);
                send_response(&mut writer, &id, result);
            }
            "initialized" => {
                eprintln!("[rail-lsp] initialized");
            }
            "shutdown" => {
                send_response(&mut writer, &id, JsonValue::Null);
            }
            "exit" => {
                break;
            }
            "textDocument/didOpen" => {
                if let Some(td) = get_nested(&params, &["textDocument"]) {
                    if let (Some(JsonValue::Str(uri)), Some(JsonValue::Str(text))) =
                        (td.get_field("uri"), td.get_field("text"))
                    {
                        documents.insert(uri.clone(), text.clone());
                        let diagnostics = diagnose(&text);
                        send_diagnostics(&mut writer, &uri, diagnostics);
                    }
                }
            }
            "textDocument/didChange" => {
                if let Some(td) = get_nested(&params, &["textDocument"]) {
                    if let Some(JsonValue::Str(uri)) = td.get_field("uri") {
                        // Full sync — take the last content change
                        if let Some(JsonValue::Array(changes)) = params.get_field("contentChanges") {
                            if let Some(last) = changes.last() {
                                if let Some(JsonValue::Str(text)) = last.get_field("text") {
                                    documents.insert(uri.clone(), text.clone());
                                    let diagnostics = diagnose(&text);
                                    send_diagnostics(&mut writer, &uri, diagnostics);
                                }
                            }
                        }
                    }
                }
            }
            "textDocument/didClose" => {
                if let Some(td) = get_nested(&params, &["textDocument"]) {
                    if let Some(JsonValue::Str(uri)) = td.get_field("uri") {
                        documents.remove(uri.as_str());
                    }
                }
            }
            "textDocument/hover" => {
                let hover = handle_hover(&params, &documents);
                send_response(&mut writer, &id, hover);
            }
            "textDocument/completion" => {
                let completions = handle_completion(&params, &documents);
                send_response(&mut writer, &id, completions);
            }
            "textDocument/definition" => {
                let def = handle_definition(&params, &documents);
                send_response(&mut writer, &id, def);
            }
            _ => {
                // Unknown method — ignore notifications, respond null to requests
                if id.is_some() {
                    send_response(&mut writer, &id, JsonValue::Null);
                }
            }
        }
    }
    eprintln!("[rail-lsp] exiting");
}

// ---- Diagnostics ----

struct Diagnostic {
    line: usize,
    col: usize,
    message: String,
    severity: u32, // 1=Error, 2=Warning, 3=Info, 4=Hint
}

fn diagnose(source: &str) -> Vec<Diagnostic> {
    let mut diagnostics = Vec::new();

    // Parse errors
    let mut lexer = Lexer::new(source);
    let tokens = match lexer.tokenize() {
        Ok(t) => t,
        Err(e) => {
            diagnostics.push(Diagnostic {
                line: e.line.saturating_sub(1),
                col: e.col.saturating_sub(1),
                message: e.message,
                severity: 1,
            });
            return diagnostics;
        }
    };

    let mut parser = Parser::new(tokens);
    let program = match parser.parse_program() {
        Ok(p) => p,
        Err(e) => {
            diagnostics.push(Diagnostic {
                line: e.line.saturating_sub(1),
                col: e.col.saturating_sub(1),
                message: e.message,
                severity: 1,
            });
            return diagnostics;
        }
    };

    // Type errors
    let mut checker = TypeChecker::new();
    let result = checker.check_program(&program);
    for error in &result.errors {
        let (line, col) = error.span.unwrap_or((1, 1));
        diagnostics.push(Diagnostic {
            line: line.saturating_sub(1),
            col: col.saturating_sub(1),
            message: error.message.clone(),
            severity: 2, // Warning for type errors (they're advisory)
        });
    }

    diagnostics
}

// ---- Hover ----

fn handle_hover(params: &JsonValue, documents: &HashMap<String, String>) -> JsonValue {
    let uri = get_uri(params);
    let (line, col) = get_position(params);

    let source = match uri.and_then(|u| documents.get(&u)) {
        Some(s) => s,
        None => return JsonValue::Null,
    };

    // Find the word at the cursor position
    let lines: Vec<&str> = source.lines().collect();
    if line >= lines.len() {
        return JsonValue::Null;
    }
    let line_text = lines[line];
    let word = word_at(line_text, col);

    if word.is_empty() {
        return JsonValue::Null;
    }

    // Check builtins
    if let Some(doc) = builtin_doc(&word) {
        return json_obj(&[
            ("contents", json_obj(&[
                ("kind", JsonValue::Str("markdown".into())),
                ("value", JsonValue::Str(doc)),
            ])),
        ]);
    }

    // Try type inference
    let mut lexer = Lexer::new(source);
    if let Ok(tokens) = lexer.tokenize() {
        let mut parser = Parser::new(tokens);
        if let Ok(program) = parser.parse_program() {
            let mut checker = TypeChecker::new();
            let result = checker.check_program(&program);
            for (name, ty) in &result.declarations {
                if name == &word {
                    return json_obj(&[
                        ("contents", json_obj(&[
                            ("kind", JsonValue::Str("markdown".into())),
                            ("value", JsonValue::Str(format!("```rail\n{} : {}\n```", name, ty))),
                        ])),
                    ]);
                }
            }
        }
    }

    JsonValue::Null
}

// ---- Completion ----

fn handle_completion(_params: &JsonValue, _documents: &HashMap<String, String>) -> JsonValue {
    let mut items: Vec<JsonValue> = Vec::new();

    // Always offer builtins
    let builtins = [
        ("print", "Print a value to stdout"),
        ("show", "Convert a value to string"),
        ("map", "Apply function to each list element"),
        ("filter", "Keep elements matching predicate"),
        ("fold", "Reduce list with accumulator"),
        ("head", "First element of list"),
        ("tail", "All but first element"),
        ("length", "Length of list or string"),
        ("range", "Generate integer range [start, end)"),
        ("append", "Concatenate two lists or strings"),
        ("reverse", "Reverse a list"),
        ("sort", "Sort a list"),
        ("zip", "Zip two lists into pairs"),
        ("split", "Split string by delimiter"),
        ("join", "Join list of strings with separator"),
        ("trim", "Trim whitespace from string"),
        ("contains", "Check if string contains substring"),
        ("replace", "Replace occurrences in string"),
        ("prompt", "Send prompt to LLM"),
        ("prompt_with", "Send prompt with system message"),
        ("prompt_typed", "Get structured JSON from LLM"),
        ("prompt_stream", "Stream LLM response to callback"),
        ("agent_loop", "Multi-turn tool-use agent loop"),
        ("context_new", "Create new conversation context"),
        ("context_push", "Add message to conversation"),
        ("context_prompt", "Send conversation to LLM"),
        ("par_prompt", "Parallel LLM calls"),
        ("par_map", "Parallel map over list"),
        ("shell", "Execute shell command"),
        ("read_file", "Read file contents"),
        ("write_file", "Write string to file"),
        ("http_get", "HTTP GET request"),
        ("http_post", "HTTP POST request"),
        ("json_parse", "Parse JSON string"),
        ("json_get", "Get field from JSON"),
        ("env", "Read environment variable"),
        ("timestamp", "Current Unix timestamp"),
        ("sleep_ms", "Sleep for milliseconds"),
    ];

    for (name, detail) in &builtins {
        items.push(json_obj(&[
            ("label", JsonValue::Str(name.to_string())),
            ("kind", JsonValue::Num(3.0)), // Function
            ("detail", JsonValue::Str(detail.to_string())),
        ]));
    }

    // Keywords
    let keywords = ["let", "match", "if", "then", "else", "type", "import",
                     "module", "export", "effect", "perform", "handle", "with", "resume"];
    for kw in &keywords {
        items.push(json_obj(&[
            ("label", JsonValue::Str(kw.to_string())),
            ("kind", JsonValue::Num(14.0)), // Keyword
        ]));
    }

    JsonValue::Array(items)
}

// ---- Go to Definition ----

fn handle_definition(params: &JsonValue, documents: &HashMap<String, String>) -> JsonValue {
    let uri = get_uri(params);
    let (line, col) = get_position(params);

    let (uri_str, source) = match uri.and_then(|u| documents.get(&u).map(|s| (u, s))) {
        Some((u, s)) => (u, s),
        None => return JsonValue::Null,
    };

    let lines: Vec<&str> = source.lines().collect();
    if line >= lines.len() {
        return JsonValue::Null;
    }
    let word = word_at(lines[line], col);
    if word.is_empty() {
        return JsonValue::Null;
    }

    // Search for function definition: `name ... =`
    for (i, src_line) in lines.iter().enumerate() {
        let trimmed = src_line.trim();
        // Match top-level definitions: word at start of line followed by params and =
        if trimmed.starts_with(&word) {
            let after = trimmed[word.len()..].trim_start();
            if after.starts_with('=') || after.starts_with(':')
                || after.chars().next().map(|c| c.is_alphabetic() || c == '_').unwrap_or(false)
            {
                return json_obj(&[
                    ("uri", JsonValue::Str(uri_str)),
                    ("range", make_range(i, 0, i, word.len())),
                ]);
            }
        }
    }

    JsonValue::Null
}

// ---- Builtin documentation ----

fn builtin_doc(name: &str) -> Option<String> {
    let doc = match name {
        "print" => "```rail\nprint : a -> ()\n```\nPrint a value to stdout.",
        "show" => "```rail\nshow : a -> String\n```\nConvert any value to its string representation.",
        "map" => "```rail\nmap : (a -> b) -> [a] -> [b]\n```\nApply a function to every element in a list.\nAuto-parallelizes for pure functions on lists >= 8 elements.",
        "filter" => "```rail\nfilter : (a -> Bool) -> [a] -> [a]\n```\nKeep only elements where the predicate returns true.\nAuto-parallelizes for pure functions on lists >= 8 elements.",
        "fold" => "```rail\nfold : b -> (b -> a -> b) -> [a] -> b\n```\nReduce a list to a single value using an accumulator.",
        "head" => "```rail\nhead : [a] -> a\n```\nReturn the first element. Errors on empty list.",
        "tail" => "```rail\ntail : [a] -> [a]\n```\nReturn all elements except the first. Errors on empty list.",
        "length" => "```rail\nlength : [a] -> Int\n```\nReturn the number of elements in a list or characters in a string.",
        "range" => "```rail\nrange : Int -> Int -> [Int]\n```\nGenerate integers from start (inclusive) to end (exclusive).",
        "append" => "```rail\nappend : [a] -> [a] -> [a]\nappend : String -> String -> String\n```\nConcatenate two lists or two strings.",
        "prompt" => "```rail\nprompt : String -> String\n```\nSend a user message to the configured LLM. Returns the response.",
        "prompt_with" => "```rail\nprompt_with : String -> String -> String\n```\nSend a system prompt and user message to the LLM.",
        "prompt_typed" => "```rail\nprompt_typed : String -> String -> String -> Record\n```\nGet structured JSON output from the LLM.\nArgs: description, schema JSON, input text.\nRetries up to 3 times on parse failure.",
        "prompt_stream" => "```rail\nprompt_stream : String -> String -> (String -> a) -> ()\n```\nStream LLM response word-by-word to a callback function.",
        "agent_loop" => "```rail\nagent_loop : String -> [(String, String)] -> [fn] -> String -> Record\n```\nMulti-turn tool-use agent loop.\nArgs: system prompt, tool specs, tool functions, user message.\nReturns: {answer: String, history: [{tool, input, output}]}",
        "context_new" => "```rail\ncontext_new : String -> Context\n```\nCreate a new conversation context with a system prompt.",
        "context_push" => "```rail\ncontext_push : Context -> String -> String -> Context\n```\nAdd a message (role, content) to a conversation context.",
        "context_prompt" => "```rail\ncontext_prompt : Context -> String -> (Context, String)\n```\nSend a message in the conversation. Returns updated context and response.",
        "par_prompt" => "```rail\npar_prompt : String -> [String] -> [String]\n```\nFan out LLM calls in parallel (batches of 4).\nAll inputs get the same system prompt.",
        "par_map" => "```rail\npar_map : (a -> b) -> [a] -> [b]\n```\nParallel map using rayon thread pool.",
        "shell" => "```rail\nshell : String -> String\n```\nExecute a shell command and return stdout. Requires --allow shell.",
        "read_file" => "```rail\nread_file : String -> String\n```\nRead file contents as string. Requires --allow fs:/path.",
        "write_file" => "```rail\nwrite_file : String -> String -> ()\n```\nWrite string to file. Requires --allow fs:/path.",
        "json_parse" => "```rail\njson_parse : String -> Value\n```\nParse a JSON string into a Rail value.",
        "json_get" => "```rail\njson_get : String -> String -> Value\n```\nGet a field from a JSON string by key.",
        "env" => "```rail\nenv : String -> String\n```\nRead an environment variable. Returns empty string if unset.",
        "split" => "```rail\nsplit : String -> String -> [String]\n```\nSplit a string by a delimiter.",
        "join" => "```rail\njoin : String -> [String] -> String\n```\nJoin a list of strings with a separator.",
        "trim" => "```rail\ntrim : String -> String\n```\nRemove leading and trailing whitespace.",
        "contains" => "```rail\ncontains : String -> String -> Bool\n```\nCheck if haystack contains needle.",
        "replace" => "```rail\nreplace : String -> String -> String -> String\n```\nReplace all occurrences of pattern with replacement in input.",
        "sort" => "```rail\nsort : [a] -> [a]\n```\nSort a list (integers, floats, or strings).",
        "zip" => "```rail\nzip : [a] -> [b] -> [(a, b)]\n```\nZip two lists into a list of pairs.",
        "reverse" => "```rail\nreverse : [a] -> [a]\n```\nReverse a list.",
        "sleep_ms" => "```rail\nsleep_ms : Int -> ()\n```\nSleep for the given number of milliseconds.",
        "timestamp" => "```rail\ntimestamp : () -> Int\n```\nReturn current Unix timestamp in seconds.",
        _ => return None,
    };
    Some(doc.to_string())
}

// ---- JSON-RPC Protocol Helpers ----

fn read_message(reader: &mut impl BufRead) -> Result<String, io::Error> {
    // Read headers
    let mut content_length: usize = 0;
    loop {
        let mut header = String::new();
        reader.read_line(&mut header)?;
        let header = header.trim();
        if header.is_empty() {
            break;
        }
        if header.to_lowercase().starts_with("content-length:") {
            content_length = header[15..].trim().parse().unwrap_or(0);
        }
    }

    if content_length == 0 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "no content-length"));
    }

    // Read body
    let mut body = vec![0u8; content_length];
    reader.read_exact(&mut body)?;
    Ok(String::from_utf8_lossy(&body).to_string())
}

fn send_response(writer: &mut impl Write, id: &Option<JsonValue>, result: JsonValue) {
    let id = match id {
        Some(id) => id.clone(),
        None => return,
    };

    let response = format!(
        r#"{{"jsonrpc":"2.0","id":{},"result":{}}}"#,
        id.to_json(), result.to_json()
    );

    let msg = format!("Content-Length: {}\r\n\r\n{}", response.len(), response);
    writer.write_all(msg.as_bytes()).ok();
    writer.flush().ok();
}

fn send_diagnostics(writer: &mut impl Write, uri: &str, diagnostics: Vec<Diagnostic>) {
    let diag_json: Vec<JsonValue> = diagnostics.iter().map(|d| {
        json_obj(&[
            ("range", make_range(d.line, d.col, d.line, d.col + 1)),
            ("severity", JsonValue::Num(d.severity as f64)),
            ("source", JsonValue::Str("rail".into())),
            ("message", JsonValue::Str(d.message.clone())),
        ])
    }).collect();

    let notification = format!(
        r#"{{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{{"uri":"{}","diagnostics":{}}}}}"#,
        escape_json_str(uri),
        JsonValue::Array(diag_json).to_json()
    );

    let msg = format!("Content-Length: {}\r\n\r\n{}", notification.len(), notification);
    writer.write_all(msg.as_bytes()).ok();
    writer.flush().ok();
}

// ---- Minimal JSON types (no serde dependency) ----

#[derive(Clone, Debug)]
enum JsonValue {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Array(Vec<JsonValue>),
    Object(Vec<(String, JsonValue)>),
}

impl JsonValue {
    fn get_field(&self, key: &str) -> Option<&JsonValue> {
        match self {
            JsonValue::Object(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    fn get(&self, key: &str) -> Option<&JsonValue> {
        self.get_field(key)
    }

    fn to_json(&self) -> String {
        match self {
            JsonValue::Null => "null".into(),
            JsonValue::Bool(b) => if *b { "true".into() } else { "false".into() },
            JsonValue::Num(n) => {
                if *n == (*n as i64) as f64 {
                    format!("{}", *n as i64)
                } else {
                    format!("{}", n)
                }
            }
            JsonValue::Str(s) => format!("\"{}\"", escape_json_str(s)),
            JsonValue::Array(items) => {
                let inner: Vec<String> = items.iter().map(|v| v.to_json()).collect();
                format!("[{}]", inner.join(","))
            }
            JsonValue::Object(fields) => {
                let inner: Vec<String> = fields.iter()
                    .map(|(k, v)| format!("\"{}\":{}", escape_json_str(k), v.to_json()))
                    .collect();
                format!("{{{}}}", inner.join(","))
            }
        }
    }
}

fn json_obj(fields: &[(&str, JsonValue)]) -> JsonValue {
    JsonValue::Object(fields.iter().map(|(k, v)| (k.to_string(), v.clone())).collect())
}

fn make_range(start_line: usize, start_col: usize, end_line: usize, end_col: usize) -> JsonValue {
    json_obj(&[
        ("start", json_obj(&[
            ("line", JsonValue::Num(start_line as f64)),
            ("character", JsonValue::Num(start_col as f64)),
        ])),
        ("end", json_obj(&[
            ("line", JsonValue::Num(end_line as f64)),
            ("character", JsonValue::Num(end_col as f64)),
        ])),
    ])
}

fn escape_json_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c => out.push(c),
        }
    }
    out
}

// ---- Minimal JSON parser (for LSP messages) ----

fn parse_json_object(s: &str) -> Option<JsonValue> {
    let s = s.trim();
    let (val, _) = parse_json_val(s).ok()?;
    Some(val)
}

fn parse_json_val(s: &str) -> Result<(JsonValue, &str), ()> {
    let s = s.trim_start();
    if s.is_empty() { return Err(()); }

    match s.as_bytes()[0] {
        b'"' => {
            let mut i = 1;
            let bytes = s.as_bytes();
            let mut out = String::new();
            while i < bytes.len() {
                if bytes[i] == b'\\' {
                    i += 1;
                    if i < bytes.len() {
                        match bytes[i] {
                            b'"' => out.push('"'),
                            b'\\' => out.push('\\'),
                            b'n' => out.push('\n'),
                            b'r' => out.push('\r'),
                            b't' => out.push('\t'),
                            b'/' => out.push('/'),
                            b'u' => {
                                // Skip unicode escapes for simplicity
                                i += 4;
                                out.push('?');
                            }
                            c => { out.push('\\'); out.push(c as char); }
                        }
                    }
                } else if bytes[i] == b'"' {
                    return Ok((JsonValue::Str(out), &s[i+1..]));
                } else {
                    out.push(bytes[i] as char);
                }
                i += 1;
            }
            Err(())
        }
        b'{' => {
            let mut rest = s[1..].trim_start();
            let mut fields = Vec::new();
            if rest.starts_with('}') {
                return Ok((JsonValue::Object(fields), &rest[1..]));
            }
            loop {
                let (key, r) = parse_json_val(rest)?;
                let key_str = match key { JsonValue::Str(s) => s, _ => return Err(()) };
                let r = r.trim_start();
                if !r.starts_with(':') { return Err(()); }
                let (val, r) = parse_json_val(&r[1..])?;
                fields.push((key_str, val));
                let r = r.trim_start();
                if r.starts_with('}') {
                    return Ok((JsonValue::Object(fields), &r[1..]));
                }
                if r.starts_with(',') {
                    rest = r[1..].trim_start();
                } else {
                    return Err(());
                }
            }
        }
        b'[' => {
            let mut rest = s[1..].trim_start();
            let mut items = Vec::new();
            if rest.starts_with(']') {
                return Ok((JsonValue::Array(items), &rest[1..]));
            }
            loop {
                let (val, r) = parse_json_val(rest)?;
                items.push(val);
                let r = r.trim_start();
                if r.starts_with(']') {
                    return Ok((JsonValue::Array(items), &r[1..]));
                }
                if r.starts_with(',') {
                    rest = r[1..].trim_start();
                } else {
                    return Err(());
                }
            }
        }
        b't' if s.starts_with("true") => Ok((JsonValue::Bool(true), &s[4..])),
        b'f' if s.starts_with("false") => Ok((JsonValue::Bool(false), &s[5..])),
        b'n' if s.starts_with("null") => Ok((JsonValue::Null, &s[4..])),
        b'0'..=b'9' | b'-' => {
            let end = s.find(|c: char| !c.is_ascii_digit() && c != '.' && c != '-' && c != 'e' && c != 'E' && c != '+')
                .unwrap_or(s.len());
            let n: f64 = s[..end].parse().map_err(|_| ())?;
            Ok((JsonValue::Num(n), &s[end..]))
        }
        _ => Err(()),
    }
}

// ---- Utility helpers ----

fn get_uri(params: &JsonValue) -> Option<String> {
    params.get_field("textDocument")
        .and_then(|td| td.get_field("uri"))
        .and_then(|v| match v { JsonValue::Str(s) => Some(s.clone()), _ => None })
}

fn get_position(params: &JsonValue) -> (usize, usize) {
    let pos = params.get_field("position");
    let line = pos.and_then(|p| p.get_field("line"))
        .and_then(|v| match v { JsonValue::Num(n) => Some(*n as usize), _ => None })
        .unwrap_or(0);
    let col = pos.and_then(|p| p.get_field("character"))
        .and_then(|v| match v { JsonValue::Num(n) => Some(*n as usize), _ => None })
        .unwrap_or(0);
    (line, col)
}

fn get_nested<'a>(val: &'a JsonValue, keys: &[&str]) -> Option<&'a JsonValue> {
    let mut current = val;
    for key in keys {
        current = current.get_field(key)?;
    }
    Some(current)
}

fn word_at(line: &str, col: usize) -> String {
    let bytes = line.as_bytes();
    if col >= bytes.len() {
        return String::new();
    }

    // Find word boundaries
    let mut start = col;
    while start > 0 && (bytes[start - 1].is_ascii_alphanumeric() || bytes[start - 1] == b'_') {
        start -= 1;
    }
    let mut end = col;
    while end < bytes.len() && (bytes[end].is_ascii_alphanumeric() || bytes[end] == b'_') {
        end += 1;
    }

    line[start..end].to_string()
}
