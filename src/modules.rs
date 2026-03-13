/// Rail module resolver — finds and loads imported modules.

use std::path::{Path, PathBuf};
use std::fs;
use crate::ast::*;
use crate::lexer::Lexer;
use crate::parser::Parser;

pub struct ModuleResolver {
    base_path: PathBuf,
    loaded: Vec<String>, // prevent circular imports
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

                // Find the module file
                let module_path = self.find_module(module)?;

                // Parse it
                let source = fs::read_to_string(&module_path)
                    .map_err(|e| format!("cannot read module '{}': {}", module, e))?;
                let mut lexer = Lexer::new(&source);
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

    fn find_module(&self, name: &str) -> Result<PathBuf, String> {
        // Try: same directory as importing file
        // Convention: ModuleName → module_name.rail (snake_case)
        let snake = name.chars().enumerate().map(|(i, c)| {
            if c.is_uppercase() && i > 0 { format!("_{}", c.to_lowercase()) }
            else { c.to_lowercase().to_string() }
        }).collect::<String>();

        let path = self.base_path.join(format!("{}.rail", snake));
        if path.exists() {
            return Ok(path);
        }

        // Also try exact name lowercase
        let path = self.base_path.join(format!("{}.rail", name.to_lowercase()));
        if path.exists() {
            return Ok(path);
        }

        Err(format!("module '{}' not found (tried {}.rail)", name, snake))
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
