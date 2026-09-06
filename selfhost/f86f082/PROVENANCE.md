# selfhost/f86f082: attestation retired

`result.json.attestation.json.stale` is a real signed witness, but it no longer
describes `result.json`. The signed digest is
`66d90c3c2014dea02c92d62d5350e99d34101ec38f081c3b7e61ba2b2f1ca9d5`; the file
in this tree hashes to
`98485f09224f8c252ba90023aa007bf4cfe2a8646da615d38c2c467d73ff8d1e`, same size
(571 bytes), different bytes. The file was rewritten by the public-surface
scrub (`c4f6050`, "sanitize public surface") after it had been signed, and the
pre-scrub bytes are not recoverable from any clone we hold.

Rather than re-sign the rewritten file and present it as the original run, the
sidecar is kept under `.stale` so the mismatch stays visible. The self-host
result it records (fixed point reached, seed_match false) stands as an
unattested historical note only. Found by the 2026-09-06 outside review.

Two other directories here (`13107d0-dirty`, `433f208`) never had a sidecar.
