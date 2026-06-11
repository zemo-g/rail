# selfhost/ — fixed-point records

These directories ARE receipts, not documentation. Each `<short-commit>/result.json`
records a 2-pass self-compile at that commit: the seed binary compiled
`tools/compile.rail` (pass 1), the result compiled it again (pass 2), and
`pass1_sha256 == pass2_sha256` is the byte-identical fixed point. Each
`result.json` is itself Ed25519-signed by the fleet0 witness
(`result.json.attestation.json`). Verify one offline, from this clone:

```bash
./rail_native run tools/attest/verify.rail \
    selfhost/94afdd1/result.json \
    selfhost/94afdd1/result.json.attestation.json \
    releases/witness-fleet0/fleet0.pub.pem
# -> ok  artifact=result.json  pulse_id=1004798  pk_fp=cac5f21a70564aeb
```

`seed_match: false` in these records is expected, not a failure: the shipped seed
binary was built by the *previous* generation, whose emitted runtime can differ
from what the current source emits — the fixed point lands on pass 2. See
`notes/bootstrap_convergence_audit_2026-05-13.md` and `docs/VERIFY.md`.

Nothing in here is ever edited, moved, or re-signed — signatures bind bytes.
