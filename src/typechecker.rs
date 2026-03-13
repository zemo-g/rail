/// Rail type checker — Hindley-Milner type inference.
/// Infers types for all expressions and checks them against annotations.
/// Supports let-polymorphism, curried functions, ADTs, and records.

use std::collections::{HashMap, HashSet};
use std::fmt;
use crate::ast::*;

// ---- Types ----

#[derive(Debug, Clone, PartialEq)]
pub enum Type {
    Int,
    Float,
    Str,
    Bool,
    Unit,
    Var(u32),
    Fun(Box<Type>, Box<Type>),
    Tuple(Vec<Type>),
    List(Box<Type>),
    Record(Vec<(String, Type)>),
    Con(String, Vec<Type>), // ADT: Con("Option", [Int])
}

impl fmt::Display for Type {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Type::Int => write!(f, "i32"),
            Type::Float => write!(f, "f64"),
            Type::Str => write!(f, "str"),
            Type::Bool => write!(f, "bool"),
            Type::Unit => write!(f, "()"),
            Type::Var(id) => {
                // Pretty-print high IDs as a, b, c, ...
                if *id >= 1000 {
                    let idx = (*id - 1000) as usize;
                    if idx < 26 {
                        write!(f, "{}", (b'a' + idx as u8) as char)
                    } else {
                        write!(f, "t{}", idx)
                    }
                } else {
                    write!(f, "?{}", id)
                }
            }
            Type::Fun(from, to) => {
                match from.as_ref() {
                    Type::Fun(_, _) => write!(f, "({}) -> {}", from, to),
                    _ => write!(f, "{} -> {}", from, to),
                }
            }
            Type::Tuple(elems) => {
                write!(f, "(")?;
                for (i, t) in elems.iter().enumerate() {
                    if i > 0 { write!(f, ", ")?; }
                    write!(f, "{}", t)?;
                }
                write!(f, ")")
            }
            Type::List(inner) => write!(f, "[{}]", inner),
            Type::Record(fields) => {
                write!(f, "{{ ")?;
                for (i, (name, ty)) in fields.iter().enumerate() {
                    if i > 0 { write!(f, ", ")?; }
                    write!(f, "{}: {}", name, ty)?;
                }
                write!(f, " }}")
            }
            Type::Con(name, args) if args.is_empty() => write!(f, "{}", name),
            Type::Con(name, args) => {
                write!(f, "{}", name)?;
                for arg in args {
                    write!(f, " {}", arg)?;
                }
                Ok(())
            }
        }
    }
}

// ---- Type Schemes (polymorphic types) ----

#[derive(Debug, Clone)]
pub struct Scheme {
    pub vars: Vec<u32>,
    pub ty: Type,
}

impl Scheme {
    fn mono(ty: Type) -> Self {
        Scheme { vars: vec![], ty }
    }
}

impl fmt::Display for Scheme {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.ty)
    }
}

// ---- Type Environment ----

type TypeEnv = HashMap<String, Scheme>;

// ---- Errors ----

#[derive(Debug)]
pub struct TypeError {
    pub message: String,
    pub span: Option<Span>,
}

impl TypeError {
    fn new(message: String) -> Self {
        TypeError { message, span: None }
    }

    fn at(span: Span, message: String) -> Self {
        TypeError { message, span: Some(span) }
    }
}

impl fmt::Display for TypeError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        if let Some((line, col)) = self.span {
            if line > 0 {
                write!(f, "type error at {}:{}: {}", line, col, self.message)
            } else {
                write!(f, "type error: {}", self.message)
            }
        } else {
            write!(f, "type error: {}", self.message)
        }
    }
}

// ---- Type Checker ----

pub struct TypeChecker {
    subst: Vec<Option<Type>>,  // substitution: subst[i] = resolved type for Var(i)
}

/// Result of checking a program
pub struct CheckResult {
    pub declarations: Vec<(String, Type)>,
    pub errors: Vec<TypeError>,
}

impl TypeChecker {
    pub fn new() -> Self {
        TypeChecker { subst: Vec::new() }
    }

    pub fn check_program(&mut self, program: &Program) -> CheckResult {
        let mut env = self.builtin_env();
        let mut declarations = Vec::new();
        let mut errors = Vec::new();

        // First pass: register all type and function declarations
        // so we can handle forward references and recursion
        let mut type_params_map: HashMap<String, Vec<String>> = HashMap::new();
        for decl in &program.declarations {
            match decl {
                Decl::TypeDecl { name, params, variants, .. } => {
                    type_params_map.insert(name.clone(), params.clone());
                    for variant in variants {
                        let ty = self.constructor_type(name, params, variant);
                        env.insert(variant.name.clone(), ty);
                    }
                }
                Decl::RecordDecl { name, params, fields } => {
                    type_params_map.insert(name.clone(), params.clone());
                    // Record fields are checked at use site
                    let _ = (name, params, fields);
                }
                Decl::Func { name, type_sig, params, .. } => {
                    // If there's a type sig, register it now for recursion
                    if let Some(sig) = type_sig {
                        if let Ok(ty) = self.type_expr_to_type(sig, &HashMap::new()) {
                            env.insert(name.clone(), Scheme::mono(ty));
                        }
                    } else {
                        // Fresh type variable for forward reference
                        let tv = self.fresh();
                        env.insert(name.clone(), Scheme::mono(tv));
                    }
                    let _ = params;
                }
                _ => {}
            }
        }

        // Second pass: type-check each function body
        for decl in &program.declarations {
            match decl {
                Decl::Func { name, type_sig, params, body, span } => {
                    match self.check_func(name, type_sig, params, body, &mut env) {
                        Ok(ty) => {
                            let resolved = self.resolve(&ty);
                            let pretty = self.prettify(&resolved);
                            declarations.push((name.clone(), pretty));
                        }
                        Err(e) => {
                            let err_span = e.span.or(Some(*span));
                            errors.push(TypeError {
                                message: format!("in '{}': {}", name, e.message),
                                span: err_span,
                            });
                        }
                    }
                }
                Decl::TypeDecl { name, .. } | Decl::RecordDecl { name, .. } => {
                    declarations.push((name.clone(), Type::Unit)); // placeholder
                }
                _ => {}
            }
        }

        CheckResult { declarations, errors }
    }

    fn check_func(
        &mut self,
        name: &str,
        type_sig: &Option<TypeExpr>,
        params: &[Pattern],
        body: &Expr,
        env: &mut TypeEnv,
    ) -> Result<Type, TypeError> {
        let mut local_env = env.clone();

        if let Some(sig) = type_sig {
            // Has type annotation — check body matches
            let declared = self.type_expr_to_type(sig, &HashMap::new())?;

            // Decompose function type for parameters
            let mut remaining_type = declared.clone();
            for param in params {
                match remaining_type {
                    Type::Fun(param_type, ret_type) => {
                        self.bind_pattern_type(param, &param_type, &mut local_env)?;
                        remaining_type = *ret_type;
                    }
                    _ => {
                        return Err(TypeError::new(
                            "type signature has fewer parameters than definition".to_string(),
                        ));
                    }
                }
            }

            // Infer body type and unify with expected return type
            let body_type = self.infer(body, &local_env)?;
            self.unify(&body_type, &remaining_type).map_err(|e| TypeError {
                message: format!("body type {} doesn't match declared {}: {}",
                    self.resolve(&body_type), self.resolve(&remaining_type), e.message),
                span: Some(body.span),
            })?;

            // Update env with the declared type
            env.insert(name.to_string(), Scheme::mono(declared.clone()));
            Ok(declared)
        } else {
            // No type annotation — infer everything
            let mut param_types = Vec::new();
            for param in params {
                let tv = self.fresh();
                self.bind_pattern_type(param, &tv, &mut local_env)?;
                param_types.push(tv);
            }

            let body_type = self.infer(body, &local_env)?;

            // Build curried function type
            let mut func_type = body_type;
            for pt in param_types.into_iter().rev() {
                func_type = Type::Fun(Box::new(pt), Box::new(func_type));
            }

            // Unify with the pre-registered type variable (for recursion)
            if let Some(scheme) = env.get(name) {
                let existing = scheme.ty.clone();
                self.unify(&func_type, &existing)?;
            }

            let resolved = self.resolve(&func_type);
            let scheme = self.generalize(env, &resolved);
            env.insert(name.to_string(), scheme);
            Ok(resolved)
        }
    }

    fn infer(&mut self, expr: &Expr, env: &TypeEnv) -> Result<Type, TypeError> {
        let span = expr.span;
        match &expr.kind {
            ExprKind::IntLit(_) => Ok(Type::Int),
            ExprKind::FloatLit(_) => Ok(Type::Float),
            ExprKind::StrLit(_) => Ok(Type::Str),
            ExprKind::BoolLit(_) => Ok(Type::Bool),

            ExprKind::Var(name) => {
                let scheme = env.get(name)
                    .ok_or_else(|| TypeError::at(span, format!("undefined: '{}'", name)))?;
                Ok(self.instantiate(scheme))
            }

            ExprKind::Constructor(name) => {
                let scheme = env.get(name)
                    .ok_or_else(|| TypeError::at(span, format!("undefined constructor: '{}'", name)))?;
                Ok(self.instantiate(scheme))
            }

            ExprKind::App { func, arg } => {
                let t_func = self.infer(func, env)?;
                let t_arg = self.infer(arg, env)?;
                let t_ret = self.fresh();
                self.unify(&t_func, &Type::Fun(
                    Box::new(t_arg),
                    Box::new(t_ret.clone()),
                )).map_err(|e| TypeError { span: Some(span), ..e })?;
                Ok(t_ret)
            }

            ExprKind::Let { name, value, body } => {
                let t_val = self.infer(value, env)?;
                let resolved = self.resolve(&t_val);
                let scheme = if name == "_" {
                    Scheme::mono(resolved)
                } else {
                    self.generalize(env, &resolved)
                };
                let mut new_env = env.clone();
                if name != "_" {
                    new_env.insert(name.clone(), scheme);
                }
                self.infer(body, &new_env)
            }

            ExprKind::If { cond, then_branch, else_branch } => {
                let t_cond = self.infer(cond, env)?;
                self.unify(&t_cond, &Type::Bool).map_err(|e| TypeError { span: Some(cond.span), ..e })?;
                let t_then = self.infer(then_branch, env)?;
                let t_else = self.infer(else_branch, env)?;
                self.unify(&t_then, &t_else).map_err(|e| TypeError { span: Some(span), ..e })?;
                Ok(t_then)
            }

            ExprKind::BinOp { op, left, right } => {
                let t_left = self.infer(left, env)?;
                let t_right = self.infer(right, env)?;
                self.infer_binop(op, &t_left, &t_right).map_err(|e| TypeError { span: Some(span), ..e })
            }

            ExprKind::UnaryOp { op, operand } => {
                let t = self.infer(operand, env)?;
                match op.as_str() {
                    "-" => {
                        // Must be numeric
                        let num = self.fresh();
                        self.unify(&t, &num)?;
                        // We don't have type classes, so accept Int or Float
                        Ok(t)
                    }
                    _ => Err(TypeError::at(span, format!("unknown unary op: {}", op))),
                }
            }

            ExprKind::Match { scrutinee, arms } => {
                let t_scrut = self.infer(scrutinee, env)?;
                let t_result = self.fresh();

                for arm in arms {
                    let mut arm_env = env.clone();
                    let t_pat = self.infer_pattern(&arm.pattern, &mut arm_env)?;
                    self.unify(&t_scrut, &t_pat)?;
                    let t_body = self.infer(&arm.body, &arm_env)?;
                    self.unify(&t_result, &t_body)?;
                }

                Ok(t_result)
            }

            ExprKind::Pipe { value, func } => {
                // x |> f  ≡  f x
                let t_val = self.infer(value, env)?;
                let t_func = self.infer(func, env)?;
                let t_ret = self.fresh();
                self.unify(&t_func, &Type::Fun(
                    Box::new(t_val),
                    Box::new(t_ret.clone()),
                )).map_err(|e| TypeError { span: Some(span), ..e })?;
                Ok(t_ret)
            }

            ExprKind::Lambda { params, body } => {
                let mut local_env = env.clone();
                let mut param_types = Vec::new();
                for param in params {
                    let tv = self.fresh();
                    self.bind_pattern_type(param, &tv, &mut local_env)?;
                    param_types.push(tv);
                }
                let t_body = self.infer(body, &local_env)?;
                let mut func_type = t_body;
                for pt in param_types.into_iter().rev() {
                    func_type = Type::Fun(Box::new(pt), Box::new(func_type));
                }
                Ok(func_type)
            }

            ExprKind::Tuple(elems) => {
                let types: Result<Vec<_>, _> = elems.iter()
                    .map(|e| self.infer(e, env))
                    .collect();
                Ok(Type::Tuple(types?))
            }

            ExprKind::List(elems) => {
                if elems.is_empty() {
                    Ok(Type::List(Box::new(self.fresh())))
                } else {
                    let t_first = self.infer(&elems[0], env)?;
                    for elem in &elems[1..] {
                        let t = self.infer(elem, env)?;
                        self.unify(&t_first, &t)?;
                    }
                    Ok(Type::List(Box::new(t_first)))
                }
            }

            ExprKind::Record(fields) => {
                let mut field_types = Vec::new();
                for (name, expr) in fields {
                    let ty = self.infer(expr, env)?;
                    field_types.push((name.clone(), ty));
                }
                Ok(Type::Record(field_types))
            }

            ExprKind::FieldAccess { expr, field } => {
                let t_expr = self.infer(expr, env)?;
                let t_expr = self.resolve(&t_expr);
                match &t_expr {
                    Type::Record(fields) => {
                        for (name, ty) in fields {
                            if name == field {
                                return Ok(ty.clone());
                            }
                        }
                        Err(TypeError::at(span, format!("no field '{}' in record type", field)))
                    }
                    _ => {
                        // Can't infer field access on unknown type — use a fresh var
                        let tv = self.fresh();
                        Ok(tv)
                    }
                }
            }

            ExprKind::Block(exprs) => {
                if exprs.is_empty() {
                    return Ok(Type::Unit);
                }
                let mut ty = Type::Unit;
                for expr in exprs {
                    ty = self.infer(expr, env)?;
                }
                Ok(ty)
            }
        }
    }

    fn infer_binop(&mut self, op: &str, t_left: &Type, t_right: &Type) -> Result<Type, TypeError> {
        match op {
            "+" | "-" | "*" | "/" | "%" => {
                self.unify(t_left, t_right)?;
                // Result is same type as operands (numeric)
                Ok(self.resolve(t_left))
            }
            "==" | "!=" | "<" | ">" | "<=" | ">=" => {
                self.unify(t_left, t_right)?;
                Ok(Type::Bool)
            }
            "&&" | "||" => {
                self.unify(t_left, &Type::Bool)?;
                self.unify(t_right, &Type::Bool)?;
                Ok(Type::Bool)
            }
            _ => Err(TypeError::new(format!("unknown operator: {}", op))),
        }
    }

    fn infer_pattern(&mut self, pattern: &Pattern, env: &mut TypeEnv) -> Result<Type, TypeError> {
        match pattern {
            Pattern::Wildcard => Ok(self.fresh()),
            Pattern::Var(name) => {
                let tv = self.fresh();
                env.insert(name.clone(), Scheme::mono(tv.clone()));
                Ok(tv)
            }
            Pattern::IntLit(_) => Ok(Type::Int),
            Pattern::FloatLit(_) => Ok(Type::Float),
            Pattern::StrLit(_) => Ok(Type::Str),
            Pattern::BoolLit(_) => Ok(Type::Bool),
            Pattern::Constructor { name, args } => {
                // Look up constructor type, instantiate, apply pattern args
                let scheme = env.get(name)
                    .ok_or_else(|| TypeError::new(format!("undefined constructor in pattern: '{}'", name)))?
                    .clone();
                let mut con_type = self.instantiate(&scheme);

                for arg_pat in args {
                    let t_arg = self.infer_pattern(arg_pat, env)?;
                    let t_ret = self.fresh();
                    self.unify(&con_type, &Type::Fun(
                        Box::new(t_arg),
                        Box::new(t_ret.clone()),
                    ))?;
                    con_type = t_ret;
                }
                Ok(con_type)
            }
            Pattern::Tuple(pats) => {
                let types: Result<Vec<_>, _> = pats.iter()
                    .map(|p| self.infer_pattern(p, env))
                    .collect();
                Ok(Type::Tuple(types?))
            }
        }
    }

    fn bind_pattern_type(&mut self, pattern: &Pattern, ty: &Type, env: &mut TypeEnv) -> Result<(), TypeError> {
        match pattern {
            Pattern::Wildcard => Ok(()),
            Pattern::Var(name) => {
                env.insert(name.clone(), Scheme::mono(ty.clone()));
                Ok(())
            }
            Pattern::Tuple(pats) => {
                let types: Vec<Type> = pats.iter().map(|_| self.fresh()).collect();
                self.unify(ty, &Type::Tuple(types.clone()))?;
                for (pat, t) in pats.iter().zip(types.iter()) {
                    self.bind_pattern_type(pat, t, env)?;
                }
                Ok(())
            }
            _ => Ok(()), // Literal patterns don't bind
        }
    }

    // ---- Unification ----

    fn unify(&mut self, t1: &Type, t2: &Type) -> Result<(), TypeError> {
        let t1 = self.resolve(t1);
        let t2 = self.resolve(t2);

        if t1 == t2 { return Ok(()); }

        match (&t1, &t2) {
            (Type::Var(id), _) => {
                if self.occurs(*id, &t2) {
                    return Err(TypeError::new(format!("infinite type: ?{} ~ {}", id, t2)));
                }
                self.subst[*id as usize] = Some(t2);
                Ok(())
            }
            (_, Type::Var(_)) => self.unify(&t2, &t1),

            (Type::Fun(a1, b1), Type::Fun(a2, b2)) => {
                self.unify(a1, a2)?;
                self.unify(b1, b2)
            }

            (Type::Tuple(a), Type::Tuple(b)) if a.len() == b.len() => {
                for (x, y) in a.iter().zip(b.iter()) {
                    self.unify(x, y)?;
                }
                Ok(())
            }

            (Type::List(a), Type::List(b)) => self.unify(a, b),

            (Type::Record(a), Type::Record(b)) if a.len() == b.len() => {
                for ((na, ta), (nb, tb)) in a.iter().zip(b.iter()) {
                    if na != nb {
                        return Err(TypeError::new(format!("record field mismatch: {} vs {}", na, nb)));
                    }
                    self.unify(ta, tb)?;
                }
                Ok(())
            }

            (Type::Con(n1, a1), Type::Con(n2, a2)) if n1 == n2 && a1.len() == a2.len() => {
                for (x, y) in a1.iter().zip(a2.iter()) {
                    self.unify(x, y)?;
                }
                Ok(())
            }

            _ => Err(TypeError::new(format!("cannot unify {} with {}", t1, t2))),
        }
    }

    fn occurs(&self, id: u32, ty: &Type) -> bool {
        let ty = self.resolve(ty);
        match &ty {
            Type::Var(other) => *other == id,
            Type::Fun(a, b) => self.occurs(id, a) || self.occurs(id, b),
            Type::Tuple(ts) => ts.iter().any(|t| self.occurs(id, t)),
            Type::List(t) => self.occurs(id, t),
            Type::Record(fields) => fields.iter().any(|(_, t)| self.occurs(id, t)),
            Type::Con(_, args) => args.iter().any(|t| self.occurs(id, t)),
            _ => false,
        }
    }

    // ---- Resolution ----

    fn resolve(&self, ty: &Type) -> Type {
        match ty {
            Type::Var(id) => {
                match &self.subst[*id as usize] {
                    Some(t) => self.resolve(t),
                    None => ty.clone(),
                }
            }
            Type::Fun(a, b) => Type::Fun(
                Box::new(self.resolve(a)),
                Box::new(self.resolve(b)),
            ),
            Type::Tuple(ts) => Type::Tuple(ts.iter().map(|t| self.resolve(t)).collect()),
            Type::List(t) => Type::List(Box::new(self.resolve(t))),
            Type::Record(fields) => Type::Record(
                fields.iter().map(|(n, t)| (n.clone(), self.resolve(t))).collect()
            ),
            Type::Con(name, args) => Type::Con(
                name.clone(),
                args.iter().map(|t| self.resolve(t)).collect(),
            ),
            _ => ty.clone(),
        }
    }

    /// Replace remaining type variables with nice names: a, b, c, ...
    fn prettify(&self, ty: &Type) -> Type {
        let mut vars = Vec::new();
        self.collect_vars(ty, &mut vars);
        if vars.is_empty() { return ty.clone(); }

        let mut mapping = HashMap::new();
        let mut next_id = 1000; // high IDs for pretty names
        for v in &vars {
            if !mapping.contains_key(v) {
                mapping.insert(*v, next_id);
                next_id += 1;
            }
        }
        self.remap_vars(ty, &mapping)
    }

    fn collect_vars(&self, ty: &Type, vars: &mut Vec<u32>) {
        match ty {
            Type::Var(id) => { if !vars.contains(id) { vars.push(*id); } }
            Type::Fun(a, b) => { self.collect_vars(a, vars); self.collect_vars(b, vars); }
            Type::Tuple(ts) => { for t in ts { self.collect_vars(t, vars); } }
            Type::List(t) => self.collect_vars(t, vars),
            Type::Record(fields) => { for (_, t) in fields { self.collect_vars(t, vars); } }
            Type::Con(_, args) => { for t in args { self.collect_vars(t, vars); } }
            _ => {}
        }
    }

    fn remap_vars(&self, ty: &Type, mapping: &HashMap<u32, u32>) -> Type {
        match ty {
            Type::Var(id) => Type::Var(*mapping.get(id).unwrap_or(id)),
            Type::Fun(a, b) => Type::Fun(
                Box::new(self.remap_vars(a, mapping)),
                Box::new(self.remap_vars(b, mapping)),
            ),
            Type::Tuple(ts) => Type::Tuple(ts.iter().map(|t| self.remap_vars(t, mapping)).collect()),
            Type::List(t) => Type::List(Box::new(self.remap_vars(t, mapping))),
            Type::Record(fields) => Type::Record(
                fields.iter().map(|(n, t)| (n.clone(), self.remap_vars(t, mapping))).collect()
            ),
            Type::Con(name, args) => Type::Con(
                name.clone(),
                args.iter().map(|t| self.remap_vars(t, mapping)).collect(),
            ),
            _ => ty.clone(),
        }
    }

    // ---- Generalization / Instantiation ----

    fn generalize(&self, env: &TypeEnv, ty: &Type) -> Scheme {
        let ty = self.resolve(ty);
        let free_in_ty = self.free_vars(&ty);
        let free_in_env = self.free_vars_env(env);
        let vars: Vec<u32> = free_in_ty.difference(&free_in_env).copied().collect();
        Scheme { vars, ty }
    }

    fn instantiate(&mut self, scheme: &Scheme) -> Type {
        if scheme.vars.is_empty() {
            return scheme.ty.clone();
        }
        let mapping: HashMap<u32, Type> = scheme.vars.iter()
            .map(|&v| (v, self.fresh()))
            .collect();
        self.apply_mapping(&scheme.ty, &mapping)
    }

    fn apply_mapping(&self, ty: &Type, mapping: &HashMap<u32, Type>) -> Type {
        match ty {
            Type::Var(id) => {
                if let Some(t) = mapping.get(id) {
                    t.clone()
                } else if let Some(t) = &self.subst[*id as usize] {
                    self.apply_mapping(t, mapping)
                } else {
                    ty.clone()
                }
            }
            Type::Fun(a, b) => Type::Fun(
                Box::new(self.apply_mapping(a, mapping)),
                Box::new(self.apply_mapping(b, mapping)),
            ),
            Type::Tuple(ts) => Type::Tuple(
                ts.iter().map(|t| self.apply_mapping(t, mapping)).collect()
            ),
            Type::List(t) => Type::List(Box::new(self.apply_mapping(t, mapping))),
            Type::Record(fields) => Type::Record(
                fields.iter().map(|(n, t)| (n.clone(), self.apply_mapping(t, mapping))).collect()
            ),
            Type::Con(name, args) => Type::Con(
                name.clone(),
                args.iter().map(|t| self.apply_mapping(t, mapping)).collect(),
            ),
            _ => ty.clone(),
        }
    }

    fn free_vars(&self, ty: &Type) -> HashSet<u32> {
        let ty = self.resolve(ty);
        let mut vars = HashSet::new();
        self.collect_free_vars(&ty, &mut vars);
        vars
    }

    fn collect_free_vars(&self, ty: &Type, vars: &mut HashSet<u32>) {
        match ty {
            Type::Var(id) => { vars.insert(*id); }
            Type::Fun(a, b) => {
                self.collect_free_vars(a, vars);
                self.collect_free_vars(b, vars);
            }
            Type::Tuple(ts) => { for t in ts { self.collect_free_vars(t, vars); } }
            Type::List(t) => self.collect_free_vars(t, vars),
            Type::Record(fields) => { for (_, t) in fields { self.collect_free_vars(t, vars); } }
            Type::Con(_, args) => { for t in args { self.collect_free_vars(t, vars); } }
            _ => {}
        }
    }

    fn free_vars_env(&self, env: &TypeEnv) -> HashSet<u32> {
        let mut vars = HashSet::new();
        for scheme in env.values() {
            let scheme_free = self.free_vars(&scheme.ty);
            let bound: HashSet<u32> = scheme.vars.iter().copied().collect();
            vars.extend(scheme_free.difference(&bound));
        }
        vars
    }

    // ---- Helpers ----

    fn fresh(&mut self) -> Type {
        let id = self.subst.len() as u32;
        self.subst.push(None);
        Type::Var(id)
    }

    fn constructor_type(&mut self, type_name: &str, type_params: &[String], variant: &Variant) -> Scheme {
        // For each type parameter, create a type variable
        let mut param_mapping: HashMap<String, Type> = HashMap::new();
        let mut scheme_vars = Vec::new();
        for param in type_params {
            let tv = self.fresh();
            if let Type::Var(id) = tv {
                scheme_vars.push(id);
            }
            param_mapping.insert(param.clone(), tv);
        }

        let result_type = if type_params.is_empty() {
            Type::Con(type_name.to_string(), vec![])
        } else {
            Type::Con(
                type_name.to_string(),
                type_params.iter().map(|p| param_mapping[p].clone()).collect(),
            )
        };

        if variant.fields.is_empty() {
            // Nullary constructor: e.g., None : forall a. Option a
            Scheme { vars: scheme_vars, ty: result_type }
        } else {
            // Constructor function: e.g., Some : forall a. a -> Option a
            let mut ty = result_type;
            for field in variant.fields.iter().rev() {
                let field_type = self.type_expr_to_type_with_params(field, &param_mapping);
                ty = Type::Fun(Box::new(field_type), Box::new(ty));
            }
            Scheme { vars: scheme_vars, ty }
        }
    }

    fn type_expr_to_type_with_params(&self, texpr: &TypeExpr, params: &HashMap<String, Type>) -> Type {
        match texpr {
            TypeExpr::Named(name) => {
                if let Some(ty) = params.get(name) {
                    return ty.clone();
                }
                match name.as_str() {
                    "i32" | "i64" | "int" => Type::Int,
                    "f32" | "f64" | "float" => Type::Float,
                    "str" | "string" => Type::Str,
                    "bool" => Type::Bool,
                    _ => Type::Con(name.clone(), vec![]),
                }
            }
            TypeExpr::Func { from, to } => Type::Fun(
                Box::new(self.type_expr_to_type_with_params(from, params)),
                Box::new(self.type_expr_to_type_with_params(to, params)),
            ),
            TypeExpr::Tuple(ts) => Type::Tuple(
                ts.iter().map(|t| self.type_expr_to_type_with_params(t, params)).collect()
            ),
            TypeExpr::List(t) => Type::List(
                Box::new(self.type_expr_to_type_with_params(t, params))
            ),
            TypeExpr::Record(fields) => Type::Record(
                fields.iter().map(|(n, t)| (n.clone(), self.type_expr_to_type_with_params(t, params))).collect()
            ),
            _ => Type::Unit, // Optional, Result, App — handle later
        }
    }

    fn type_expr_to_type(&mut self, texpr: &TypeExpr, params: &HashMap<String, Type>) -> Result<Type, TypeError> {
        Ok(self.type_expr_to_type_with_params(texpr, params))
    }

    fn builtin_env(&mut self) -> TypeEnv {
        let mut env = TypeEnv::new();

        // print : a -> ()
        let a = self.fresh();
        let a_id = if let Type::Var(id) = a { id } else { unreachable!() };
        env.insert("print".to_string(), Scheme {
            vars: vec![a_id],
            ty: Type::Fun(Box::new(a), Box::new(Type::Unit)),
        });

        // show : a -> str
        let a = self.fresh();
        let a_id = if let Type::Var(id) = a { id } else { unreachable!() };
        env.insert("show".to_string(), Scheme {
            vars: vec![a_id],
            ty: Type::Fun(Box::new(a), Box::new(Type::Str)),
        });

        // not : bool -> bool
        env.insert("not".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Bool), Box::new(Type::Bool))
        ));

        // map : (a -> b) -> [a] -> [b]
        let a = self.fresh();
        let b = self.fresh();
        let (a_id, b_id) = match (&a, &b) {
            (Type::Var(ai), Type::Var(bi)) => (*ai, *bi),
            _ => unreachable!(),
        };
        env.insert("map".to_string(), Scheme {
            vars: vec![a_id, b_id],
            ty: Type::Fun(
                Box::new(Type::Fun(Box::new(a.clone()), Box::new(b.clone()))),
                Box::new(Type::Fun(
                    Box::new(Type::List(Box::new(a))),
                    Box::new(Type::List(Box::new(b))),
                )),
            ),
        });

        // filter : (a -> bool) -> [a] -> [a]
        let a = self.fresh();
        let a_id = if let Type::Var(id) = a { id } else { unreachable!() };
        env.insert("filter".to_string(), Scheme {
            vars: vec![a_id],
            ty: Type::Fun(
                Box::new(Type::Fun(Box::new(a.clone()), Box::new(Type::Bool))),
                Box::new(Type::Fun(
                    Box::new(Type::List(Box::new(a.clone()))),
                    Box::new(Type::List(Box::new(a))),
                )),
            ),
        });

        // fold : b -> (b -> a -> b) -> [a] -> b
        let a = self.fresh();
        let b = self.fresh();
        let (a_id, b_id) = match (&a, &b) {
            (Type::Var(ai), Type::Var(bi)) => (*ai, *bi),
            _ => unreachable!(),
        };
        env.insert("fold".to_string(), Scheme {
            vars: vec![a_id, b_id],
            ty: Type::Fun(
                Box::new(b.clone()),
                Box::new(Type::Fun(
                    Box::new(Type::Fun(Box::new(b.clone()), Box::new(Type::Fun(Box::new(a.clone()), Box::new(b.clone()))))),
                    Box::new(Type::Fun(
                        Box::new(Type::List(Box::new(a))),
                        Box::new(b),
                    )),
                )),
            ),
        });

        // head : [a] -> a
        let a = self.fresh();
        let a_id = if let Type::Var(id) = a { id } else { unreachable!() };
        env.insert("head".to_string(), Scheme {
            vars: vec![a_id],
            ty: Type::Fun(Box::new(Type::List(Box::new(a.clone()))), Box::new(a)),
        });

        // tail : [a] -> [a]
        let a = self.fresh();
        let a_id = if let Type::Var(id) = a { id } else { unreachable!() };
        env.insert("tail".to_string(), Scheme {
            vars: vec![a_id],
            ty: Type::Fun(
                Box::new(Type::List(Box::new(a.clone()))),
                Box::new(Type::List(Box::new(a))),
            ),
        });

        // length : [a] -> i32
        let a = self.fresh();
        let a_id = if let Type::Var(id) = a { id } else { unreachable!() };
        env.insert("length".to_string(), Scheme {
            vars: vec![a_id],
            ty: Type::Fun(Box::new(Type::List(Box::new(a))), Box::new(Type::Int)),
        });

        // range : i32 -> i32 -> [i32]
        env.insert("range".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Int), Box::new(
                Type::Fun(Box::new(Type::Int), Box::new(Type::List(Box::new(Type::Int))))
            ))
        ));

        // cons : a -> [a] -> [a]
        let a = self.fresh();
        let a_id = if let Type::Var(id) = a { id } else { unreachable!() };
        env.insert("cons".to_string(), Scheme {
            vars: vec![a_id],
            ty: Type::Fun(
                Box::new(a.clone()),
                Box::new(Type::Fun(
                    Box::new(Type::List(Box::new(a.clone()))),
                    Box::new(Type::List(Box::new(a))),
                )),
            ),
        });

        // append : [a] -> [a] -> [a]
        let a = self.fresh();
        let a_id = if let Type::Var(id) = a { id } else { unreachable!() };
        env.insert("append".to_string(), Scheme {
            vars: vec![a_id],
            ty: Type::Fun(
                Box::new(Type::List(Box::new(a.clone()))),
                Box::new(Type::Fun(
                    Box::new(Type::List(Box::new(a.clone()))),
                    Box::new(Type::List(Box::new(a))),
                )),
            ),
        });

        // reverse : [a] -> [a]
        let a = self.fresh();
        let a_id = if let Type::Var(id) = a { id } else { unreachable!() };
        env.insert("reverse".to_string(), Scheme {
            vars: vec![a_id],
            ty: Type::Fun(
                Box::new(Type::List(Box::new(a.clone()))),
                Box::new(Type::List(Box::new(a))),
            ),
        });

        // sort : [a] -> [a]
        let a = self.fresh();
        let a_id = if let Type::Var(id) = a { id } else { unreachable!() };
        env.insert("sort".to_string(), Scheme {
            vars: vec![a_id],
            ty: Type::Fun(
                Box::new(Type::List(Box::new(a.clone()))),
                Box::new(Type::List(Box::new(a))),
            ),
        });

        // zip : [a] -> [b] -> [(a, b)]
        let a = self.fresh();
        let b = self.fresh();
        let (a_id, b_id) = match (&a, &b) {
            (Type::Var(ai), Type::Var(bi)) => (*ai, *bi),
            _ => unreachable!(),
        };
        env.insert("zip".to_string(), Scheme {
            vars: vec![a_id, b_id],
            ty: Type::Fun(
                Box::new(Type::List(Box::new(a.clone()))),
                Box::new(Type::Fun(
                    Box::new(Type::List(Box::new(b.clone()))),
                    Box::new(Type::List(Box::new(Type::Tuple(vec![a, b])))),
                )),
            ),
        });

        // enumerate : [a] -> [(i32, a)]
        let a = self.fresh();
        let a_id = if let Type::Var(id) = a { id } else { unreachable!() };
        env.insert("enumerate".to_string(), Scheme {
            vars: vec![a_id],
            ty: Type::Fun(
                Box::new(Type::List(Box::new(a.clone()))),
                Box::new(Type::List(Box::new(Type::Tuple(vec![Type::Int, a])))),
            ),
        });

        // Numeric builtins
        env.insert("int_to_float".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Int), Box::new(Type::Float))
        ));
        env.insert("floor".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Float), Box::new(Type::Int))
        ));
        env.insert("ceil".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Float), Box::new(Type::Int))
        ));

        // abs : a -> a (numeric, but we approximate with polymorphism)
        let a = self.fresh();
        let a_id = if let Type::Var(id) = a { id } else { unreachable!() };
        env.insert("abs".to_string(), Scheme {
            vars: vec![a_id],
            ty: Type::Fun(Box::new(a.clone()), Box::new(a)),
        });

        // max, min : a -> a -> a
        for name in &["max", "min"] {
            let a = self.fresh();
            let a_id = if let Type::Var(id) = a { id } else { unreachable!() };
            env.insert(name.to_string(), Scheme {
                vars: vec![a_id],
                ty: Type::Fun(Box::new(a.clone()), Box::new(
                    Type::Fun(Box::new(a.clone()), Box::new(a))
                )),
            });
        }

        // mod : i32 -> i32 -> i32
        env.insert("mod".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Int), Box::new(
                Type::Fun(Box::new(Type::Int), Box::new(Type::Int))
            ))
        ));

        // --- IO ---

        // read_line : () -> str
        env.insert("read_line".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Unit), Box::new(Type::Str))
        ));

        // read_file : str -> str
        env.insert("read_file".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(Type::Str))
        ));

        // write_file : str -> str -> ()
        env.insert("write_file".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(
                Type::Fun(Box::new(Type::Str), Box::new(Type::Unit))
            ))
        ));

        // --- String operations ---

        // split : str -> str -> [str]
        env.insert("split".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(
                Type::Fun(Box::new(Type::Str), Box::new(Type::List(Box::new(Type::Str))))
            ))
        ));

        // join : str -> [str] -> str
        env.insert("join".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(
                Type::Fun(Box::new(Type::List(Box::new(Type::Str))), Box::new(Type::Str))
            ))
        ));

        // trim : str -> str
        env.insert("trim".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(Type::Str))
        ));

        // chars : str -> [str]
        env.insert("chars".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(Type::List(Box::new(Type::Str))))
        ));

        // contains : str -> str -> bool
        env.insert("contains".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(
                Type::Fun(Box::new(Type::Str), Box::new(Type::Bool))
            ))
        ));

        // starts_with : str -> str -> bool
        env.insert("starts_with".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(
                Type::Fun(Box::new(Type::Str), Box::new(Type::Bool))
            ))
        ));

        // ends_with : str -> str -> bool
        env.insert("ends_with".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(
                Type::Fun(Box::new(Type::Str), Box::new(Type::Bool))
            ))
        ));

        // to_upper : str -> str
        env.insert("to_upper".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(Type::Str))
        ));

        // to_lower : str -> str
        env.insert("to_lower".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(Type::Str))
        ));

        // replace : str -> str -> str -> str
        env.insert("replace".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(
                Type::Fun(Box::new(Type::Str), Box::new(
                    Type::Fun(Box::new(Type::Str), Box::new(Type::Str))
                ))
            ))
        ));

        // substring : i32 -> i32 -> str -> str
        env.insert("substring".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Int), Box::new(
                Type::Fun(Box::new(Type::Int), Box::new(
                    Type::Fun(Box::new(Type::Str), Box::new(Type::Str))
                ))
            ))
        ));

        // --- Math ---

        // sqrt : f64 -> f64
        env.insert("sqrt".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Float), Box::new(Type::Float))
        ));

        // pow : f64 -> f64 -> f64
        env.insert("pow".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Float), Box::new(
                Type::Fun(Box::new(Type::Float), Box::new(Type::Float))
            ))
        ));

        // log : f64 -> f64
        env.insert("log".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Float), Box::new(Type::Float))
        ));

        // sin : f64 -> f64
        env.insert("sin".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Float), Box::new(Type::Float))
        ));

        // cos : f64 -> f64
        env.insert("cos".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Float), Box::new(Type::Float))
        ));

        // tan : f64 -> f64
        env.insert("tan".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Float), Box::new(Type::Float))
        ));

        // pi : () -> f64
        env.insert("pi".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Unit), Box::new(Type::Float))
        ));

        // e : () -> f64
        env.insert("e".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Unit), Box::new(Type::Float))
        ));

        // --- Conversion ---

        // parse_int : str -> i32
        env.insert("parse_int".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(Type::Int))
        ));

        // parse_float : str -> f64
        env.insert("parse_float".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(Type::Float))
        ));

        // float_to_str : f64 -> str
        env.insert("float_to_str".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Float), Box::new(Type::Str))
        ));

        // --- AI ---

        // prompt : str -> str
        env.insert("prompt".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(Type::Str))
        ));

        // prompt_with : str -> str -> str
        env.insert("prompt_with".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(
                Type::Fun(Box::new(Type::Str), Box::new(Type::Str))
            ))
        ));

        // prompt_json : str -> str -> str
        env.insert("prompt_json".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(
                Type::Fun(Box::new(Type::Str), Box::new(Type::Str))
            ))
        ));

        // embed : str -> [f64]
        env.insert("embed".to_string(), Scheme::mono(
            Type::Fun(Box::new(Type::Str), Box::new(Type::List(Box::new(Type::Float))))
        ));

        env
    }
}
