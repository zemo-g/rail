mod token;
mod lexer;
mod ast;
mod parser;
mod interpreter;
mod typechecker;
mod codegen;
mod repl;
mod modules;
mod stdlib;
mod ai;
mod route;
mod purity;
mod serve;
mod agent;
mod fmt;
mod test_runner;
mod lsp;

use std::env;
use std::fs;

fn main() {
    let raw_args: Vec<String> = env::args().collect();
    // Parse --allow/--sandbox/--open flags, return route + remaining args
    let (route, args) = route::Route::from_args(&raw_args[1..]);
    // Re-insert program name for index consistency
    let args: Vec<String> = std::iter::once(raw_args[0].clone()).chain(args).collect();

    match args.get(1).map(|s| s.as_str()) {
        Some("run") => {
            let file = args.get(2).unwrap_or_else(|| {
                eprintln!("usage: rail run <file.rail> [--allow fs:/path] [--allow shell] [--allow ai] [--allow net:host] [--allow all]");
                std::process::exit(1);
            });
            run_file(file, route);
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
        Some("serve") => {
            let file = args.get(2).unwrap_or_else(|| {
                eprintln!("usage: rail serve <file.rail> [--http PORT] [--browser]");
                std::process::exit(1);
            });
            let http_port = args.iter().position(|a| a == "--http")
                .and_then(|i| args.get(i + 1))
                .and_then(|p| p.parse::<u16>().ok());
            let auto_open = args.iter().any(|a| a == "--browser");

            if let Some(port) = http_port {
                serve::serve_loop_http(file, route, port, auto_open);
            } else {
                serve::serve_loop(file, route);
            }
        }
        Some("repl") => {
            repl::start();
        }
        Some("fmt") => {
            let file = args.get(2).unwrap_or_else(|| {
                eprintln!("usage: rail fmt <file.rail> [--check]");
                std::process::exit(1);
            });
            let check_only = args.iter().any(|a| a == "--check");
            fmt_file(file, check_only);
        }
        Some("test") => {
            let file = args.get(2).unwrap_or_else(|| {
                eprintln!("usage: rail test <file.rail>");
                std::process::exit(1);
            });
            test_file(file, route);
        }
        Some("lsp") => {
            lsp::run_lsp();
        }
        Some("init") => {
            let dir = args.get(2).map(|s| s.as_str());
            init_project(dir);
        }
        Some("stdlib-path") => {
            let base = args.get(2)
                .map(|s| std::path::PathBuf::from(s))
                .unwrap_or_else(|| std::env::current_dir().unwrap());
            println!("stdlib search paths:");
            for path in modules::stdlib_search_paths(&base) {
                println!("  {}", path);
            }
            println!();
            println!("embedded modules:");
            for name in stdlib::list_modules() {
                println!("  {}", name);
            }
        }
        Some("version") | Some("--version") | Some("-v") => {
            println!("Rail 0.6.0");
        }
        Some(arg) if arg.ends_with(".rail") => {
            // User typed `rail file.rail` — they probably meant `rail run file.rail`
            eprintln!("hint: did you mean `rail run {}`?", arg);
            eprintln!();
            run_file(arg, route);
        }
        _ => {
            println!("Rail — a pure functional, AI-native language");
            println!();
            println!("usage:");
            println!("  rail run <file.rail>     Run a Rail program (interpreter)");
            println!("  rail serve <file.rail>   Run with hot code reloading");
            println!("  rail serve <f> --http N  Serve main's output as HTML on port N");
            println!("  rail compile <file.rail> Compile and run (native ARM64/x86_64)");
            println!("  rail check <file.rail>   Type-check a Rail program");
            println!("  rail parse <file.rail>   Parse and show AST");
            println!("  rail lex <file.rail>     Tokenize and show tokens");
            println!("  rail fmt <file.rail>     Format a Rail source file");
            println!("  rail fmt <file> --check  Check if file is formatted (CI mode)");
            println!("  rail test <file.rail>    Run test_ functions in a file");
            println!("  rail repl                Interactive mode");
            println!("  rail lsp                 Start Language Server Protocol server");
            println!("  rail init [dir]          Create a new Rail project");
            println!("  rail stdlib-path [dir]   Show stdlib search paths");
            println!("  rail version             Show version");
            println!();
            println!("route flags (capability system):");
            println!("  --allow fs:/path         Allow filesystem access under /path");
            println!("  --allow net:host         Allow network access to host");
            println!("  --allow shell            Allow shell command execution");
            println!("  --allow ai               Allow AI/LLM calls");
            println!("  --allow env:VAR          Allow reading env var VAR");
            println!("  --allow all              Full access (no restrictions)");
            println!("  --open                   Shorthand for --allow all");
            println!("  --sandbox                No system access (default)");
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

fn run_file(path: &str, route: route::Route) {
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

    // Show route if not default open — help beginners understand the sandbox
    if !route.allow_all {
        eprintln!("[sandbox mode — use --open for full access, or --allow ai/shell/fs:path]");
    }
    let interp = interpreter::Interpreter::with_route(route);
    match interp.run(&program) {
        Ok(val) => {
            // main's return value is an exit code, not output.
            // Unit = fine (ended with print or side effect)
            // Int(0) = success, don't print
            // Int(n) = use as process exit code
            // Anything else = print it (useful in REPL / debugging)
            match val {
                interpreter::Value::Unit => {}
                interpreter::Value::Int(0) => {}
                interpreter::Value::Int(code) => {
                    std::process::exit(code as i32);
                }
                _ => println!("{}", val),
            }
        }
        Err(e) => {
            eprintln!("{}", e);
            let msg = format!("{}", e);
            if msg.contains("type error") {
                eprintln!("hint: run `rail check {}` for detailed type analysis", path);
            }
            std::process::exit(1);
        }
    }
}

fn fmt_file(path: &str, check_only: bool) {
    let source = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("error reading {}: {}", path, e);
        std::process::exit(1);
    });

    let formatted = fmt::format_source(&source);

    if check_only {
        if formatted == source {
            println!("{}: ok", path);
        } else {
            eprintln!("{}: not formatted", path);
            std::process::exit(1);
        }
    } else {
        if formatted == source {
            println!("{}: already formatted", path);
        } else {
            fs::write(path, &formatted).unwrap_or_else(|e| {
                eprintln!("error writing {}: {}", path, e);
                std::process::exit(1);
            });
            println!("{}: formatted", path);
        }
    }
}

fn test_file(path: &str, route: route::Route) {
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

    let results = test_runner::run_tests(&program, route);
    let failed = results.iter().filter(|r| !r.passed).count();
    if failed > 0 {
        std::process::exit(1);
    }
}

fn init_project(dir: Option<&str>) {
    let project_dir = match dir {
        Some(d) => std::path::PathBuf::from(d),
        None => std::env::current_dir().unwrap_or_else(|e| {
            eprintln!("cannot get current directory: {}", e);
            std::process::exit(1);
        }),
    };

    // Derive project name from directory
    let project_name = project_dir
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("my-project")
        .to_string();

    // Create directories
    let src_dir = project_dir.join("src");
    if let Err(e) = fs::create_dir_all(&src_dir) {
        eprintln!("cannot create {}: {}", src_dir.display(), e);
        std::process::exit(1);
    }

    // Create rail.toml
    let toml_path = project_dir.join("rail.toml");
    if toml_path.exists() {
        eprintln!("rail.toml already exists in {}", project_dir.display());
        std::process::exit(1);
    }
    let toml_content = format!(
        "[package]\nname = \"{}\"\nversion = \"0.1.0\"\n\n[dependencies]\n# future: external packages\n",
        project_name
    );
    if let Err(e) = fs::write(&toml_path, toml_content) {
        eprintln!("cannot write {}: {}", toml_path.display(), e);
        std::process::exit(1);
    }

    // Create src/main.rail
    let main_path = src_dir.join("main.rail");
    if !main_path.exists() {
        let main_content = "main =\n  let _ = print \"Hello from Rail!\"\n  0\n";
        if let Err(e) = fs::write(&main_path, main_content) {
            eprintln!("cannot write {}: {}", main_path.display(), e);
            std::process::exit(1);
        }
    }

    println!("initialized Rail project '{}' in {}", project_name, project_dir.display());
    println!();
    println!("  rail.toml       project manifest");
    println!("  src/main.rail   entry point");
    println!();
    println!("run it:");
    println!("  rail run src/main.rail");
}
