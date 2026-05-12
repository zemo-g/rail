#!/usr/bin/env bash
# x86_64 conformance harness for Rail.
# Pipeline per test:
#   src → ./rail_native x86 → /tmp/rail_x86.s → docker(gcc -no-pie) → run → diff stdout/exit
# Output: PASS/FAIL lines + final N/M summary. Non-zero exit if any FAIL.
#
# Tests are a representative subset of run_tests (~30) covering ints, strings,
# lists, ADTs, closures, floats, FFI, TCO, arena. Used to baseline x86 backend
# before triaging the top failure cluster.

# Deliberately no `set -eu`: test failures are expected, and empty bash arrays
# trip nounset. Each phase handles its own errors.

cd "$(dirname "$0")/../.."

# Colima/Lima mounts $HOME by default; /tmp is NOT mounted. Stage under $HOME.
STAGE="$HOME/.cache/rail-x86-conformance"
rm -rf "$STAGE"
mkdir -p "$STAGE/src" "$STAGE/asm" "$STAGE/out"

# Each test: name|expected|source
# Sources may contain \n for newlines; we'll printf %b them.
TESTS=(
'main42|42|main = 42'
'add|7|main = 3 + 4'
'if|42|main = if 1 == 1 then 42 else 0'
'double|42|double x = x * 2\nmain = double 21'
'fact|120|fact n =\n  if n <= 1 then 1\n  else n * fact (n - 1)\nmain = fact 5'
'print|42|main =\n  let _ = print 42\n  0'
'lets|48|main =\n  let a = 7\n  let b = a * a\n  b - 1'
'strprint|hello|main =\n  let _ = print "hello"\n  0'
'streq|1|main = if "ab" == "ab" then 1 else 0'
'show|42|main =\n  let _ = print (show 42)\n  0'
'append|hello|main =\n  let _ = print (append "hel" "lo")\n  0'
'listlen|3|main = length [10, 20, 30]'
'headtail|20|main = head (tail [10, 20, 30])'
'cons|42|main = head (cons 42 [1, 2])'
'empty|0|main = length []'
'strlen|5|main = length "hello"'
'mapfn|6|double x = x * 2\nmain = head (map double [3, 5, 7])'
'maplam|15|main = head (map (\\x -> x + 10) [5, 6, 7])'
'closure|101|main =\n  let n = 100\n  head (map (\\x -> x + n) [1, 2, 3])'
'join|a-b-c|main =\n  let _ = print (join "-" ["a", "b", "c"])\n  0'
'tuple|42|main =\n  let (a, b) = (10, 32)\n  a + b'
'tco|42|loop n = if n == 0 then 42 else loop (n - 1)\nmain =\n  let _ = print (show (loop 50000))\n  0'
'adt_none|42|type Option = | Some x | None\nmain = match None | Some x -> x | None -> 42'
'adt_some|42|type Option = | Some x | None\nmain = match (Some 42) | Some x -> x | None -> 0'
'neg|-42|main =\n  let _ = print (show (-42))\n  0'
'float|3.75|main =\n  let _ = print (show (1.5 + 2.25))\n  0'
'float_mul|7.5|main =\n  let _ = print (show (3.0 * 2.5))\n  0'
'float_cmp|1|main = if 3.14 > 2.71 then 1 else 0'
'fold|15|add a b = a + b\nmain = fold add 0 [1, 2, 3, 4, 5]'
'filter|3|gt2 x = if x > 2 then true else false\nmain = length (filter gt2 [1, 2, 3, 4, 5])'
'range|10|main = length (range 10)'
'fold_sum|5050|add a b = a + b\nmain =\n  let _ = print (show (fold add 0 (range 101)))\n  0'
'strne|0|main = if "ab" == "cd" then 1 else 0'
'str_plus|foobar|main =\n  let _ = print ("foo" + "bar")\n  0'
'listapp|5|main = length (append [1, 2] [3, 4, 5])'
'tupret|21|swap a b = (b, a)\nmain =\n  let (x, y) = swap 1 2\n  x * 10 + y'
'tup3|123|main =\n  let (a, b, c) = (100, 20, 3)\n  a + b + c'
'chars|a|main =\n  let cs = chars "abc"\n  let _ = print (head cs)\n  length cs'
'split_csv|b|main =\n  let _ = print (head (tail (split "," "a,b,c")))\n  0'
'bigint|42|main =\n  let x = 100000\n  x - 99958'
'adt_pair|10|type Pair = | MkPair a b\nfst p = match p | MkPair a b -> a\nmain = fst (MkPair 10 32)'
'wildcard|42|type T = | A x | B x | C\nmain = match (B 99)\n  | A x -> 0\n  | _ -> 42'
'reverse|3|main =\n  let xs = reverse [1, 2, 3]\n  head xs'
'not|1|main = if not false then 1 else 0'
'neg_arith|7|main = 10 + (-3)'
'match_int|one|classify n = match n\n  | 0 -> "zero"\n  | 1 -> "one"\n  | _ -> "other"\nmain =\n  let _ = print (classify 1)\n  0'
'guard|5|type Option = | Some x | None\nsafe_div a b = match b\n  | 0 -> None\n  | _ -> Some (a / b)\nmain = match (safe_div 10 2)\n  | Some x -> x\n  | None -> 0'
'map_fusion|6|double x = x * 2\ntriple x = x * 3\nmain = head (map double (map triple [1, 2, 3]))'
'nested_lam|7|main = (\\a -> \\b -> a + b) 3 4'
'nested_lam_let|7|main =\n  let f = \\a -> \\b -> a + b\n  f 3 4'
'nested_lam_cap|17|main =\n  let n = 10\n  let f = \\a -> \\b -> a + b + n\n  f 3 4'
'pipe|8|inc x = x + 1\ndbl x = x * 2\nmain = 3 |> inc |> dbl'
'match_str|hello|greet s = match s\n  | "hi" -> "hello"\n  | _ -> "huh"\nmain =\n  let _ = print (greet "hi")\n  0'
'fold_str|abc|cat2 a b = append a b\nmain =\n  let _ = print (fold cat2 "" ["a", "b", "c"])\n  0'
'arr_set|99|main =\n  let a = arr_new 3 0\n  let _ = arr_set a 1 99\n  arr_get a 1'
'arr_len|10|main =\n  let a = arr_new 10 0\n  arr_len a'
'arr_sum|50|sum a i = if i >= arr_len a then 0 else arr_get a i + sum a (i + 1)\nmain =\n  let a = arr_new 5 10\n  sum a 0'
'error|1|main =\n  let e = error "oops"\n  let ok = is_error e\n  let bad = is_error 42\n  ok - bad'
'char_to_int|65|main = char_to_int "A"'
'parse_int|1134|main =\n  let a = parse_int "1234"\n  let b = parse_int "-100"\n  let _ = print (show (a + b))\n  0'
# --- Extension: tests from run_tests t30-t72 not yet in the harness ---
# Categorization (see classification table in commit message):
#   portable        — uses only builtins already wired in x86_cg_bi*
#   foreign-libc    — uses `foreign` and depends on Linux libc symbol resolution
#   carry-through   — uses imports / stdlib paths that themselves stay portable
'fileio|hello42|main =\n  let _ = write_file "/tmp/rail_x86conf_fileio.txt" "hello42"\n  let s = read_file "/tmp/rail_x86conf_fileio.txt"\n  let _ = print s\n  0'
'shell_echo|hi|main =\n  let _ = print (head (split "\\n" (shell "echo hi")))\n  0'
'integ|sum=9|cat2 parts = join "" parts\ndbl x = x * 2\nmain =\n  let xs = map dbl [3, 5, 7]\n  let (a, b) = (head xs, length xs)\n  let _ = print (cat2 ["sum=", show (a + b)])\n  0'
'escape|{hello}|main =\n  let _ = print "\\{hello\\}"\n  0'
'ffi_abs|5|foreign abs n\nmain =\n  let _ = print (show (abs (-5)))\n  0'
'ffi_strlen|5|foreign strlen s\nmain =\n  let _ = print (show (strlen "hello"))\n  0'
'ffi_getenv_root|/|foreign getenv s -> str\nmain =\n  let h = getenv "PWD"\n  let _ = print (str_sub h 0 1)\n  0'
'arena|42|main =\n  let m = arena_mark 0\n  let _ = cons 1 [2, 3]\n  let _ = arena_reset m\n  42'
'gpu_map_pass|1|main =\n  let r = gpu_map (\\x -> x * 3 + 1) (range 8)\n  let _ = print (show (head r))\n  0'
'gpu_auto|1|main =\n  let r = map (\\x -> x * 2 + 1) (range 8)\n  let _ = print (show (head r))\n  0'
# Diagnostic: stdlib string ops dispatched in x86_cg_bi2 but with no
# corresponding _rail_* symbol in tools/x86_rt.s. Surfaces the gap.
'str_find|1|main = str_find "b" "abc"'
'str_contains|1|main = if str_contains "b" "abc" then 1 else 0'
'str_sub|el|main =\n  let _ = print (str_sub "hello" 1 2)\n  0'
'str_split|b|main =\n  let _ = print (head (tail (str_split ", " "a, b, c")))\n  0'
'str_replace|hAllo|main =\n  let _ = print (str_replace "e" "A" "hello")\n  0'

# --- Extension: t76-t134 from run_tests in tools/compile.rail ---
# Each row carries an `expected_status` classification:
#   portable                 — should PASS today (verified empirically below)
#   deferred-symbol:<sym>    — fails because <sym> is not in tools/x86_rt.s
#                              and the x86 builtin dispatch in tools/compile.rail
#                              has no inline emit (falls through to user-fn,
#                              emits `call _<sym>`, linker fails)
#   deferred-feature:<name>  — needs an x86 codegen path that doesn't exist yet
#                              (e.g., #generate macro, GPU dispatch)
#   expected-after:<agent>   — currently fails but will pass once a sibling
#                              agent's branch lands (Agent A: ELF-prefix fix,
#                              Agent B: 5 str_runtime symbols)
# See notes/x86_conformance_classification_2026-05-13.md for the full table.

# t76-t80: stdlib/map.rail (pure-Rail; depends only on already-portable builtins)
# Expected: portable
'map_new|0|import "stdlib/map.rail"\nmain = map_size (map_new 0)'
'map_put_get|42|import "stdlib/map.rail"\nmain =\n  let m = map_new 0\n  let m = map_put m "x" 42\n  map_get m "x"'
'map_has|1|import "stdlib/map.rail"\nmain =\n  let m = map_put (map_new 0) "a" 1\n  if map_has m "a" then 1 else 0'
'map_keys|1|import "stdlib/map.rail"\nmain =\n  let m = map_put (map_new 0) "k" 9\n  length (map_keys m)'
'map_int_key|99|import "stdlib/map.rail"\nmain =\n  let m = map_put (map_new 0) 10 99\n  map_get m 10'

# t81-t85: stdlib/strbuf.rail
# Expected: deferred-symbol:_rail_str_sub  (buf_str uses str_sub internally) — empirically check
'buf_new|0|import "stdlib/strbuf.rail"\nmain = buf_len (buf_new 0)'
'buf_append|hello|import "stdlib/strbuf.rail"\nmain =\n  let b = buf_append (buf_new 0) "hello"\n  let _ = print (buf_str b)\n  0'
'buf_multi|abc|import "stdlib/strbuf.rail"\nmain =\n  let b = buf_append (buf_append (buf_append (buf_new 0) "a") "b") "c"\n  let _ = print (buf_str b)\n  0'
'buf_int|x=42|import "stdlib/strbuf.rail"\nmain =\n  let b = buf_append_int (buf_append (buf_new 0) "x=") 42\n  let _ = print (buf_str b)\n  0'
'buf_big|100|import "stdlib/strbuf.rail"\nhelper b n = if n == 0 then b else helper (buf_append b "x") (n - 1)\nmain = buf_len (helper (buf_new 0) 100)'

# t86: arr_new (already exercised but verify the t86-specific form)
# Expected: portable
'arr_new|42|main =\n  let a = arr_new 3 42\n  arr_get a 1'

# t91-t92: spawn_thread/join_thread
# Expected: deferred-symbol:_rail_spawn_thread + _rail_join_thread
'thread|42|double x = x * 2\nmain =\n  let t = spawn_thread double 21\n  join_thread t'
'thread_par|45|add10 x = x + 10\nmain =\n  let t1 = spawn_thread add10 5\n  let t2 = spawn_thread add10 20\n  let a = join_thread t1\n  let b = join_thread t2\n  a + b'

# t94-t97: stdlib/hash.rail set/ht
# Expected: portable (pure-Rail; depends on already-portable builtins)
'set_basic|42|import "stdlib/hash.rail"\nmain =\n  let s = set_add (set_new 0) "foo"\n  if set_contains s "foo" then 42 else 0'
'set_absent|99|import "stdlib/hash.rail"\nmain =\n  let s = set_add (set_new 0) "foo"\n  if set_contains s "bar" then 1 else 99'
'ht_map|42|import "stdlib/hash.rail"\nmain =\n  let h = ht_put (ht_new 0) "x" 42\n  ht_get h "x"'
'set_many|1|import "stdlib/hash.rail"\nadd_many s n = if n == 0 then s else add_many (set_add s (join "" ["k", show n])) (n - 1)\ncheck_all s n = if n == 0 then 1 else if set_contains s (join "" ["k", show n]) then check_all s (n - 1) else 0\nmain =\n  let s = add_many (set_new 0) 100\n  check_all s 100'

# t98: byte_set/byte_at + foreign malloc
# Expected: deferred-symbol:_rail_byte_set + _rail_byte_at + expected-after:A (foreign malloc → _malloc)
'byte_rw|198|foreign malloc size -> ptr\nmain =\n  let p = malloc 16\n  let _ = byte_set p 0 65\n  let _ = byte_set p 1 66\n  let _ = byte_set p 2 67\n  let a = byte_at p 0\n  let b = byte_at p 1\n  let c = byte_at p 2\n  a + b + c'

# t99: parse_float
# Expected: deferred-symbol:_rail_parse_float
'parse_float|49|main = to_int (parse_float "42.5") + to_int (parse_float "7.25")'

# t101-t102: scientific-notation float literals
# Expected: deferred-symbol:_rail_to_int (and float-literal emit may differ in x86)
'sci_int_exp|1000500|main =\n  let v = 1e6 +. 5.0e2\n  let _ = print (show (to_int v))\n  0'
'sci_frac|1501|main =\n  let v = 1.5e3 +. 2.5e-1 *. 4.0\n  let _ = print (show (to_int v))\n  0'

# t103: null-safe ADT equality on uninitialized array slots
# Expected: portable
'null_safe_eq|10|type T = | T x\nmain =\n  let t = T 42\n  let a = arr_new 2 0\n  let _ = arr_set a 1 t\n  let v0 = arr_get a 0\n  let v1 = arr_get a 1\n  let z0 = if v0 == 0 then 1 else 0\n  let z1 = if v1 == 0 then 1 else 0\n  z0 * 10 + z1'

# t104, t106: float-array I/O + mixed int/float arithmetic
# Expected: deferred-symbol:_rail_float_arr_* (multiple)
'f32_io_roundtrip|-13|main =\n  let src = float_arr_new 3 0.0\n  let _ = float_arr_set src 0 1.5\n  let _ = float_arr_set src 1 (0.0 -. 3.25)\n  let _ = float_arr_set src 2 0.125\n  let _ = float_arr_to_f32_file "/tmp/rail_x86conf_f32roundtrip.bin" src 3\n  let dst = float_arr_new 3 0.0\n  let _ = float_arr_from_f32_file "/tmp/rail_x86conf_f32roundtrip.bin" dst 3\n  let s = float_arr_get dst 0 +. float_arr_get dst 1 +. float_arr_get dst 2\n  let _ = print (show (to_int (s *. 8.0)))\n  0'
'mixed_float_int_op|6|fill arr i =\n  if i >= 3 then 0\n  else\n    let _ = float_arr_set arr i (0.0 + (i + 1))\n    fill arr (i + 1)\nmain =\n  let a = float_arr_new 3 0.0\n  let _ = fill a 0\n  let s = float_arr_get a 0 + float_arr_get a 1 + float_arr_get a 2\n  to_int s'

# t107: char_to_int on a runtime-extracted char
# Expected: portable (already uses char_to_int which is portable, and chars/head are portable)
'char_to_int_rt|57|main =\n  let c = head (chars "9")\n  char_to_int c'

# t105, t108-t110: stdlib/tensor.rail
# Expected: deferred-symbol: depends on float_arr_* and bit ops via tensor.rail internals
'tensor_prims|2|import "stdlib/tensor.rail"\nmain =\n  let x = tensor_new (cons 4 []) 0.0\n  let _ = tensor_set_flat x 0 (0.0 - 2.0)\n  let _ = tensor_set_flat x 1 0.5\n  let _ = tensor_set_flat x 2 (0.0 - 1.0)\n  let _ = tensor_set_flat x 3 3.0\n  let m = tensor_relu_mask x\n  let n = tensor_get_flat m 0 + tensor_get_flat m 1 + tensor_get_flat m 2 + tensor_get_flat m 3\n  to_int n'
'tensor_rank|3|import "stdlib/tensor.rail"\nmain =\n  let t = tensor_new (cons 2 (cons 3 (cons 4 []))) 0.0\n  tensor_rank t'
'tensor_slice|18|import "stdlib/tensor.rail"\nmain =\n  let t = tensor_new (cons 4 (cons 2 [])) 0.0\n  let _ = tensor_set_flat t 0 1.0\n  let _ = tensor_set_flat t 1 2.0\n  let _ = tensor_set_flat t 2 3.0\n  let _ = tensor_set_flat t 3 4.0\n  let _ = tensor_set_flat t 4 5.0\n  let _ = tensor_set_flat t 5 6.0\n  let _ = tensor_set_flat t 6 7.0\n  let _ = tensor_set_flat t 7 8.0\n  let s = tensor_slice t 1 3\n  let sum = tensor_sum s\n  to_int sum'
'tensor_layer_norm|0|import "stdlib/tensor.rail"\nmain =\n  let x = tensor_new (cons 1 (cons 4 [])) 0.0\n  let _ = tensor_set_flat x 0 1.0\n  let _ = tensor_set_flat x 1 2.0\n  let _ = tensor_set_flat x 2 3.0\n  let _ = tensor_set_flat x 3 4.0\n  let g = tensor_ones (cons 4 [])\n  let b = tensor_zeros (cons 4 [])\n  let y = tensor_layer_norm x g b 0.00001\n  let s = tensor_sum y\n  let scaled = s *. 1000.0\n  to_int scaled'

# t111-t117: bit ops — high blast-radius cluster
# Expected: deferred-symbol:_rail_bit_and / _rail_bit_or / _rail_bit_xor / _rail_shl / _rail_shr / _rail_rotl
'bit_and|15|main = bit_and 255 15'
'bit_or|255|main = bit_or 240 15'
'bit_xor_identity|0|main = bit_xor 4660 4660'
'shl_basic|16|main = shl 1 4'
'shr_basic|255|main = shr 65280 8'
'rotl_roundtrip|1|main = rotl 256 56'
'rotr32_composed|4155207611|main =\n  let x = 3735928559\n  let a = shr x 2\n  let b = shl x 30\n  let c = bit_or a b\n  let r = bit_and c 4294967295\n  let _ = print (show r)\n  0'

# t118-t131: crypto stdlib (all depend on bit ops via sha256.rail's mixers)
# Expected: deferred-symbol (cascade): bit_and / shr / shl / bit_xor / bit_or / rotl / byte_at / byte_set
'sha256_empty|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|import "stdlib/sha256.rail"\nmain =\n  let _ = print (sha256_hex "")\n  0'
'sha256_abc|ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad|import "stdlib/sha256.rail"\nmain =\n  let _ = print (sha256_hex "abc")\n  0'
'sha256_two_blocks|248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1|import "stdlib/sha256.rail"\nmain =\n  let _ = print (sha256_hex "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")\n  0'
'hmac_sha256_jefe|5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843|import "stdlib/hmac.rail"\nmain =\n  let _ = print (hmac_sha256_hex "Jefe" "what do ya want for nothing?")\n  0'

# t122-t131: deeper crypto/TLS — all cascade-deferred via sha256/bit ops
# Expected: deferred-symbol cascade (bit_and, shr, shl, bit_xor, byte_at/set)
'hkdf_rfc5869_tc1|3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865|import "stdlib/hkdf.rail"\nmain =\n  let ikm = hex_to_bytes "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"\n  let salt = hex_to_bytes "000102030405060708090a0b0c"\n  let info = hex_to_bytes "f0f1f2f3f4f5f6f7f8f9"\n  let prk = hkdf_extract salt 13 ikm 22\n  let okm = hkdf_expand prk info 10 42\n  let _ = print (bytes_to_hex okm 42)\n  0'
'chacha20_block|10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4ed2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e|import "stdlib/bytes.rail"\nimport "stdlib/chacha20.rail"\nmain =\n  let key = hex_to_bytes "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"\n  let nonce = hex_to_bytes "000000090000004a00000000"\n  let b = chacha20_block key nonce 1\n  let _ = print (bytes_to_hex b 64)\n  0'
'poly1305_mac|a8061dc1305136c6c22b8baf0c0127a9|import "stdlib/bytes.rail"\nimport "stdlib/poly1305.rail"\nmain =\n  let key = hex_to_bytes "85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b"\n  let msg = string_to_bytes "Cryptographic Forum Research Group"\n  let tag = poly1305_mac key msg 34\n  let _ = print (bytes_to_hex tag 16)\n  0'
'aead_tag|1ae10b594f09e26a7e902ecbd0600691|import "stdlib/bytes.rail"\nimport "stdlib/aead.rail"\nmain =\n  let key = hex_to_bytes "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"\n  let nonce = hex_to_bytes "070000004041424344454647"\n  let aad = hex_to_bytes "50515253c0c1c2c3c4c5c6c7"\n  let pt = string_to_bytes "Ladies and Gentlemen of the class of \x2799: If I could offer you only one tip for the future, sunscreen would be it."\n  let r = aead_encrypt key nonce aad 12 pt 114\n  let _ = print (bytes_to_hex (arr_get r 1) 16)\n  0'
'x25519_rfc7748_v1|c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552|import "stdlib/bytes.rail"\nimport "stdlib/x25519.rail"\nmain =\n  let s = hex_to_bytes "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"\n  let u = hex_to_bytes "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"\n  let _ = print (bytes_to_hex (x25519 s u) 32)\n  0'

# t132-t134: large int literals (3-movk and 4-movk codegen on ARM64; x86 uses movabs)
# Expected: portable on x86 (movabs handles 64-bit immediates uniformly)
'int_lit_3movk|1099511627776|main =\n  let n = 1099511627776\n  let _ = print (show n)\n  0'
'int_lit_4movk|281474976710656|main =\n  let n = 281474976710656\n  let _ = print (show n)\n  0'
'int_lit_4movk_neg|-281474976710656|main =\n  let n = 0 - 281474976710656\n  let _ = print (show n)\n  0'
)

# Phase 0: stage import targets for tests that use `import` / `import baremod`
# t47 (import-path), t60 (qual_import), t71/t72 (bare_import[_as])
mkdir -p "$STAGE/import_aux"
printf "double x = x * 2\ntriple x = x * 3\n" > "$STAGE/import_aux/rail_importlib.rail"
printf "double x = x * 2\n_private x = x\n" > "$STAGE/import_aux/rail_quallib.rail"
# Bare imports look at: cwd, $(dirname $RAIL_BINARY)/stdlib/, ./stdlib/, ~/.rail/packages/
# Harness cd's to repo root, so a baremod.rail in repo root resolves first.
# Use a guard to avoid clobbering anything pre-existing.
if [[ ! -e "baremod.rail" ]]; then
  printf "square x = x * x\n" > baremod.rail
  STAGED_BAREMOD=1
fi
trap '[[ ${STAGED_BAREMOD:-0} -eq 1 ]] && rm -f baremod.rail' EXIT

# Tests with imports that need an aux file — emit pass uses the aux file by
# absolute path so we don't pollute /tmp during parallel runs.
IMP1="$STAGE/import_aux/rail_importlib.rail"
IMP2="$STAGE/import_aux/rail_quallib.rail"
IMPORT_TESTS=(
  "import_path|45|import \"$IMP1\"\nmain = double 21 + triple 1"
  "qual_import|42|import \"$IMP2\" as M\nmain = M_double 21"
  "bare_import|49|import baremod\nmain = square 7"
  "bare_import_as|36|import baremod as B\nmain = B_square 6"
)
for it in "${IMPORT_TESTS[@]}"; do
  TESTS+=("$it")
done

# Phase 1: emit asm for every test
# rail_native writes to a hardcoded /tmp/rail_x86.s. Other concurrent agents on
# the same host can race us between emit and cp. We serialize via flock on a
# per-host lock file, and we wrap the emit+cp in a single critical section.
EMITTED=()
EMIT_FAILS=()
# Mutex via mkdir (atomic on macOS). /tmp/rail_x86.s is shared host-wide.
LOCK_DIR="/tmp/rail_x86_conformance.lockdir"
acquire_lock() {
  local i=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    i=$((i+1))
    if (( i > 300 )); then  # 30s ceiling
      rmdir "$LOCK_DIR" 2>/dev/null
      mkdir "$LOCK_DIR" 2>/dev/null
      return 0
    fi
    sleep 0.1
  done
}
release_lock() { rmdir "$LOCK_DIR" 2>/dev/null; }
trap 'release_lock; [[ ${STAGED_BAREMOD:-0} -eq 1 ]] && rm -f baremod.rail' EXIT
for entry in "${TESTS[@]}"; do
  name="${entry%%|*}"
  rest="${entry#*|}"
  expected="${rest%%|*}"
  src="${rest#*|}"
  printf "%b" "$src" > "$STAGE/src/$name.rail"
  acquire_lock
  rm -f /tmp/rail_x86.s
  if ./rail_native x86 "$STAGE/src/$name.rail" > "$STAGE/out/$name.emit.log" 2>&1; then
    if [[ -s /tmp/rail_x86.s ]]; then
      cp /tmp/rail_x86.s "$STAGE/asm/$name.s"
      release_lock
      EMITTED+=("$name|$expected")
    else
      release_lock
      EMIT_FAILS+=("$name|empty-asm")
    fi
  else
    rc=$?
    release_lock
    EMIT_FAILS+=("$name|emit-exit-$rc")
  fi
done

# Phase 2: single docker invocation to assemble+link+run everything
# We mount $STAGE so the container can see asm/ and write out/.
# The tensor.rail stdlib declares ~33 `foreign tgl_*` symbols backed by the
# Mac-only libtensor_gpu.dylib. On Linux we ship a no-op CPU-fallback stub
# (tools/metal/libtensor_gpu_linux_stub.c) so the link resolves; the runtime
# never enters the GPU path because `gpu_available` shells out to a Mac path.
cp tools/metal/libtensor_gpu_linux_stub.c "$STAGE/libtensor_gpu_linux_stub.c"
cat > "$STAGE/runner.sh" <<'EOF'
#!/bin/sh
cd /stage
# Build the tensor-GPU stub once; link every test against it.
gcc -shared -fPIC -O0 -o libtensor_gpu.so libtensor_gpu_linux_stub.c \
    2> out/_stub.build.log || { echo "STUB-BUILD-FAIL"; cat out/_stub.build.log; exit 2; }
for s in asm/*.s; do
  name=$(basename "$s" .s)
  if gcc -no-pie -o "/tmp/$name.bin" "$s" \
         -L/stage -ltensor_gpu -Wl,-rpath,/stage -lm 2> "out/$name.link.log"; then
    actual=$(/tmp/$name.bin 2>&1)
    ec=$?
    printf "%s\n--EXIT--\n%s\n" "$actual" "$ec" > "out/$name.run.log"
    rm -f "/tmp/$name.bin"
  else
    printf "LINK-FAIL\n" > "out/$name.run.log"
  fi
done
EOF
chmod +x "$STAGE/runner.sh"

docker run --rm --platform=linux/amd64 -v "$STAGE":/stage gcc:latest /stage/runner.sh

# Phase 3: diff results
PASS=0
FAIL=0
declare -a FAIL_LINES=()
for entry in "${EMITTED[@]}"; do
  name="${entry%%|*}"
  expected="${entry#*|}"
  log="$STAGE/out/$name.run.log"
  if [[ ! -f "$log" ]]; then
    FAIL=$((FAIL+1))
    FAIL_LINES+=("$name: no-run-log")
    continue
  fi
  if grep -q "^LINK-FAIL" "$log"; then
    FAIL=$((FAIL+1))
    linkerr=$(head -3 "$STAGE/out/$name.link.log" 2>/dev/null | tr '\n' ' ')
    FAIL_LINES+=("$name: link-fail [$linkerr]")
    continue
  fi
  stdout=$(awk 'NR==1{print; next} /^--EXIT--$/{exit}{print}' "$log" | head -1)
  exit_code=$(awk '/^--EXIT--$/{getline; print; exit}' "$log")
  # Mirror native runner: if stdout is empty, use exit_code as the "actual" value
  if [[ -n "$stdout" ]]; then
    actual="$stdout"
  else
    actual="$exit_code"
  fi
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS+1))
    printf "  PASS: %-25s = %s\n" "$name" "$actual"
  else
    FAIL=$((FAIL+1))
    FAIL_LINES+=("$name: got [$actual] expected [$expected] (exit=$exit_code)")
    printf "  FAIL: %-25s got [%s] expected [%s]\n" "$name" "$actual" "$expected"
  fi
done

# Phase 4: emit-failure summary
for ef in "${EMIT_FAILS[@]}"; do
  name="${ef%%|*}"
  reason="${ef#*|}"
  FAIL=$((FAIL+1))
  printf "  EMIT-FAIL: %-22s %s\n" "$name" "$reason"
done

TOTAL=$((PASS+FAIL))
echo "---"
echo "x86_64 conformance: $PASS/$TOTAL"
if (( FAIL > 0 )); then
  echo "Failures:"
  for line in "${FAIL_LINES[@]}"; do
    echo "  $line"
  done
fi
exit $([[ $FAIL -eq 0 ]] && echo 0 || echo 1)
