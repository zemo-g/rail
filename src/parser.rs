/// Rail parser — transforms tokens into AST.
/// Recursive descent, handles indentation-based layout.

use crate::token::{Token, Spanned};
use crate::ast::*;

pub struct Parser {
    tokens: Vec<Spanned>,
    pos: usize,
}

#[derive(Debug)]
pub struct ParseError {
    pub message: String,
    pub line: usize,
    pub col: usize,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "parse error at {}:{}: {}", self.line, self.col, self.message)
    }
}

impl Parser {
    pub fn new(tokens: Vec<Spanned>) -> Self {
        Self { tokens, pos: 0 }
    }

    pub fn parse_program(&mut self) -> Result<Program, ParseError> {
        let mut declarations = Vec::new();

        self.skip_newlines();

        while !self.at_eof() {
            let decl = self.parse_declaration()?;
            declarations.push(decl);
            self.skip_newlines();
        }

        Ok(Program { declarations })
    }

    /// Get the current token's (line, col) as a Span
    fn current_span(&self) -> Span {
        if self.pos < self.tokens.len() {
            (self.tokens[self.pos].span.line, self.tokens[self.pos].span.col)
        } else {
            (0, 0)
        }
    }

    /// Create a spanned Expr from an ExprKind and a span
    fn spanned(&self, kind: ExprKind, span: Span) -> Expr {
        Expr::new(kind, span)
    }

    fn parse_declaration(&mut self) -> Result<Decl, ParseError> {
        self.skip_newlines();

        match self.peek_token() {
            Token::Type => self.parse_type_decl(),
            Token::Module => self.parse_module_decl(),
            Token::Export => self.parse_export_decl(),
            Token::Import => self.parse_import_decl(),
            Token::Prop => self.parse_property(),
            Token::Ident(_) => self.parse_func_decl(),
            _ => Err(self.error("expected declaration")),
        }
    }

    fn parse_func_decl(&mut self) -> Result<Decl, ParseError> {
        let span = self.current_span();
        let name = self.expect_ident()?;
        self.skip_newlines();

        // Check for type signature: `name : type`
        let type_sig = if self.check(&Token::Colon) {
            self.advance(); // eat :
            let sig = self.parse_type_expr()?;
            self.skip_newlines();

            // Now expect the function definition on the next line
            let def_name = self.expect_ident()?;
            if def_name != name {
                return Err(self.error(
                    &format!("type signature for '{}' but definition for '{}'", name, def_name),
                ));
            }
            Some(sig)
        } else {
            None
        };

        // Parse parameters
        let mut params = Vec::new();
        while !self.check(&Token::Equals) && !self.at_eof() {
            let pat = self.parse_simple_pattern()?;
            params.push(pat);
        }

        self.expect(&Token::Equals)?;
        self.skip_newlines();

        // Parse body
        let body = if self.check_token(&Token::Indent) {
            self.advance(); // eat Indent
            let expr = self.parse_block()?;
            if self.check_token(&Token::Dedent) {
                self.advance();
            }
            expr
        } else {
            self.parse_expr()?
        };

        Ok(Decl::Func { name, type_sig, params, body, span })
    }

    fn parse_type_decl(&mut self) -> Result<Decl, ParseError> {
        self.expect(&Token::Type)?;
        let name = self.expect_type_ident()?;

        // Optional type parameters
        let mut params = Vec::new();
        while let Token::TypeIdent(_) | Token::Ident(_) = self.peek_token() {
            if self.check(&Token::Equals) { break; }
            match self.peek_token() {
                Token::TypeIdent(s) | Token::Ident(s) => {
                    params.push(s.clone());
                    self.advance();
                }
                _ => break,
            }
        }

        self.expect(&Token::Equals)?;
        self.skip_newlines();

        // Check if it's a record or ADT
        if self.check(&Token::Bar) || (self.check_token(&Token::Indent) && self.peek_token_at(1) == Token::Bar) {
            // ADT
            let mut variants = Vec::new();

            if self.check_token(&Token::Indent) {
                self.advance();
            }

            while self.check(&Token::Bar) {
                self.advance(); // eat |
                let vname = self.expect_type_ident()?;
                let mut fields = Vec::new();
                while !self.check(&Token::Bar) && !self.check_token(&Token::Newline)
                    && !self.check_token(&Token::Dedent) && !self.at_eof()
                {
                    let ty = self.parse_type_atom()?;
                    fields.push(ty);
                }
                variants.push(Variant { name: vname, fields });
                self.skip_newlines();
            }

            if self.check_token(&Token::Dedent) {
                self.advance();
            }

            Ok(Decl::TypeDecl { name, params, variants })
        } else {
            // Record
            let mut fields = Vec::new();

            if self.check_token(&Token::Indent) {
                self.advance();
            }

            while !self.check_token(&Token::Dedent) && !self.at_eof() {
                let fname = self.expect_ident()?;
                self.expect(&Token::Colon)?;
                let ftype = self.parse_type_expr()?;
                fields.push((fname, ftype));
                self.skip_newlines();
            }

            if self.check_token(&Token::Dedent) {
                self.advance();
            }

            Ok(Decl::RecordDecl { name, params, fields })
        }
    }

    fn parse_module_decl(&mut self) -> Result<Decl, ParseError> {
        self.expect(&Token::Module)?;
        let name = self.expect_type_ident()?;
        Ok(Decl::ModuleDecl { name })
    }

    fn parse_export_decl(&mut self) -> Result<Decl, ParseError> {
        self.expect(&Token::Export)?;
        let mut names = Vec::new();
        let has_parens = self.check(&Token::LParen);
        if has_parens {
            self.advance();
        }
        if !has_parens || !self.check(&Token::RParen) {
            names.push(self.expect_ident()?);
            while self.check(&Token::Comma) {
                self.advance();
                names.push(self.expect_ident()?);
            }
        }
        if has_parens {
            self.expect(&Token::RParen)?;
        }
        Ok(Decl::ExportDecl { names })
    }

    fn parse_import_decl(&mut self) -> Result<Decl, ParseError> {
        self.expect(&Token::Import)?;
        let module = self.expect_type_ident()?;
        let names = if self.check(&Token::LParen) {
            self.advance();
            let mut ns = Vec::new();
            if !self.check(&Token::RParen) {
                ns.push(self.expect_ident()?);
                while self.check(&Token::Comma) {
                    self.advance();
                    ns.push(self.expect_ident()?);
                }
            }
            self.expect(&Token::RParen)?;
            Some(ns)
        } else {
            None
        };
        Ok(Decl::ImportDecl { module, names })
    }

    fn parse_property(&mut self) -> Result<Decl, ParseError> {
        self.expect(&Token::Prop)?;
        let name = self.expect_ident()?;

        // Properties need typed parameters: `prop name : T -> T -> bool`
        self.expect(&Token::Colon)?;
        let type_sig = self.parse_type_expr()?;

        // Now parse definition
        self.skip_newlines();
        let _def_name = self.expect_ident()?;

        let mut params = Vec::new();
        while !self.check(&Token::Equals) && !self.at_eof() {
            let pname = self.expect_ident()?;
            params.push((pname, TypeExpr::Named("_".to_string()))); // inferred from sig
        }

        self.expect(&Token::Equals)?;
        self.skip_newlines();

        let body = if self.check_token(&Token::Indent) {
            self.advance();
            let expr = self.parse_block()?;
            if self.check_token(&Token::Dedent) {
                self.advance();
            }
            expr
        } else {
            self.parse_expr()?
        };

        // Enrich params with types from signature
        let _ = type_sig; // TODO: extract param types from function type sig

        Ok(Decl::Property { name, params, body })
    }

    // ---- Expressions ----

    fn parse_block(&mut self) -> Result<Expr, ParseError> {
        let span = self.current_span();
        let mut exprs = Vec::new();

        loop {
            self.skip_newlines();
            if self.check_token(&Token::Dedent) || self.at_eof() {
                break;
            }
            let expr = self.parse_expr()?;
            exprs.push(expr);
            self.skip_newlines();
        }

        match exprs.len() {
            0 => Err(self.error("empty block")),
            1 => Ok(exprs.into_iter().next().unwrap()),
            _ => Ok(self.spanned(ExprKind::Block(exprs), span)),
        }
    }

    fn parse_expr(&mut self) -> Result<Expr, ParseError> {
        let expr = self.parse_pipe_expr()?;
        Ok(expr)
    }

    fn parse_pipe_expr(&mut self) -> Result<Expr, ParseError> {
        let mut expr = self.parse_let_expr()?;

        loop {
            // Allow pipes on the next line (multiline pipe chains)
            let saved_pos = self.pos;
            self.skip_newlines();
            if self.check(&Token::Pipe) {
                let span = self.current_span();
                self.advance(); // eat |>
                let func = self.parse_let_expr()?;
                expr = self.spanned(ExprKind::Pipe {
                    value: Box::new(expr),
                    func: Box::new(func),
                }, span);
            } else {
                // Not a pipe — restore position so block parser sees the newlines
                self.pos = saved_pos;
                break;
            }
        }

        Ok(expr)
    }

    fn parse_let_expr(&mut self) -> Result<Expr, ParseError> {
        if self.check(&Token::Let) {
            let span = self.current_span();
            self.advance(); // eat let
            let name = if self.check(&Token::Underscore) {
                self.advance();
                "_".to_string()
            } else {
                self.expect_ident()?
            };
            self.expect(&Token::Equals)?;
            let value = self.parse_expr()?;
            self.skip_newlines();

            // The body is the rest of the block
            let body = self.parse_expr()?;

            Ok(self.spanned(ExprKind::Let {
                name,
                value: Box::new(value),
                body: Box::new(body),
            }, span))
        } else if self.check(&Token::If) {
            self.parse_if_expr()
        } else if self.check(&Token::Match) {
            self.parse_match_expr()
        } else if self.check(&Token::Backslash) {
            self.parse_lambda()
        } else {
            self.parse_comparison()
        }
    }

    fn parse_if_expr(&mut self) -> Result<Expr, ParseError> {
        let span = self.current_span();
        self.expect(&Token::If)?;
        let cond = self.parse_expr()?;
        self.expect(&Token::Then)?;
        self.skip_newlines();
        let then_branch = self.parse_expr()?;
        self.skip_newlines();
        self.expect(&Token::Else)?;
        self.skip_newlines();
        let else_branch = self.parse_expr()?;

        Ok(self.spanned(ExprKind::If {
            cond: Box::new(cond),
            then_branch: Box::new(then_branch),
            else_branch: Box::new(else_branch),
        }, span))
    }

    fn parse_lambda(&mut self) -> Result<Expr, ParseError> {
        let span = self.current_span();
        self.expect(&Token::Backslash)?;
        let mut params = Vec::new();
        while !self.check(&Token::Arrow) && !self.at_eof() {
            params.push(self.parse_simple_pattern()?);
        }
        if params.is_empty() {
            return Err(self.error("lambda requires at least one parameter"));
        }
        self.expect(&Token::Arrow)?;
        self.skip_newlines();

        // Support multi-line lambda bodies (indented block)
        let body = if self.check_token(&Token::Indent) {
            self.advance(); // eat Indent
            let expr = self.parse_block()?;
            if self.check_token(&Token::Dedent) {
                self.advance();
            }
            expr
        } else {
            self.parse_expr()?
        };

        Ok(self.spanned(ExprKind::Lambda {
            params,
            body: Box::new(body),
        }, span))
    }

    fn parse_match_expr(&mut self) -> Result<Expr, ParseError> {
        let span = self.current_span();
        self.expect(&Token::Match)?;
        let scrutinee = self.parse_comparison()?;
        self.skip_newlines();

        let mut arms = Vec::new();

        if self.check_token(&Token::Indent) {
            self.advance();
        }

        while !self.check_token(&Token::Dedent) && !self.at_eof() {
            let pattern = self.parse_pattern()?;
            self.expect(&Token::Arrow)?;
            let body = self.parse_expr()?;
            arms.push(MatchArm { pattern, body });
            self.skip_newlines();
        }

        if self.check_token(&Token::Dedent) {
            self.advance();
        }

        Ok(self.spanned(ExprKind::Match {
            scrutinee: Box::new(scrutinee),
            arms,
        }, span))
    }

    fn parse_comparison(&mut self) -> Result<Expr, ParseError> {
        let mut left = self.parse_logical()?;

        while let Token::Operator(ref op) = self.peek_token() {
            if matches!(op.as_str(), "==" | "!=" | "<" | ">" | "<=" | ">=") {
                let span = self.current_span();
                let op = op.clone();
                self.advance();
                let right = self.parse_logical()?;
                left = self.spanned(ExprKind::BinOp {
                    op,
                    left: Box::new(left),
                    right: Box::new(right),
                }, span);
            } else {
                break;
            }
        }

        Ok(left)
    }

    fn parse_logical(&mut self) -> Result<Expr, ParseError> {
        let mut left = self.parse_additive()?;

        while let Token::Operator(ref op) = self.peek_token() {
            if matches!(op.as_str(), "&&" | "||") {
                let span = self.current_span();
                let op = op.clone();
                self.advance();
                let right = self.parse_additive()?;
                left = self.spanned(ExprKind::BinOp {
                    op,
                    left: Box::new(left),
                    right: Box::new(right),
                }, span);
            } else {
                break;
            }
        }

        Ok(left)
    }

    fn parse_additive(&mut self) -> Result<Expr, ParseError> {
        let mut left = self.parse_multiplicative()?;

        while let Token::Operator(ref op) = self.peek_token() {
            if matches!(op.as_str(), "+" | "-") {
                let span = self.current_span();
                let op = op.clone();
                self.advance();
                let right = self.parse_multiplicative()?;
                left = self.spanned(ExprKind::BinOp {
                    op,
                    left: Box::new(left),
                    right: Box::new(right),
                }, span);
            } else {
                break;
            }
        }

        Ok(left)
    }

    fn parse_multiplicative(&mut self) -> Result<Expr, ParseError> {
        let mut left = self.parse_unary()?;

        while let Token::Operator(ref op) = self.peek_token() {
            if matches!(op.as_str(), "*" | "/" | "%") {
                let span = self.current_span();
                let op = op.clone();
                self.advance();
                let right = self.parse_unary()?;
                left = self.spanned(ExprKind::BinOp {
                    op,
                    left: Box::new(left),
                    right: Box::new(right),
                }, span);
            } else {
                break;
            }
        }

        Ok(left)
    }

    fn parse_unary(&mut self) -> Result<Expr, ParseError> {
        if let Token::Operator(ref op) = self.peek_token() {
            if op == "-" {
                let span = self.current_span();
                let op = op.clone();
                self.advance();
                let operand = self.parse_application()?;
                return Ok(self.spanned(ExprKind::UnaryOp {
                    op,
                    operand: Box::new(operand),
                }, span));
            }
        }
        self.parse_application()
    }

    fn parse_application(&mut self) -> Result<Expr, ParseError> {
        let func = self.parse_field_access()?;

        // Collect arguments (atoms with field access that follow)
        let mut args = Vec::new();
        loop {
            match self.peek_token() {
                Token::Int(_) | Token::Float(_) | Token::Str(_) | Token::Bool(_)
                | Token::Ident(_) | Token::LParen | Token::LBracket | Token::LBrace
                | Token::TypeIdent(_) => {
                    let arg = self.parse_field_access()?;
                    args.push(arg);
                }
                _ => break,
            }
        }

        if args.is_empty() {
            Ok(func)
        } else {
            let mut result = func;
            for arg in args {
                let span = result.span;
                result = self.spanned(ExprKind::App {
                    func: Box::new(result),
                    arg: Box::new(arg),
                }, span);
            }
            Ok(result)
        }
    }

    fn parse_field_access(&mut self) -> Result<Expr, ParseError> {
        let mut expr = self.parse_atom()?;

        while self.check(&Token::Dot) {
            let span = self.current_span();
            self.advance();
            let field = self.expect_ident()?;
            expr = self.spanned(ExprKind::FieldAccess {
                expr: Box::new(expr),
                field,
            }, span);
        }

        Ok(expr)
    }

    fn parse_atom(&mut self) -> Result<Expr, ParseError> {
        let span = self.current_span();
        match self.peek_token() {
            Token::Int(n) => {
                let n = n;
                self.advance();
                Ok(self.spanned(ExprKind::IntLit(n), span))
            }
            Token::Float(f) => {
                let f = f;
                self.advance();
                Ok(self.spanned(ExprKind::FloatLit(f), span))
            }
            Token::Str(s) => {
                let s = s.clone();
                self.advance();
                Ok(self.spanned(ExprKind::StrLit(s), span))
            }
            Token::Bool(b) => {
                let b = b;
                self.advance();
                Ok(self.spanned(ExprKind::BoolLit(b), span))
            }
            Token::Ident(name) => {
                let name = name.clone();
                self.advance();
                Ok(self.spanned(ExprKind::Var(name), span))
            }
            Token::TypeIdent(name) => {
                let name = name.clone();
                self.advance();
                Ok(self.spanned(ExprKind::Constructor(name), span))
            }
            Token::LParen => {
                self.advance();
                if self.check(&Token::RParen) {
                    self.advance();
                    return Ok(self.spanned(ExprKind::Tuple(vec![]), span)); // unit
                }

                // Check for operator section: `(+ 1)` or `(> 0)`
                if let Token::Operator(_) = self.peek_token() {
                    // Could be an operator section or a parenthesized negative
                    // For now, parse as expression
                }

                let expr = self.parse_expr()?;

                if self.check(&Token::Comma) {
                    // Tuple
                    let mut elements = vec![expr];
                    while self.check(&Token::Comma) {
                        self.advance();
                        elements.push(self.parse_expr()?);
                    }
                    self.expect(&Token::RParen)?;
                    Ok(self.spanned(ExprKind::Tuple(elements), span))
                } else {
                    self.expect(&Token::RParen)?;
                    Ok(expr)
                }
            }
            Token::LBracket => {
                self.advance();
                let mut elements = Vec::new();
                if !self.check(&Token::RBracket) {
                    elements.push(self.parse_expr()?);
                    while self.check(&Token::Comma) {
                        self.advance();
                        elements.push(self.parse_expr()?);
                    }
                }
                self.expect(&Token::RBracket)?;
                Ok(self.spanned(ExprKind::List(elements), span))
            }
            Token::LBrace => {
                self.advance();
                let mut fields = Vec::new();
                if !self.check(&Token::RBrace) {
                    let name = self.expect_ident()?;
                    self.expect(&Token::Colon)?;
                    let value = self.parse_expr()?;
                    fields.push((name, value));
                    while self.check(&Token::Comma) {
                        self.advance();
                        let name = self.expect_ident()?;
                        self.expect(&Token::Colon)?;
                        let value = self.parse_expr()?;
                        fields.push((name, value));
                    }
                }
                self.expect(&Token::RBrace)?;
                Ok(self.spanned(ExprKind::Record(fields), span))
            }
            _ => Err(self.error(&format!("expected expression, got {:?}", self.peek_token()))),
        }
    }

    // ---- Patterns ----

    fn parse_pattern(&mut self) -> Result<Pattern, ParseError> {
        match self.peek_token() {
            Token::Underscore => {
                self.advance();
                Ok(Pattern::Wildcard)
            }
            Token::Int(n) => {
                let n = n;
                self.advance();
                Ok(Pattern::IntLit(n))
            }
            Token::Float(f) => {
                let f = f;
                self.advance();
                Ok(Pattern::FloatLit(f))
            }
            Token::Str(s) => {
                let s = s.clone();
                self.advance();
                Ok(Pattern::StrLit(s))
            }
            Token::Bool(b) => {
                let b = b;
                self.advance();
                Ok(Pattern::BoolLit(b))
            }
            Token::Ident(name) => {
                let name = name.clone();
                self.advance();
                Ok(Pattern::Var(name))
            }
            Token::TypeIdent(name) => {
                let name = name.clone();
                self.advance();
                let mut args = Vec::new();
                // Collect pattern arguments until we hit ->
                while !self.check(&Token::Arrow) && !self.check_token(&Token::Newline)
                    && !self.check_token(&Token::Dedent) && !self.at_eof()
                {
                    args.push(self.parse_simple_pattern()?);
                }
                Ok(Pattern::Constructor { name, args })
            }
            Token::LParen => {
                self.advance();
                let mut pats = Vec::new();
                if !self.check(&Token::RParen) {
                    pats.push(self.parse_pattern()?);
                    while self.check(&Token::Comma) {
                        self.advance();
                        pats.push(self.parse_pattern()?);
                    }
                }
                self.expect(&Token::RParen)?;
                Ok(Pattern::Tuple(pats))
            }
            _ => Err(self.error(&format!("expected pattern, got {:?}", self.peek_token()))),
        }
    }

    fn parse_simple_pattern(&mut self) -> Result<Pattern, ParseError> {
        match self.peek_token() {
            Token::Underscore => { self.advance(); Ok(Pattern::Wildcard) }
            Token::Ident(name) => {
                let name = name.clone();
                self.advance();
                Ok(Pattern::Var(name))
            }
            Token::Int(n) => {
                let n = n;
                self.advance();
                Ok(Pattern::IntLit(n))
            }
            Token::LParen => {
                self.advance();
                let mut pats = Vec::new();
                if !self.check(&Token::RParen) {
                    pats.push(self.parse_pattern()?);
                    while self.check(&Token::Comma) {
                        self.advance();
                        pats.push(self.parse_pattern()?);
                    }
                }
                self.expect(&Token::RParen)?;
                Ok(Pattern::Tuple(pats))
            }
            _ => Err(self.error("expected pattern")),
        }
    }

    // ---- Type expressions ----

    fn parse_type_expr(&mut self) -> Result<TypeExpr, ParseError> {
        let ty = self.parse_type_atom()?;

        // Check for function type: T -> U
        if self.check(&Token::Arrow) {
            self.advance();
            let ret = self.parse_type_expr()?; // right-associative
            Ok(TypeExpr::Func {
                from: Box::new(ty),
                to: Box::new(ret),
            })
        } else if self.check(&Token::Question) {
            self.advance();
            Ok(TypeExpr::Optional(Box::new(ty)))
        } else if self.check(&Token::Bang) {
            self.advance();
            let err = self.parse_type_atom()?;
            Ok(TypeExpr::Result {
                ok: Box::new(ty),
                err: Box::new(err),
            })
        } else {
            Ok(ty)
        }
    }

    fn parse_type_atom(&mut self) -> Result<TypeExpr, ParseError> {
        match self.peek_token() {
            Token::Ident(name) | Token::TypeIdent(name) => {
                let name = name.clone();
                self.advance();
                Ok(TypeExpr::Named(name))
            }
            Token::LParen => {
                self.advance();
                if self.check(&Token::RParen) {
                    self.advance();
                    return Ok(TypeExpr::Tuple(vec![])); // unit
                }
                let ty = self.parse_type_expr()?;
                if self.check(&Token::Comma) {
                    let mut types = vec![ty];
                    while self.check(&Token::Comma) {
                        self.advance();
                        types.push(self.parse_type_expr()?);
                    }
                    self.expect(&Token::RParen)?;
                    Ok(TypeExpr::Tuple(types))
                } else {
                    self.expect(&Token::RParen)?;
                    Ok(ty)
                }
            }
            Token::LBracket => {
                self.advance();
                let inner = self.parse_type_expr()?;
                self.expect(&Token::RBracket)?;
                Ok(TypeExpr::List(Box::new(inner)))
            }
            Token::LBrace => {
                self.advance();
                let mut fields = Vec::new();
                if !self.check(&Token::RBrace) {
                    let name = self.expect_ident()?;
                    self.expect(&Token::Colon)?;
                    let ty = self.parse_type_expr()?;
                    fields.push((name, ty));
                    while self.check(&Token::Comma) {
                        self.advance();
                        let name = self.expect_ident()?;
                        self.expect(&Token::Colon)?;
                        let ty = self.parse_type_expr()?;
                        fields.push((name, ty));
                    }
                }
                self.expect(&Token::RBrace)?;
                Ok(TypeExpr::Record(fields))
            }
            _ => Err(self.error(&format!("expected type, got {:?}", self.peek_token()))),
        }
    }

    // ---- Helpers ----

    fn peek_token(&self) -> Token {
        if self.pos < self.tokens.len() {
            self.tokens[self.pos].token.clone()
        } else {
            Token::EOF
        }
    }

    fn peek_token_at(&self, offset: usize) -> Token {
        let idx = self.pos + offset;
        if idx < self.tokens.len() {
            self.tokens[idx].token.clone()
        } else {
            Token::EOF
        }
    }

    fn advance(&mut self) {
        if self.pos < self.tokens.len() {
            self.pos += 1;
        }
    }

    fn check(&self, token: &Token) -> bool {
        self.peek_token() == *token
    }

    fn check_token(&self, token: &Token) -> bool {
        std::mem::discriminant(&self.peek_token()) == std::mem::discriminant(token)
    }

    fn expect(&mut self, token: &Token) -> Result<(), ParseError> {
        if self.check(token) {
            self.advance();
            Ok(())
        } else {
            Err(self.error(&format!("expected {:?}, got {:?}", token, self.peek_token())))
        }
    }

    fn expect_ident(&mut self) -> Result<String, ParseError> {
        match self.peek_token() {
            Token::Ident(name) => {
                self.advance();
                Ok(name)
            }
            _ => Err(self.error(&format!("expected identifier, got {:?}", self.peek_token()))),
        }
    }

    fn expect_type_ident(&mut self) -> Result<String, ParseError> {
        match self.peek_token() {
            Token::TypeIdent(name) => {
                self.advance();
                Ok(name)
            }
            _ => Err(self.error(&format!("expected type name, got {:?}", self.peek_token()))),
        }
    }

    fn skip_newlines(&mut self) {
        while matches!(self.peek_token(), Token::Newline | Token::Comment(_)) {
            self.advance();
        }
    }

    fn at_eof(&self) -> bool {
        self.peek_token() == Token::EOF
    }

    fn error(&self, message: &str) -> ParseError {
        let (line, col) = if self.pos < self.tokens.len() {
            (self.tokens[self.pos].span.line, self.tokens[self.pos].span.col)
        } else {
            (0, 0)
        };
        ParseError {
            message: message.to_string(),
            line,
            col,
        }
    }
}
