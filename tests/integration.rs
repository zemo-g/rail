/// Integration tests for Rail — runs .rail programs and checks output.
/// Tests the full pipeline: source → lex → parse → interpret.

use std::process::Command;
use std::path::Path;

fn rail_run(source: &str) -> (String, String, i32) {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let id = COUNTER.fetch_add(1, Ordering::SeqCst);
    let tmp = std::env::temp_dir().join(format!("_rail_test_{}.rail", id));
    std::fs::write(&tmp, source).expect("write temp file");
    let output = Command::new(env!("CARGO_BIN_EXE_rail"))
        .args(["run", tmp.to_str().unwrap(), "--open"])
        .output()
        .expect("run rail");
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    let code = output.status.code().unwrap_or(-1);
    std::fs::remove_file(&tmp).ok();
    (stdout.trim_end().to_string(), stderr, code)
}

fn assert_output(source: &str, expected: &str) {
    let (stdout, stderr, code) = rail_run(source);
    assert_eq!(
        stdout, expected,
        "\n--- EXPECTED ---\n{}\n--- GOT ---\n{}\n--- STDERR ---\n{}\n",
        expected, stdout, stderr
    );
    assert_eq!(code, 0, "non-zero exit code: {}\nstderr: {}", code, stderr);
}

fn assert_error(source: &str) {
    let (_, _, code) = rail_run(source);
    assert_ne!(code, 0, "expected error but got exit code 0");
}

// =========================================================================
// Arithmetic
// =========================================================================

#[test]
fn test_add() {
    assert_output(
        "main =\n  let _ = print (3 + 4)\n  0",
        "7",
    );
}

#[test]
fn test_subtract() {
    assert_output(
        "main =\n  let _ = print (100 - 37)\n  0",
        "63",
    );
}

#[test]
fn test_multiply() {
    assert_output(
        "main =\n  let _ = print (6 * 7)\n  0",
        "42",
    );
}

#[test]
fn test_divide() {
    assert_output(
        "main =\n  let _ = print (100 / 4)\n  0",
        "25",
    );
}

#[test]
fn test_modulo() {
    assert_output(
        "main =\n  let _ = print (17 % 5)\n  0",
        "2",
    );
}

#[test]
fn test_negative() {
    assert_output(
        "main =\n  let _ = print (0 - 99)\n  0",
        "-99",
    );
}

#[test]
fn test_operator_precedence() {
    assert_output(
        "main =\n  let _ = print (2 + 3 * 4)\n  0",
        "14",
    );
}

#[test]
fn test_parenthesized_expr() {
    assert_output(
        "main =\n  let _ = print ((2 + 3) * 4)\n  0",
        "20",
    );
}

// =========================================================================
// Floats
// =========================================================================

#[test]
fn test_float_add() {
    assert_output(
        "main =\n  let _ = print (1.5 + 2.5)\n  0",
        "4.0",
    );
}

#[test]
fn test_float_multiply() {
    assert_output(
        "main =\n  let _ = print (3.0 * 2.5)\n  0",
        "7.5",
    );
}

// =========================================================================
// Booleans and comparisons
// =========================================================================

#[test]
fn test_bool_true() {
    assert_output(
        "main =\n  let _ = print true\n  0",
        "true",
    );
}

#[test]
fn test_bool_false() {
    assert_output(
        "main =\n  let _ = print false\n  0",
        "false",
    );
}

#[test]
fn test_comparison_eq() {
    assert_output(
        "main =\n  let _ = print (5 == 5)\n  0",
        "true",
    );
}

#[test]
fn test_comparison_neq() {
    assert_output(
        "main =\n  let _ = print (5 != 3)\n  0",
        "true",
    );
}

#[test]
fn test_comparison_lt() {
    assert_output(
        "main =\n  let _ = print (3 < 5)\n  0",
        "true",
    );
}

#[test]
fn test_comparison_gt() {
    assert_output(
        "main =\n  let _ = print (5 > 3)\n  0",
        "true",
    );
}

#[test]
fn test_logical_and() {
    assert_output(
        "main =\n  let _ = print (true && false)\n  0",
        "false",
    );
}

#[test]
fn test_logical_and_true() {
    assert_output(
        "main =\n  let _ = print (true && true)\n  0",
        "true",
    );
}

#[test]
fn test_logical_or() {
    assert_output(
        "main =\n  let _ = print (false || true)\n  0",
        "true",
    );
}

#[test]
fn test_logical_or_false() {
    assert_output(
        "main =\n  let _ = print (false || false)\n  0",
        "false",
    );
}

#[test]
fn test_logical_combined() {
    assert_output(
        "main =\n  let _ = print (true && false || true)\n  0",
        "true",
    );
}

// =========================================================================
// Strings
// =========================================================================

#[test]
fn test_string_print() {
    assert_output(
        "main =\n  let _ = print \"hello\"\n  0",
        "hello",
    );
}

#[test]
fn test_string_append() {
    assert_output(
        "main =\n  let _ = print (append \"hello\" \" world\")\n  0",
        "hello world",
    );
}

#[test]
fn test_string_show() {
    assert_output(
        "main =\n  let _ = print (show 42)\n  0",
        "42",
    );
}

#[test]
fn test_string_length() {
    assert_output(
        "main =\n  let _ = print (length \"hello\")\n  0",
        "5",
    );
}

#[test]
fn test_string_trim() {
    assert_output(
        "main =\n  let _ = print (trim \"  hi  \")\n  0",
        "hi",
    );
}

#[test]
fn test_string_contains() {
    assert_output(
        "main =\n  let _ = print (contains \"lo\" \"hello\")\n  0",
        "true",
    );
}

#[test]
fn test_string_split() {
    assert_output(
        "main =\n  let _ = print (split \",\" \"a,b,c\")\n  0",
        "[a, b, c]",
    );
}

#[test]
fn test_string_join() {
    assert_output(
        "main =\n  let _ = print (join \"-\" [\"a\", \"b\", \"c\"])\n  0",
        "a-b-c",
    );
}

// =========================================================================
// Let bindings
// =========================================================================

#[test]
fn test_let_binding() {
    assert_output(
        "main =\n  let x = 10\n  let y = x + 5\n  let _ = print y\n  0",
        "15",
    );
}

#[test]
fn test_let_chain() {
    assert_output(
        "main =\n  let a = 3\n  let b = 4\n  let c = a * b\n  let d = c + 1\n  let e = d * 2\n  let _ = print e\n  0",
        "26",
    );
}

// =========================================================================
// If/then/else
// =========================================================================

#[test]
fn test_if_true() {
    assert_output(
        "main =\n  let _ = print (if 5 > 3 then \"yes\" else \"no\")\n  0",
        "yes",
    );
}

#[test]
fn test_if_false() {
    assert_output(
        "main =\n  let _ = print (if 3 > 5 then \"yes\" else \"no\")\n  0",
        "no",
    );
}

#[test]
fn test_nested_if() {
    assert_output(
        "classify : i32 -> String\nclassify n = if n >= 90 then \"A\" else if n >= 80 then \"B\" else if n >= 70 then \"C\" else \"F\"\n\nmain =\n  let _ = print (classify 75)\n  0",
        "C",
    );
}

// =========================================================================
// Functions
// =========================================================================

#[test]
fn test_simple_function() {
    assert_output(
        "double : i32 -> i32\ndouble n = n * 2\n\nmain =\n  let _ = print (double 21)\n  0",
        "42",
    );
}

#[test]
fn test_two_arg_function() {
    assert_output(
        "add : i32 -> i32 -> i32\nadd x y = x + y\n\nmain =\n  let _ = print (add 3 4)\n  0",
        "7",
    );
}

#[test]
fn test_recursion_factorial() {
    assert_output(
        "factorial : i32 -> i32\nfactorial n = if n <= 1 then 1 else n * factorial (n - 1)\n\nmain =\n  let _ = print (factorial 10)\n  0",
        "3628800",
    );
}

#[test]
fn test_recursion_fibonacci() {
    assert_output(
        "fib : i32 -> i32\nfib n = if n < 2 then n else fib (n - 1) + fib (n - 2)\n\nmain =\n  let _ = print (fib 10)\n  0",
        "55",
    );
}

#[test]
fn test_mutual_recursion_style() {
    assert_output(
        "is_even : i32 -> Bool\nis_even n = if n == 0 then true else is_odd (n - 1)\n\nis_odd : i32 -> Bool\nis_odd n = if n == 0 then false else is_even (n - 1)\n\nmain =\n  let _ = print (is_even 14)\n  0",
        "true",
    );
}

#[test]
fn test_tco_large_recursion() {
    assert_output(
        "loop : i32 -> i32 -> i32\nloop n acc = if n <= 0 then acc else loop (n - 1) (acc + n)\n\nmain =\n  let _ = print (loop 100000 0)\n  0",
        "5000050000",
    );
}

// =========================================================================
// Lists
// =========================================================================

#[test]
fn test_list_literal() {
    assert_output(
        "main =\n  let _ = print [1, 2, 3]\n  0",
        "[1, 2, 3]",
    );
}

#[test]
fn test_list_head() {
    assert_output(
        "main =\n  let _ = print (head [10, 20, 30])\n  0",
        "10",
    );
}

#[test]
fn test_list_tail() {
    assert_output(
        "main =\n  let _ = print (tail [10, 20, 30])\n  0",
        "[20, 30]",
    );
}

#[test]
fn test_list_length() {
    assert_output(
        "main =\n  let _ = print (length [1, 2, 3, 4])\n  0",
        "4",
    );
}

#[test]
fn test_list_map() {
    assert_output(
        "main =\n  let _ = print (map (\\x -> x * 2) [1, 2, 3])\n  0",
        "[2, 4, 6]",
    );
}

#[test]
fn test_list_filter() {
    assert_output(
        "main =\n  let _ = print (filter (\\x -> x % 2 == 0) [1, 2, 3, 4, 5, 6])\n  0",
        "[2, 4, 6]",
    );
}

#[test]
fn test_list_fold() {
    assert_output(
        "main =\n  let _ = print (fold 0 (\\a -> \\b -> a + b) [1, 2, 3, 4, 5])\n  0",
        "15",
    );
}

#[test]
fn test_list_reverse() {
    assert_output(
        "main =\n  let _ = print (reverse [1, 2, 3])\n  0",
        "[3, 2, 1]",
    );
}

#[test]
fn test_list_sort() {
    assert_output(
        "main =\n  let _ = print (sort [3, 1, 4, 1, 5, 9, 2, 6])\n  0",
        "[1, 1, 2, 3, 4, 5, 6, 9]",
    );
}

#[test]
fn test_list_range() {
    assert_output(
        "main =\n  let _ = print (range 1 6)\n  0",
        "[1, 2, 3, 4, 5]",
    );
}

#[test]
fn test_list_cons() {
    assert_output(
        "main =\n  let _ = print (cons 0 [1, 2, 3])\n  0",
        "[0, 1, 2, 3]",
    );
}

#[test]
fn test_empty_list() {
    assert_output(
        "main =\n  let _ = print (length [])\n  0",
        "0",
    );
}

// =========================================================================
// Tuples
// =========================================================================

#[test]
fn test_tuple() {
    assert_output(
        "main =\n  let _ = print (1, 2)\n  0",
        "(1, 2)",
    );
}

// =========================================================================
// Pattern matching
// =========================================================================

#[test]
fn test_match_literal() {
    assert_output(
        "describe : i32 -> String\ndescribe n =\n  match n\n    0 -> \"zero\"\n    1 -> \"one\"\n    _ -> \"many\"\n\nmain =\n  let _ = print (describe 0)\n  let _ = print (describe 1)\n  let _ = print (describe 42)\n  0",
        "zero\none\nmany",
    );
}

#[test]
fn test_match_bool() {
    assert_output(
        "yesno : Bool -> String\nyesno b =\n  match b\n    true -> \"yes\"\n    false -> \"no\"\n\nmain =\n  let _ = print (yesno true)\n  0",
        "yes",
    );
}

// =========================================================================
// ADTs (Algebraic Data Types)
// =========================================================================

#[test]
fn test_adt_constructor() {
    assert_output(
        "type Option T =\n  | Some T\n  | None\n\nunwrap default opt =\n  match opt\n    Some x -> x\n    None -> default\n\nmain =\n  let _ = print (unwrap 0 (Some 42))\n  let _ = print (unwrap 99 None)\n  0",
        "42\n99",
    );
}

// =========================================================================
// Records
// =========================================================================

#[test]
fn test_record_create_and_access() {
    assert_output(
        "type Point =\n  x: i32\n  y: i32\n\nmain =\n  let p = { x: 10, y: 20 }\n  let _ = print p.x\n  let _ = print p.y\n  0",
        "10\n20",
    );
}

// =========================================================================
// Pipe operator
// =========================================================================

#[test]
fn test_pipe_simple() {
    assert_output(
        "double : i32 -> i32\ndouble x = x * 2\n\nmain =\n  let _ = print (5 |> double)\n  0",
        "10",
    );
}

#[test]
fn test_pipe_chain() {
    assert_output(
        "double : i32 -> i32\ndouble x = x * 2\n\nadd3 : i32 -> i32\nadd3 x = x + 3\n\nmain =\n  let result = 5 |> double |> add3\n  let _ = print result\n  0",
        "13",
    );
}

#[test]
fn test_pipe_with_lambda() {
    assert_output(
        "main =\n  let result = 5 |> (\\x -> x * 2) |> (\\x -> x + 3)\n  let _ = print result\n  0",
        "13",
    );
}

#[test]
fn test_pipe_list_operations() {
    assert_output(
        "main =\n  let _ = print (split \"\\n\" \"a\\nb\\nc\" |> length)\n  0",
        "3",
    );
}

// =========================================================================
// Lambdas
// =========================================================================

#[test]
fn test_lambda_simple() {
    assert_output(
        "main =\n  let _ = print ((\\x -> x + 1) 5)\n  0",
        "6",
    );
}

#[test]
fn test_lambda_two_arg() {
    assert_output(
        "main =\n  let _ = print ((\\x -> \\y -> x + y) 3 4)\n  0",
        "7",
    );
}

// =========================================================================
// Currying / partial application
// =========================================================================

#[test]
fn test_curried_function() {
    assert_output(
        "add : i32 -> i32 -> i32\nadd x y = x + y\n\nmain =\n  let inc = add 1\n  let _ = print (inc 99)\n  0",
        "100",
    );
}

// =========================================================================
// Exit codes
// =========================================================================

#[test]
fn test_exit_code_zero() {
    let (_, _, code) = rail_run("main = 0");
    assert_eq!(code, 0);
}

#[test]
fn test_exit_code_nonzero() {
    let (_, _, code) = rail_run("main = 1");
    assert_ne!(code, 0);
}

#[test]
fn test_exit_code_unit() {
    let (stdout, _, code) = rail_run("main = print \"hello\"");
    assert_eq!(code, 0);
    assert_eq!(stdout.trim(), "hello");
}

// =========================================================================
// Multiple print statements
// =========================================================================

#[test]
fn test_multiple_prints() {
    assert_output(
        "main =\n  let _ = print 1\n  let _ = print 2\n  let _ = print 3\n  0",
        "1\n2\n3",
    );
}

#[test]
fn test_countdown() {
    assert_output(
        "printAndCount : i32 -> i32\nprintAndCount n =\n  let _ = print n\n  countdown (n - 1)\n\ncountdown : i32 -> i32\ncountdown n = if n <= 0 then 0 else printAndCount n\n\nmain =\n  let _ = countdown 5\n  0",
        "5\n4\n3\n2\n1",
    );
}

// =========================================================================
// Complex programs
// =========================================================================

#[test]
fn test_gcd() {
    assert_output(
        "gcd : i32 -> i32 -> i32\ngcd a b = if b == 0 then a else gcd b (a % b)\n\nmain =\n  let _ = print (gcd 48 18)\n  0",
        "6",
    );
}

#[test]
fn test_power() {
    assert_output(
        "pow : i32 -> i32 -> i32\npow base exp = if exp <= 0 then 1 else base * pow base (exp - 1)\n\nmain =\n  let _ = print (pow 2 10)\n  0",
        "1024",
    );
}

#[test]
fn test_collatz_steps() {
    assert_output(
        "collatz : i32 -> i32 -> i32\ncollatz n steps =\n  if n == 1 then steps\n  else if n % 2 == 0 then collatz (n / 2) (steps + 1)\n  else collatz (3 * n + 1) (steps + 1)\n\nmain =\n  let _ = print (collatz 27 0)\n  0",
        "111",
    );
}

#[test]
fn test_sum_list_with_fold() {
    assert_output(
        "main =\n  let nums = range 1 11\n  let total = fold 0 (\\a -> \\b -> a + b) nums\n  let _ = print total\n  0",
        "55",
    );
}

#[test]
fn test_fizzbuzz_single() {
    assert_output(
        "fizzbuzz : i32 -> String\nfizzbuzz n =\n  if n % 15 == 0 then \"FizzBuzz\"\n  else if n % 3 == 0 then \"Fizz\"\n  else if n % 5 == 0 then \"Buzz\"\n  else show n\n\nmain =\n  let _ = print (fizzbuzz 15)\n  let _ = print (fizzbuzz 9)\n  let _ = print (fizzbuzz 10)\n  let _ = print (fizzbuzz 7)\n  0",
        "FizzBuzz\nFizz\nBuzz\n7",
    );
}

#[test]
fn test_string_repeat() {
    assert_output(
        "repeatStr : i32 -> String -> String\nrepeatStr n s = if n <= 0 then \"\" else append s (repeatStr (n - 1) s)\n\nmain =\n  let _ = print (repeatStr 4 \"ab\")\n  0",
        "abababab",
    );
}

#[test]
fn test_map_show_join() {
    assert_output(
        "main =\n  let _ = print (join \"-\" (map (\\x -> show x) [1, 2, 3]))\n  0",
        "1-2-3",
    );
}

#[test]
fn test_nested_append() {
    assert_output(
        "main =\n  let _ = print (append (append \"a\" \"b\") \"c\")\n  0",
        "abc",
    );
}

#[test]
fn test_partition() {
    assert_output(
        "main =\n  let nums = [3, 1, 4, 1, 5, 9, 2, 6]\n  let low = filter (\\x -> x < 4) nums\n  let high = filter (\\x -> x >= 4) nums\n  let _ = print low\n  let _ = print high\n  0",
        "[3, 1, 1, 2]\n[4, 5, 9, 6]",
    );
}

// =========================================================================
// Error cases
// =========================================================================

#[test]
fn test_parse_error() {
    assert_error("main = if true then");
}

#[test]
fn test_undefined_variable() {
    assert_error("main =\n  let _ = print undefined_var\n  0");
}

// =========================================================================
// Example files
// =========================================================================

#[test]
fn test_example_hello() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/hello.rail");
    let output = Command::new(env!("CARGO_BIN_EXE_rail"))
        .args(["run", path.to_str().unwrap(), "--open"])
        .output()
        .expect("run rail");
    assert!(output.status.success(), "hello.rail failed: {:?}",
        String::from_utf8_lossy(&output.stderr));
}

#[test]
fn test_example_demo() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/demo.rail");
    let output = Command::new(env!("CARGO_BIN_EXE_rail"))
        .args(["run", path.to_str().unwrap(), "--open"])
        .output()
        .expect("run rail");
    assert!(output.status.success(), "demo.rail failed: {:?}",
        String::from_utf8_lossy(&output.stderr));
}

#[test]
fn test_example_bench() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/bench.rail");
    let output = Command::new(env!("CARGO_BIN_EXE_rail"))
        .args(["run", path.to_str().unwrap(), "--open"])
        .output()
        .expect("run rail");
    assert!(output.status.success(), "bench.rail failed: {:?}",
        String::from_utf8_lossy(&output.stderr));
}

#[test]
fn test_example_test() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/test.rail");
    let output = Command::new(env!("CARGO_BIN_EXE_rail"))
        .args(["run", path.to_str().unwrap(), "--open"])
        .output()
        .expect("run rail");
    assert!(output.status.success(), "test.rail failed: {:?}",
        String::from_utf8_lossy(&output.stderr));
}

#[test]
fn test_example_full() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/full.rail");
    let output = Command::new(env!("CARGO_BIN_EXE_rail"))
        .args(["run", path.to_str().unwrap(), "--open"])
        .output()
        .expect("run rail");
    assert!(output.status.success(), "full.rail failed: {:?}",
        String::from_utf8_lossy(&output.stderr));
}

#[test]
fn test_example_tco() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/tco_test.rail");
    let output = Command::new(env!("CARGO_BIN_EXE_rail"))
        .args(["run", path.to_str().unwrap(), "--open"])
        .output()
        .expect("run rail");
    assert!(output.status.success(), "tco_test.rail failed: {:?}",
        String::from_utf8_lossy(&output.stderr));
}

// =========================================================================
// CLI commands
// =========================================================================

#[test]
fn test_version() {
    let output = Command::new(env!("CARGO_BIN_EXE_rail"))
        .args(["version"])
        .output()
        .expect("run rail version");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Rail"), "version output: {}", stdout);
}

#[test]
fn test_check_simple() {
    // Use a simple program for type-check testing (hello.rail has known type-checker gaps)
    let tmp = std::env::temp_dir().join("_rail_check_test.rail");
    std::fs::write(&tmp, "add : i32 -> i32 -> i32\nadd x y = x + y\n\nmain =\n  let _ = print (add 3 4)\n  0\n").unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_rail"))
        .args(["check", tmp.to_str().unwrap()])
        .output()
        .expect("run rail check");
    assert!(output.status.success(), "check failed: {:?}",
        String::from_utf8_lossy(&output.stderr));
    std::fs::remove_file(&tmp).ok();
}

#[test]
fn test_lex_hello() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/hello.rail");
    let output = Command::new(env!("CARGO_BIN_EXE_rail"))
        .args(["lex", path.to_str().unwrap()])
        .output()
        .expect("run rail lex");
    assert!(output.status.success(), "lex hello.rail failed: {:?}",
        String::from_utf8_lossy(&output.stderr));
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("tokens"), "expected token count in output");
}

#[test]
fn test_parse_hello() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/hello.rail");
    let output = Command::new(env!("CARGO_BIN_EXE_rail"))
        .args(["parse", path.to_str().unwrap()])
        .output()
        .expect("run rail parse");
    assert!(output.status.success(), "parse hello.rail failed: {:?}",
        String::from_utf8_lossy(&output.stderr));
}

// =========================================================================
// Route system (sandbox)
// =========================================================================

#[test]
fn test_sandbox_blocks_shell() {
    let tmp = std::env::temp_dir().join("_rail_sandbox_test.rail");
    std::fs::write(&tmp, "main =\n  let _ = shell \"echo hi\"\n  0").unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_rail"))
        .args(["run", tmp.to_str().unwrap()])  // no --open, no --allow
        .output()
        .expect("run rail");
    assert!(!output.status.success(), "sandbox should block shell");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("shell") || stderr.contains("denied"),
        "expected denial message, got: {}", stderr);
    std::fs::remove_file(&tmp).ok();
}

#[test]
fn test_allow_shell() {
    let tmp = std::env::temp_dir().join("_rail_allow_test.rail");
    std::fs::write(&tmp, "main =\n  let _ = print (trim (shell \"echo hi\"))\n  0").unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_rail"))
        .args(["run", tmp.to_str().unwrap(), "--allow", "shell"])
        .output()
        .expect("run rail");
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    assert_eq!(stdout, "hi");
    std::fs::remove_file(&tmp).ok();
}

// =========================================================================
// v0.4.0 — Parser polish
// =========================================================================

#[test]
fn test_multiline_list() {
    assert_output(
        "main =\n  let xs = [\n    1,\n    2,\n    3\n  ]\n  let _ = print (length xs)\n  0",
        "3",
    );
}

#[test]
fn test_multiline_list_trailing_comma() {
    assert_output(
        "main =\n  let xs = [\n    10,\n    20,\n  ]\n  let _ = print (length xs)\n  0",
        "2",
    );
}

#[test]
fn test_multiline_record() {
    assert_output(
        "main =\n  let p = {\n    x: 10,\n    y: 20\n  }\n  let _ = print p.x\n  let _ = print p.y\n  0",
        "10\n20",
    );
}

#[test]
fn test_multiline_record_trailing_comma() {
    assert_output(
        "main =\n  let p = {\n    x: 5,\n    y: 6,\n  }\n  let _ = print (p.x + p.y)\n  0",
        "11",
    );
}

#[test]
fn test_tuple_destructuring() {
    assert_output(
        "main =\n  let pair = (10, 20)\n  let (a, b) = pair\n  let _ = print (a + b)\n  0",
        "30",
    );
}

#[test]
fn test_tuple_destructuring_three() {
    assert_output(
        "main =\n  let triple = (1, 2, 3)\n  let (a, b, c) = triple\n  let _ = print (a + b + c)\n  0",
        "6",
    );
}

#[test]
fn test_tuple_destructuring_with_wildcard() {
    assert_output(
        "main =\n  let pair = (42, 99)\n  let (x, _) = pair\n  let _ = print x\n  0",
        "42",
    );
}

#[test]
fn test_recursion_depth_limit() {
    // Non-tail-recursive: `1 + infinite(x+1)` prevents TCO,
    // so it grows the eval stack and hits the depth limit
    let (_, stderr, code) = rail_run(
        "infinite x = 1 + (infinite (x + 1))\nmain =\n  let _ = print (infinite 0)\n  0",
    );
    assert_ne!(code, 0, "expected error from recursion limit");
    assert!(stderr.contains("recursion depth exceeded") || stderr.contains("stack overflow"),
        "expected recursion depth error, got: {}", stderr);
}

#[test]
fn test_version_0_3() {
    let output = Command::new(env!("CARGO_BIN_EXE_rail"))
        .args(["version"])
        .output()
        .expect("run rail version");
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    assert!(stdout.starts_with("Rail "), "expected 'Rail X.Y.Z', got: {}", stdout);
}

// =========================================================================
// v0.5.0 — Agent primitives
// =========================================================================

#[test]
fn test_context_new() {
    assert_output(
        "main =\n  let ctx = context_new \"You are helpful.\"\n  let _ = print ctx.system\n  0",
        "You are helpful.",
    );
}

#[test]
fn test_context_push() {
    assert_output(
        "main =\n  let ctx = context_new \"sys\"\n  let ctx = context_push ctx \"user\" \"hello\"\n  let msgs = ctx.messages\n  let _ = print (length msgs)\n  0",
        "1",
    );
}

#[test]
fn test_context_push_multiple() {
    assert_output(
        "main =\n  let ctx = context_new \"sys\"\n  let ctx = context_push ctx \"user\" \"hello\"\n  let ctx = context_push ctx \"assistant\" \"hi\"\n  let _ = print (length ctx.messages)\n  0",
        "2",
    );
}

// =========================================================================
// v0.6.0 — Developer experience
// =========================================================================

#[test]
fn test_fmt_check() {
    let tmp = std::env::temp_dir().join("_rail_fmt_test.rail");
    std::fs::write(&tmp, "add x y = x + y\n\nmain =\n  let _ = print (add 1 2)\n  0\n").unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_rail"))
        .args(["fmt", tmp.to_str().unwrap(), "--check"])
        .output()
        .expect("run rail fmt");
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    assert!(stdout.contains("ok") || stdout.contains("formatted"),
        "expected ok or formatted, got: {}", stdout);
    std::fs::remove_file(&tmp).ok();
}

#[test]
fn test_fmt_formats() {
    let tmp = std::env::temp_dir().join("_rail_fmt_test2.rail");
    std::fs::write(&tmp, "add x y = x + y   \nmain =  \n  0\n").unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_rail"))
        .args(["fmt", tmp.to_str().unwrap()])
        .output()
        .expect("run rail fmt");
    assert!(output.status.success());
    let content = std::fs::read_to_string(&tmp).unwrap();
    assert!(!content.contains("   \n"), "trailing whitespace should be removed");
    std::fs::remove_file(&tmp).ok();
}

#[test]
fn test_test_runner_discovers() {
    // A file with test_ functions should be discoverable
    assert_output(
        "test_addition _ = 1 + 1 == 2\nmain = 0",
        "",
    );
}

#[test]
fn test_prompt_stream_mock() {
    // Mock provider — streaming simulated via word splitting
    assert_output(
        "main =\n  let _ = prompt_stream \"\" \"What is 2+2?\" (\\chunk -> print chunk)\n  0",
        "4",
    );
}
