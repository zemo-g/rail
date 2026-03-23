#!/usr/bin/env python3
"""Rail Language Server Protocol (LSP) server.

Provides diagnostics (compile errors/warnings), hover info for builtins,
and go-to-definition for user-defined functions.

Usage:
  python3 tools/lsp_server.py              # stdio mode (default)
  ./rail_native run tools/lsp.rail         # via Rail wrapper (if created)

The VS Code extension connects via stdio. Messages use JSON-RPC 2.0
with Content-Length framing.
"""

import json
import os
import re
import subprocess
import sys

RAIL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAIL_BIN = os.path.join(RAIL_DIR, "rail_native")

# ── Builtin reference ────────────────────────────────────────────────

BUILTINS = {
    "print":       {"sig": "print : string -> ()",        "doc": "Print a string to stdout with newline."},
    "show":        {"sig": "show : int -> string",        "doc": "Convert an integer to its string representation."},
    "read_file":   {"sig": "read_file : string -> string", "doc": "Read entire file contents as a string."},
    "write_file":  {"sig": "write_file : string -> string -> ()", "doc": "Write string contents to a file path."},
    "append":      {"sig": "append : string -> string -> string", "doc": "Append second string to first."},
    "shell":       {"sig": "shell : string -> string",    "doc": "Execute shell command, return stdout."},
    "cat":         {"sig": "cat : [string] -> string",    "doc": "Concatenate a list of strings."},
    "join":        {"sig": "join : string -> [string] -> string", "doc": "Join list of strings with separator."},
    "split":       {"sig": "split : string -> string -> [string]", "doc": "Split string on each character in the delimiter string (single-char split)."},
    "length":      {"sig": "length : [a] -> int",         "doc": "Return length of a list."},
    "head":        {"sig": "head : [a] -> a",             "doc": "Return first element of a list."},
    "tail":        {"sig": "tail : [a] -> [a]",           "doc": "Return list without its first element."},
    "cons":        {"sig": "cons : a -> [a] -> [a]",      "doc": "Prepend element to a list."},
    "reverse":     {"sig": "reverse : [a] -> [a]",        "doc": "Reverse a list."},
    "range":       {"sig": "range : int -> [int]",        "doc": "Generate list [0..N-1]."},
    "map":         {"sig": "map : (a -> b) -> [a] -> [b]", "doc": "Apply function to each element."},
    "filter":      {"sig": "filter : (a -> bool) -> [a] -> [a]", "doc": "Keep elements where predicate is true. Note: use named functions, not lambdas."},
    "fold":        {"sig": "fold : (b -> a -> b) -> b -> [a] -> b", "doc": "Left fold over a list."},
    "match":       {"sig": "match expr | Pattern -> body", "doc": "Pattern match on ADT values."},
    "let":         {"sig": "let x = expr in body",        "doc": "Bind a value to a name."},
    "if":          {"sig": "if cond then expr else expr",  "doc": "Conditional expression."},
    "llm":         {"sig": "llm : int -> string -> string -> string", "doc": "Call LLM server. Args: port, system_prompt, user_prompt."},
    "arena_mark":  {"sig": "arena_mark : () -> int",      "doc": "Save current arena position for later reset."},
    "arena_reset": {"sig": "arena_reset : int -> ()",     "doc": "Reset arena to saved position, freeing allocations."},
    "type":        {"sig": "type Name = | Constructor args ...", "doc": "Define an algebraic data type (ADT)."},
    "str_len":     {"sig": "str_len : string -> int",     "doc": "Return length of a string in bytes."},
    "char_at":     {"sig": "char_at : string -> int -> string", "doc": "Get character at index as a single-char string."},
    "int_of_char": {"sig": "int_of_char : string -> int", "doc": "Get ASCII code of first character."},
    "char_of_int": {"sig": "char_of_int : int -> string", "doc": "Convert ASCII code to single-char string."},
    "str_slice":   {"sig": "str_slice : string -> int -> int -> string", "doc": "Substring from start index with given length."},
}

# ── JSON-RPC framing ────────────────────────────────────────────────

def read_message():
    """Read one LSP message from stdin. Returns parsed JSON or None on EOF."""
    # Read headers
    content_length = -1
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None  # EOF
        line = line.decode('utf-8', errors='replace')
        if line.strip() == '':
            break  # End of headers
        if line.lower().startswith('content-length:'):
            content_length = int(line.split(':')[1].strip())

    if content_length < 0:
        return None

    # Read body
    body = sys.stdin.buffer.read(content_length)
    if not body:
        return None
    return json.loads(body.decode('utf-8', errors='replace'))


def send_message(msg):
    """Send an LSP message to stdout with Content-Length framing."""
    body = json.dumps(msg, ensure_ascii=False)
    encoded = body.encode('utf-8')
    header = f"Content-Length: {len(encoded)}\r\n\r\n"
    sys.stdout.buffer.write(header.encode('ascii'))
    sys.stdout.buffer.write(encoded)
    sys.stdout.buffer.flush()


def send_response(req_id, result):
    send_message({"jsonrpc": "2.0", "id": req_id, "result": result})


def send_error(req_id, code, message):
    send_message({"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}})


def send_notification(method, params):
    send_message({"jsonrpc": "2.0", "method": method, "params": params})


# ── Diagnostics ──────────────────────────────────────────────────────

def uri_to_path(uri):
    """Convert file:// URI to filesystem path."""
    if uri.startswith('file://'):
        path = uri[7:]
    else:
        path = uri
    # Normalize to prevent path traversal
    return os.path.normpath(os.path.abspath(path))


def path_to_uri(path):
    """Convert filesystem path to file:// URI."""
    if not path.startswith('file://'):
        return 'file://' + path
    return path


def compile_and_get_diagnostics(file_path):
    """Compile a Rail file and parse diagnostics from output."""
    diagnostics = []

    if not file_path.endswith('.rail') or not os.path.exists(file_path):
        return diagnostics

    try:
        result = subprocess.run(
            [RAIL_BIN, file_path],
            capture_output=True, text=True, timeout=15,
            cwd=RAIL_DIR
        )
        output = result.stdout + result.stderr
    except (subprocess.TimeoutExpired, FileNotFoundError):
        diagnostics.append({
            "range": _range(0, 0, 0, 1),
            "severity": 1,
            "source": "rail",
            "message": "Compilation timed out or rail_native not found"
        })
        return diagnostics

    for line in output.splitlines():
        line = line.strip()

        # file:line:col: error: message
        m = re.match(r'(.+?):(\d+):(\d+):\s*(error|warning):\s*(.*)', line)
        if m:
            ln = max(0, int(m.group(2)) - 1)
            col = max(0, int(m.group(3)) - 1)
            severity = 1 if m.group(4) == 'error' else 2
            diagnostics.append({
                "range": _range(ln, col, ln, col + 10),
                "severity": severity,
                "source": "rail",
                "message": m.group(5)
            })
            continue

        # WARNING: non-exhaustive match — missing: X, Y
        m = re.match(r'WARNING:\s*(.*)', line)
        if m:
            diagnostics.append({
                "range": _range(0, 0, 0, 1),
                "severity": 2,  # Warning
                "source": "rail",
                "message": m.group(1)
            })
            continue

        # Linker errors: Undefined symbols
        if 'Undefined symbols' in line or 'ld:' in line and 'error' in line.lower():
            diagnostics.append({
                "range": _range(0, 0, 0, 1),
                "severity": 1,
                "source": "rail",
                "message": f"Link error: {line}"
            })
            continue

        # assembler errors
        if line.startswith('as:') and line != 'as: OK':
            diagnostics.append({
                "range": _range(0, 0, 0, 1),
                "severity": 1,
                "source": "rail",
                "message": f"Assembler error: {line}"
            })

        # ld not OK
        if line.startswith('ld:') and line != 'ld: OK' and 'Undefined' not in line:
            # Parse ld errors that contain useful info
            if 'cannot be open' not in line:
                diagnostics.append({
                    "range": _range(0, 0, 0, 1),
                    "severity": 1,
                    "source": "rail",
                    "message": line
                })

    return diagnostics


def _range(sl, sc, el, ec):
    return {
        "start": {"line": sl, "character": sc},
        "end": {"line": el, "character": ec}
    }


def publish_diagnostics(uri, file_path):
    diags = compile_and_get_diagnostics(file_path)
    send_notification("textDocument/publishDiagnostics", {
        "uri": uri,
        "diagnostics": diags
    })


# ── Document storage ─────────────────────────────────────────────────

# uri -> {"text": ..., "path": ...}
documents = {}


def store_document(uri, text=None):
    path = uri_to_path(uri)
    if text is None and os.path.exists(path):
        with open(path, 'r', errors='replace') as f:
            text = f.read()
    documents[uri] = {"text": text or "", "path": path}


def get_document_text(uri):
    if uri in documents:
        return documents[uri]["text"]
    path = uri_to_path(uri)
    if os.path.exists(path):
        with open(path, 'r', errors='replace') as f:
            return f.read()
    return ""


# ── Hover ────────────────────────────────────────────────────────────

def get_word_at_position(text, line, character):
    """Extract the word at the given position."""
    lines = text.splitlines()
    if line >= len(lines):
        return ""
    ln = lines[line]
    if character >= len(ln):
        return ""

    # Expand left
    start = character
    while start > 0 and (ln[start - 1].isalnum() or ln[start - 1] == '_'):
        start -= 1

    # Expand right
    end = character
    while end < len(ln) and (ln[end].isalnum() or ln[end] == '_'):
        end += 1

    return ln[start:end]


def handle_hover(req_id, params):
    uri = params["textDocument"]["uri"]
    pos = params["position"]
    text = get_document_text(uri)
    word = get_word_at_position(text, pos["line"], pos["character"])

    if not word:
        send_response(req_id, None)
        return

    # Check builtins
    if word in BUILTINS:
        info = BUILTINS[word]
        content = f"```rail\n{info['sig']}\n```\n---\n{info['doc']}"
        send_response(req_id, {
            "contents": {"kind": "markdown", "value": content}
        })
        return

    # Check user-defined functions in the same file
    func_info = find_function_def(text, word)
    if func_info:
        content = f"```rail\n{func_info['signature']}\n```\n---\nDefined at line {func_info['line'] + 1}"
        send_response(req_id, {
            "contents": {"kind": "markdown", "value": content}
        })
        return

    send_response(req_id, None)


# ── Definition ───────────────────────────────────────────────────────

def find_function_def(text, name):
    """Find where a function is defined: `name arg1 arg2 = ...`"""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith('--'):
            continue
        # Match: name <args> =
        # Patterns: `name = expr`, `name arg1 arg2 = expr`
        m = re.match(r'^(' + re.escape(name) + r')(\s+\w+)*\s*=', stripped)
        if m:
            # Build a signature from the definition
            eq_idx = stripped.index('=')
            sig = stripped[:eq_idx].strip()
            return {"line": i, "character": 0, "signature": sig}
    return None


def find_type_def(text, name):
    """Find where a type or constructor is defined."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        stripped = line.strip()
        # type Name = | Constructor ...
        if stripped.startswith('type ') and name in stripped:
            return {"line": i, "character": 0}
        # | Constructor ...  (continuation of type def)
        m = re.match(r'^\|\s*' + re.escape(name) + r'\b', stripped)
        if m:
            return {"line": i, "character": 0}
    return None


def handle_definition(req_id, params):
    uri = params["textDocument"]["uri"]
    pos = params["position"]
    text = get_document_text(uri)
    word = get_word_at_position(text, pos["line"], pos["character"])

    if not word:
        send_response(req_id, None)
        return

    # Search for function definition
    func_info = find_function_def(text, word)
    if func_info:
        send_response(req_id, {
            "uri": uri,
            "range": _range(func_info["line"], 0, func_info["line"], len(word))
        })
        return

    # Search for type/constructor definition
    type_info = find_type_def(text, word)
    if type_info:
        send_response(req_id, {
            "uri": uri,
            "range": _range(type_info["line"], 0, type_info["line"], len(word))
        })
        return

    send_response(req_id, None)


# ── Completion ───────────────────────────────────────────────────────

def handle_completion(req_id, params):
    """Provide basic completion for builtins and keywords."""
    items = []
    for name, info in BUILTINS.items():
        items.append({
            "label": name,
            "kind": 3,  # Function
            "detail": info["sig"],
            "documentation": info["doc"]
        })

    # Add keywords
    for kw in ["let", "in", "if", "then", "else", "match", "type", "main"]:
        items.append({
            "label": kw,
            "kind": 14,  # Keyword
        })

    send_response(req_id, {"isIncomplete": False, "items": items})


# ── Main loop ────────────────────────────────────────────────────────

def log(msg):
    """Log to stderr (won't interfere with LSP stdout)."""
    sys.stderr.write(f"[rail-lsp] {msg}\n")
    sys.stderr.flush()


def main():
    log("Rail LSP server starting")
    initialized = False
    shutdown_requested = False

    while True:
        msg = read_message()
        if msg is None:
            break

        method = msg.get("method", "")
        req_id = msg.get("id")
        params = msg.get("params", {})

        # ── Lifecycle ────────────────────────────────────────────
        if method == "initialize":
            send_response(req_id, {
                "capabilities": {
                    "textDocumentSync": {
                        "openClose": True,
                        "change": 1,  # Full sync
                        "save": {"includeText": False}
                    },
                    "hoverProvider": True,
                    "definitionProvider": True,
                    "completionProvider": {
                        "triggerCharacters": []
                    }
                },
                "serverInfo": {
                    "name": "rail-lsp",
                    "version": "0.1.0"
                }
            })
            log("Initialized")

        elif method == "initialized":
            initialized = True

        elif method == "shutdown":
            shutdown_requested = True
            send_response(req_id, None)

        elif method == "exit":
            sys.exit(0 if shutdown_requested else 1)

        # ── Document sync ────────────────────────────────────────
        elif method == "textDocument/didOpen":
            td = params.get("textDocument", {})
            uri = td.get("uri", "")
            text = td.get("text", "")
            store_document(uri, text)
            publish_diagnostics(uri, uri_to_path(uri))

        elif method == "textDocument/didChange":
            td = params.get("textDocument", {})
            uri = td.get("uri", "")
            changes = params.get("contentChanges", [])
            if changes:
                # Full sync — last change has the full text
                text = changes[-1].get("text", "")
                store_document(uri, text)

        elif method == "textDocument/didSave":
            td = params.get("textDocument", {})
            uri = td.get("uri", "")
            # Re-read from disk on save
            store_document(uri)
            publish_diagnostics(uri, uri_to_path(uri))

        elif method == "textDocument/didClose":
            td = params.get("textDocument", {})
            uri = td.get("uri", "")
            documents.pop(uri, None)
            # Clear diagnostics
            send_notification("textDocument/publishDiagnostics", {
                "uri": uri,
                "diagnostics": []
            })

        # ── Features ─────────────────────────────────────────────
        elif method == "textDocument/hover":
            handle_hover(req_id, params)

        elif method == "textDocument/definition":
            handle_definition(req_id, params)

        elif method == "textDocument/completion":
            handle_completion(req_id, params)

        # ── Unknown requests (must respond to avoid client timeout) ──
        elif req_id is not None:
            send_error(req_id, -32601, f"Method not found: {method}")

        # Notifications we don't handle — just ignore
        # ($/cancelRequest, $/setTrace, workspace/*, etc.)


if __name__ == "__main__":
    main()
