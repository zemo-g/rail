/// Rail lexer — transforms source text into tokens.
/// Handles indentation-based scoping by emitting Indent/Dedent tokens.

use crate::token::{Token, Spanned};

pub struct Lexer {
    source: Vec<char>,
    pos: usize,
    line: usize,
    col: usize,
    indent_stack: Vec<usize>,
    pending_dedents: usize,
    at_line_start: bool,
}

impl Lexer {
    pub fn new(source: &str) -> Self {
        Self {
            source: source.chars().collect(),
            pos: 0,
            line: 1,
            col: 1,
            indent_stack: vec![0],
            pending_dedents: 0,
            at_line_start: true,
        }
    }

    pub fn tokenize(&mut self) -> Result<Vec<Spanned>, LexError> {
        let mut tokens = Vec::new();

        while self.pos < self.source.len() {
            // Emit pending dedents
            while self.pending_dedents > 0 {
                tokens.push(Spanned::new(Token::Dedent, self.line, self.col, 0));
                self.pending_dedents -= 1;
            }

            // Handle line starts (indentation)
            if self.at_line_start {
                self.handle_indentation(&mut tokens)?;
                self.at_line_start = false;
                continue;
            }

            let ch = self.peek();

            match ch {
                // Skip spaces (not at line start)
                ' ' => { self.advance(); }

                // Newlines
                '\n' => {
                    tokens.push(Spanned::new(Token::Newline, self.line, self.col, 1));
                    self.advance();
                    self.at_line_start = true;
                }

                '\r' => {
                    self.advance();
                    if self.peek() == '\n' {
                        self.advance();
                    }
                    tokens.push(Spanned::new(Token::Newline, self.line, self.col, 1));
                    self.at_line_start = true;
                }

                // Comments
                '-' if self.peek_at(1) == '-' => {
                    let start_col = self.col;
                    self.advance(); // -
                    self.advance(); // -
                    let mut text = String::new();
                    while self.pos < self.source.len() && self.peek() != '\n' {
                        text.push(self.peek());
                        self.advance();
                    }
                    tokens.push(Spanned::new(
                        Token::Comment(text.trim().to_string()),
                        self.line, start_col, self.col - start_col,
                    ));
                }

                // Strings
                '"' => {
                    let tok = self.lex_string()?;
                    tokens.push(tok);
                }

                // Numbers
                '0'..='9' => {
                    let tok = self.lex_number()?;
                    tokens.push(tok);
                }

                // Identifiers, keywords, type names
                'a'..='z' | '_' => {
                    let tok = self.lex_identifier();
                    tokens.push(tok);
                }

                'A'..='Z' => {
                    let tok = self.lex_type_identifier();
                    tokens.push(tok);
                }

                // Operators and symbols
                '|' => {
                    let start_col = self.col;
                    self.advance();
                    if self.peek() == '>' {
                        self.advance();
                        tokens.push(Spanned::new(Token::Pipe, self.line, start_col, 2));
                    } else if self.peek() == '|' {
                        self.advance();
                        tokens.push(Spanned::new(
                            Token::Operator("||".to_string()),
                            self.line, start_col, 2,
                        ));
                    } else {
                        tokens.push(Spanned::new(Token::Bar, self.line, start_col, 1));
                    }
                }

                '-' => {
                    let start_col = self.col;
                    self.advance();
                    if self.peek() == '>' {
                        self.advance();
                        tokens.push(Spanned::new(Token::Arrow, self.line, start_col, 2));
                    } else {
                        tokens.push(Spanned::new(
                            Token::Operator("-".to_string()),
                            self.line, start_col, 1,
                        ));
                    }
                }

                '=' => {
                    let start_col = self.col;
                    self.advance();
                    if self.peek() == '>' {
                        self.advance();
                        tokens.push(Spanned::new(Token::FatArrow, self.line, start_col, 2));
                    } else if self.peek() == '=' {
                        self.advance();
                        tokens.push(Spanned::new(
                            Token::Operator("==".to_string()),
                            self.line, start_col, 2,
                        ));
                    } else {
                        tokens.push(Spanned::new(Token::Equals, self.line, start_col, 1));
                    }
                }

                ':' => {
                    let start_col = self.col;
                    self.advance();
                    tokens.push(Spanned::new(Token::Colon, self.line, start_col, 1));
                }

                ',' => {
                    let start_col = self.col;
                    self.advance();
                    tokens.push(Spanned::new(Token::Comma, self.line, start_col, 1));
                }

                '.' => {
                    let start_col = self.col;
                    self.advance();
                    tokens.push(Spanned::new(Token::Dot, self.line, start_col, 1));
                }

                '(' => {
                    let start_col = self.col;
                    self.advance();
                    tokens.push(Spanned::new(Token::LParen, self.line, start_col, 1));
                }

                ')' => {
                    let start_col = self.col;
                    self.advance();
                    tokens.push(Spanned::new(Token::RParen, self.line, start_col, 1));
                }

                '[' => {
                    let start_col = self.col;
                    self.advance();
                    tokens.push(Spanned::new(Token::LBracket, self.line, start_col, 1));
                }

                ']' => {
                    let start_col = self.col;
                    self.advance();
                    tokens.push(Spanned::new(Token::RBracket, self.line, start_col, 1));
                }

                '{' => {
                    let start_col = self.col;
                    self.advance();
                    tokens.push(Spanned::new(Token::LBrace, self.line, start_col, 1));
                }

                '}' => {
                    let start_col = self.col;
                    self.advance();
                    tokens.push(Spanned::new(Token::RBrace, self.line, start_col, 1));
                }

                '?' => {
                    let start_col = self.col;
                    self.advance();
                    tokens.push(Spanned::new(Token::Question, self.line, start_col, 1));
                }

                '!' => {
                    let start_col = self.col;
                    self.advance();
                    if self.peek() == '=' {
                        self.advance();
                        tokens.push(Spanned::new(
                            Token::Operator("!=".to_string()),
                            self.line, start_col, 2,
                        ));
                    } else {
                        tokens.push(Spanned::new(Token::Bang, self.line, start_col, 1));
                    }
                }

                '+' | '*' | '/' | '%' => {
                    let start_col = self.col;
                    let op = ch.to_string();
                    self.advance();
                    tokens.push(Spanned::new(
                        Token::Operator(op),
                        self.line, start_col, 1,
                    ));
                }

                '<' => {
                    let start_col = self.col;
                    self.advance();
                    if self.peek() == '=' {
                        self.advance();
                        tokens.push(Spanned::new(
                            Token::Operator("<=".to_string()),
                            self.line, start_col, 2,
                        ));
                    } else {
                        tokens.push(Spanned::new(
                            Token::Operator("<".to_string()),
                            self.line, start_col, 1,
                        ));
                    }
                }

                '>' => {
                    let start_col = self.col;
                    self.advance();
                    if self.peek() == '=' {
                        self.advance();
                        tokens.push(Spanned::new(
                            Token::Operator(">=".to_string()),
                            self.line, start_col, 2,
                        ));
                    } else {
                        tokens.push(Spanned::new(
                            Token::Operator(">".to_string()),
                            self.line, start_col, 1,
                        ));
                    }
                }

                '\\' => {
                    let start_col = self.col;
                    self.advance();
                    tokens.push(Spanned::new(Token::Backslash, self.line, start_col, 1));
                }

                '&' if self.peek_at(1) == '&' => {
                    let start_col = self.col;
                    self.advance();
                    self.advance();
                    tokens.push(Spanned::new(
                        Token::Operator("&&".to_string()),
                        self.line, start_col, 2,
                    ));
                }

                other => {
                    return Err(LexError {
                        message: format!("unexpected character: '{}'", other),
                        line: self.line,
                        col: self.col,
                    });
                }
            }
        }

        // Emit final dedents
        while self.indent_stack.len() > 1 {
            self.indent_stack.pop();
            tokens.push(Spanned::new(Token::Dedent, self.line, self.col, 0));
        }

        tokens.push(Spanned::new(Token::EOF, self.line, self.col, 0));
        Ok(tokens)
    }

    fn handle_indentation(&mut self, tokens: &mut Vec<Spanned>) -> Result<(), LexError> {
        let mut spaces = 0;

        while self.pos < self.source.len() && self.peek() == ' ' {
            spaces += 1;
            self.advance();
        }

        // Skip blank lines
        if self.pos >= self.source.len() || self.peek() == '\n' || self.peek() == '\r' {
            return Ok(());
        }

        // Skip comment-only lines for indentation purposes
        if self.peek() == '-' && self.peek_at(1) == '-' {
            return Ok(());
        }

        let current_indent = *self.indent_stack.last().unwrap();

        if spaces > current_indent {
            self.indent_stack.push(spaces);
            tokens.push(Spanned::new(Token::Indent, self.line, 1, spaces));
        } else if spaces < current_indent {
            while *self.indent_stack.last().unwrap() > spaces {
                self.indent_stack.pop();
                tokens.push(Spanned::new(Token::Dedent, self.line, 1, 0));
            }
            if *self.indent_stack.last().unwrap() != spaces {
                return Err(LexError {
                    message: format!("inconsistent indentation: expected {} spaces, got {}",
                        self.indent_stack.last().unwrap(), spaces),
                    line: self.line,
                    col: 1,
                });
            }
        }

        Ok(())
    }

    fn lex_string(&mut self) -> Result<Spanned, LexError> {
        use crate::token::InterpPart;
        let start_col = self.col;
        let start_line = self.line;
        self.advance(); // opening "

        let mut value = String::new();
        let mut has_interp = false;
        let mut parts: Vec<InterpPart> = Vec::new();

        loop {
            if self.pos >= self.source.len() {
                return Err(LexError {
                    message: "unterminated string".to_string(),
                    line: start_line,
                    col: start_col,
                });
            }
            let ch = self.peek();
            match ch {
                '"' => {
                    self.advance();
                    break;
                }
                '{' => {
                    has_interp = true;
                    self.advance(); // eat {
                    // Save the literal part so far
                    if !value.is_empty() {
                        parts.push(InterpPart::Lit(std::mem::take(&mut value)));
                    }
                    // Collect expression text until matching }
                    let mut expr_text = String::new();
                    let mut depth = 1;
                    while self.pos < self.source.len() {
                        let c = self.peek();
                        if c == '{' { depth += 1; }
                        if c == '}' {
                            depth -= 1;
                            if depth == 0 { self.advance(); break; }
                        }
                        expr_text.push(c);
                        self.advance();
                    }
                    if depth != 0 {
                        return Err(LexError {
                            message: "unterminated interpolation in string".to_string(),
                            line: self.line,
                            col: self.col,
                        });
                    }
                    parts.push(InterpPart::Expr(expr_text));
                }
                '\\' => {
                    self.advance();
                    if self.pos >= self.source.len() {
                        return Err(LexError {
                            message: "unterminated escape in string".to_string(),
                            line: self.line,
                            col: self.col,
                        });
                    }
                    match self.peek() {
                        'n' => { value.push('\n'); self.advance(); }
                        't' => { value.push('\t'); self.advance(); }
                        '\\' => { value.push('\\'); self.advance(); }
                        '"' => { value.push('"'); self.advance(); }
                        '{' => { value.push('{'); self.advance(); }
                        '}' => { value.push('}'); self.advance(); }
                        other => {
                            return Err(LexError {
                                message: format!("unknown escape: \\{}", other),
                                line: self.line,
                                col: self.col,
                            });
                        }
                    }
                }
                _ => {
                    value.push(ch);
                    self.advance();
                }
            }
        }

        if has_interp {
            if !value.is_empty() {
                parts.push(InterpPart::Lit(value));
            }
            Ok(Spanned::new(Token::InterpStr(parts), start_line, start_col, self.col - start_col))
        } else {
            Ok(Spanned::new(Token::Str(value), start_line, start_col, self.col - start_col))
        }
    }

    fn lex_number(&mut self) -> Result<Spanned, LexError> {
        let start_col = self.col;
        let mut num_str = String::new();
        let mut is_float = false;

        while self.pos < self.source.len() {
            let ch = self.peek();
            match ch {
                '0'..='9' => {
                    num_str.push(ch);
                    self.advance();
                }
                '.' if !is_float => {
                    // Check next char is a digit (not a method call)
                    if self.peek_at(1).is_ascii_digit() {
                        is_float = true;
                        num_str.push('.');
                        self.advance();
                    } else {
                        break;
                    }
                }
                '_' => { self.advance(); } // numeric separator, skip
                _ => break,
            }
        }

        if is_float {
            let val: f64 = num_str.parse().map_err(|_| LexError {
                message: format!("invalid float: {}", num_str),
                line: self.line,
                col: start_col,
            })?;
            Ok(Spanned::new(Token::Float(val), self.line, start_col, self.col - start_col))
        } else {
            let val: i64 = num_str.parse().map_err(|_| LexError {
                message: format!("invalid integer: {}", num_str),
                line: self.line,
                col: start_col,
            })?;
            Ok(Spanned::new(Token::Int(val), self.line, start_col, self.col - start_col))
        }
    }

    fn lex_identifier(&mut self) -> Spanned {
        let start_col = self.col;
        let mut name = String::new();

        while self.pos < self.source.len() {
            let ch = self.peek();
            if ch.is_alphanumeric() || ch == '_' {
                name.push(ch);
                self.advance();
            } else {
                break;
            }
        }

        let token = match name.as_str() {
            "let" => Token::Let,
            "match" => Token::Match,
            "type" => Token::Type,
            "module" => Token::Module,
            "export" => Token::Export,
            "import" => Token::Import,
            "prop" => Token::Prop,
            "mut" => Token::Mut,
            "if" => Token::If,
            "then" => Token::Then,
            "else" => Token::Else,
            "do" => Token::Do,
            "effect" => Token::Effect,
            "perform" => Token::Perform,
            "handle" => Token::Handle,
            "with" => Token::With,
            "resume" => Token::Resume,
            "true" => Token::Bool(true),
            "false" => Token::Bool(false),
            "_" => Token::Underscore,
            _ => Token::Ident(name),
        };

        Spanned::new(token, self.line, start_col, self.col - start_col)
    }

    fn lex_type_identifier(&mut self) -> Spanned {
        let start_col = self.col;
        let mut name = String::new();

        while self.pos < self.source.len() {
            let ch = self.peek();
            if ch.is_alphanumeric() || ch == '_' {
                name.push(ch);
                self.advance();
            } else {
                break;
            }
        }

        Spanned::new(Token::TypeIdent(name), self.line, start_col, self.col - start_col)
    }

    fn peek(&self) -> char {
        if self.pos < self.source.len() {
            self.source[self.pos]
        } else {
            '\0'
        }
    }

    fn peek_at(&self, offset: usize) -> char {
        let idx = self.pos + offset;
        if idx < self.source.len() {
            self.source[idx]
        } else {
            '\0'
        }
    }

    fn advance(&mut self) {
        if self.pos < self.source.len() {
            if self.source[self.pos] == '\n' {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.pos += 1;
        }
    }
}

#[derive(Debug)]
pub struct LexError {
    pub message: String,
    pub line: usize,
    pub col: usize,
}

impl std::fmt::Display for LexError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "error at {}:{}: {}", self.line, self.col, self.message)
    }
}
