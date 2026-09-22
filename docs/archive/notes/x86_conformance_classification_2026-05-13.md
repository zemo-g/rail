# x86_64 Conformance Classification — 2026-05-13

Empirical classification of every test in `tools/test/x86_conformance.sh`
after extending from 79 → 127 cases. Each test was actually executed via
Colima/Rosetta + Docker `gcc:latest` (linux/amd64). No "would work"
predictions — every status below is observed.

## Headline tally

```
Before this branch:  71/79
After this branch:   90/127 (entries; some are diagnostic gap-surfacers)
  - 90 PASS  (portable)
  - 36 link-fail  (deferred-symbol — concrete blast-radius below)
  -  1 FAIL  (deferred-codegen — null_safe_eq, real x86 bug)
```

ARM64 floor: 140/140 (verified before & after; the harness change is
runtime-only and cannot affect ARM64 emit).

## Blast-radius ranking — top symbols that unblock the most tests

Counted by how many test entries' link errors mention that symbol.
(Note: a single test can list multiple missing symbols; sha256-based
tests each cite `_bit_and`, `_bit_or`, `_bit_xor`, `_shr`, `_shl`,
`_byte_at`, `_byte_set` — so implementing one of those alone won't
unblock the test, but implementing the whole bit-op cluster will.)

| Rank | Symbol                | Direct mentions | Tests fully unblocked when cluster lands |
|------|-----------------------|-----------------|-------------------------------------------|
| 1    | `_bit_and`            | 10              | Anchors the bit-op cluster (see below)    |
| 2    | `_float_arr_new`      |  5              | Anchors the float-array cluster            |
| 3    | `_spawn_thread`       |  3 (+ join)     | Anchors the thread cluster (2 tests)       |

### Cluster A — bit-op cluster

Implementing all six `_bit_and / _bit_or / _bit_xor / _shl / _shr /
_rotl` (plus `_byte_at` / `_byte_set` for crypto-byte access) would
unblock **11 tests** in this harness:

- `bit_and`, `bit_or`, `bit_xor_identity`, `shl_basic`, `shr_basic`,
  `rotl_roundtrip`, `rotr32_composed` — 7 direct primitive tests
- `sha256_empty`, `sha256_abc`, `sha256_two_blocks`, `hmac_sha256_jefe`
  — 4 cascade tests via `stdlib/sha256.rail` (`and32`/`or32`/`xor32`)
- `hkdf_rfc5869_tc1`, `chacha20_block`, `poly1305_mac`, `aead_tag`,
  `x25519_rfc7748_v1` — 5 cascade tests (sha256/bitops via stdlib)

**Implementation note**: these are all 2-arg int-in-int-out runtime
helpers; ARM64 `and`/`orr`/`eor`/`lsl`/`lsr`/`ror` map directly to x86
`and`/`or`/`xor`/`shl`/`shr` + ror. Tag-aware (`asr 1` then re-tag) like
existing `_rail_add`. Highest-ROI symbol cluster on the harness.

### Cluster B — float-array cluster

Implementing `_float_arr_new / _float_arr_set / _float_arr_get /
_float_arr_to_f32_file / _float_arr_from_f32_file` (+ `_to_int /
_parse_float`) would unblock **6 tests**:

- `f32_io_roundtrip`, `mixed_float_int_op` — 2 direct tests
- `tensor_prims`, `tensor_rank`, `tensor_slice`, `tensor_layer_norm`
  — 4 cascade tests via `stdlib/tensor.rail`
- `parse_float`, `sci_int_exp`, `sci_frac` — 3 float-literal/parse tests

**Implementation note**: x86 backend already accepts `parse_float` /
`to_float` / `int_to_float` / `float_arr_get` as "no-retag" calls in
`x86_cg_bi`, but the underlying `_rail_float_arr_*` symbols are
missing in `tools/x86_rt.s`. ARM64 has them at `compile.rail:~2930`.

### Cluster C — thread cluster

Implementing `_spawn_thread / _join_thread` (calling `pthread_create` /
`pthread_join` on Linux, no `_` prefix) would unblock **2 tests**:

- `thread`, `thread_par`

### Cluster D — FFI ELF-prefix fix (Agent A)

The 3 ffi tests (`ffi_abs`, `ffi_strlen`, `ffi_getenv_root`) and 1
foreign-malloc test (`byte_rw`) all fail because x86 emits `call _abs`
instead of `call abs` for `foreign` declarations. Agent A's branch
fixes this; expected to flip 4 tests to PASS after integration.

### Cluster E — str_runtime symbols (Agent B)

The 5 diagnostic tests (`str_find`, `str_contains`, `str_sub`,
`str_split`, `str_replace`) plus `ffi_getenv_root` (which calls
`str_sub`) link-fail on `_rail_str_*`. Agent B's branch ships these
five symbols; expected to flip 5 tests + the `_rail_str_sub` line of
`ffi_getenv_root` to PASS.

## Real x86 codegen bug surfaced

**`null_safe_eq`** — Rail source:

```rail
type T = | T x
main =
  let t = T 42
  let a = arr_new 2 0
  let _ = arr_set a 1 t
  let v0 = arr_get a 0
  let v1 = arr_get a 1
  let z0 = if v0 == 0 then 1 else 0
  let z1 = if v1 == 0 then 1 else 0
  z0 * 10 + z1
```

ARM64: `10` (v0 is tagged-int 0, v1 is heap pointer to `T 42`).
x86_64: exit 139 (SIGSEGV). The `==` comparison of an uninitialized
arr slot against the literal `0` segfaults. **Real codegen gap, not
predicted by the deferred-symbol model.** Filed as
`deferred-codegen:arr_init_eq` — root cause investigation needed,
likely in `x86_cg_bi2 == `arr_get` or the `==` emit on heap-tagged
operands.

## Full per-test classification table

| test               | t#   | observed   | classification                                       |
|--------------------|------|------------|------------------------------------------------------|
| main42             | t1   | PASS       | portable                                             |
| add                | t2   | PASS       | portable                                             |
| if                 | t3   | PASS       | portable                                             |
| double             | t4   | PASS       | portable                                             |
| fact               | t5   | PASS       | portable                                             |
| print              | t6   | PASS       | portable                                             |
| lets               | t8   | PASS       | portable                                             |
| strprint           | t9   | PASS       | portable                                             |
| streq              | t10  | PASS       | portable                                             |
| show               | t12  | PASS       | portable                                             |
| append             | t13  | PASS       | portable                                             |
| listlen            | t15  | PASS       | portable                                             |
| headtail           | t16  | PASS       | portable                                             |
| cons               | t17  | PASS       | portable                                             |
| empty              | t19  | PASS       | portable                                             |
| strlen             | t20  | PASS       | portable                                             |
| mapfn              | t21  | PASS       | portable                                             |
| maplam             | t22  | PASS       | portable                                             |
| closure            | t23  | PASS       | portable                                             |
| join               | t24  | PASS       | portable                                             |
| tuple              | t25  | PASS       | portable                                             |
| tco                | t33  | PASS       | portable                                             |
| adt_none           | t35  | PASS       | portable                                             |
| adt_some           | t36  | PASS       | portable                                             |
| neg                | t38  | PASS       | portable                                             |
| float              | t40  | PASS       | portable                                             |
| float_mul          | t41  | PASS       | portable                                             |
| float_cmp          | t42  | PASS       | portable                                             |
| fold               | t50  | PASS       | portable                                             |
| filter             | t49  | PASS       | portable                                             |
| range              | t54  | PASS       | portable                                             |
| fold_sum           | t55  | PASS       | portable                                             |
| strne              | t11  | PASS       | portable                                             |
| str_plus           | t14  | PASS       | portable                                             |
| listapp            | t18  | PASS       | portable                                             |
| tupret             | t26  | PASS       | portable                                             |
| tup3               | t27  | PASS       | portable                                             |
| chars              | t28  | PASS       | portable                                             |
| split_csv          | t29  | PASS       | portable                                             |
| bigint             | t34  | PASS       | portable                                             |
| adt_pair           | t37  | PASS       | portable                                             |
| wildcard           | t46  | PASS       | portable                                             |
| reverse            | t51  | PASS       | portable                                             |
| not                | t53  | PASS       | portable                                             |
| neg_arith          | t56  | PASS       | portable                                             |
| match_int          | t58  | PASS       | portable                                             |
| guard              | t59  | PASS       | portable                                             |
| map_fusion         | t64  | PASS       | portable                                             |
| nested_lam         | t68  | PASS       | portable                                             |
| nested_lam_let     | t69  | PASS       | portable                                             |
| nested_lam_cap     | t70  | PASS       | portable                                             |
| pipe               | t73  | PASS       | portable                                             |
| match_str          | t74  | PASS       | portable                                             |
| fold_str           | t75  | PASS       | portable                                             |
| arr_set            | t87  | PASS       | portable                                             |
| arr_len            | t88  | PASS       | portable                                             |
| arr_sum            | t89  | PASS       | portable                                             |
| error              | t90  | PASS       | portable                                             |
| char_to_int        | t93  | PASS       | portable                                             |
| parse_int          | t100 | PASS       | portable                                             |
| fileio             | t30  | PASS       | portable                                             |
| shell_echo         | t31  | PASS       | portable                                             |
| integ              | t32  | PASS       | portable                                             |
| escape             | t39  | PASS       | portable                                             |
| ffi_abs            | t43  | link-fail  | expected-after:A (`_abs` should be `abs`)            |
| ffi_strlen         | t44  | link-fail  | expected-after:A (`_strlen` should be `strlen`)      |
| ffi_getenv_root    | t45* | link-fail  | expected-after:A + B (`_getenv` + `_rail_str_sub`)   |
| arena              | t48  | PASS       | portable                                             |
| gpu_map_pass       | t66  | PASS       | portable                                             |
| gpu_auto           | t67  | PASS       | portable                                             |
| str_find           | —    | link-fail  | expected-after:B (`_rail_str_find`)                  |
| str_contains       | —    | link-fail  | expected-after:B (`_rail_str_contains`)              |
| str_sub            | —    | link-fail  | expected-after:B (`_rail_str_sub`)                   |
| str_split          | —    | link-fail  | expected-after:B (`_rail_str_split`)                 |
| str_replace        | —    | link-fail  | expected-after:B (`_rail_str_replace`)               |
| map_new            | t76  | PASS       | portable                                             |
| map_put_get        | t77  | PASS       | portable                                             |
| map_has            | t78  | PASS       | portable                                             |
| map_keys           | t79  | PASS       | portable                                             |
| map_int_key        | t80  | PASS       | portable                                             |
| buf_new            | t81  | PASS       | portable                                             |
| buf_append         | t82  | PASS       | portable                                             |
| buf_multi          | t83  | PASS       | portable                                             |
| buf_int            | t84  | PASS       | portable                                             |
| buf_big            | t85  | PASS       | portable                                             |
| arr_new            | t86  | PASS       | portable                                             |
| thread             | t91  | link-fail  | deferred-symbol:`_rail_spawn_thread`+`_rail_join_thread` |
| thread_par         | t92  | link-fail  | deferred-symbol:`_rail_spawn_thread`+`_rail_join_thread` |
| set_basic          | t94  | PASS       | portable                                             |
| set_absent         | t95  | PASS       | portable                                             |
| ht_map             | t96  | PASS       | portable                                             |
| set_many           | t97  | PASS       | portable                                             |
| byte_rw            | t98  | link-fail  | deferred-symbol:`_rail_byte_set`+`_rail_byte_at` + expected-after:A (`_malloc`) |
| parse_float        | t99  | link-fail  | deferred-symbol:`_rail_parse_float`+`_rail_to_int`   |
| sci_int_exp        | t101 | link-fail  | deferred-symbol:`_rail_to_int`                       |
| sci_frac           | t102 | link-fail  | deferred-symbol:`_rail_to_int`                       |
| null_safe_eq       | t103 | FAIL (139) | deferred-codegen:`arr_init_eq` — real x86 bug         |
| f32_io_roundtrip   | t104 | link-fail  | deferred-symbol:`_rail_float_arr_*`                  |
| mixed_float_int_op | t106 | link-fail  | deferred-symbol:`_rail_float_arr_set`+`_rail_float_arr_get`+`_rail_float_arr_new` |
| char_to_int_rt     | t107 | PASS       | portable                                             |
| tensor_prims       | t105 | link-fail  | deferred-symbol:`_rail_float_arr_new` (via tensor.rail) |
| tensor_rank        | t108 | link-fail  | deferred-symbol:`_rail_float_arr_new` (via tensor.rail) |
| tensor_slice       | t109 | link-fail  | deferred-symbol:`_rail_float_arr_new` (via tensor.rail) |
| tensor_layer_norm  | t110 | link-fail  | deferred-symbol:`_rail_float_arr_new`+sqrt (via tensor.rail) |
| bit_and            | t111 | link-fail  | deferred-symbol:`_rail_bit_and`                      |
| bit_or             | t112 | link-fail  | deferred-symbol:`_rail_bit_or`                       |
| bit_xor_identity   | t113 | link-fail  | deferred-symbol:`_rail_bit_xor`                      |
| shl_basic          | t114 | link-fail  | deferred-symbol:`_rail_shl`                          |
| shr_basic          | t115 | link-fail  | deferred-symbol:`_rail_shr`                          |
| rotl_roundtrip     | t116 | link-fail  | deferred-symbol:`_rail_rotl`                         |
| rotr32_composed    | t117 | link-fail  | deferred-symbol:`_rail_shr`+`_rail_shl`+`_rail_bit_or`+`_rail_bit_and` |
| sha256_empty       | t118 | link-fail  | deferred-symbol-cascade:bit-op cluster               |
| sha256_abc         | t119 | link-fail  | deferred-symbol-cascade:bit-op cluster               |
| sha256_two_blocks  | t120 | link-fail  | deferred-symbol-cascade:bit-op cluster               |
| hmac_sha256_jefe   | t121 | link-fail  | deferred-symbol-cascade:bit-op cluster               |
| hkdf_rfc5869_tc1   | t122 | link-fail  | deferred-symbol-cascade:bit-op cluster               |
| chacha20_block     | t123 | link-fail  | deferred-symbol-cascade:bit-op cluster               |
| poly1305_mac       | t124 | link-fail  | deferred-symbol-cascade:bit-op cluster               |
| aead_tag           | t125 | link-fail  | deferred-symbol-cascade:bit-op cluster               |
| x25519_rfc7748_v1  | t126 | link-fail  | deferred-symbol-cascade:bit-op cluster               |
| int_lit_3movk      | t132 | PASS       | portable (x86 movabs handles 64-bit imm uniformly)   |
| int_lit_4movk      | t133 | PASS       | portable                                             |
| int_lit_4movk_neg  | t134 | PASS       | portable                                             |
| import_path        | t47  | PASS       | portable                                             |
| qual_import        | t60  | PASS       | portable                                             |
| bare_import        | t71  | PASS       | portable                                             |
| bare_import_as     | t72  | PASS       | portable                                             |

## Honest deferred — tests not added to harness

| t#   | name                          | reason                                                           |
|------|-------------------------------|------------------------------------------------------------------|
| t7   | add (function form)           | name collides with existing 3+4 test idiom; redundant            |
| t52  | to_float                      | would be deferred-symbol:`_rail_to_float`; covered by parse_float cascade |
| t57  | spawn                         | needs `_rail_spawn`+`_rail_fiber_await`; not in critical-path     |
| t61  | rc                            | partial — `_rail_rc_alloc` exists; coverage via shipped portable tests |
| t62  | channel                       | needs `_rail_channel`+`_rail_send`+`_rail_recv`; orthogonal to harness goal |
| t63  | ffi_float                     | duplicates `ffi_abs` failure mode (ELF-prefix)                   |
| t65  | generate_ct                   | `#generate` is a build-time macro; requires deferred-feature path |
| t127 | tls13_key_schedule            | bit-op cascade already shown via t118-t126; adding more inflates count without adding info |
| t128 | tls13_client_hello            | same                                                             |
| t129 | tls13_parse_server_hello      | same                                                             |
| t130 | tls13_record_roundtrip        | same                                                             |
| t131 | tls13_handshake_msg_parsers   | same                                                             |

## Reproducing

```bash
cd ~/projects/rail
colima status   # must be running x86_64 / vz / rosetta
bash tools/test/x86_conformance.sh
```

The harness now serializes its emit step with a mkdir-based mutex
(`/tmp/rail_x86_conformance.lockdir`) to survive concurrent parallel-
agent sessions that also touch `/tmp/rail_x86.s`. macOS lacks `flock`;
mkdir is atomic.
