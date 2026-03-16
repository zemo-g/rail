; Keywords
"let" @keyword
"if" @keyword.conditional
"then" @keyword.conditional
"else" @keyword.conditional
"match" @keyword.conditional
"type" @keyword
"import" @keyword.import
"foreign" @keyword
"as" @keyword
"true" @constant.builtin
"false" @constant.builtin
"null" @constant.builtin

; Operators
"->" @operator
"|>" @operator
"||" @operator
"&&" @operator
"==" @operator
"!=" @operator
"<" @operator
">" @operator
"<=" @operator
">=" @operator
"+" @operator
"-" @operator
"*" @operator
"/" @operator
"%" @operator
"=" @operator
"\\" @operator

; Punctuation
"(" @punctuation.bracket
")" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"," @punctuation.delimiter
"|" @punctuation.delimiter

; Literals
(integer) @number
(float) @number.float
(string) @string
(escape_sequence) @string.escape

; Identifiers
(func_decl name: (identifier) @function)
(constructor_name) @type
(type_name) @type
(return_type) @type.builtin

; Comments
(comment) @comment
