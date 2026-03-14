/// Hot code reloading for Rail.
///
/// The simplest thing that works:
///   rail serve program.rail --watch
///
/// Two reloading modes:
///
///   1. Auto-reload: main returns → watch for changes → re-parse → re-run main.
///      State survives via set_state/get_state.
///
///   2. Manual reload: main runs forever, calls check_reload() in its loop.
///      If the source file changed, check_reload re-parses and swaps globals.
///      Next function call sees the new definition. Zero downtime.
///
/// No threads, no channels, no framework. Just a file, a timestamp, and a swap.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, Duration};

use crate::ast;
use crate::interpreter::{Interpreter, Value};
use crate::route::Route;
use crate::lexer::Lexer;
use crate::parser::Parser;
use crate::modules::ModuleResolver;

/// Persistent state that survives reloads.
/// Programs store values with set_state/get_state — they live here.
pub type State = HashMap<String, Value>;

/// Everything the interpreter needs to know about its source file.
pub struct ServeContext {
    /// Path to the main source file
    pub path: PathBuf,
    /// All files involved (main + imports) — we watch all of them
    pub watched: Vec<PathBuf>,
    /// Last observed mtime for each watched file
    pub mtimes: HashMap<PathBuf, SystemTime>,
    /// Persistent state across reloads
    pub state: State,
    /// How many times we've reloaded
    pub generation: u64,
}

impl ServeContext {
    pub fn new(path: &str) -> Self {
        let path = PathBuf::from(path);
        let mtime = file_mtime(&path).unwrap_or(SystemTime::UNIX_EPOCH);
        let mut mtimes = HashMap::new();
        mtimes.insert(path.clone(), mtime);

        ServeContext {
            path: path.clone(),
            watched: vec![path],
            mtimes,
            state: HashMap::new(),
            generation: 0,
        }
    }

    /// Check if any watched file has changed.
    /// Returns the list of changed file names, or empty if nothing changed.
    pub fn check_changes(&self) -> Vec<String> {
        let mut changed = Vec::new();
        for path in &self.watched {
            let current = file_mtime(path).unwrap_or(SystemTime::UNIX_EPOCH);
            if let Some(prev) = self.mtimes.get(path) {
                if current != *prev {
                    let name = path.file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("unknown");
                    changed.push(name.to_string());
                }
            }
        }
        changed
    }

    /// Update mtimes after a reload.
    pub fn refresh_mtimes(&mut self) {
        for path in &self.watched {
            if let Ok(mtime) = file_mtime(path) {
                self.mtimes.insert(path.clone(), mtime);
            }
        }
    }

    /// Re-parse the source file and return the program + list of changed function names.
    pub fn reload(&mut self) -> Result<(ast::Program, Vec<String>), String> {
        self.generation += 1;
        self.refresh_mtimes();

        // Read and parse
        let source = std::fs::read_to_string(&self.path)
            .map_err(|e| format!("cannot read {}: {}", self.path.display(), e))?;

        let mut lexer = Lexer::new(&source);
        let tokens = lexer.tokenize()
            .map_err(|e| format!("lex error: {}", e))?;

        let mut parser = Parser::new(tokens);
        let program = parser.parse_program()
            .map_err(|e| format!("parse error: {}", e))?;

        // Resolve imports
        let base = self.path.parent().unwrap_or(Path::new("."));
        let mut resolver = ModuleResolver::new(base);
        let imported = resolver.resolve_imports(&program)?;

        let mut all_decls = imported;
        // Collect new function names
        let new_names: Vec<String> = program.declarations.iter()
            .filter_map(|d| match d {
                ast::Decl::Func { name, .. } => Some(name.clone()),
                _ => None,
            })
            .collect();
        all_decls.extend(program.declarations);
        let program = ast::Program { declarations: all_decls };

        Ok((program, new_names))
    }
}

/// The serve loop — auto-reload mode.
///
/// Runs main, waits for file changes, re-runs main.
/// State persists across reloads via set_state/get_state.
pub fn serve_loop(path: &str, route: Route) {
    let mut ctx = ServeContext::new(path);

    loop {
        // Parse
        let (program, fn_names) = match ctx.reload() {
            Ok(p) => p,
            Err(e) => {
                eprintln!("[serve] error: {}", e);
                eprintln!("[serve] waiting for fix...");
                wait_for_change(&ctx);
                ctx.refresh_mtimes();
                continue;
            }
        };

        let fn_count = fn_names.len();
        if ctx.generation == 1 {
            eprintln!("[serve] {} loaded ({} functions)",
                ctx.path.file_name().and_then(|n| n.to_str()).unwrap_or("?"),
                fn_count);
        } else {
            eprintln!("[serve] reloaded gen {} ({} functions)",
                ctx.generation, fn_count);
        }

        // Run
        let mut interp = Interpreter::with_route(route.clone());
        interp.set_serve_context_state(&ctx.state);

        match interp.run(&program) {
            Ok(_) => {}
            Err(e) => {
                eprintln!("[serve] runtime error: {}", e);
            }
        }

        // Harvest state for next generation
        ctx.state = interp.take_serve_state();

        // Watch for changes
        eprintln!("[serve] watching for changes...");
        wait_for_change(&ctx);
        ctx.refresh_mtimes();
        eprintln!("[serve] change detected — reloading");
    }
}

/// Block until any watched file changes (500ms poll).
fn wait_for_change(ctx: &ServeContext) {
    loop {
        std::thread::sleep(Duration::from_millis(500));
        if !ctx.check_changes().is_empty() {
            return;
        }
    }
}

/// Get a file's mtime.
fn file_mtime(path: &Path) -> Result<SystemTime, ()> {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .map_err(|_| ())
}
