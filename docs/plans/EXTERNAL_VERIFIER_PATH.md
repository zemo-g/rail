# EXTERNAL_VERIFIER_PATH.md

Status: proposal · 2026-05-15

## The asymmetry

Rail attests every release, build, selfhost result, fleet node, plasma frame, DDA brief, CI run, and deploy against a live entropy beacon. The verifier is itself Rail (`tools/attest/verify.rail`). Pi witness fleet0 signs every attestation with Ed25519 key `cac5f21a70564aeb`. Fourteen public endpoints are live at `ledatic.org/*`.

**Nobody outside Ledatic verifies any of it.** This makes the thesis ("physicifies") thesis-fragile. The verb is "live, attested, self-hosted." The third leg only stands if someone other than the producer can check the work.

## Concrete first verifier

**Candidate:** one ML-curious developer Reilly has light prior contact with — someone who's already shown they enjoy compiler-internals weirdness (Bellard's circle, the Zig/Roc crowd, the "I'd compile this for fun" cohort). Not Anthropic security (too high friction), not a stranger from HN (too narrow signal), not DDA contacts (engagement closed). One human, one ask.

**Minimum thing they verify:** the v5.1.0 release. One release means one binary (`releases/v5.1.0/rail_native`), one source (`compile.rail`), two attestation JSONs, one beacon pulse (1004625), one witness pubkey.

## Smallest possible verifier UX

```
$ git clone https://github.com/zemo-g/rail
$ cd rail
$ ./tools/attest/verify.sh releases/v5.1.0
ok  artifact=rail_native       pulse_id=1004625  pk_fp=cac5f21a70564aeb
ok  artifact=compile.rail      pulse_id=1004626  pk_fp=cac5f21a70564aeb
ok  selfhost fixed point       pulse_id=1004798
```

Three lines. No accounts, no API keys, no Rail-specific tooling — the verifier runs from a pre-built `rail_native` they trust by reputation (or build from source first, then verify itself, which is its own proof).

**Failure mode to remove:** verify.sh today assumes the user has Rust/cargo/python/X in PATH. Strip to a clean `bash + curl + openssl` floor. If openssl isn't sufficient for Ed25519, embed the public key in `verify.sh` and use Rail's `verify.rail` directly.

## Concrete ask

One DM, before 2026-05-23: "I shipped this thing called Rail; here's a one-command way to verify the release I just cut; would you run it and tell me if it errors? Three lines of expected output." If verify.sh errors on their machine, fix the friction and re-send. If they run it and the output matches, the thesis has its first independent verifier — and the README + ledatic.org gain a credible "verified by N" counter that starts at 1.
