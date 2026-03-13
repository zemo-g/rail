/// Rail REPL — interactive mode.
/// Maintains interpreter state across the session.

use std::io::{self, BufRead, Write};

use crate::lexer::Lexer;
use crate::parser::Parser;
use crate::interpreter::{Interpreter, Value};
use crate::typechecker::TypeChecker;

pub fn start() {
    let stdin = io::stdin();
    let mut reader = stdin.lock();
    let mut interp = Interpreter::new();
    let mut accumulated = String::new();
    let mut prev_decl_count: usize = 0;

    eprint!("Rail v0.1 — interactive mode\n");
    eprint!("Type expressions or declarations. :quit to exit.\n\n");
    eprint!("> ");
    io::stderr().flush().unwrap();

    let mut line_buf = String::new();

    loop {
        line_buf.clear();
        match reader.read_line(&mut line_buf) {
            Ok(0) => break, // EOF
            Err(_) => break,
            Ok(_) => {}
        }

        let line = line_buf.trim_end_matches('\n').trim_end_matches('\r').to_string();

        // Handle commands
        let trimmed = line.trim();
        if trimmed == ":quit" || trimmed == ":q" {
            break;
        }
        if trimmed == ":reset" {
            interp = Interpreter::new();
            accumulated.clear();
            prev_decl_count = 0;
            eprint!("  reset\n> ");
            io::stderr().flush().unwrap();
            continue;
        }
        if let Some(name) = trimmed.strip_prefix(":type ").or_else(|| trimmed.strip_prefix(":t ")) {
            let name = name.trim();
            handle_type_command(name, &accumulated);
            eprint!("> ");
            io::stderr().flush().unwrap();
            continue;
        }
        if trimmed.is_empty() {
            eprint!("> ");
            io::stderr().flush().unwrap();
            continue;
        }

        // Multi-line input: if line ends with '=', keep reading
        let mut input = line.to_string();
        if trimmed.ends_with('=') {
            loop {
                eprint!(".. ");
                io::stderr().flush().unwrap();
                line_buf.clear();
                match reader.read_line(&mut line_buf) {
                    Ok(0) => break,
                    Err(_) => break,
                    Ok(_) => {}
                }
                let cont = line_buf.trim_end_matches('\n').trim_end_matches('\r');
                if cont.is_empty() || (!cont.starts_with(' ') && !cont.starts_with('\t')) {
                    // Blank line or line at indent 0 ends continuation
                    if !cont.is_empty() {
                        input.push('\n');
                        input.push_str(cont);
                    }
                    break;
                }
                input.push('\n');
                input.push_str(cont);
            }
        }

        // Strategy a: try parsing accumulated + new input as declarations
        let try_source = if accumulated.is_empty() {
            input.clone()
        } else {
            format!("{}\n{}", accumulated, input)
        };

        if let Some(new_count) = try_as_decls(&try_source) {
            if new_count > prev_decl_count {
                // Parse again to register new declarations
                if let Ok(program) = parse_source(&try_source) {
                    let mut ok = true;
                    for decl in &program.declarations[prev_decl_count..] {
                        match interp.register_decl(decl) {
                            Ok(()) => {
                                if let Some(name) = decl_name(decl) {
                                    println!("  defined {}", name);
                                }
                            }
                            Err(e) => {
                                eprintln!("  {}", e);
                                ok = false;
                            }
                        }
                    }
                    if ok {
                        accumulated = try_source;
                        prev_decl_count = new_count;
                    }
                }
                eprint!("> ");
                io::stderr().flush().unwrap();
                continue;
            }
        }

        // Strategy b1: bare `let x = expr` → register as `x = expr` declaration
        if trimmed.starts_with("let ") {
            // Transform "let x = expr" into "x = expr" (a top-level declaration)
            let rest = trimmed.strip_prefix("let ").unwrap().trim();
            let decl_source = if accumulated.is_empty() {
                rest.to_string()
            } else {
                format!("{}\n{}", accumulated, rest)
            };
            if let Some(new_count) = try_as_decls(&decl_source) {
                if new_count > prev_decl_count {
                    if let Ok(program) = parse_source(&decl_source) {
                        let mut ok = true;
                        for decl in &program.declarations[prev_decl_count..] {
                            match interp.register_decl(decl) {
                                Ok(()) => {
                                    if let Some(name) = decl_name(decl) {
                                        println!("  {} = ...", name);
                                    }
                                }
                                Err(e) => {
                                    eprintln!("  {}", e);
                                    ok = false;
                                }
                            }
                        }
                        if ok {
                            accumulated = decl_source;
                            prev_decl_count = new_count;
                        }
                    }
                    eprint!("> ");
                    io::stderr().flush().unwrap();
                    continue;
                }
            }
        }

        // Strategy b2: try as expression by wrapping as __repl__ = <input>
        let expr_source = if accumulated.is_empty() {
            format!("__repl__ = {}", input)
        } else {
            format!("{}\n__repl__ = {}", accumulated, input)
        };

        match parse_source(&expr_source) {
            Ok(program) => {
                // Register all declarations (re-register existing ones + __repl__)
                let mut temp_interp = clone_interp_state(&interp, &accumulated);
                let last = program.declarations.last();
                if let Some(decl) = last {
                    match temp_interp.register_decl(decl) {
                        Ok(()) => {
                            // Evaluate __repl__
                            match temp_interp.globals().get("__repl__") {
                                Some(Value::Closure { params, body, env }) if params.is_empty() => {
                                    match temp_interp.eval_expr(&body.clone()) {
                                        Ok(Value::Unit) => {} // don't print unit
                                        Ok(val) => println!("{}", val),
                                        Err(e) => eprintln!("  {}", e),
                                    }
                                }
                                Some(val) => {
                                    match val {
                                        Value::Unit => {}
                                        _ => println!("{}", val),
                                    }
                                }
                                None => {}
                            }
                        }
                        Err(e) => eprintln!("  {}", e),
                    }
                }
            }
            Err(e) => {
                eprintln!("  {}", e);
            }
        }

        eprint!("> ");
        io::stderr().flush().unwrap();
    }
}

fn parse_source(source: &str) -> Result<crate::ast::Program, String> {
    let mut lexer = Lexer::new(source);
    let tokens = lexer.tokenize().map_err(|e| format!("{}", e))?;
    let mut parser = Parser::new(tokens);
    parser.parse_program().map_err(|e| format!("{}", e))
}

fn try_as_decls(source: &str) -> Option<usize> {
    let program = parse_source(source).ok()?;
    Some(program.declarations.len())
}

fn decl_name(decl: &crate::ast::Decl) -> Option<String> {
    match decl {
        crate::ast::Decl::Func { name, .. } => Some(name.clone()),
        crate::ast::Decl::TypeDecl { name, .. } => Some(name.clone()),
        crate::ast::Decl::RecordDecl { name, .. } => Some(name.clone()),
        _ => None,
    }
}

fn handle_type_command(name: &str, accumulated: &str) {
    // Build a minimal program with accumulated source and type-check it
    let source = if accumulated.is_empty() {
        // nothing to check
        eprintln!("  undefined: '{}'", name);
        return;
    } else {
        accumulated.to_string()
    };

    match parse_source(&source) {
        Ok(program) => {
            let mut checker = TypeChecker::new();
            let result = checker.check_program(&program);
            for (dname, ty) in &result.declarations {
                if dname == name {
                    println!("{} : {}", dname, ty);
                    return;
                }
            }
            eprintln!("  undefined: '{}'", name);
        }
        Err(e) => eprintln!("  {}", e),
    }
}

/// Create a fresh interpreter and re-register all accumulated declarations.
fn clone_interp_state(_original: &Interpreter, accumulated: &str) -> Interpreter {
    let mut interp = Interpreter::new();
    if !accumulated.is_empty() {
        if let Ok(program) = parse_source(accumulated) {
            for decl in &program.declarations {
                let _ = interp.register_decl(decl);
            }
        }
    }
    interp
}
