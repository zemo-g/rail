/// Rail module resolver — finds and loads imported modules.
///
/// Search order:
/// 1. Relative to the source file (current behavior)
/// 2. Embedded stdlib (compiled into binary)
/// 3. Project-local `stdlib/` directory
/// 4. `~/.rail/stdlib/` (global user stdlib)
/// 5. Stdlib directory next to the executable

use std::path::{Path, PathBuf};
use std::fs;
use crate::ast::*;
use crate::lexer::Lexer;
use crate::parser::Parser;
use crate::stdlib;

pub struct ModuleResolver {
    base_path: PathBuf,
    loaded: Vec<String>, // prevent circular imports
}

/// Source of a module — either a file on disk or embedded in the binary.
enum ModuleSource {
    File(PathBuf),
    Embedded(&'static str),
}

impl ModuleResolver {
    pub fn new(base_path: &Path) -> Self {
        ModuleResolver {
            base_path: base_path.to_path_buf(),
            loaded: Vec::new(),
        }
    }

    /// Resolve all imports in a program, returning additional declarations to prepend
    pub fn resolve_imports(&mut self, program: &Program) -> Result<Vec<Decl>, String> {
        let mut imported_decls = Vec::new();

        for decl in &program.declarations {
            if let Decl::ImportDecl { module, names } = decl {
                if self.loaded.contains(module) {
                    continue; // already loaded
                }
                self.loaded.push(module.clone());

                // Find the module source
                let source_text = self.load_module(module)?;

                // Parse it
                let mut lexer = Lexer::new(&source_text);
                let tokens = lexer.tokenize()
                    .map_err(|e| format!("lex error in module '{}': {}", module, e))?;
                let mut parser = Parser::new(tokens);
                let module_program = parser.parse_program()
                    .map_err(|e| format!("parse error in module '{}': {}", module, e))?;

                // Recursively resolve imports in the imported module
                let nested = self.resolve_imports(&module_program)?;
                imported_decls.extend(nested);

                // Filter by export list and import names
                let exports = self.get_exports(&module_program);

                for decl in module_program.declarations {
                    match &decl {
                        Decl::Func { name, .. } | Decl::TypeDecl { name, .. } | Decl::RecordDecl { name, .. } => {
                            // Check if this name should be imported
                            let should_import = match (&exports, names) {
                                (Some(exp), Some(wanted)) => exp.contains(name) && wanted.contains(name),
                                (Some(exp), None) => exp.contains(name), // import all exported
                                (None, Some(wanted)) => wanted.contains(name), // no export list, import requested
                                (None, None) => true, // import everything
                            };
                            if should_import {
                                imported_decls.push(decl);
                            }
                        }
                        _ => {} // skip module/export/import decls
                    }
                }
            }
        }

        Ok(imported_decls)
    }

    /// Load a module's source text, searching all resolution paths.
    fn load_module(&self, name: &str) -> Result<String, String> {
        match self.find_module(name)? {
            ModuleSource::File(path) => {
                fs::read_to_string(&path)
                    .map_err(|e| format!("cannot read module '{}': {}", name, e))
            }
            ModuleSource::Embedded(src) => Ok(src.to_string()),
        }
    }

    fn find_module(&self, name: &str) -> Result<ModuleSource, String> {
        let snake = to_snake_case(name);

        // 1. Relative to the source file
        let path = self.base_path.join(format!("{}.rail", snake));
        if path.exists() {
            return Ok(ModuleSource::File(path));
        }
        let path = self.base_path.join(format!("{}.rail", name.to_lowercase()));
        if path.exists() {
            return Ok(ModuleSource::File(path));
        }

        // 2. Embedded stdlib (compiled into binary)
        if let Some(_src) = stdlib::get_embedded(name) {
            return Ok(ModuleSource::Embedded(stdlib::get_embedded(name).unwrap()));
        }

        // 3. Project-local stdlib/ directory (walk up from base_path to find project root with rail.toml)
        if let Some(project_root) = find_project_root(&self.base_path) {
            let path = project_root.join("stdlib").join(format!("{}.rail", snake));
            if path.exists() {
                return Ok(ModuleSource::File(path));
            }
            let path = project_root.join("stdlib").join(format!("{}.rail", name.to_lowercase()));
            if path.exists() {
                return Ok(ModuleSource::File(path));
            }
        }

        // 4. ~/.rail/stdlib/
        if let Some(home) = home_dir() {
            let path = home.join(".rail").join("stdlib").join(format!("{}.rail", snake));
            if path.exists() {
                return Ok(ModuleSource::File(path));
            }
            let path = home.join(".rail").join("stdlib").join(format!("{}.rail", name.to_lowercase()));
            if path.exists() {
                return Ok(ModuleSource::File(path));
            }
        }

        // 5. Next to the executable
        if let Ok(exe) = std::env::current_exe() {
            if let Some(exe_dir) = exe.parent() {
                let path = exe_dir.join("stdlib").join(format!("{}.rail", snake));
                if path.exists() {
                    return Ok(ModuleSource::File(path));
                }
            }
        }

        Err(format!("module '{}' not found (tried {}.rail in local dir, embedded stdlib, project stdlib, ~/.rail/stdlib/, and executable dir)", name, snake))
    }

    fn get_exports(&self, program: &Program) -> Option<Vec<String>> {
        for decl in &program.declarations {
            if let Decl::ExportDecl { names } = decl {
                return Some(names.clone());
            }
        }
        None
    }
}

/// Convert PascalCase to snake_case
fn to_snake_case(name: &str) -> String {
    name.chars().enumerate().map(|(i, c)| {
        if c.is_uppercase() && i > 0 { format!("_{}", c.to_lowercase()) }
        else { c.to_lowercase().to_string() }
    }).collect::<String>()
}

/// Walk up the directory tree looking for a rail.toml to find the project root
fn find_project_root(start: &Path) -> Option<PathBuf> {
    let mut dir = if start.is_dir() {
        start.to_path_buf()
    } else {
        start.parent()?.to_path_buf()
    };
    loop {
        if dir.join("rail.toml").exists() {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

/// Get the user's home directory
fn home_dir() -> Option<PathBuf> {
    std::env::var("HOME").ok().map(PathBuf::from)
}

/// Return the list of stdlib search paths (for debugging)
pub fn stdlib_search_paths(base_path: &Path) -> Vec<String> {
    let mut paths = Vec::new();

    paths.push(format!("{} (source-relative)", base_path.display()));
    paths.push("(embedded in binary)".to_string());

    if let Some(root) = find_project_root(base_path) {
        paths.push(format!("{} (project stdlib)", root.join("stdlib").display()));
    }

    if let Some(home) = home_dir() {
        paths.push(format!("{} (user global)", home.join(".rail").join("stdlib").display()));
    }

    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            paths.push(format!("{} (bundled with executable)", exe_dir.join("stdlib").display()));
        }
    }

    paths
}
