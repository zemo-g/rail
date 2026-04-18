# Security

Rail v3.0.0 ships a pure-Rail TLS 1.3 + X.509 stack. This file documents what that means for security-minded users, and how to report issues.

## Security posture (read this before deploying)

**Rail is not a drop-in OpenSSL replacement.** It's a minimal-surface TLS client built for one story: let a self-hosted language talk to real HTTPS APIs without a C dependency. The cryptographic code is straightforward, testable, and vector-validated — but it is **not**:

- **Constant-time.** The bignum, ECDSA, and RSA implementations are written for clarity, not for resistance to timing side-channels. An attacker who can measure precise execution timing of a Rail process can probably extract secret material.
- **Side-channel hardened.** No effort has been made to equalise memory access patterns, guard against cache-timing attacks, or resist power analysis.
- **Formally verified.** No soundness proof, no model-checked state machine. The TLS 1.3 handshake is validated against RFC 8448 §3 traces; that's a vector match, not a proof.
- **Audited.** There has been no third-party security review.
- **Feature-complete.** One cipher suite, one ECDHE group, three sig-algs (see `README.md` honest-limits section). Server cert chain walking is an opt-in primitive, not the default in `https_get`.

**What this means in practice:**

- Fine for calling `api.anthropic.com` or `slack.com` from your own machine over your own network.
- Fine for fleet-to-fleet traffic you control.
- **Not** fine for handling third-party user traffic, client-certificate authentication, or anything where a sophisticated adversary can observe your process.

If you're evaluating this for any kind of production deployment, use OpenSSL / rustls / boringssl instead. Rail v3.0.0's HTTPS is for *Rail* — for the language itself to talk to the world. It is not a general-purpose TLS library.

## Cryptographic primitives shipped

Every one is validated against NIST or RFC test vectors. See `tools/tls/*.rail`.

| Primitive | Source vector |
|---|---|
| SHA-256 | NIST "abc", "", NIST 56-byte dual-block edge case |
| SHA-384 / SHA-512 | NIST "abc", "" |
| HMAC-SHA-256 | RFC 4231 Tests 1 / 2 / 4 |
| HKDF | RFC 5869 Test Case 1 |
| ChaCha20 | RFC 8439 §2.3.2 block, §2.4.2 114-byte |
| Poly1305 | RFC 8439 §2.5.2 |
| ChaCha20-Poly1305 AEAD | RFC 8439 §2.8.2 |
| X25519 | RFC 7748 §5.2 Vectors 1 + 2 |
| ECDSA-P256 | RFC 6979 §A.2.5 |
| ECDSA-P384 | RFC 6979 §A.2.6 |
| RSA-PSS-SHA256 | Self-signed round-trip via Python `cryptography` |
| RSA-PKCS1-v1.5 | Self-signed round-trip via Python `cryptography` |
| TLS 1.3 handshake | RFC 8448 §3 Simple 1-RTT trace, byte-exact |

## Reporting a vulnerability

If you find a real security issue:

1. **Do not open a public GitHub issue.**
2. Email the maintainer at `zemo-g@users.noreply.github.com`. A plaintext email is fine — Rail's threat model doesn't yet include encrypted reports as a hard requirement.
3. Include a minimal reproducer. A Rail program that exhibits the bug is ideal; a test vector + expected-vs-actual output is next best.
4. Expect an acknowledgement within a few days. Fixes land on `master` and get tagged as a point release.

Non-security bugs (including crypto correctness issues that aren't exploitable) should go on the regular GitHub issue tracker.

## Scope

Rail v3.0.0's TLS is in scope for security reports. So is the cert chain walker, the `/etc/ssl/cert.pem` loader, and the URL-parser surface in `stdlib/https_client.rail`.

Out of scope:

- Side-channel / timing issues in the bignum or elliptic-curve code — acknowledged limitation, see "Security posture" above.
- Compiler bugs that corrupt emitted code are bugs, not security issues, unless they produce a specific cryptographic failure.
- DoS via a malicious cert payload parsed by `stdlib/asn1.rail` — we handle malformed inputs with a bounded fail-path (returns 0), but have not fuzzed exhaustively.
