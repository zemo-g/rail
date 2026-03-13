mod token;
mod lexer;
mod ast;
mod parser;
mod interpreter;
mod typechecker;
mod codegen;
mod repl;
mod modules;

use std::env;
use std::fs;

fn main() {
    let args: Vec<String> = env::args().collect();

    match args.get(1).map(|s| s.as_str()) {
        Some("run") => {
            let file = args.get(2).unwrap_or_else(|| {
                eprintln!("usage: rail run <file.rail>");
                std::process::exit(1);
            });
            run_file(file);
        }
        Some("compile") => {
            let file = args.get(2).unwrap_or_else(|| {
                eprintln!("usage: rail compile <file.rail>");
                std::process::exit(1);
            });
            compile_file(file);
        }
        Some("check") => {
            let file = args.get(2).unwrap_or_else(|| {
                eprintln!("usage: rail check <file.rail>");
                std::process::exit(1);
            });
            check_file(file);
        }
        Some("parse") => {
            let file = args.get(2).unwrap_or_else(|| {
                eprintln!("usage: rail parse <file.rail>");
                std::process::exit(1);
            });
            parse_file(file);
        }
        Some("lex") => {
            let file = args.get(2).unwrap_or_else(|| {
                eprintln!("usage: rail lex <file.rail>");
                std::process::exit(1);
            });
            lex_file(file);
        }
        Some("repl") => {
            repl::start();
        }
        Some("version") | Some("--version") | Some("-v") => {
            println!("Rail 0.1.0");
        }
        _ => {
            println!("Rail — a pure functional, AI-native language");
            println!();
            println!("usage:");
            println!("  rail run <file.rail>     Run a Rail program (interpreter)");
            println!("  rail compile <file.rail> Compile and run (native ARM64/x86_64)");
            println!("  rail check <file.rail>   Type-check a Rail program");
            println!("  rail parse <file.rail>   Parse and show AST");
            println!("  rail lex <file.rail>     Tokenize and show tokens");
            println!("  rail repl                Interactive mode");
            println!("  rail version             Show version");
        }
    }
}

fn resolve_modules(path: &str, program: ast::Program) -> ast::Program {
    let base_path = std::path::Path::new(path).parent().unwrap_or(std::path::Path::new("."));
    let mut resolver = modules::ModuleResolver::new(base_path);
    let imported = match resolver.resolve_imports(&program) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("{}", e);
            std::process::exit(1);
        }
    };
    // Prepend imported declarations
    let mut all_decls = imported;
    all_decls.extend(program.declarations);
    ast::Program { declarations: all_decls }
}

fn compile_file(path: &str) {
    let source = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("error reading {}: {}", path, e);
        std::process::exit(1);
    });

    let mut lexer = lexer::Lexer::new(&source);
    let tokens = match lexer.tokenize() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("{}", e);
            std::process::exit(1);
        }
    };

    let mut parser = parser::Parser::new(tokens);
    let program = match parser.parse_program() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("{}", e);
            std::process::exit(1);
        }
    };

    let program = resolve_modules(path, program);

    let mut compiler = match codegen::Compiler::new() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("compiler init failed: {}", e);
            std::process::exit(1);
        }
    };

    let start = std::time::Instant::now();
    match compiler.compile_and_run(&program) {
        Ok(result) => {
            let elapsed = start.elapsed();
            if result != 0 {
                println!("{}", result);
            }
            eprintln!("[native: {:.3}ms]", elapsed.as_secs_f64() * 1000.0);
        }
        Err(e) => {
            eprintln!("compile error: {}", e);
            std::process::exit(1);
        }
    }
}

fn check_file(path: &str) {
    let source = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("error reading {}: {}", path, e);
        std::process::exit(1);
    });

    let mut lexer = lexer::Lexer::new(&source);
    let tokens = match lexer.tokenize() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("{}", e);
            std::process::exit(1);
        }
    };

    let mut parser = parser::Parser::new(tokens);
    let program = match parser.parse_program() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("{}", e);
            std::process::exit(1);
        }
    };

    let program = resolve_modules(path, program);

    let mut checker = typechecker::TypeChecker::new();
    let result = checker.check_program(&program);

    for (name, ty) in &result.declarations {
        match ty {
            typechecker::Type::Unit if !name.chars().next().unwrap().is_lowercase() => {
                // Type declaration — just show name
                println!("  type {}", name);
            }
            _ => println!("  {} : {}", name, ty),
        }
    }

    if result.errors.is_empty() {
        println!("\n{} declarations, 0 errors", result.declarations.len());
    } else {
        println!();
        for err in &result.errors {
            eprintln!("  {}", err);
        }
        eprintln!("\n{} declarations, {} error(s)",
            result.declarations.len(), result.errors.len());
        std::process::exit(1);
    }
}

fn lex_file(path: &str) {
    let source = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("error reading {}: {}", path, e);
        std::process::exit(1);
    });

    let mut lexer = lexer::Lexer::new(&source);
    match lexer.tokenize() {
        Ok(tokens) => {
            for tok in &tokens {
                match &tok.token {
                    token::Token::Newline => println!("  {:>3}:{:<3}  Newline", tok.span.line, tok.span.col),
                    token::Token::Indent => println!("  {:>3}:{:<3}  >>> Indent", tok.span.line, tok.span.col),
                    token::Token::Dedent => println!("  {:>3}:{:<3}  <<< Dedent", tok.span.line, tok.span.col),
                    token::Token::EOF => println!("  {:>3}:{:<3}  EOF", tok.span.line, tok.span.col),
                    _ => println!("  {:>3}:{:<3}  {:?}", tok.span.line, tok.span.col, tok.token),
                }
            }
            println!("\n{} tokens", tokens.len());
        }
        Err(e) => {
            eprintln!("{}", e);
            std::process::exit(1);
        }
    }
}

fn parse_file(path: &str) {
    let source = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("error reading {}: {}", path, e);
        std::process::exit(1);
    });

    let mut lexer = lexer::Lexer::new(&source);
    let tokens = match lexer.tokenize() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("{}", e);
            std::process::exit(1);
        }
    };

    let mut parser = parser::Parser::new(tokens);
    match parser.parse_program() {
        Ok(program) => {
            for decl in &program.declarations {
                println!("{:#?}", decl);
                println!();
            }
        }
        Err(e) => {
            eprintln!("{}", e);
            std::process::exit(1);
        }
    }
}

fn run_file(path: &str) {
    let source = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("error reading {}: {}", path, e);
        std::process::exit(1);
    });

    let mut lexer = lexer::Lexer::new(&source);
    let tokens = match lexer.tokenize() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("{}", e);
            std::process::exit(1);
        }
    };

    let mut parser = parser::Parser::new(tokens);
    let program = match parser.parse_program() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("{}", e);
            std::process::exit(1);
        }
    };

    let program = resolve_modules(path, program);

    let mut interp = interpreter::Interpreter::new();
    match interp.run(&program) {
        Ok(val) => {
            // Don't print Unit — it means main ended with a print call
            match val {
                interpreter::Value::Unit => {}
                _ => println!("{}", val),
            }
        }
        Err(e) => {
            eprintln!("{}", e);
            std::process::exit(1);
        }
    }
}
