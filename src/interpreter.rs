/// Rail interpreter — tree-walking evaluator.
/// Evaluates a parsed AST by walking the tree directly.
/// Supports curried functions, pattern matching, ADTs, records, and recursion.

use std::collections::HashMap;
use std::fmt;
use std::io::Write;
use crate::ast::*;

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

impl fmt::Display for RuntimeError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "runtime error: {}", self.0)
    }
}

// ---- Interpreter ----

pub struct Interpreter {
    globals: Env,
}

impl Interpreter {
    pub fn new() -> Self {
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

        Interpreter { globals }
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
        match expr {
            Expr::IntLit(n) => Ok(Value::Int(*n)),
            Expr::FloatLit(f) => Ok(Value::Float(*f)),
            Expr::StrLit(s) => Ok(Value::Str(s.clone())),
            Expr::BoolLit(b) => Ok(Value::Bool(*b)),

            Expr::Var(name) => {
                let val = env.get(name)
                    .or_else(|| self.globals.get(name))
                    .cloned()
                    .ok_or_else(|| RuntimeError(format!("undefined: '{}'", name)))?;

                // Auto-evaluate zero-param closures (thunks like `origin = { ... }`)
                match val {
                    Value::Closure { ref params, ref body, ref env } if params.is_empty() => {
                        self.eval(body, env)
                    }
                    _ => Ok(val),
                }
            }

            Expr::Constructor(name) => {
                self.globals.get(name)
                    .cloned()
                    .ok_or_else(|| RuntimeError(format!("undefined constructor: '{}'", name)))
            }

            Expr::BinOp { op, left, right } => {
                let l = self.eval(left, env)?;
                let r = self.eval(right, env)?;
                self.eval_binop(op, &l, &r)
            }

            Expr::UnaryOp { op, operand } => {
                let v = self.eval(operand, env)?;
                match (op.as_str(), &v) {
                    ("-", Value::Int(n)) => Ok(Value::Int(-n)),
                    ("-", Value::Float(f)) => Ok(Value::Float(-f)),
                    _ => Err(RuntimeError(format!("invalid unary op: {}{}", op, v))),
                }
            }

            Expr::App { func, arg } => {
                let f = self.eval(func, env)?;
                let a = self.eval(arg, env)?;
                self.apply(f, a)
            }

            Expr::Let { name, value, body } => {
                let val = self.eval(value, env)?;
                let mut new_env = env.clone();
                if name != "_" {
                    new_env.insert(name.clone(), val);
                }
                self.eval(body, &new_env)
            }

            Expr::If { cond, then_branch, else_branch } => {
                match self.eval(cond, env)? {
                    Value::Bool(true) => self.eval(then_branch, env),
                    Value::Bool(false) => self.eval(else_branch, env),
                    v => Err(RuntimeError(format!("if condition must be bool, got: {}", v))),
                }
            }

            Expr::Match { scrutinee, arms } => {
                let val = self.eval(scrutinee, env)?;
                for arm in arms {
                    if let Some(bindings) = self.match_pattern(&arm.pattern, &val) {
                        let mut new_env = env.clone();
                        new_env.extend(bindings);
                        return self.eval(&arm.body, &new_env);
                    }
                }
                Err(RuntimeError(format!("non-exhaustive match on: {}", val)))
            }

            Expr::Pipe { value, func } => {
                // x |> f  desugars to  f x
                let v = self.eval(value, env)?;
                let f = self.eval(func, env)?;
                self.apply(f, v)
            }

            Expr::Lambda { params, body } => {
                Ok(Value::Closure {
                    params: params.clone(),
                    body: *body.clone(),
                    env: env.clone(),
                })
            }

            Expr::Tuple(elems) => {
                let vals: Result<Vec<_>, _> = elems.iter()
                    .map(|e| self.eval(e, env))
                    .collect();
                Ok(Value::Tuple(vals?))
            }

            Expr::List(elems) => {
                let vals: Result<Vec<_>, _> = elems.iter()
                    .map(|e| self.eval(e, env))
                    .collect();
                Ok(Value::List(vals?))
            }

            Expr::Record(fields) => {
                let mut vals = Vec::new();
                for (name, expr) in fields {
                    vals.push((name.clone(), self.eval(expr, env)?));
                }
                Ok(Value::Record(vals))
            }

            Expr::FieldAccess { expr, field } => {
                let val = self.eval(expr, env)?;
                match &val {
                    Value::Record(fields) => {
                        for (name, v) in fields {
                            if name == field {
                                return Ok(v.clone());
                            }
                        }
                        Err(RuntimeError(format!("no field '{}' in record", field)))
                    }
                    _ => Err(RuntimeError(format!("field access on non-record: {}", val))),
                }
            }

            Expr::Block(exprs) => {
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

    fn apply(&self, func: Value, arg: Value) -> Result<Value, RuntimeError> {
        match func {
            Value::Closure { params, body, env } if params.is_empty() => {
                // Zero-param closure applied as value — evaluate body, then apply result
                let result = self.eval(&body, &env)?;
                self.apply(result, arg)
            }
            Value::Closure { params, body, env } => {
                // Bind first param
                let mut new_env = env;
                let bindings = self.match_pattern(&params[0], &arg)
                    .ok_or_else(|| RuntimeError(format!(
                        "argument {} doesn't match parameter pattern", arg
                    )))?;
                new_env.extend(bindings);

                if params.len() == 1 {
                    // All params bound — evaluate body
                    self.eval(&body, &new_env)
                } else {
                    // Partial application — return closure with remaining params
                    Ok(Value::Closure {
                        params: params[1..].to_vec(),
                        body,
                        env: new_env,
                    })
                }
            }
            Value::BuiltIn(builtin) => self.apply_builtin(builtin, arg),
            other => Err(RuntimeError(format!("cannot apply non-function: {}", other))),
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
                        result.push(self.apply(func.clone(), item.clone())?);
                    }
                    Ok(Value::List(result))
                }
                (_, v) => Err(RuntimeError(format!("map: expected list, got {}", v))),
            },
            "filter" => match (&args[0], &args[1]) {
                (func, Value::List(list)) => {
                    let mut result = Vec::new();
                    for item in list {
                        match self.apply(func.clone(), item.clone())? {
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
                        let partial = self.apply(func.clone(), acc)?;
                        acc = self.apply(partial, item.clone())?;
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
                    match std::fs::read_to_string(path) {
                        Ok(contents) => Ok(Value::Str(contents)),
                        Err(e) => Ok(Value::Str(format!("{}", e))),
                    }
                }
                v => Err(RuntimeError(format!("read_file: expected string, got {}", v))),
            },
            "write_file" => match (&args[0], &args[1]) {
                (Value::Str(path), Value::Str(content)) => {
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

            _ => Err(RuntimeError(format!("unknown builtin: {}", name))),
        }
    }

    fn eval_binop(&self, op: &str, left: &Value, right: &Value) -> Result<Value, RuntimeError> {
        match (op, left, right) {
            // Integer arithmetic
            ("+", Value::Int(a), Value::Int(b)) => Ok(Value::Int(a + b)),
            ("-", Value::Int(a), Value::Int(b)) => Ok(Value::Int(a - b)),
            ("*", Value::Int(a), Value::Int(b)) => Ok(Value::Int(a * b)),
            ("/", Value::Int(a), Value::Int(b)) => {
                if *b == 0 { return Err(RuntimeError("division by zero".into())); }
                Ok(Value::Int(a / b))
            }
            ("%", Value::Int(a), Value::Int(b)) => {
                if *b == 0 { return Err(RuntimeError("modulo by zero".into())); }
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

            _ => Err(RuntimeError(format!(
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
