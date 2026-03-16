/// tree-sitter grammar for Rail
/// Derived from grammar/rail.ebnf and tools/compile.rail parser

module.exports = grammar({
  name: 'rail',

  extras: $ => [
    /[\s]/,
    $.comment,
  ],

  externals: $ => [],

  word: $ => $.identifier,

  conflicts: $ => [],

  rules: {
    program: $ => repeat($._declaration),

    _declaration: $ => choice(
      $.type_decl,
      $.foreign_decl,
      $.import_decl,
      $.func_decl,
    ),

    // type Option = | Some x | None
    type_decl: $ => seq(
      'type',
      $.type_name,
      '=',
      repeat1(seq('|', $.constructor)),
    ),

    type_name: $ => $.identifier,

    constructor: $ => prec.right(seq(
      $.constructor_name,
      repeat($.identifier),
    )),

    constructor_name: $ => /[A-Z][a-zA-Z0-9_]*/,

    // foreign sin x -> float
    foreign_decl: $ => prec.right(seq(
      'foreign',
      $.identifier,
      repeat($.identifier),
      optional(seq('->', $.return_type)),
    )),

    return_type: $ => choice('int', 'str', 'ptr', 'float'),

    // import "stdlib/math.rail"
    import_decl: $ => seq(
      'import',
      $.string,
      optional(seq('as', $.identifier)),
    ),

    // double x = x * 2
    func_decl: $ => seq(
      $.identifier,
      repeat($.identifier),
      '=',
      $._expr,
    ),

    _expr: $ => choice(
      $.let_expr,
      $.if_expr,
      $.match_expr,
      $.pipe_expr,
    ),

    // let x = 5\n  x + 1
    let_expr: $ => prec.right(seq(
      'let',
      choice(
        $.identifier,
        seq('(', commaSep1($.identifier), ')'),
      ),
      '=',
      $._expr,
      $._expr,
    )),

    // if n == 0 then 1 else n * fact (n - 1)
    if_expr: $ => seq(
      'if',
      $._expr,
      'then',
      $._expr,
      'else',
      $._expr,
    ),

    // match x | Some v -> v | None -> 0
    match_expr: $ => prec.right(seq(
      'match',
      $._expr,
      repeat1($.match_arm),
    )),

    match_arm: $ => seq(
      '|',
      $.pattern,
      '->',
      $._expr,
    ),

    pattern: $ => choice(
      seq($.constructor_name, repeat($.identifier)),
      $.identifier,
      $.integer,
      $.string,
    ),

    // Precedence climbing
    pipe_expr: $ => prec.left(1, seq(
      $.or_expr,
      repeat(seq('|>', $.or_expr)),
    )),

    or_expr: $ => prec.left(2, seq(
      $.and_expr,
      repeat(seq('||', $.and_expr)),
    )),

    and_expr: $ => prec.left(3, seq(
      $.cmp_expr,
      repeat(seq('&&', $.cmp_expr)),
    )),

    cmp_expr: $ => prec.left(4, seq(
      $.add_expr,
      optional(seq(
        choice('==', '!=', '<', '>', '<=', '>='),
        $.add_expr,
      )),
    )),

    add_expr: $ => prec.left(5, seq(
      $.mul_expr,
      repeat(seq(choice('+', '-'), $.mul_expr)),
    )),

    mul_expr: $ => prec.left(6, seq(
      $.app_expr,
      repeat(seq(choice('*', '/', '%'), $.app_expr)),
    )),

    // Function application: f x y z
    app_expr: $ => prec.left(7, seq(
      $._atom,
      repeat($._atom),
    )),

    _atom: $ => choice(
      $.integer,
      $.float,
      $.string,
      $.identifier,
      $.constructor_name,
      'true',
      'false',
      'null',
      $.paren_expr,
      $.tuple_expr,
      $.list_literal,
      $.lambda,
    ),

    paren_expr: $ => seq('(', $._expr, ')'),

    tuple_expr: $ => seq(
      '(',
      $._expr,
      ',',
      commaSep1($._expr),
      ')',
    ),

    list_literal: $ => seq(
      '[',
      optional(commaSep1($._expr)),
      ']',
    ),

    // \x -> x + 1
    lambda: $ => seq(
      '\\',
      $.identifier,
      '->',
      $._expr,
    ),

    // Tokens
    identifier: $ => /[a-z_][a-zA-Z0-9_]*/,
    integer: $ => /\-?[0-9]+/,
    float: $ => /\-?[0-9]+\.[0-9]+/,
    string: $ => seq(
      '"',
      repeat(choice(
        $.escape_sequence,
        $.string_content,
      )),
      '"',
    ),
    escape_sequence: $ => /\\[nrt\\"{}]/,
    string_content: $ => /[^"\\]+/,

    comment: $ => /--[^\n]*/,
  },
});

function commaSep1(rule) {
  return seq(rule, repeat(seq(',', rule)));
}
