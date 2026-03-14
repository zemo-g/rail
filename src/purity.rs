/// Purity analysis for Rail expressions.
/// Pure = no `perform`, no effectful builtins (shell, io, ai, etc.)
/// Used by par_map to decide if safe to parallelize.

use crate::ast::*;
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone, PartialEq)]
pub enum Purity {
    Pure,
    Effectful,
}

/// Effectful builtins — anything that does IO, shell, AI, or mutation
const EFFECTFUL_BUILTINS: &[&str] = &[
    "print", "read_line", "read_file", "write_file",
    "shell", "shell_lines", "env", "timestamp", "sleep_ms",
    "http_get", "http_post",
    "prompt", "prompt_with", "prompt_json", "embed",
];

/// Analyze purity of all functions in a program
#[allow(dead_code)]
pub fn analyze_program(program: &Program) -> HashMap<String, Purity> {
    let mut result = HashMap::new();

    // First pass: direct analysis
    for decl in &program.declarations {
        if let Decl::Func { name, body, .. } = decl {
            let purity = analyze_expr(body);
            result.insert(name.clone(), purity);
        }
    }

    // Second pass: propagate — if f calls g and g is effectful, f is effectful
    let mut changed = true;
    let call_graph = build_call_graph(program);
    while changed {
        changed = false;
        for (name, callees) in &call_graph {
            if result.get(name) == Some(&Purity::Pure) {
                for callee in callees {
                    if result.get(callee) == Some(&Purity::Effectful) {
                        result.insert(name.clone(), Purity::Effectful);
                        changed = true;
                        break;
                    }
                }
            }
        }
    }

    result
}

/// Check if a single expression is pure (no performs, no effectful builtins)
pub fn analyze_expr(expr: &Expr) -> Purity {
    match &expr.kind {
        ExprKind::IntLit(_) | ExprKind::FloatLit(_) | ExprKind::StrLit(_)
        | ExprKind::BoolLit(_) | ExprKind::Var(_) | ExprKind::Constructor(_) => Purity::Pure,

        ExprKind::Perform { .. } => Purity::Effectful,
        ExprKind::Resume(_) => Purity::Effectful,

        ExprKind::Handle { body, handlers } => {
            // Handle itself is effectful (it manages effects)
            let _ = (body, handlers);
            Purity::Effectful
        }

        ExprKind::App { func, arg } => {
            // Check if func is an effectful builtin
            if let ExprKind::Var(name) = &func.kind {
                if EFFECTFUL_BUILTINS.contains(&name.as_str()) {
                    return Purity::Effectful;
                }
            }
            merge(analyze_expr(func), analyze_expr(arg))
        }

        ExprKind::BinOp { left, right, .. } => merge(analyze_expr(left), analyze_expr(right)),
        ExprKind::UnaryOp { operand, .. } => analyze_expr(operand),

        ExprKind::Let { value, body, .. } => merge(analyze_expr(value), analyze_expr(body)),

        ExprKind::If { cond, then_branch, else_branch } => {
            merge(merge(analyze_expr(cond), analyze_expr(then_branch)), analyze_expr(else_branch))
        }

        ExprKind::Match { scrutinee, arms } => {
            let mut p = analyze_expr(scrutinee);
            for arm in arms {
                p = merge(p, analyze_expr(&arm.body));
            }
            p
        }

        ExprKind::Pipe { value, func } => merge(analyze_expr(value), analyze_expr(func)),

        ExprKind::Lambda { body, .. } => analyze_expr(body),

        ExprKind::Tuple(elems) | ExprKind::List(elems) => {
            let mut p = Purity::Pure;
            for e in elems {
                p = merge(p, analyze_expr(e));
            }
            p
        }

        ExprKind::Record(fields) => {
            let mut p = Purity::Pure;
            for (_, e) in fields {
                p = merge(p, analyze_expr(e));
            }
            p
        }

        ExprKind::FieldAccess { expr, .. } => analyze_expr(expr),
        ExprKind::Block(exprs) => {
            let mut p = Purity::Pure;
            for e in exprs {
                p = merge(p, analyze_expr(e));
            }
            p
        }
    }
}

/// Check if a Value (at runtime) is a pure function
pub fn is_pure_value(val: &crate::interpreter::Value) -> bool {
    use crate::interpreter::Value;
    match val {
        Value::Closure { body, .. } => analyze_expr(body) == Purity::Pure,
        Value::BuiltIn(builtin) => {
            let name = match builtin {
                crate::interpreter::BuiltIn::Fn { name, .. } => name.as_str(),
                crate::interpreter::BuiltIn::ConstructorFn { .. } => return true,
            };
            !EFFECTFUL_BUILTINS.contains(&name)
        }
        _ => true, // non-functions are trivially "pure"
    }
}

fn merge(a: Purity, b: Purity) -> Purity {
    if a == Purity::Effectful || b == Purity::Effectful {
        Purity::Effectful
    } else {
        Purity::Pure
    }
}

#[allow(dead_code)]
fn build_call_graph(program: &Program) -> HashMap<String, HashSet<String>> {
    let mut graph = HashMap::new();
    for decl in &program.declarations {
        if let Decl::Func { name, body, .. } = decl {
            let mut callees = HashSet::new();
            collect_calls(body, &mut callees);
            graph.insert(name.clone(), callees);
        }
    }
    graph
}

#[allow(dead_code)]
fn collect_calls(expr: &Expr, callees: &mut HashSet<String>) {
    match &expr.kind {
        ExprKind::App { func, arg } => {
            if let ExprKind::Var(name) = &func.kind {
                callees.insert(name.clone());
            }
            collect_calls(func, callees);
            collect_calls(arg, callees);
        }
        ExprKind::Var(_) | ExprKind::IntLit(_) | ExprKind::FloatLit(_)
        | ExprKind::StrLit(_) | ExprKind::BoolLit(_) | ExprKind::Constructor(_) => {}
        ExprKind::BinOp { left, right, .. } => {
            collect_calls(left, callees);
            collect_calls(right, callees);
        }
        ExprKind::UnaryOp { operand, .. } => collect_calls(operand, callees),
        ExprKind::Let { value, body, .. } => {
            collect_calls(value, callees);
            collect_calls(body, callees);
        }
        ExprKind::If { cond, then_branch, else_branch } => {
            collect_calls(cond, callees);
            collect_calls(then_branch, callees);
            collect_calls(else_branch, callees);
        }
        ExprKind::Match { scrutinee, arms } => {
            collect_calls(scrutinee, callees);
            for arm in arms { collect_calls(&arm.body, callees); }
        }
        ExprKind::Pipe { value, func } => {
            collect_calls(value, callees);
            collect_calls(func, callees);
        }
        ExprKind::Lambda { body, .. } => collect_calls(body, callees),
        ExprKind::Tuple(elems) | ExprKind::List(elems) => {
            for e in elems { collect_calls(e, callees); }
        }
        ExprKind::Record(fields) => {
            for (_, e) in fields { collect_calls(e, callees); }
        }
        ExprKind::FieldAccess { expr, .. } => collect_calls(expr, callees),
        ExprKind::Block(exprs) => {
            for e in exprs { collect_calls(e, callees); }
        }
        ExprKind::Perform { args, .. } => {
            for a in args { collect_calls(a, callees); }
        }
        ExprKind::Handle { body, handlers } => {
            collect_calls(body, callees);
            for h in handlers { collect_calls(&h.body, callees); }
        }
        ExprKind::Resume(e) => collect_calls(e, callees),
    }
}
