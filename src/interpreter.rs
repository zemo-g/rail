/// Rail interpreter — tree-walking evaluator.
/// Evaluates a parsed AST by walking the tree directly.
/// Supports curried functions, pattern matching, ADTs, records, and recursion.
/// Uses trampoline-based tail call optimization (TCO) for recursive tail calls.

use std::collections::HashMap;
use std::cell::RefCell;
use std::rc::Rc;
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

// ---- Effect system ----

#[derive(Clone)]
struct HandleContext {
    body: Rc<Expr>,
    body_env: Env,
    handlers: Vec<(String, Vec<Pattern>, Expr)>,
    resume_answers: Vec<Value>,
    resume_cursor: usize,
    resumed: bool,
    // Snapshot of outer contexts' cursors when this handle started —
    // restored on re-execution so nested effects replay correctly
    saved_outer_cursors: Vec<usize>,
}

struct EffectSignal {
    op: String,
    args: Vec<Value>,
}

// ---- Interpreter ----

const MAX_RECURSION_DEPTH: usize = 200;

pub struct Interpreter {
    globals: RefCell<Env>,
    route: Route,
    // Effect system
    effect_signal: RefCell<Option<EffectSignal>>,
    handle_contexts: RefCell<Vec<HandleContext>>,
    // Hot reload: persistent state + serve context
    state: RefCell<HashMap<String, Value>>,
    serve_ctx: Option<RefCell<crate::serve::ServeContext>>,
    // Recursion depth tracking
    depth: RefCell<usize>,
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
            ("map", 2), ("par_map", 2), ("filter", 2), ("par_filter", 2), ("fold", 3),
            ("head", 1), ("tail", 1), ("length", 1),
            ("range", 2), ("cons", 2), ("append", 2), ("reverse", 1),
            ("sort", 1), ("zip", 2), ("enumerate", 1),
            ("int_to_float", 1), ("floor", 1), ("ceil", 1),
            ("abs", 1), ("max", 2), ("min", 2), ("mod", 2),
            // IO
            ("read_line", 1), ("read_file", 1), ("write_file", 2),
            // System
            ("shell", 1), ("shell_lines", 1), ("env", 1), ("timestamp", 1),
            ("sleep_ms", 1), ("random", 0), ("random_int", 2),
            // JSON
            ("json_parse", 1), ("json_get", 2),
            // HTTP
            ("http_get", 1), ("http_post", 2),
            // AI
            ("prompt", 1), ("prompt_with", 2), ("prompt_json", 2), ("embed", 1),
            ("prompt_model", 3), ("par_prompt", 2), ("llm_usage", 1), ("llm_reset", 1),
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
            // Hot reload
            ("set_state", 2), ("get_state", 1), ("check_reload", 1),
            // SQLite
            ("db_query", 2), ("db_execute", 2),
            // Agent primitives (v0.5)
            ("agent_loop", 4), ("prompt_stream", 3), ("prompt_typed", 3),
            ("context_new", 1), ("context_push", 3), ("context_prompt", 2),
        ];
        for (name, arity) in builtins {
            globals.insert(name.to_string(), Value::BuiltIn(BuiltIn::Fn {
                name: name.to_string(),
                arity,
                args: vec![],
            }));
        }

        Interpreter {
            globals: RefCell::new(globals),
            route,
            effect_signal: RefCell::new(None),
            handle_contexts: RefCell::new(Vec::new()),
            state: RefCell::new(HashMap::new()),
            serve_ctx: None,
            depth: RefCell::new(0),
        }
    }

    /// Inject persistent state from a previous generation (used by serve loop).
    pub fn set_serve_context_state(&mut self, state: &HashMap<String, Value>) {
        *self.state.borrow_mut() = state.clone();
    }

    /// Get a global value by name (used by test runner).
    pub fn get_global(&self, name: &str) -> Option<Value> {
        self.globals.borrow().get(name).cloned()
    }

    /// Apply a function value to an argument (public wrapper for test runner).
    pub fn apply_value(&self, func: Value, arg: Value) -> Result<Value, RuntimeError> {
        self.apply(func, arg, (0, 0))
    }

    /// Harvest persistent state after a run (used by serve loop).
    pub fn take_serve_state(&self) -> HashMap<String, Value> {
        self.state.borrow().clone()
    }

    /// Attach a serve context for check_reload support.
    #[allow(dead_code)]
    pub fn set_serve_context(&mut self, ctx: crate::serve::ServeContext) {
        self.serve_ctx = Some(RefCell::new(ctx));
    }

    /// Take the serve context back (used by serve loop).
    #[allow(dead_code)]
    pub fn take_serve_context(&mut self) -> Option<crate::serve::ServeContext> {
        self.serve_ctx.take().map(|c| c.into_inner())
    }

    pub fn run(&self, program: &Program) -> Result<Value, RuntimeError> {
        // Phase 1: register all declarations into globals
        for decl in &program.declarations {
            self.register(decl)?;
        }

        // Phase 2: find and evaluate main
        let main_val = self.globals.borrow().get("main")
            .ok_or_else(|| RuntimeError("no 'main' function defined. Add: main =\n  let _ = print \"hello\"\n  0".into()))?
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

    pub fn register_decl(&self, decl: &Decl) -> Result<(), RuntimeError> {
        self.register(decl)
    }

    pub fn eval_expr(&self, expr: &Expr) -> Result<Value, RuntimeError> {
        self.eval(expr, &HashMap::new())
    }

    pub fn globals(&self) -> std::cell::Ref<'_, HashMap<String, Value>> {
        self.globals.borrow()
    }

    fn register(&self, decl: &Decl) -> Result<(), RuntimeError> {
        match decl {
            Decl::Func { name, params, body, .. } => {
                let val = Value::Closure {
                    params: params.clone(),
                    body: body.clone(),
                    env: HashMap::new(),
                };
                self.globals.borrow_mut().insert(name.clone(), val);
            }
            Decl::TypeDecl { variants, .. } => {
                for variant in variants {
                    if variant.fields.is_empty() {
                        self.globals.borrow_mut().insert(
                            variant.name.clone(),
                            Value::Constructor {
                                name: variant.name.clone(),
                                args: vec![],
                            },
                        );
                    } else {
                        self.globals.borrow_mut().insert(
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
            Decl::EffectDecl { .. } => {} // type-level only (handlers are runtime)
            Decl::Property { .. } => {}   // TODO: property-based testing
            Decl::ModuleDecl { .. } => {}
            Decl::ExportDecl { .. } => {}
            Decl::ImportDecl { .. } => {}
        }
        Ok(())
    }

    fn eval(&self, expr: &Expr, env: &Env) -> Result<Value, RuntimeError> {
        // Check recursion depth
        {
            let mut d = self.depth.borrow_mut();
            *d += 1;
            if *d > MAX_RECURSION_DEPTH {
                return Err(RuntimeError(format!(
                    "recursion depth exceeded (limit: {})", MAX_RECURSION_DEPTH
                )));
            }
        }
        let result = self.eval_inner(expr, env);
        *self.depth.borrow_mut() -= 1;
        result
    }

    fn eval_inner(&self, expr: &Expr, env: &Env) -> Result<Value, RuntimeError> {
        let span = expr.span;
        match &expr.kind {
            ExprKind::IntLit(n) => Ok(Value::Int(*n)),
            ExprKind::FloatLit(f) => Ok(Value::Float(*f)),
            ExprKind::StrLit(s) => Ok(Value::Str(s.clone())),
            ExprKind::BoolLit(b) => Ok(Value::Bool(*b)),

            ExprKind::Var(name) => {
                let val = env.get(name)
                    .cloned()
                    .or_else(|| self.globals.borrow().get(name).cloned())
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
                self.globals.borrow().get(name)
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
                if elems.is_empty() {
                    return Ok(Value::Unit);
                }
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

            ExprKind::Perform { op, args } => {
                // Walk the handler stack from innermost to outermost,
                // find the first context that handles this op and check for resume answer
                let answer = {
                    let mut contexts = self.handle_contexts.borrow_mut();
                    let mut found = None;
                    for ctx in contexts.iter_mut().rev() {
                        if ctx.handlers.iter().any(|(name, _, _)| name == op) {
                            // This context handles this op — check for pre-supplied answer
                            if ctx.resume_cursor < ctx.resume_answers.len() {
                                let val = ctx.resume_answers[ctx.resume_cursor].clone();
                                ctx.resume_cursor += 1;
                                found = Some(val);
                            }
                            break; // stop at first handler regardless
                        }
                    }
                    found
                };

                if let Some(val) = answer {
                    return Ok(val);
                }

                // Evaluate args
                let evaluated_args: Result<Vec<_>, _> = args.iter()
                    .map(|a| self.eval(a, env))
                    .collect();
                let evaluated_args = evaluated_args?;

                // Check if any handler on the stack handles this op
                let has_handler = self.handle_contexts.borrow().iter()
                    .any(|ctx| ctx.handlers.iter().any(|(name, _, _)| name == op));

                if !has_handler {
                    return Err(RuntimeError::at(span, format!("unhandled effect: '{}'", op)));
                }

                // Signal the effect
                *self.effect_signal.borrow_mut() = Some(EffectSignal {
                    op: op.clone(),
                    args: evaluated_args,
                });
                Err(RuntimeError("__effect__".into()))
            }

            ExprKind::Handle { body, handlers } => {
                let handler_list: Vec<_> = handlers.iter().map(|h| {
                    (h.op_name.clone(), h.params.clone(), h.body.clone())
                }).collect();

                // Save outer contexts' cursors so nested re-execution replays correctly
                let saved_outer_cursors: Vec<usize> = self.handle_contexts.borrow()
                    .iter().map(|c| c.resume_cursor).collect();

                let ctx = HandleContext {
                    body: Rc::new((**body).clone()),
                    body_env: env.clone(),
                    handlers: handler_list,
                    resume_answers: vec![],
                    resume_cursor: 0,
                    resumed: false,
                    saved_outer_cursors,
                };

                self.handle_contexts.borrow_mut().push(ctx);

                if self.handle_contexts.borrow().len() > 100 {
                    return Err(RuntimeError::at(span, "effect handler recursion limit exceeded (possible infinite resume loop)".into()));
                }

                // Start by evaluating the body
                let mut result = self.eval(body, env);

                // Loop: keep handling effect signals until we get a final value or real error.
                // When a handler calls resume, it re-executes the body which may signal again.
                // That signal propagates up through resume → handler body → here.
                loop {
                    match result {
                        Ok(value) => {
                            self.handle_contexts.borrow_mut().pop();
                            return Ok(value);
                        }
                        Err(ref e) if e.0 == "__effect__" => {
                            let signal = self.effect_signal.borrow_mut().take();
                            if let Some(signal) = signal {
                                // Find matching handler
                                let handler = {
                                    let contexts = self.handle_contexts.borrow();
                                    let ctx = contexts.last().unwrap();
                                    ctx.handlers.iter()
                                        .find(|(name, _, _)| *name == signal.op)
                                        .cloned()
                                };

                                if let Some((_, params, handler_body)) = handler {
                                    // Reset resumed flag for this fresh handler invocation
                                    self.handle_contexts.borrow_mut().last_mut().unwrap().resumed = false;

                                    // Bind handler params to signal args
                                    let mut handler_env = env.clone();
                                    for (param, arg) in params.iter().zip(signal.args.iter()) {
                                        match param {
                                            Pattern::Var(name) => {
                                                handler_env.insert(name.clone(), arg.clone());
                                            }
                                            Pattern::Wildcard => {}
                                            _ => {}
                                        }
                                    }

                                    // Eval handler body — if it resumes and body signals again,
                                    // the result will be Err(__effect__) and we loop
                                    result = self.eval(&handler_body, &handler_env);
                                    continue;
                                } else {
                                    // No matching handler — propagate to outer handle
                                    self.handle_contexts.borrow_mut().pop();
                                    *self.effect_signal.borrow_mut() = Some(signal);
                                    return Err(RuntimeError("__effect__".into()));
                                }
                            } else {
                                self.handle_contexts.borrow_mut().pop();
                                return Err(RuntimeError::at(span, "internal: effect signal lost".into()));
                            }
                        }
                        Err(e) => {
                            self.handle_contexts.borrow_mut().pop();
                            return Err(e);
                        }
                    }
                }
            }

            ExprKind::Resume(value_expr) => {
                let value = self.eval(value_expr, env)?;

                // Check for double-resume
                let already_resumed = {
                    let contexts = self.handle_contexts.borrow();
                    contexts.last()
                        .map(|ctx| ctx.resumed)
                        .unwrap_or(false)
                };
                if already_resumed {
                    return Err(RuntimeError::at(span, "resume called more than once (continuation is one-shot)".into()));
                }

                // Get the body and env from the current handle context,
                // and restore outer cursors for correct nested replay
                let (body, body_env) = {
                    let mut contexts = self.handle_contexts.borrow_mut();
                    let ctx_idx = contexts.len() - 1;
                    let ctx = &mut contexts[ctx_idx];
                    ctx.resumed = true;
                    ctx.resume_answers.push(value);
                    ctx.resume_cursor = 0;

                    // Restore outer contexts' cursors to where they were when
                    // this handle started — so nested effects replay correctly
                    let saved = ctx.saved_outer_cursors.clone();
                    for (i, cursor) in saved.into_iter().enumerate() {
                        if i < ctx_idx {
                            contexts[i].resume_cursor = cursor;
                        }
                    }

                    (Rc::clone(&contexts[ctx_idx].body), contexts[ctx_idx].body_env.clone())
                };

                // Re-execute the body — performs will consume resume_answers in order
                self.eval(&body, &body_env)
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

        // Trampoline loop: keep resolving TailCalls until we get a Value.
        // No iteration limit here — TCO is designed for arbitrarily deep tail recursion.
        // Non-tail recursion is caught by the depth counter in eval().
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
            Value::Int(_) | Value::Float(_) | Value::Str(_) | Value::Bool(_) => {
                Err(RuntimeError::at(call_span, format!(
                    "tried to call '{}' as a function, but it's a value — too many arguments?", arg
                )))
            }
            other => Err(RuntimeError::at(call_span, format!(
                "tried to call '{}' as a function — did you pass too many arguments?", other
            ))),
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
                    // Auto-promote to parallel when function is pure and list is large enough
                    if list.len() >= 8 && crate::purity::is_pure_value(func) {
                        let globals = self.globals.borrow().clone();
                        let route = self.route.clone();
                        use rayon::prelude::*;
                        let results: Result<Vec<Value>, RuntimeError> = list.par_iter()
                            .map(|item| {
                                let interp = Interpreter {
                                    globals: RefCell::new(globals.clone()),
                                    route: route.clone(),
                                    effect_signal: RefCell::new(None),
                                    handle_contexts: RefCell::new(Vec::new()),
                                    state: RefCell::new(HashMap::new()),
                                    serve_ctx: None,
                                    depth: RefCell::new(0),
                                };
                                interp.apply(func.clone(), item.clone(), (0, 0))
                            })
                            .collect();
                        return Ok(Value::List(results?));
                    }
                    let mut result = Vec::with_capacity(list.len());
                    for item in list {
                        result.push(self.apply(func.clone(), item.clone(), (0,0))?);
                    }
                    Ok(Value::List(result))
                }
                (_, v) => Err(RuntimeError(format!("map: expected list, got {}", v))),
            },
            "par_map" => match (&args[0], &args[1]) {
                (func, Value::List(list)) => {
                    if list.len() < 4 {
                        // Sequential fallback for small lists
                        let mut result = Vec::with_capacity(list.len());
                        for item in list {
                            result.push(self.apply(func.clone(), item.clone(), (0,0))?);
                        }
                        return Ok(Value::List(result));
                    }
                    // Parallel: each rayon task gets its own interpreter
                    let globals = self.globals.borrow().clone();
                    let route = self.route.clone();
                    use rayon::prelude::*;
                    let results: Result<Vec<Value>, RuntimeError> = list.par_iter()
                        .map(|item| {
                            let interp = Interpreter {
                                globals: RefCell::new(globals.clone()),
                                route: route.clone(),
                                effect_signal: RefCell::new(None),
                                handle_contexts: RefCell::new(Vec::new()),
                                state: RefCell::new(HashMap::new()),
                                serve_ctx: None,
                                depth: RefCell::new(0),
                            };
                            interp.apply(func.clone(), item.clone(), (0, 0))
                        })
                        .collect();
                    Ok(Value::List(results?))
                }
                (_, v) => Err(RuntimeError(format!("par_map: expected list, got {}", v))),
            },
            "filter" => match (&args[0], &args[1]) {
                (func, Value::List(list)) => {
                    // Auto-promote to parallel when function is pure and list is large enough
                    if list.len() >= 8 && crate::purity::is_pure_value(func) {
                        let globals = self.globals.borrow().clone();
                        let route = self.route.clone();
                        use rayon::prelude::*;
                        let results: Result<Vec<Option<Value>>, RuntimeError> = list.par_iter()
                            .map(|item| {
                                let interp = Interpreter {
                                    globals: RefCell::new(globals.clone()),
                                    route: route.clone(),
                                    effect_signal: RefCell::new(None),
                                    handle_contexts: RefCell::new(Vec::new()),
                                    state: RefCell::new(HashMap::new()),
                                    serve_ctx: None,
                                    depth: RefCell::new(0),
                                };
                                match interp.apply(func.clone(), item.clone(), (0, 0))? {
                                    Value::Bool(true) => Ok(Some(item.clone())),
                                    Value::Bool(false) => Ok(None),
                                    v => Err(RuntimeError(format!("filter: predicate returned {}, expected bool", v))),
                                }
                            })
                            .collect();
                        return Ok(Value::List(results?.into_iter().flatten().collect()));
                    }
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
            "par_filter" => match (&args[0], &args[1]) {
                (func, Value::List(list)) => {
                    if list.len() < 4 {
                        let mut result = Vec::new();
                        for item in list {
                            match self.apply(func.clone(), item.clone(), (0,0))? {
                                Value::Bool(true) => result.push(item.clone()),
                                Value::Bool(false) => {}
                                v => return Err(RuntimeError(format!("par_filter: predicate returned {}, expected bool", v))),
                            }
                        }
                        return Ok(Value::List(result));
                    }
                    let globals = self.globals.borrow().clone();
                    let route = self.route.clone();
                    use rayon::prelude::*;
                    let results: Result<Vec<Option<Value>>, RuntimeError> = list.par_iter()
                        .map(|item| {
                            let interp = Interpreter {
                                globals: RefCell::new(globals.clone()),
                                route: route.clone(),
                                effect_signal: RefCell::new(None),
                                handle_contexts: RefCell::new(Vec::new()),
                                state: RefCell::new(HashMap::new()),
                                serve_ctx: None,
                                depth: RefCell::new(0),
                            };
                            match interp.apply(func.clone(), item.clone(), (0, 0))? {
                                Value::Bool(true) => Ok(Some(item.clone())),
                                Value::Bool(false) => Ok(None),
                                v => Err(RuntimeError(format!("par_filter: predicate returned {}, expected bool", v))),
                            }
                        })
                        .collect();
                    Ok(Value::List(results?.into_iter().flatten().collect()))
                }
                (_, v) => Err(RuntimeError(format!("par_filter: expected list, got {}", v))),
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

            // Random
            "random" => {
                // Returns a random float in [0.0, 1.0)
                use std::collections::hash_map::DefaultHasher;
                use std::hash::{Hash, Hasher};
                let mut hasher = DefaultHasher::new();
                std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default().as_nanos().hash(&mut hasher);
                std::thread::current().id().hash(&mut hasher);
                let bits = hasher.finish();
                let f = (bits >> 11) as f64 / (1u64 << 53) as f64;
                Ok(Value::Float(f))
            },
            "random_int" => match (&args[0], &args[1]) {
                // random_int lo hi — returns random int in [lo, hi)
                (Value::Int(lo), Value::Int(hi)) => {
                    if hi <= lo { return Ok(Value::Int(*lo)); }
                    use std::collections::hash_map::DefaultHasher;
                    use std::hash::{Hash, Hasher};
                    let mut hasher = DefaultHasher::new();
                    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default().as_nanos().hash(&mut hasher);
                    std::thread::current().id().hash(&mut hasher);
                    let bits = hasher.finish();
                    let range = (*hi - *lo) as u64;
                    let val = *lo + (bits % range) as i64;
                    Ok(Value::Int(val))
                }
                (a, b) => Err(RuntimeError(format!("random_int: expected (int, int), got ({}, {})", a, b))),
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

            // SQLite operations (route-gated via fs)
            // db_query : db_path -> sql -> [[values]]
            // Returns list of rows, each row is a list of values
            "db_query" => match (&args[0], &args[1]) {
                (Value::Str(db_path), Value::Str(sql)) => {
                    self.route.check_fs(db_path).map_err(RuntimeError)?;
                    match std::process::Command::new("sqlite3")
                        .args(["-json", db_path, sql])
                        .output()
                    {
                        Ok(output) => {
                            if !output.status.success() {
                                let stderr = String::from_utf8_lossy(&output.stderr);
                                return Err(RuntimeError(format!("db_query: {}", stderr.trim())));
                            }
                            let stdout = String::from_utf8_lossy(&output.stdout).to_string();
                            if stdout.trim().is_empty() {
                                return Ok(Value::List(vec![]));
                            }
                            // sqlite3 -json returns JSON array of objects
                            // Parse into list of records
                            match parse_json_value(&stdout) {
                                Ok(val) => Ok(val),
                                Err(e) => Err(RuntimeError(format!("db_query: failed to parse result: {}", e))),
                            }
                        }
                        Err(e) => Err(RuntimeError(format!("db_query: {}", e))),
                    }
                }
                _ => Err(RuntimeError("db_query: expected (db_path, sql_string)".into())),
            },

            // db_execute : db_path -> sql -> Int (rows affected)
            "db_execute" => match (&args[0], &args[1]) {
                (Value::Str(db_path), Value::Str(sql)) => {
                    self.route.check_fs(db_path).map_err(RuntimeError)?;
                    match std::process::Command::new("sqlite3")
                        .args([db_path, sql])
                        .output()
                    {
                        Ok(output) => {
                            if !output.status.success() {
                                let stderr = String::from_utf8_lossy(&output.stderr);
                                return Err(RuntimeError(format!("db_execute: {}", stderr.trim())));
                            }
                            Ok(Value::Int(0))
                        }
                        Err(e) => Err(RuntimeError(format!("db_execute: {}", e))),
                    }
                }
                _ => Err(RuntimeError("db_execute: expected (db_path, sql_string)".into())),
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

            // prompt_model : model -> system -> user -> String
            // Override the model per call. Useful for routing between 9B/27B/cloud.
            "prompt_model" => match (&args[0], &args[1], &args[2]) {
                (Value::Str(model), Value::Str(system), Value::Str(user_prompt)) => {
                    self.route.check_ai().map_err(RuntimeError)?;
                    let config = ai::AiConfig::from_env();
                    match ai::call_llm_with_model(&config, model, system, user_prompt) {
                        Ok(response) => Ok(Value::Str(response)),
                        Err(e) => Err(RuntimeError(format!("prompt_model: {}", e))),
                    }
                }
                _ => Err(RuntimeError("prompt_model: expected three strings (model, system, user)".into())),
            },

            // par_prompt : system -> [inputs] -> [outputs]
            // Fan out LLM calls in parallel. Each input gets the same system prompt.
            "par_prompt" => match (&args[0], &args[1]) {
                (Value::Str(system), Value::List(inputs)) => {
                    self.route.check_ai().map_err(RuntimeError)?;
                    if inputs.is_empty() {
                        return Ok(Value::List(vec![]));
                    }
                    let config = ai::AiConfig::from_env();
                    let system = system.clone();
                    let inputs: Result<Vec<String>, _> = inputs.iter().map(|v| match v {
                        Value::Str(s) => Ok(s.clone()),
                        other => Err(RuntimeError(format!("par_prompt: expected string in list, got {}", other))),
                    }).collect();
                    let inputs = inputs?;

                    // Fan out in batches of 4 to avoid overwhelming the LLM server
                    const MAX_CONCURRENT: usize = 4;
                    let mut results: Vec<Result<String, String>> = Vec::with_capacity(inputs.len());
                    for chunk in inputs.chunks(MAX_CONCURRENT) {
                        let chunk_results: Vec<Result<String, String>> = std::thread::scope(|s| {
                            let handles: Vec<_> = chunk.iter().map(|input| {
                                let sys = &system;
                                let cfg = &config;
                                s.spawn(move || ai::call_llm(cfg, sys, input))
                            }).collect();
                            handles.into_iter().map(|h| h.join().unwrap()).collect()
                        });
                        results.extend(chunk_results);
                    }

                    let mut output = Vec::with_capacity(results.len());
                    for r in results {
                        match r {
                            Ok(text) => output.push(Value::Str(text)),
                            Err(e) => output.push(Value::Str(format!("[error: {}]", e))),
                        }
                    }
                    Ok(Value::List(output))
                }
                _ => Err(RuntimeError("par_prompt: expected (system_string, [input_strings])".into())),
            },

            // llm_usage : () -> {calls: Int, prompt_tokens: Int, completion_tokens: Int}
            "llm_usage" => {
                let (prompt_t, completion_t, calls) = ai::get_usage();
                Ok(Value::Record(vec![
                    ("calls".to_string(), Value::Int(calls as i64)),
                    ("prompt_tokens".to_string(), Value::Int(prompt_t as i64)),
                    ("completion_tokens".to_string(), Value::Int(completion_t as i64)),
                    ("total_tokens".to_string(), Value::Int((prompt_t + completion_t) as i64)),
                ]))
            },

            // llm_reset : () -> ()
            "llm_reset" => {
                ai::reset_usage();
                Ok(Value::Unit)
            },

            // ---- Agent primitives (v0.5) ----

            // agent_loop : system -> tools -> tool_fns -> user_message -> String
            // tools: [(name, description)]
            // tool_fns: [fn(String) -> Value]
            "agent_loop" => match (&args[0], &args[1], &args[2], &args[3]) {
                (Value::Str(system), Value::List(tools), Value::List(tool_fns), Value::Str(user_msg)) => {
                    self.route.check_ai().map_err(RuntimeError)?;
                    // Parse tool specs: list of (name, description) tuples
                    let tool_specs: Result<Vec<(String, String)>, RuntimeError> = tools.iter()
                        .map(|t| match t {
                            Value::Tuple(parts) if parts.len() == 2 => {
                                match (&parts[0], &parts[1]) {
                                    (Value::Str(name), Value::Str(desc)) => Ok((name.clone(), desc.clone())),
                                    _ => Err(RuntimeError("agent_loop: tool must be (name_string, description_string)".into())),
                                }
                            }
                            _ => Err(RuntimeError("agent_loop: tool must be a (name, description) tuple".into())),
                        })
                        .collect();
                    let tool_specs = tool_specs?;

                    if tool_specs.len() != tool_fns.len() {
                        return Err(RuntimeError(format!(
                            "agent_loop: {} tool specs but {} tool functions",
                            tool_specs.len(), tool_fns.len()
                        )));
                    }

                    let apply_fn = |func: &Value, arg: Value| -> Result<Value, RuntimeError> {
                        self.apply(func.clone(), arg, (0, 0))
                    };

                    let (answer, history) = crate::agent::run_agent_loop(
                        system, &tool_specs, user_msg, &apply_fn, tool_fns,
                    )?;

                    // Return record with answer and history
                    let history_vals: Vec<Value> = history.into_iter()
                        .map(|(tool, input, output)| Value::Record(vec![
                            ("tool".to_string(), Value::Str(tool)),
                            ("input".to_string(), Value::Str(input)),
                            ("output".to_string(), Value::Str(output)),
                        ]))
                        .collect();

                    Ok(Value::Record(vec![
                        ("answer".to_string(), Value::Str(answer)),
                        ("history".to_string(), Value::List(history_vals)),
                    ]))
                }
                _ => Err(RuntimeError("agent_loop: expected (system_str, [(name, desc)], [tool_fns], user_str)".into())),
            },

            // prompt_stream : system -> user -> callback -> ()
            // callback receives each content delta as it arrives via SSE streaming
            "prompt_stream" => match (&args[0], &args[1], &args[2]) {
                (Value::Str(system), Value::Str(user_msg), callback) => {
                    self.route.check_ai().map_err(RuntimeError)?;
                    let config = ai::AiConfig::from_env();

                    // Stream via SSE — collect chunks then deliver to callback
                    let mut chunks: Vec<String> = Vec::new();
                    ai::call_llm_stream(&config, system, user_msg, &mut |chunk| {
                        chunks.push(chunk.to_string());
                    }).map_err(|e| RuntimeError(format!("prompt_stream: {}", e)))?;

                    for chunk in chunks {
                        self.apply(callback.clone(), Value::Str(chunk), (0, 0))?;
                    }
                    Ok(Value::Unit)
                }
                _ => Err(RuntimeError("prompt_stream: expected (system_str, user_str, callback_fn)".into())),
            },

            // prompt_typed : schema_desc -> schema_json -> input -> Record
            // Forces JSON output matching the schema, retries on parse failure
            "prompt_typed" => match (&args[0], &args[1], &args[2]) {
                (Value::Str(description), Value::Str(schema), Value::Str(input)) => {
                    self.route.check_ai().map_err(RuntimeError)?;
                    let config = ai::AiConfig::from_env();

                    let system = format!(
                        "{}. You MUST respond with valid JSON matching this schema: {}. \
                         No explanation, no markdown, just the JSON object.",
                        description, schema
                    );

                    // Try up to 3 times
                    for attempt in 0..3 {
                        let response = ai::call_llm(&config, &system, input)
                            .map_err(|e| RuntimeError(format!("prompt_typed: {}", e)))?;

                        // Try to parse as JSON
                        let trimmed = response.trim();
                        // Strip markdown code fences if present
                        let json_str = if trimmed.starts_with("```") {
                            let inner = trimmed.trim_start_matches("```json")
                                .trim_start_matches("```")
                                .trim_end_matches("```")
                                .trim();
                            inner
                        } else {
                            trimmed
                        };

                        match parse_json_value(json_str) {
                            Ok(val) => return Ok(val),
                            Err(e) => {
                                if attempt == 2 {
                                    return Err(RuntimeError(format!(
                                        "prompt_typed: failed to parse JSON after 3 attempts: {}. Last response: {}",
                                        e, &response[..response.len().min(200)]
                                    )));
                                }
                                // Retry with error context
                            }
                        }
                    }
                    unreachable!()
                }
                _ => Err(RuntimeError("prompt_typed: expected (description, schema_json, input)".into())),
            },

            // context_new : system_prompt -> Context
            "context_new" => match &args[0] {
                Value::Str(system) => {
                    let ctx = crate::agent::ConversationContext::new(system);
                    Ok(ctx.to_value())
                }
                v => Err(RuntimeError(format!("context_new: expected string, got {}", v))),
            },

            // context_push : context -> role -> content -> Context
            "context_push" => match (&args[0], &args[1], &args[2]) {
                (ctx_val, Value::Str(role), Value::Str(content)) => {
                    let mut ctx = crate::agent::ConversationContext::from_value(ctx_val)
                        .map_err(RuntimeError)?;
                    ctx.push(role, content);
                    Ok(ctx.to_value())
                }
                _ => Err(RuntimeError("context_push: expected (context, role_str, content_str)".into())),
            },

            // context_prompt : context -> message -> (Context, response_str)
            "context_prompt" => match (&args[0], &args[1]) {
                (ctx_val, Value::Str(message)) => {
                    self.route.check_ai().map_err(RuntimeError)?;
                    let mut ctx = crate::agent::ConversationContext::from_value(ctx_val)
                        .map_err(RuntimeError)?;
                    let response = ctx.prompt(message)
                        .map_err(|e| RuntimeError(format!("context_prompt: {}", e)))?;
                    Ok(Value::Tuple(vec![ctx.to_value(), Value::Str(response)]))
                }
                _ => Err(RuntimeError("context_prompt: expected (context, message_str)".into())),
            },

            // ---- Hot reload ----

            "set_state" => match (&args[0], &args[1]) {
                (Value::Str(key), value) => {
                    self.state.borrow_mut().insert(key.clone(), value.clone());
                    Ok(Value::Unit)
                }
                _ => Err(RuntimeError("set_state: expected (string, value)".into())),
            },

            "get_state" => match &args[0] {
                Value::Str(key) => {
                    Ok(self.state.borrow().get(key).cloned().unwrap_or(Value::Unit))
                }
                _ => Err(RuntimeError("get_state: expected string key".into())),
            },

            "check_reload" => {
                // Check if source file changed. If yes, re-parse and swap globals.
                // Returns true if reloaded, false if no change.
                if let Some(ref ctx_cell) = self.serve_ctx {
                    let ctx = ctx_cell.borrow();
                    let changes = ctx.check_changes();
                    if changes.is_empty() {
                        return Ok(Value::Bool(false));
                    }
                    drop(ctx);

                    // Reload
                    let mut ctx = ctx_cell.borrow_mut();
                    match ctx.reload() {
                        Ok((program, fn_names)) => {
                            eprintln!("[reload] gen {} — swapped: {}",
                                ctx.generation,
                                if fn_names.is_empty() { "(none)".to_string() }
                                else { fn_names.join(", ") });
                            drop(ctx);

                            // Swap globals with new definitions
                            for decl in &program.declarations {
                                let _ = self.register(decl);
                            }
                            Ok(Value::Bool(true))
                        }
                        Err(e) => {
                            eprintln!("[reload] error: {}", e);
                            Ok(Value::Bool(false))
                        }
                    }
                } else {
                    // Not in serve mode — no-op
                    Ok(Value::Bool(false))
                }
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

            // Unit comparisons
            ("==", Value::Unit, Value::Unit) => Ok(Value::Bool(true)),
            ("!=", Value::Unit, Value::Unit) => Ok(Value::Bool(false)),
            ("==", Value::Unit, _) | ("==", _, Value::Unit) => Ok(Value::Bool(false)),
            ("!=", Value::Unit, _) | ("!=", _, Value::Unit) => Ok(Value::Bool(true)),

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
