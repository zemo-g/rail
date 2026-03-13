/// Rail interpreter — tree-walking evaluator.
/// Evaluates a parsed AST by walking the tree directly.
/// Supports curried functions, pattern matching, ADTs, records, and recursion.
/// Uses trampoline-based tail call optimization (TCO) for recursive tail calls.

use std::collections::HashMap;
use std::fmt;
use std::io::Write;
use crate::ast::*;
use crate::ai;
use crate::route::Route;

// ---- JSON parser (minimal, no deps) ----

fn parse_json_value(s: &str) -> Result<Value, String> {
    let s = s.trim();
    if s.is_empty() {
        return Err("empty input".into());
    }
    let (val, _) = parse_json_inner(s)?;
    Ok(val)
}

fn parse_json_inner(s: &str) -> Result<(Value, &str), String> {
    let s = s.trim_start();
    if s.is_empty() {
        return Err("unexpected end of input".into());
    }
    match s.as_bytes()[0] {
        b'"' => {
            let rest = &s[1..];
            let mut escaped = String::new();
            let mut chars = rest.chars();
            loop {
                match chars.next() {
                    None => return Err("unterminated string".into()),
                    Some('\\') => {
                        match chars.next() {
                            Some('n') => escaped.push('\n'),
                            Some('t') => escaped.push('\t'),
                            Some('r') => escaped.push('\r'),
                            Some('"') => escaped.push('"'),
                            Some('\\') => escaped.push('\\'),
                            Some('/') => escaped.push('/'),
                            Some(c) => { escaped.push('\\'); escaped.push(c); }
                            None => return Err("unterminated escape".into()),
                        }
                    }
                    Some('"') => {
                        let remaining = chars.as_str();
                        return Ok((Value::Str(escaped), remaining));
                    }
                    Some(c) => escaped.push(c),
                }
            }
        }
        b'{' => {
            let mut rest = s[1..].trim_start();
            let mut pairs = Vec::new();
            if rest.starts_with('}') {
                return Ok((Value::List(pairs), &rest[1..]));
            }
            loop {
                let (key, r) = parse_json_inner(rest)?;
                let key_str = match key {
                    Value::Str(s) => s,
                    _ => return Err("expected string key".into()),
                };
                let r = r.trim_start();
                if !r.starts_with(':') {
                    return Err("expected ':' after key".into());
                }
                let (val, r) = parse_json_inner(&r[1..])?;
                pairs.push(Value::Tuple(vec![Value::Str(key_str), val]));
                let r = r.trim_start();
                if r.starts_with('}') {
                    return Ok((Value::List(pairs), &r[1..]));
                }
                if r.starts_with(',') {
                    rest = r[1..].trim_start();
                } else {
                    return Err(format!("expected ',' or '}}' in object, got {:?}", &r[..r.len().min(20)]));
                }
            }
        }
        b'[' => {
            let mut rest = s[1..].trim_start();
            let mut items = Vec::new();
            if rest.starts_with(']') {
                return Ok((Value::List(items), &rest[1..]));
            }
            loop {
                let (val, r) = parse_json_inner(rest)?;
                items.push(val);
                let r = r.trim_start();
                if r.starts_with(']') {
                    return Ok((Value::List(items), &r[1..]));
                }
                if r.starts_with(',') {
                    rest = r[1..].trim_start();
                } else {
                    return Err(format!("expected ',' or ']' in array, got {:?}", &r[..r.len().min(20)]));
                }
            }
        }
        b't' if s.starts_with("true") => Ok((Value::Bool(true), &s[4..])),
        b'f' if s.starts_with("false") => Ok((Value::Bool(false), &s[5..])),
        b'n' if s.starts_with("null") => Ok((Value::Str(String::new()), &s[4..])),
        b'-' | b'0'..=b'9' => {
            let end = s.find(|c: char| !c.is_ascii_digit() && c != '.' && c != '-' && c != 'e' && c != 'E' && c != '+')
                .unwrap_or(s.len());
            let num_str = &s[..end];
            if num_str.contains('.') || num_str.contains('e') || num_str.contains('E') {
                let f: f64 = num_str.parse().map_err(|e| format!("bad float: {}", e))?;
                Ok((Value::Float(f), &s[end..]))
            } else {
                let n: i64 = num_str.parse().map_err(|e| format!("bad int: {}", e))?;
                Ok((Value::Int(n), &s[end..]))
            }
        }
        c => Err(format!("unexpected character '{}' in JSON", c as char)),
    }
}

// ---- Values ----

#[derive(Clone)]
pub enum Value {
    Int(i64),
    Float(f64),
    Str(String),
    Bool(bool),
    Tuple(Vec<Value>),
    List(Vec<Value>),
    Record(Vec<(String, Value)>),
    Constructor { name: String, args: Vec<Value> },
    Closure {
        params: Vec<Pattern>,
        body: Expr,
        env: Env,
    },
    BuiltIn(BuiltIn),
    Unit,
}

#[derive(Clone)]
pub enum BuiltIn {
    /// General built-in function with curried args
    Fn { name: String, arity: usize, args: Vec<Value> },
    /// ADT constructor function
    ConstructorFn { name: String, arity: usize, applied: Vec<Value> },
}

type Env = HashMap<String, Value>;

/// Internal result type for tail call optimization.
/// When a function call is in tail position, we return TailCall instead of
/// recursing, allowing the trampoline loop to handle it iteratively.
enum EvalResult {
    Value(Value),
    TailCall {
        params: Vec<Pattern>,
        body: Expr,
        env: Env,
        arg: Value,
    },
}

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Value::Int(n) => write!(f, "{}", n),
            Value::Float(v) => {
                if *v == v.floor() && v.is_finite() {
                    write!(f, "{:.1}", v)
                } else {
                    write!(f, "{}", v)
                }
            }
            Value::Str(s) => write!(f, "{}", s),
            Value::Bool(b) => write!(f, "{}", b),
            Value::Tuple(elems) => {
                write!(f, "(")?;
                for (i, e) in elems.iter().enumerate() {
                    if i > 0 { write!(f, ", ")?; }
                    write!(f, "{}", e)?;
                }
                write!(f, ")")
            }
            Value::List(elems) => {
                write!(f, "[")?;
                for (i, e) in elems.iter().enumerate() {
                    if i > 0 { write!(f, ", ")?; }
                    write!(f, "{}", e)?;
                }
                write!(f, "]")
            }
            Value::Record(fields) => {
                write!(f, "{{ ")?;
                for (i, (name, val)) in fields.iter().enumerate() {
                    if i > 0 { write!(f, ", ")?; }
                    write!(f, "{}: {}", name, val)?;
                }
                write!(f, " }}")
            }
            Value::Constructor { name, args } if args.is_empty() => {
                write!(f, "{}", name)
            }
            Value::Constructor { name, args } => {
                write!(f, "{}", name)?;
                for arg in args {
                    // Wrap compound args in parens for readability
                    match arg {
                        Value::Constructor { args: inner, .. } if !inner.is_empty() => {
                            write!(f, " ({})", arg)?;
                        }
                        _ => write!(f, " {}", arg)?,
                    }
                }
                Ok(())
            }
            Value::Closure { .. } => write!(f, "<function>"),
            Value::BuiltIn(_) => write!(f, "<builtin>"),
            Value::Unit => write!(f, "()"),
        }
    }
}

impl fmt::Debug for Value {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self)
    }
}

// ---- Errors ----

#[derive(Debug)]
pub struct RuntimeError(pub String);

impl RuntimeError {
    /// Create a runtime error with source location
    fn at(span: Span, msg: String) -> Self {
        if span != (0, 0) {
            RuntimeError(format!("at {}:{}: {}", span.0, span.1, msg))
        } else {
            RuntimeError(msg)
        }
    }
}

impl fmt::Display for RuntimeError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "runtime error: {}", self.0)
    }
}

// ---- Interpreter ----

pub struct Interpreter {
    globals: Env,
    route: Route,
}

impl Interpreter {
    pub fn new() -> Self {
        Self::with_route(Route::open())
    }

    pub fn with_route(route: Route) -> Self {
        let mut globals = HashMap::new();

        // Register built-in functions: (name, arity)
        let builtins = [
            ("print", 1), ("show", 1), ("not", 1),
            ("map", 2), ("filter", 2), ("fold", 3),
            ("head", 1), ("tail", 1), ("length", 1),
            ("range", 2), ("cons", 2), ("append", 2), ("reverse", 1),
            ("sort", 1), ("zip", 2), ("enumerate", 1),
            ("int_to_float", 1), ("floor", 1), ("ceil", 1),
            ("abs", 1), ("max", 2), ("min", 2), ("mod", 2),
            // IO
            ("read_line", 1), ("read_file", 1), ("write_file", 2),
            // System
            ("shell", 1), ("shell_lines", 1), ("env", 1), ("timestamp", 1),
            ("sleep_ms", 1),
            // JSON
            ("json_parse", 1), ("json_get", 2),
            // HTTP
            ("http_get", 1), ("http_post", 2),
            // AI
            ("prompt", 1), ("prompt_with", 2), ("prompt_json", 2), ("embed", 1),
            // String operations
            ("split", 2), ("join", 2), ("trim", 1), ("chars", 1),
            ("contains", 2), ("starts_with", 2), ("ends_with", 2),
            ("to_upper", 1), ("to_lower", 1), ("replace", 3), ("substring", 3),
            // Math
            ("sqrt", 1), ("pow", 2), ("log", 1),
            ("sin", 1), ("cos", 1), ("tan", 1),
            ("pi", 1), ("e", 1),
            // Conversion
            ("parse_int", 1), ("parse_float", 1), ("float_to_str", 1),
        ];
        for (name, arity) in builtins {
            globals.insert(name.to_string(), Value::BuiltIn(BuiltIn::Fn {
                name: name.to_string(),
                arity,
                args: vec![],
            }));
        }

        Interpreter { globals, route }
    }

    pub fn run(&mut self, program: &Program) -> Result<Value, RuntimeError> {
        // Phase 1: register all declarations into globals
        for decl in &program.declarations {
            self.register(decl)?;
        }

        // Phase 2: find and evaluate main
        let main_val = self.globals.get("main")
            .ok_or_else(|| RuntimeError("no 'main' function defined".into()))?
            .clone();

        match main_val {
            Value::Closure { params, body, env } if params.is_empty() => {
                self.eval(&body, &env)
            }
            Value::Closure { .. } => {
                Err(RuntimeError("'main' must take no parameters".into()))
            }
            other => Ok(other),
        }
    }

    pub fn register_decl(&mut self, decl: &Decl) -> Result<(), RuntimeError> {
        self.register(decl)
    }

    pub fn eval_expr(&self, expr: &Expr) -> Result<Value, RuntimeError> {
        self.eval(expr, &HashMap::new())
    }

    pub fn globals(&self) -> &HashMap<String, Value> {
        &self.globals
    }

    fn register(&mut self, decl: &Decl) -> Result<(), RuntimeError> {
        match decl {
            Decl::Func { name, params, body, .. } => {
                let val = Value::Closure {
                    params: params.clone(),
                    body: body.clone(),
                    env: HashMap::new(),
                };
                self.globals.insert(name.clone(), val);
            }
            Decl::TypeDecl { variants, .. } => {
                for variant in variants {
                    if variant.fields.is_empty() {
                        // Nullary constructor — just a value
                        self.globals.insert(
                            variant.name.clone(),
                            Value::Constructor {
                                name: variant.name.clone(),
                                args: vec![],
                            },
                        );
                    } else {
                        // Constructor function — takes N args
                        self.globals.insert(
                            variant.name.clone(),
                            Value::BuiltIn(BuiltIn::ConstructorFn {
                                name: variant.name.clone(),
                                arity: variant.fields.len(),
                                applied: vec![],
                            }),
                        );
                    }
                }
            }
            Decl::RecordDecl { .. } => {} // type-level only
            Decl::Property { .. } => {}   // TODO: property-based testing
            Decl::ModuleDecl { .. } => {}
            Decl::ExportDecl { .. } => {}
            Decl::ImportDecl { .. } => {}
        }
        Ok(())
    }

    fn eval(&self, expr: &Expr, env: &Env) -> Result<Value, RuntimeError> {
        let span = expr.span;
        match &expr.kind {
            ExprKind::IntLit(n) => Ok(Value::Int(*n)),
            ExprKind::FloatLit(f) => Ok(Value::Float(*f)),
            ExprKind::StrLit(s) => Ok(Value::Str(s.clone())),
            ExprKind::BoolLit(b) => Ok(Value::Bool(*b)),

            ExprKind::Var(name) => {
                let val = env.get(name)
                    .or_else(|| self.globals.get(name))
                    .cloned()
                    .ok_or_else(|| RuntimeError::at(span, format!("undefined: '{}'", name)))?;

                // Auto-evaluate zero-param closures (thunks like `origin = { ... }`)
                match val {
                    Value::Closure { ref params, ref body, ref env } if params.is_empty() => {
                        self.eval(body, env)
                    }
                    _ => Ok(val),
                }
            }

            ExprKind::Constructor(name) => {
                self.globals.get(name)
                    .cloned()
                    .ok_or_else(|| RuntimeError::at(span, format!("undefined constructor: '{}'", name)))
            }

            ExprKind::BinOp { op, left, right } => {
                let l = self.eval(left, env)?;
                let r = self.eval(right, env)?;
                self.eval_binop(op, &l, &r, span)
            }

            ExprKind::UnaryOp { op, operand } => {
                let v = self.eval(operand, env)?;
                match (op.as_str(), &v) {
                    ("-", Value::Int(n)) => Ok(Value::Int(-n)),
                    ("-", Value::Float(f)) => Ok(Value::Float(-f)),
                    _ => Err(RuntimeError::at(span, format!("invalid unary op: {}{}", op, v))),
                }
            }

            ExprKind::App { func, arg } => {
                let f = self.eval(func, env)?;
                let a = self.eval(arg, env)?;
                self.apply(f, a, span)
            }

            ExprKind::Let { name, value, body } => {
                let val = self.eval(value, env)?;
                let mut new_env = env.clone();
                if name != "_" {
                    new_env.insert(name.clone(), val);
                }
                self.eval(body, &new_env)
            }

            ExprKind::If { cond, then_branch, else_branch } => {
                match self.eval(cond, env)? {
                    Value::Bool(true) => self.eval(then_branch, env),
                    Value::Bool(false) => self.eval(else_branch, env),
                    v => Err(RuntimeError::at(span, format!("if condition must be bool, got: {}", v))),
                }
            }

            ExprKind::Match { scrutinee, arms } => {
                let val = self.eval(scrutinee, env)?;
                for arm in arms {
                    if let Some(bindings) = self.match_pattern(&arm.pattern, &val) {
                        let mut new_env = env.clone();
                        new_env.extend(bindings);
                        return self.eval(&arm.body, &new_env);
                    }
                }
                Err(RuntimeError::at(span, format!("non-exhaustive match on: {}", val)))
            }

            ExprKind::Pipe { value, func } => {
                // x |> f  desugars to  f x
                let v = self.eval(value, env)?;
                let f = self.eval(func, env)?;
                self.apply(f, v, span)
            }

            ExprKind::Lambda { params, body } => {
                Ok(Value::Closure {
                    params: params.clone(),
                    body: *body.clone(),
                    env: env.clone(),
                })
            }

            ExprKind::Tuple(elems) => {
                let vals: Result<Vec<_>, _> = elems.iter()
                    .map(|e| self.eval(e, env))
                    .collect();
                Ok(Value::Tuple(vals?))
            }

            ExprKind::List(elems) => {
                let vals: Result<Vec<_>, _> = elems.iter()
                    .map(|e| self.eval(e, env))
                    .collect();
                Ok(Value::List(vals?))
            }

            ExprKind::Record(fields) => {
                let mut vals = Vec::new();
                for (name, expr) in fields {
                    vals.push((name.clone(), self.eval(expr, env)?));
                }
                Ok(Value::Record(vals))
            }

            ExprKind::FieldAccess { expr, field } => {
                let val = self.eval(expr, env)?;
                match &val {
                    Value::Record(fields) => {
                        for (name, v) in fields {
                            if name == field {
                                return Ok(v.clone());
                            }
                        }
                        Err(RuntimeError::at(span, format!("no field '{}' in record", field)))
                    }
                    _ => Err(RuntimeError::at(span, format!("field access on non-record: {}", val))),
                }
            }

            ExprKind::Block(exprs) => {
                if exprs.is_empty() {
                    return Ok(Value::Unit);
                }
                let mut result = Value::Unit;
                for expr in exprs {
                    result = self.eval(expr, env)?;
                }
                Ok(result)
            }
        }
    }

    /// Evaluate an expression in tail position.
    /// Returns TailCall for function applications that are in tail position,
    /// allowing the trampoline in `apply` to handle them without growing the stack.
    fn eval_tail(&self, expr: &Expr, env: &Env) -> Result<EvalResult, RuntimeError> {
        let span = expr.span;
        match &expr.kind {
            // If/else: both branches are in tail position
            ExprKind::If { cond, then_branch, else_branch } => {
                match self.eval(cond, env)? {
                    Value::Bool(true) => self.eval_tail(then_branch, env),
                    Value::Bool(false) => self.eval_tail(else_branch, env),
                    v => Err(RuntimeError::at(span, format!("if condition must be bool, got: {}", v))),
                }
            }

            // Match: each arm body is in tail position
            ExprKind::Match { scrutinee, arms } => {
                let val = self.eval(scrutinee, env)?;
                for arm in arms {
                    if let Some(bindings) = self.match_pattern(&arm.pattern, &val) {
                        let mut new_env = env.clone();
                        new_env.extend(bindings);
                        return self.eval_tail(&arm.body, &new_env);
                    }
                }
                Err(RuntimeError::at(span, format!("non-exhaustive match on: {}", val)))
            }

            // Let: the body is in tail position
            ExprKind::Let { name, value, body } => {
                let val = self.eval(value, env)?;
                let mut new_env = env.clone();
                if name != "_" {
                    new_env.insert(name.clone(), val);
                }
                self.eval_tail(body, &new_env)
            }

            // Block: last expression is in tail position
            ExprKind::Block(exprs) => {
                if exprs.is_empty() {
                    return Ok(EvalResult::Value(Value::Unit));
                }
                let (last, rest) = exprs.split_last().unwrap();
                for expr in rest {
                    self.eval(expr, env)?;
                }
                self.eval_tail(last, env)
            }

            // Function application in tail position — return TailCall
            ExprKind::App { func, arg } => {
                let f = self.eval(func, env)?;
                let a = self.eval(arg, env)?;
                self.apply_tail(f, a, span)
            }

            // Pipe in tail position
            ExprKind::Pipe { value, func } => {
                let v = self.eval(value, env)?;
                let f = self.eval(func, env)?;
                self.apply_tail(f, v, span)
            }

            // Everything else: not a tail call, just evaluate normally
            _ => {
                let val = self.eval(expr, env)?;
                Ok(EvalResult::Value(val))
            }
        }
    }

    /// Apply a function, using the trampoline to handle tail calls iteratively.
    fn apply(&self, func: Value, arg: Value, call_span: Span) -> Result<Value, RuntimeError> {
        // Start with the initial application
        let mut result = self.apply_tail(func, arg, call_span)?;

        // Trampoline loop: keep resolving TailCalls until we get a Value
        loop {
            match result {
                EvalResult::Value(v) => return Ok(v),
                EvalResult::TailCall { params, body, env, arg } => {
                    // Bind the argument to the first parameter
                    let mut new_env = env;
                    let bindings = self.match_pattern(&params[0], &arg)
                        .ok_or_else(|| RuntimeError::at(call_span, format!(
                            "argument {} doesn't match parameter pattern", arg
                        )))?;
                    new_env.extend(bindings);

                    if params.len() == 1 {
                        // All params bound — evaluate body in tail position
                        result = self.eval_tail(&body, &new_env)?;
                    } else {
                        // Partial application — return closure (no tail call possible)
                        return Ok(Value::Closure {
                            params: params[1..].to_vec(),
                            body,
                            env: new_env,
                        });
                    }
                }
            }
        }
    }

    /// Try to apply a function, returning TailCall if the closure body
    /// should be evaluated in tail position by the trampoline.
    fn apply_tail(&self, func: Value, arg: Value, call_span: Span) -> Result<EvalResult, RuntimeError> {
        match func {
            Value::Closure { params, body, env } if params.is_empty() => {
                // Zero-param closure applied as value — evaluate body, then apply result
                let result = self.eval(&body, &env)?;
                self.apply_tail(result, arg, call_span)
            }
            Value::Closure { params, body, env } => {
                // Return a TailCall so the trampoline handles binding + eval
                Ok(EvalResult::TailCall { params, body, env, arg })
            }
            Value::BuiltIn(builtin) => {
                let val = self.apply_builtin(builtin, arg)?;
                Ok(EvalResult::Value(val))
            }
            other => Err(RuntimeError::at(call_span, format!("cannot apply non-function: {}", other))),
        }
    }

    fn apply_builtin(&self, builtin: BuiltIn, arg: Value) -> Result<Value, RuntimeError> {
        match builtin {
            BuiltIn::Fn { name, arity, mut args } => {
                args.push(arg);
                if args.len() < arity {
                    // Partial application — still waiting for more args
                    Ok(Value::BuiltIn(BuiltIn::Fn { name, arity, args }))
                } else {
                    // All args collected — execute
                    self.exec_builtin(&name, &args)
                }
            }
            BuiltIn::ConstructorFn { name, arity, mut applied } => {
                applied.push(arg);
                if applied.len() == arity {
                    Ok(Value::Constructor { name, args: applied })
                } else {
                    Ok(Value::BuiltIn(BuiltIn::ConstructorFn { name, arity, applied }))
                }
            }
        }
    }

    fn exec_builtin(&self, name: &str, args: &[Value]) -> Result<Value, RuntimeError> {
        match name {
            "print" => {
                println!("{}", args[0]);
                Ok(Value::Unit)
            }
            "show" => Ok(Value::Str(format!("{}", args[0]))),
            "not" => match &args[0] {
                Value::Bool(b) => Ok(Value::Bool(!b)),
                v => Err(RuntimeError(format!("not: expected bool, got {}", v))),
            },

            // List operations
            "map" => match (&args[0], &args[1]) {
                (func, Value::List(list)) => {
                    let mut result = Vec::with_capacity(list.len());
                    for item in list {
                        result.push(self.apply(func.clone(), item.clone(), (0,0))?);
                    }
                    Ok(Value::List(result))
                }
                (_, v) => Err(RuntimeError(format!("map: expected list, got {}", v))),
            },
            "filter" => match (&args[0], &args[1]) {
                (func, Value::List(list)) => {
                    let mut result = Vec::new();
                    for item in list {
                        match self.apply(func.clone(), item.clone(), (0,0))? {
                            Value::Bool(true) => result.push(item.clone()),
                            Value::Bool(false) => {}
                            v => return Err(RuntimeError(format!("filter: predicate returned {}, expected bool", v))),
                        }
                    }
                    Ok(Value::List(result))
                }
                (_, v) => Err(RuntimeError(format!("filter: expected list, got {}", v))),
            },
            "fold" => match (&args[0], &args[1], &args[2]) {
                (init, func, Value::List(list)) => {
                    let mut acc = init.clone();
                    for item in list {
                        let partial = self.apply(func.clone(), acc, (0,0))?;
                        acc = self.apply(partial, item.clone(), (0,0))?;
                    }
                    Ok(acc)
                }
                (_, _, v) => Err(RuntimeError(format!("fold: expected list as third arg, got {}", v))),
            },
            "head" => match &args[0] {
                Value::List(list) => list.first().cloned()
                    .ok_or_else(|| RuntimeError("head: empty list".into())),
                v => Err(RuntimeError(format!("head: expected list, got {}", v))),
            },
            "tail" => match &args[0] {
                Value::List(list) if list.is_empty() =>
                    Err(RuntimeError("tail: empty list".into())),
                Value::List(list) => Ok(Value::List(list[1..].to_vec())),
                v => Err(RuntimeError(format!("tail: expected list, got {}", v))),
            },
            "length" => match &args[0] {
                Value::List(list) => Ok(Value::Int(list.len() as i64)),
                Value::Str(s) => Ok(Value::Int(s.len() as i64)),
                v => Err(RuntimeError(format!("length: expected list or string, got {}", v))),
            },
            "range" => match (&args[0], &args[1]) {
                (Value::Int(start), Value::Int(end)) =>
                    Ok(Value::List((*start..*end).map(Value::Int).collect())),
                _ => Err(RuntimeError("range: expected two integers".into())),
            },
            "cons" => match &args[1] {
                Value::List(list) => {
                    let mut result = vec![args[0].clone()];
                    result.extend(list.iter().cloned());
                    Ok(Value::List(result))
                }
                v => Err(RuntimeError(format!("cons: expected list, got {}", v))),
            },
            "append" => match (&args[0], &args[1]) {
                (Value::List(a), Value::List(b)) => {
                    let mut result = a.clone();
                    result.extend(b.iter().cloned());
                    Ok(Value::List(result))
                }
                (Value::Str(a), Value::Str(b)) => Ok(Value::Str(format!("{}{}", a, b))),
                _ => Err(RuntimeError("append: expected two lists or two strings".into())),
            },
            "reverse" => match &args[0] {
                Value::List(list) => {
                    let mut result = list.clone();
                    result.reverse();
                    Ok(Value::List(result))
                }
                v => Err(RuntimeError(format!("reverse: expected list, got {}", v))),
            },
            "sort" => match &args[0] {
                Value::List(list) => {
                    let mut result = list.clone();
                    result.sort_by(|a, b| {
                        match (a, b) {
                            (Value::Int(x), Value::Int(y)) => x.cmp(y),
                            (Value::Float(x), Value::Float(y)) => x.partial_cmp(y).unwrap_or(std::cmp::Ordering::Equal),
                            (Value::Str(x), Value::Str(y)) => x.cmp(y),
                            _ => std::cmp::Ordering::Equal,
                        }
                    });
                    Ok(Value::List(result))
                }
                v => Err(RuntimeError(format!("sort: expected list, got {}", v))),
            },
            "zip" => match (&args[0], &args[1]) {
                (Value::List(a), Value::List(b)) => {
                    let result: Vec<Value> = a.iter().zip(b.iter())
                        .map(|(x, y)| Value::Tuple(vec![x.clone(), y.clone()]))
                        .collect();
                    Ok(Value::List(result))
                }
                _ => Err(RuntimeError("zip: expected two lists".into())),
            },
            "enumerate" => match &args[0] {
                Value::List(list) => {
                    let result: Vec<Value> = list.iter().enumerate()
                        .map(|(i, v)| Value::Tuple(vec![Value::Int(i as i64), v.clone()]))
                        .collect();
                    Ok(Value::List(result))
                }
                v => Err(RuntimeError(format!("enumerate: expected list, got {}", v))),
            },

            // Numeric operations
            "int_to_float" => match &args[0] {
                Value::Int(n) => Ok(Value::Float(*n as f64)),
                v => Err(RuntimeError(format!("int_to_float: expected int, got {}", v))),
            },
            "floor" => match &args[0] {
                Value::Float(f) => Ok(Value::Int(f.floor() as i64)),
                v => Err(RuntimeError(format!("floor: expected float, got {}", v))),
            },
            "ceil" => match &args[0] {
                Value::Float(f) => Ok(Value::Int(f.ceil() as i64)),
                v => Err(RuntimeError(format!("ceil: expected float, got {}", v))),
            },
            "abs" => match &args[0] {
                Value::Int(n) => Ok(Value::Int(n.abs())),
                Value::Float(f) => Ok(Value::Float(f.abs())),
                v => Err(RuntimeError(format!("abs: expected number, got {}", v))),
            },
            "max" => match (&args[0], &args[1]) {
                (Value::Int(a), Value::Int(b)) => Ok(Value::Int(*a.max(b))),
                (Value::Float(a), Value::Float(b)) => Ok(Value::Float(a.max(*b))),
                _ => Err(RuntimeError("max: expected two numbers of same type".into())),
            },
            "min" => match (&args[0], &args[1]) {
                (Value::Int(a), Value::Int(b)) => Ok(Value::Int(*a.min(b))),
                (Value::Float(a), Value::Float(b)) => Ok(Value::Float(a.min(*b))),
                _ => Err(RuntimeError("min: expected two numbers of same type".into())),
            },
            "mod" => match (&args[0], &args[1]) {
                (Value::Int(a), Value::Int(b)) => {
                    if *b == 0 { return Err(RuntimeError("mod: division by zero".into())); }
                    Ok(Value::Int(a % b))
                }
                _ => Err(RuntimeError("mod: expected two integers".into())),
            },

            // IO operations
            "read_line" => {
                std::io::stdout().flush().ok();
                let mut input = String::new();
                std::io::stdin().read_line(&mut input)
                    .map_err(|e| RuntimeError(format!("read_line: {}", e)))?;
                if input.ends_with('\n') {
                    input.pop();
                    if input.ends_with('\r') {
                        input.pop();
                    }
                }
                Ok(Value::Str(input))
            },
            "read_file" => match &args[0] {
                Value::Str(path) => {
                    self.route.check_fs(path).map_err(RuntimeError)?;
                    match std::fs::read_to_string(path) {
                        Ok(contents) => Ok(Value::Str(contents)),
                        Err(e) => Ok(Value::Str(format!("{}", e))),
                    }
                }
                v => Err(RuntimeError(format!("read_file: expected string, got {}", v))),
            },
            "write_file" => match (&args[0], &args[1]) {
                (Value::Str(path), Value::Str(content)) => {
                    self.route.check_fs(path).map_err(RuntimeError)?;
                    std::fs::write(path, content)
                        .map_err(|e| RuntimeError(format!("write_file: {}", e)))?;
                    Ok(Value::Unit)
                }
                _ => Err(RuntimeError("write_file: expected two strings".into())),
            },

            // String operations
            "split" => match (&args[0], &args[1]) {
                (Value::Str(delim), Value::Str(input)) => {
                    let parts: Vec<Value> = input.split(delim.as_str())
                        .map(|s| Value::Str(s.to_string()))
                        .collect();
                    Ok(Value::List(parts))
                }
                _ => Err(RuntimeError("split: expected two strings".into())),
            },
            "join" => match (&args[0], &args[1]) {
                (Value::Str(sep), Value::List(list)) => {
                    let strs: Result<Vec<String>, _> = list.iter().map(|v| match v {
                        Value::Str(s) => Ok(s.clone()),
                        other => Err(RuntimeError(format!("join: list element is not a string: {}", other))),
                    }).collect();
                    Ok(Value::Str(strs?.join(sep)))
                }
                _ => Err(RuntimeError("join: expected string and list".into())),
            },
            "trim" => match &args[0] {
                Value::Str(s) => Ok(Value::Str(s.trim().to_string())),
                v => Err(RuntimeError(format!("trim: expected string, got {}", v))),
            },
            "chars" => match &args[0] {
                Value::Str(s) => {
                    let chars: Vec<Value> = s.chars()
                        .map(|c| Value::Str(c.to_string()))
                        .collect();
                    Ok(Value::List(chars))
                }
                v => Err(RuntimeError(format!("chars: expected string, got {}", v))),
            },
            "contains" => match (&args[0], &args[1]) {
                (Value::Str(needle), Value::Str(haystack)) => {
                    Ok(Value::Bool(haystack.contains(needle.as_str())))
                }
                _ => Err(RuntimeError("contains: expected two strings".into())),
            },
            "starts_with" => match (&args[0], &args[1]) {
                (Value::Str(prefix), Value::Str(input)) => {
                    Ok(Value::Bool(input.starts_with(prefix.as_str())))
                }
                _ => Err(RuntimeError("starts_with: expected two strings".into())),
            },
            "ends_with" => match (&args[0], &args[1]) {
                (Value::Str(suffix), Value::Str(input)) => {
                    Ok(Value::Bool(input.ends_with(suffix.as_str())))
                }
                _ => Err(RuntimeError("ends_with: expected two strings".into())),
            },
            "to_upper" => match &args[0] {
                Value::Str(s) => Ok(Value::Str(s.to_uppercase())),
                v => Err(RuntimeError(format!("to_upper: expected string, got {}", v))),
            },
            "to_lower" => match &args[0] {
                Value::Str(s) => Ok(Value::Str(s.to_lowercase())),
                v => Err(RuntimeError(format!("to_lower: expected string, got {}", v))),
            },
            "replace" => match (&args[0], &args[1], &args[2]) {
                (Value::Str(from), Value::Str(to), Value::Str(input)) => {
                    Ok(Value::Str(input.replace(from.as_str(), to.as_str())))
                }
                _ => Err(RuntimeError("replace: expected three strings".into())),
            },
            "substring" => match (&args[0], &args[1], &args[2]) {
                (Value::Int(start), Value::Int(end), Value::Str(input)) => {
                    let start = *start as usize;
                    let end = *end as usize;
                    let len = input.len();
                    let start = start.min(len);
                    let end = end.min(len);
                    if start > end {
                        Ok(Value::Str(String::new()))
                    } else {
                        Ok(Value::Str(input[start..end].to_string()))
                    }
                }
                _ => Err(RuntimeError("substring: expected int, int, string".into())),
            },

            // Math operations
            "sqrt" => match &args[0] {
                Value::Float(f) => Ok(Value::Float(f.sqrt())),
                v => Err(RuntimeError(format!("sqrt: expected float, got {}", v))),
            },
            "pow" => match (&args[0], &args[1]) {
                (Value::Float(base), Value::Float(exp)) => Ok(Value::Float(base.powf(*exp))),
                _ => Err(RuntimeError("pow: expected two floats".into())),
            },
            "log" => match &args[0] {
                Value::Float(f) => Ok(Value::Float(f.ln())),
                v => Err(RuntimeError(format!("log: expected float, got {}", v))),
            },
            "sin" => match &args[0] {
                Value::Float(f) => Ok(Value::Float(f.sin())),
                v => Err(RuntimeError(format!("sin: expected float, got {}", v))),
            },
            "cos" => match &args[0] {
                Value::Float(f) => Ok(Value::Float(f.cos())),
                v => Err(RuntimeError(format!("cos: expected float, got {}", v))),
            },
            "tan" => match &args[0] {
                Value::Float(f) => Ok(Value::Float(f.tan())),
                v => Err(RuntimeError(format!("tan: expected float, got {}", v))),
            },
            "pi" => Ok(Value::Float(std::f64::consts::PI)),
            "e" => Ok(Value::Float(std::f64::consts::E)),

            // Conversion operations
            "parse_int" => match &args[0] {
                Value::Str(s) => Ok(Value::Int(s.trim().parse::<i64>().unwrap_or(0))),
                v => Err(RuntimeError(format!("parse_int: expected string, got {}", v))),
            },
            "parse_float" => match &args[0] {
                Value::Str(s) => Ok(Value::Float(s.trim().parse::<f64>().unwrap_or(0.0))),
                v => Err(RuntimeError(format!("parse_float: expected string, got {}", v))),
            },
            "float_to_str" => match &args[0] {
                Value::Float(f) => Ok(Value::Str(format!("{}", f))),
                v => Err(RuntimeError(format!("float_to_str: expected float, got {}", v))),
            },

            // System operations (route-gated)
            "shell" => match &args[0] {
                Value::Str(cmd) => {
                    self.route.check_shell().map_err(RuntimeError)?;
                    match std::process::Command::new("sh")
                        .arg("-c")
                        .arg(cmd)
                        .output()
                    {
                        Ok(output) => {
                            let stdout = String::from_utf8_lossy(&output.stdout).to_string();
                            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
                            if output.status.success() {
                                Ok(Value::Str(stdout))
                            } else {
                                Ok(Value::Str(format!("ERROR({}): {}{}", output.status.code().unwrap_or(-1), stderr, stdout)))
                            }
                        }
                        Err(e) => Err(RuntimeError(format!("shell: {}", e))),
                    }
                }
                v => Err(RuntimeError(format!("shell: expected string, got {}", v))),
            },
            "shell_lines" => match &args[0] {
                Value::Str(cmd) => {
                    self.route.check_shell().map_err(RuntimeError)?;
                    match std::process::Command::new("sh")
                        .arg("-c")
                        .arg(cmd)
                        .output()
                    {
                        Ok(output) => {
                            let stdout = String::from_utf8_lossy(&output.stdout);
                            let lines: Vec<Value> = stdout.lines()
                                .map(|l| Value::Str(l.to_string()))
                                .collect();
                            Ok(Value::List(lines))
                        }
                        Err(e) => Err(RuntimeError(format!("shell_lines: {}", e))),
                    }
                }
                v => Err(RuntimeError(format!("shell_lines: expected string, got {}", v))),
            },
            "env" => match &args[0] {
                Value::Str(name) => {
                    self.route.check_env(name).map_err(RuntimeError)?;
                    Ok(Value::Str(std::env::var(name).unwrap_or_default()))
                }
                v => Err(RuntimeError(format!("env: expected string, got {}", v))),
            },
            "timestamp" => {
                let ts = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs() as i64;
                Ok(Value::Int(ts))
            },
            "sleep_ms" => match &args[0] {
                Value::Int(ms) => {
                    std::thread::sleep(std::time::Duration::from_millis(*ms as u64));
                    Ok(Value::Unit)
                }
                v => Err(RuntimeError(format!("sleep_ms: expected int, got {}", v))),
            },

            // JSON operations
            "json_parse" => match &args[0] {
                Value::Str(s) => {
                    Ok(parse_json_value(s)
                        .unwrap_or_else(|e| Value::Str(format!("JSON_ERROR: {}", e))))
                }
                v => Err(RuntimeError(format!("json_parse: expected string, got {}", v))),
            },
            "json_get" => match (&args[0], &args[1]) {
                (Value::Str(key), Value::Str(json_str)) => {
                    // Simple JSON field extraction — parse and get key
                    match parse_json_value(json_str) {
                        Ok(Value::List(pairs)) => {
                            // Records are stored as list of (key, value) tuples
                            for pair in &pairs {
                                if let Value::Tuple(kv) = pair {
                                    if kv.len() == 2 {
                                        if let Value::Str(k) = &kv[0] {
                                            if k == key {
                                                return Ok(kv[1].clone());
                                            }
                                        }
                                    }
                                }
                            }
                            Ok(Value::Str(String::new()))
                        }
                        _ => Ok(Value::Str(String::new())),
                    }
                }
                _ => Err(RuntimeError("json_get: expected two strings (key, json)".into())),
            },

            // HTTP operations
            "http_get" => match &args[0] {
                Value::Str(url) => {
                    self.route.check_net(url).map_err(RuntimeError)?;
                    match std::process::Command::new("curl")
                        .args(["-s", "-L", "--max-time", "30", url])
                        .output()
                    {
                        Ok(output) => Ok(Value::Str(String::from_utf8_lossy(&output.stdout).to_string())),
                        Err(e) => Err(RuntimeError(format!("http_get: {}", e))),
                    }
                }
                v => Err(RuntimeError(format!("http_get: expected string, got {}", v))),
            },
            "http_post" => match (&args[0], &args[1]) {
                (Value::Str(url), Value::Str(body)) => {
                    self.route.check_net(url).map_err(RuntimeError)?;
                    match std::process::Command::new("curl")
                        .args(["-s", "-L", "--max-time", "30", "-X", "POST",
                               "-H", "Content-Type: application/json",
                               "-d", body, url])
                        .output()
                    {
                        Ok(output) => Ok(Value::Str(String::from_utf8_lossy(&output.stdout).to_string())),
                        Err(e) => Err(RuntimeError(format!("http_post: {}", e))),
                    }
                }
                _ => Err(RuntimeError("http_post: expected two strings (url, body)".into())),
            },

            // AI operations (route-gated)
            "prompt" => match &args[0] {
                Value::Str(user_prompt) => {
                    self.route.check_ai().map_err(RuntimeError)?;
                    let config = ai::AiConfig::from_env();
                    match ai::call_llm(&config, "", user_prompt) {
                        Ok(response) => Ok(Value::Str(response)),
                        Err(e) => Err(RuntimeError(format!("prompt: {}", e))),
                    }
                }
                v => Err(RuntimeError(format!("prompt: expected string, got {}", v))),
            },
            "prompt_with" => match (&args[0], &args[1]) {
                (Value::Str(system), Value::Str(user_prompt)) => {
                    self.route.check_ai().map_err(RuntimeError)?;
                    let config = ai::AiConfig::from_env();
                    match ai::call_llm(&config, system, user_prompt) {
                        Ok(response) => Ok(Value::Str(response)),
                        Err(e) => Err(RuntimeError(format!("prompt_with: {}", e))),
                    }
                }
                _ => Err(RuntimeError("prompt_with: expected two strings".into())),
            },
            "prompt_json" => match (&args[0], &args[1]) {
                (Value::Str(schema_hint), Value::Str(user_prompt)) => {
                    self.route.check_ai().map_err(RuntimeError)?;
                    let config = ai::AiConfig::from_env();
                    let system = format!(
                        "{}. Respond with valid JSON only, no explanation.",
                        schema_hint
                    );
                    match ai::call_llm(&config, &system, user_prompt) {
                        Ok(response) => Ok(Value::Str(response)),
                        Err(e) => Err(RuntimeError(format!("prompt_json: {}", e))),
                    }
                }
                _ => Err(RuntimeError("prompt_json: expected two strings".into())),
            },
            "embed" => match &args[0] {
                Value::Str(text) => {
                    self.route.check_ai().map_err(RuntimeError)?;
                    let config = ai::AiConfig::from_env();
                    match ai::call_embed(&config, text) {
                        Ok(vec) => Ok(Value::List(
                            vec.into_iter().map(Value::Float).collect()
                        )),
                        Err(e) => Err(RuntimeError(format!("embed: {}", e))),
                    }
                }
                v => Err(RuntimeError(format!("embed: expected string, got {}", v))),
            },

            _ => Err(RuntimeError(format!("unknown builtin: {}", name))),
        }
    }

    fn eval_binop(&self, op: &str, left: &Value, right: &Value, span: Span) -> Result<Value, RuntimeError> {
        match (op, left, right) {
            // Integer arithmetic
            ("+", Value::Int(a), Value::Int(b)) => Ok(Value::Int(a + b)),
            ("-", Value::Int(a), Value::Int(b)) => Ok(Value::Int(a - b)),
            ("*", Value::Int(a), Value::Int(b)) => Ok(Value::Int(a * b)),
            ("/", Value::Int(a), Value::Int(b)) => {
                if *b == 0 { return Err(RuntimeError::at(span, "division by zero".into())); }
                Ok(Value::Int(a / b))
            }
            ("%", Value::Int(a), Value::Int(b)) => {
                if *b == 0 { return Err(RuntimeError::at(span, "modulo by zero".into())); }
                Ok(Value::Int(a % b))
            }

            // Float arithmetic
            ("+", Value::Float(a), Value::Float(b)) => Ok(Value::Float(a + b)),
            ("-", Value::Float(a), Value::Float(b)) => Ok(Value::Float(a - b)),
            ("*", Value::Float(a), Value::Float(b)) => Ok(Value::Float(a * b)),
            ("/", Value::Float(a), Value::Float(b)) => Ok(Value::Float(a / b)),

            // String concatenation
            ("+", Value::Str(a), Value::Str(b)) => Ok(Value::Str(format!("{}{}", a, b))),

            // Integer comparisons
            ("==", Value::Int(a), Value::Int(b)) => Ok(Value::Bool(a == b)),
            ("!=", Value::Int(a), Value::Int(b)) => Ok(Value::Bool(a != b)),
            ("<",  Value::Int(a), Value::Int(b)) => Ok(Value::Bool(a < b)),
            (">",  Value::Int(a), Value::Int(b)) => Ok(Value::Bool(a > b)),
            ("<=", Value::Int(a), Value::Int(b)) => Ok(Value::Bool(a <= b)),
            (">=", Value::Int(a), Value::Int(b)) => Ok(Value::Bool(a >= b)),

            // Float comparisons
            ("==", Value::Float(a), Value::Float(b)) => Ok(Value::Bool(a == b)),
            ("!=", Value::Float(a), Value::Float(b)) => Ok(Value::Bool(a != b)),
            ("<",  Value::Float(a), Value::Float(b)) => Ok(Value::Bool(a < b)),
            (">",  Value::Float(a), Value::Float(b)) => Ok(Value::Bool(a > b)),
            ("<=", Value::Float(a), Value::Float(b)) => Ok(Value::Bool(a <= b)),
            (">=", Value::Float(a), Value::Float(b)) => Ok(Value::Bool(a >= b)),

            // String comparisons
            ("==", Value::Str(a), Value::Str(b)) => Ok(Value::Bool(a == b)),
            ("!=", Value::Str(a), Value::Str(b)) => Ok(Value::Bool(a != b)),

            // Bool comparisons
            ("==", Value::Bool(a), Value::Bool(b)) => Ok(Value::Bool(a == b)),
            ("!=", Value::Bool(a), Value::Bool(b)) => Ok(Value::Bool(a != b)),

            // Boolean logic
            ("&&", Value::Bool(a), Value::Bool(b)) => Ok(Value::Bool(*a && *b)),
            ("||", Value::Bool(a), Value::Bool(b)) => Ok(Value::Bool(*a || *b)),

            _ => Err(RuntimeError::at(span, format!(
                "type error: {} {} {}", left, op, right
            ))),
        }
    }

    fn match_pattern(&self, pattern: &Pattern, value: &Value) -> Option<Vec<(String, Value)>> {
        match (pattern, value) {
            (Pattern::Wildcard, _) => Some(vec![]),

            (Pattern::Var(name), val) => {
                Some(vec![(name.clone(), val.clone())])
            }

            (Pattern::IntLit(a), Value::Int(b)) if a == b => Some(vec![]),
            (Pattern::FloatLit(a), Value::Float(b)) if a == b => Some(vec![]),
            (Pattern::StrLit(a), Value::Str(b)) if a == b => Some(vec![]),
            (Pattern::BoolLit(a), Value::Bool(b)) if a == b => Some(vec![]),

            (Pattern::Constructor { name: pn, args: pargs },
             Value::Constructor { name: vn, args: vargs }) => {
                if pn != vn || pargs.len() != vargs.len() {
                    return None;
                }
                let mut bindings = vec![];
                for (p, v) in pargs.iter().zip(vargs.iter()) {
                    bindings.extend(self.match_pattern(p, v)?);
                }
                Some(bindings)
            }

            (Pattern::Tuple(pats), Value::Tuple(vals)) => {
                if pats.len() != vals.len() { return None; }
                let mut bindings = vec![];
                for (p, v) in pats.iter().zip(vals.iter()) {
                    bindings.extend(self.match_pattern(p, v)?);
                }
                Some(bindings)
            }

            _ => None,
        }
    }
}
