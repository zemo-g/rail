# Ed25519 sign in pure Rail — Session 1 handoff

**Date:** 2026-05-02
**Branch:** `ed25519-sign` (off `master` v3.8.0), commit `91aafd4`
**Worktree:** `~/projects/rail-https/`
**Status:** Session 1 of 3 complete. Math substrate (sc_reduce + sc_muladd) shipped + verified against Python oracle. Sign function still TODO (Session 2).

---

## What shipped this session

| File | LOC | Role |
|---|---|---|
| `stdlib/ed25519_scalar.rail` | 195 | `sc_reduce` + `sc_muladd` + 8 byte-array primitives |
| `tools/tls/ed25519_scalar_test.rail` | 165 | 8 vectors, all PASS |

Public API (single-line summary):

```
sc_reduce  bytes64           -> bytes32   -- bytes64 mod L (RFC 8032 §5.1.6)
sc_muladd  a32 b32 c32       -> bytes32   -- (a*b + c) mod L
```

Both are pure functions over malloc'd `arr_new` byte buffers. Caller owns buffers.

### Vectors that pass

```
sc_reduce(0)                          == 0                       1/8
sc_reduce(L)                          == 0                       2/8
sc_reduce(L+1)                        == 1                       3/8
sc_reduce(2L+5)                       == 5                       4/8
sc_reduce(SHA-512(''))                == Python(... % L)         5/8  ← external oracle
sc_muladd(2,3,5)                      == 11                      6/8
sc_muladd(1, L-1, 1)                  == 0   (= L mod L)         7/8
sc_muladd((L-1)^2, 0)                 == 1                       8/8
```

The fifth vector is the killer — Python computes
`int.from_bytes(hashlib.sha512(b'').digest(), 'little') % L` and we match
byte-for-byte. Any off-by-one in carry propagation, byte ordering, or
reduction count shows up here immediately.

### Design choices worth knowing

- **Byte-array shift-and-subtract reduction** instead of libsodium ref10's
  signed 21-bit-limb representation. Slower (~O(N²) over 64 bytes) but
  trivially auditable: every step diffs against a 5-line Python reference.
  Perf doesn't matter — we sign at attestation cadence (seconds-minutes).
- **No signed shifts.** Rail's `shr` is logical/unsigned only (per
  `tools/compile.rail:1080`). The byte-array design has all values in
  `[0, 255]` so signedness never enters the picture.
- **Stdlib lives separately from `ed25519.rail`.** Verify-only callers
  don't pull in the sign-mode code. Match the existing convention where
  signing is opt-in.

---

## How to run the tests

```bash
cd ~/projects/rail-https
./rail_native tools/tls/ed25519_scalar_test.rail   # compile only -> /tmp/rail_out
cp -p /tmp/rail_out /tmp/sc_test
codesign --sign - --force /tmp/sc_test             # see playbook step 5
/tmp/sc_test                                        # PASS expected
```

Full suite:
```bash
./rail_native test                                  # 137/137
```

---

## Two playbook hits this session (no surprises)

1. **Plasma daemon clobbered `/tmp/rail_out`** mid-test (playbook step #4).
   Symptom: test "output" was actually `mhd_beacon` frame logs.
   Fix: `pkill -9 -f "rail_native run tools/plasma"`.

2. **`cp` of Mach-O strips signature → exit 137** (playbook step #5).
   `cp -p` ALONE is no longer sufficient on this OS — needed
   `codesign --sign - --force /tmp/sc_test` to get the binary to run.
   *(Worth a one-line update to `feedback_rail_debugging_playbook.md`
   step 5 — `cp -p` is now insufficient; force-resign required.)*

---

## Session 2 — the sign function (next)

Per the original handoff:

```
ed25519_sk_expand(seed_32) -> (a_32, prefix_32)
    SHA-512(seed) -> 64 bytes
    a_32 = first 32, with clamping (clear bits 0,1,2 of byte 0;
                                    clear bit 7 and set bit 6 of byte 31)
    prefix_32 = last 32 (used as nonce-deriving prefix)

ed25519_pk_from_sk(seed_32) -> bytes_32
    a, _ = sk_expand(seed)
    A = ed_scalar_mul(B, a, 32) over base point B
    encode A -> 32 bytes

ed25519_sign(seed, msg, msg_len) -> sig_64
    (a, prefix) = sk_expand(seed)
    A           = pk_from_sk(seed)
    r           = sc_reduce(SHA512(prefix || msg))
    R           = encode(scalar_mul(B, r, 32))
    k           = sc_reduce(SHA512(R || A || msg))
    S           = sc_muladd(k, a, r)        ← uses session 1's sc_muladd
    return R || S
```

**Killer test** (RFC 8032 §A.4 vector 1):

```
secret key: 9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60
public key: d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a
message:    (empty)
expected:   e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b
```

If sig matches byte-for-byte, sign is correct. Bonus check: round-trip
`ed25519_verify(pk, msg, msg_len, sig)` should return 1 (uses
`tools/tls/ed25519_test.rail`'s existing infrastructure).

**Stop condition for Session 2:** RFC vector 1 byte-identical AND
round-trip via existing `ed25519_verify` returns 1.

**Estimated effort:** 1-2 hours. The math is in place; this is
orchestration plus the SHA-512-of-`prefix||msg` plumbing.

---

## Session 3 — `attest.rail` (after Session 2 lands)

Once `ed25519_sign` works, `tools/attest/attest.sh` can become
`tools/attest/attest.rail`. The Pi-side signer (`sign_attestation.sh`
over SSH) still needs to be replaced with a Pi-hosted HTTP signer
endpoint OR by porting the signer to Rail (gated on Linux ARM64
cross-compile fix — see `rail-linux-cross-compile-broken.md`).

Path A (Pi grows HTTP signer): ~50 lines Python + systemd unit on
fleet0. Ships in days. Caller is Rail.

Path B (Rail-on-Pi): rabbit-hole risk on the Linux ELF emit path.
Worth a budgeted attempt with explicit "I will spend up to 6 hours and
otherwise back out cleanly" timer.

---

## Branch / merge state

```
ed25519-sign  91aafd4  ed25519: scalar arithmetic mod L (sc_reduce + sc_muladd)
master        3d782b9  runtime+stdlib+attest: read_file_bytes builtin + binary release flow  (= v3.8.0)
```

`ed25519-sign` adds two new files only — no compiler edits, no stdlib
edits to existing modules, no behavior change to anything that already
shipped. Safe to leave on a branch until Session 2 lands and the full
sign+verify story is ready to merge.

---

## Don't widen scope (carried from prior handoff)

The original frame said: don't write the sign function before the math
is proven. Math is now proven. The follow-on rule for Session 2: don't
write `attest.rail` before RFC vector 1 byte-matches. One layer at a
time. Each layer fully testable before the next is started.
