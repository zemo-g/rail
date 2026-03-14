/// Rail AST — the abstract syntax tree.
/// Every Rail program is a list of declarations.
/// Every declaration is a function, type, property, or module directive.

/// Source location: (line, col)
pub type Span = (usize, usize);

#[allow(dead_code)]
#[derive(Debug, Clone)]
pub enum Decl {
    /// Function with optional type signature
    /// `add : i32 -> i32 -> i32`
    /// `add x y = x + y`
    Func {
        name: String,
        type_sig: Option<TypeExpr>,
        params: Vec<Pattern>,
        body: Expr,
        span: Span,
    },

    /// Algebraic data type
    /// `type Option T = | Some T | None`
    TypeDecl {
        name: String,
        params: Vec<String>,
        variants: Vec<Variant>,
    },

    /// Record type
    /// `type Point = { x: f64, y: f64 }`
    RecordDecl {
        name: String,
        params: Vec<String>,
        fields: Vec<(String, TypeExpr)>,
    },

    /// Property (built-in test)
    /// `prop add_commutative x y = add x y == add y x`
    Property {
        name: String,
        params: Vec<(String, TypeExpr)>,
        body: Expr,
    },

    /// Module declaration
    ModuleDecl { name: String },

    /// Export list
    ExportDecl { names: Vec<String> },

    /// Import
    ImportDecl {
        module: String,
        names: Option<Vec<String>>,
    },

    /// Effect declaration
    /// `effect LLM`
    ///   `ask : String -> String`
    EffectDecl {
        name: String,
        operations: Vec<EffectOp>,
    },
}

#[derive(Debug, Clone)]
pub struct Variant {
    pub name: String,
    pub fields: Vec<TypeExpr>,
}

/// An expression with source location tracking.
#[derive(Debug, Clone)]
pub struct Expr {
    pub kind: ExprKind,
    pub span: Span,
}

impl Expr {
    pub fn new(kind: ExprKind, span: Span) -> Self {
        Expr { kind, span }
    }

    /// Create an Expr with a default (0,0) span (for generated code / tests)
    #[allow(dead_code)]
    pub fn unspanned(kind: ExprKind) -> Self {
        Expr { kind, span: (0, 0) }
    }
}

#[allow(dead_code)]
#[derive(Debug, Clone)]
pub enum ExprKind {
    /// Integer literal
    IntLit(i64),

    /// Float literal
    FloatLit(f64),

    /// String literal
    StrLit(String),

    /// Boolean literal
    BoolLit(bool),

    /// Variable reference
    Var(String),

    /// Constructor (uppercase identifier)
    Constructor(String),

    /// Function application: `f x`
    App {
        func: Box<Expr>,
        arg: Box<Expr>,
    },

    /// Binary operator: `x + y`
    BinOp {
        op: String,
        left: Box<Expr>,
        right: Box<Expr>,
    },

    /// Unary operator: `-x`
    UnaryOp {
        op: String,
        operand: Box<Expr>,
    },

    /// Let binding: `let x = e1 in e2`
    Let {
        name: String,
        value: Box<Expr>,
        body: Box<Expr>,
    },

    /// If expression: `if cond then e1 else e2`
    If {
        cond: Box<Expr>,
        then_branch: Box<Expr>,
        else_branch: Box<Expr>,
    },

    /// Match expression
    Match {
        scrutinee: Box<Expr>,
        arms: Vec<MatchArm>,
    },

    /// Pipe: `x |> f` desugars to `f x`
    Pipe {
        value: Box<Expr>,
        func: Box<Expr>,
    },

    /// Lambda: `\x -> x + 1`
    Lambda {
        params: Vec<Pattern>,
        body: Box<Expr>,
    },

    /// Tuple: `(1, 2, 3)`
    Tuple(Vec<Expr>),

    /// List: `[1, 2, 3]`
    List(Vec<Expr>),

    /// Record literal: `{ x: 1, y: 2 }`
    Record(Vec<(String, Expr)>),

    /// Field access: `point.x`
    FieldAccess {
        expr: Box<Expr>,
        field: String,
    },

    /// Block (sequence of let-bindings ending in an expression)
    Block(Vec<Expr>),

    /// Perform an effect operation: `perform ask "hello"`
    Perform {
        op: String,
        args: Vec<Expr>,
    },

    /// Handle effects: `handle <body> with <handlers>`
    Handle {
        body: Box<Expr>,
        handlers: Vec<EffectHandler>,
    },

    /// Resume a continuation: `resume <value>`
    Resume(Box<Expr>),
}

#[derive(Debug, Clone)]
pub struct MatchArm {
    pub pattern: Pattern,
    pub body: Expr,
}

#[derive(Debug, Clone)]
pub enum Pattern {
    /// Wildcard: `_`
    Wildcard,

    /// Variable binding: `x`
    Var(String),

    /// Literal pattern
    IntLit(i64),
    FloatLit(f64),
    StrLit(String),
    BoolLit(bool),

    /// Constructor pattern: `Some x`
    Constructor {
        name: String,
        args: Vec<Pattern>,
    },

    /// Tuple pattern: `(x, y)`
    Tuple(Vec<Pattern>),
}

/// An operation declared within an effect
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct EffectOp {
    pub name: String,
    pub type_sig: TypeExpr,
}

/// A handler clause within a handle expression
#[derive(Debug, Clone)]
pub struct EffectHandler {
    pub op_name: String,
    pub params: Vec<Pattern>,
    pub body: Expr,
}

/// Type expressions
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub enum TypeExpr {
    /// Named type: `i32`, `bool`, `Option`
    Named(String),

    /// Type application: `Option i32`, `Result str Error`
    App {
        base: Box<TypeExpr>,
        args: Vec<TypeExpr>,
    },

    /// Function type: `i32 -> i32`
    Func {
        from: Box<TypeExpr>,
        to: Box<TypeExpr>,
    },

    /// Tuple type: `(i32, str)`
    Tuple(Vec<TypeExpr>),

    /// List type: `[i32]`
    List(Box<TypeExpr>),

    /// Optional: `i32?`
    Optional(Box<TypeExpr>),

    /// Result: `i32!str`
    Result {
        ok: Box<TypeExpr>,
        err: Box<TypeExpr>,
    },

    /// Record type: `{ x: f64, y: f64 }`
    Record(Vec<(String, TypeExpr)>),
}

/// A Rail program is a list of declarations
#[derive(Debug)]
pub struct Program {
    pub declarations: Vec<Decl>,
}
