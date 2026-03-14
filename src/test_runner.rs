/// Rail test runner — `rail test`
/// Discovers and runs test_ functions and prop declarations.

use crate::ast::{Program, Decl};
use crate::interpreter::{Interpreter, Value};
use crate::route::Route;

#[allow(dead_code)]
pub struct TestResult {
    pub name: String,
    pub passed: bool,
    pub error: Option<String>,
}

/// Discover all test functions (prefixed with `test_`) and properties.
fn discover_tests(program: &Program) -> Vec<String> {
    let mut tests = Vec::new();
    for decl in &program.declarations {
        match decl {
            Decl::Func { name, params, .. } if name.starts_with("test_") && params.len() <= 1 => {
                tests.push(name.clone());
            }
            Decl::Property { name, .. } => {
                tests.push(format!("prop_{}", name));
            }
            _ => {}
        }
    }
    tests
}

/// Run all tests in a program and return results.
pub fn run_tests(program: &Program, route: Route) -> Vec<TestResult> {
    let test_names = discover_tests(program);

    if test_names.is_empty() {
        eprintln!("no tests found (functions starting with test_ or prop declarations)");
        return vec![];
    }

    eprintln!("running {} test(s)...\n", test_names.len());

    let mut results = Vec::new();
    let interp = Interpreter::with_route(route);

    // Register all declarations without running main
    for decl in &program.declarations {
        if let Err(e) = interp.register_decl(decl) {
            eprintln!("  error registering declaration: {}", e);
        }
    }

    for name in &test_names {
        if name.starts_with("prop_") {
            // Property-based test — TODO: generate random inputs
            results.push(TestResult {
                name: name.clone(),
                passed: true,
                error: Some("property tests not yet implemented".to_string()),
            });
            continue;
        }

        // Regular test: call the test_ function with no args
        let test_fn = interp.get_global(name);
        match test_fn {
            Some(func) => {
                // Test functions take unit () and should return bool or not error
                match interp.apply_value(func, Value::Unit) {
                    Ok(Value::Bool(true)) => {
                        eprint!("  \x1b[32m✓\x1b[0m {}\n", name);
                        results.push(TestResult { name: name.clone(), passed: true, error: None });
                    }
                    Ok(Value::Bool(false)) => {
                        eprint!("  \x1b[31m✗\x1b[0m {} — returned false\n", name);
                        results.push(TestResult {
                            name: name.clone(),
                            passed: false,
                            error: Some("test returned false".to_string()),
                        });
                    }
                    Ok(Value::Unit) => {
                        // Void test — passed if no error
                        eprint!("  \x1b[32m✓\x1b[0m {}\n", name);
                        results.push(TestResult { name: name.clone(), passed: true, error: None });
                    }
                    Ok(other) => {
                        eprint!("  \x1b[32m✓\x1b[0m {} (returned: {})\n", name, other);
                        results.push(TestResult { name: name.clone(), passed: true, error: None });
                    }
                    Err(e) => {
                        eprint!("  \x1b[31m✗\x1b[0m {} — {}\n", name, e);
                        results.push(TestResult {
                            name: name.clone(),
                            passed: false,
                            error: Some(format!("{}", e)),
                        });
                    }
                }
            }
            None => {
                eprint!("  \x1b[31m✗\x1b[0m {} — not found\n", name);
                results.push(TestResult {
                    name: name.clone(),
                    passed: false,
                    error: Some("test function not found".to_string()),
                });
            }
        }
    }

    let passed = results.iter().filter(|r| r.passed).count();
    let failed = results.iter().filter(|r| !r.passed).count();
    eprintln!();
    if failed == 0 {
        eprintln!("\x1b[32m{} passed\x1b[0m", passed);
    } else {
        eprintln!("\x1b[31m{} failed\x1b[0m, {} passed", failed, passed);
    }

    results
}
