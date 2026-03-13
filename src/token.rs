/// Rail tokens — the atomic units of the language.
/// Kept minimal: ~30 token types for ~30 grammar rules.

#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    // Literals
    Int(i64),
    Float(f64),
    Str(String),
    Bool(bool),

    // Identifiers and operators
    Ident(String),       // lowercase start: variables, functions
    TypeIdent(String),   // uppercase start: types
    Operator(String),    // +, -, *, /, ==, !=, <, >, <=, >=, &&, ||

    // Keywords
    Let,
    Match,
    Type,
    Module,
    Export,
    Import,
    Prop,
    Mut,
    If,
    Then,
    Else,
    Do,

    // Symbols
    Arrow,       // ->
    FatArrow,    // =>
    Pipe,        // |>
    Colon,       // :
    Equals,      // =
    Bar,         // |
    Comma,       // ,
    Dot,         // .
    LParen,      // (
    RParen,      // )
    LBracket,    // [
    RBracket,    // ]
    LBrace,      // {
    RBrace,      // }
    Question,    // ?
    Bang,        // !
    Underscore,  // _
    Backslash,   // \

    // Layout
    Newline,
    Indent,      // increase in indentation
    Dedent,      // decrease in indentation

    // Special
    Comment(String),
    EOF,
}

#[derive(Debug, Clone)]
pub struct Span {
    pub line: usize,
    pub col: usize,
    pub len: usize,
}

#[derive(Debug, Clone)]
pub struct Spanned {
    pub token: Token,
    pub span: Span,
}

impl Spanned {
    pub fn new(token: Token, line: usize, col: usize, len: usize) -> Self {
        Self {
            token,
            span: Span { line, col, len },
        }
    }
}
