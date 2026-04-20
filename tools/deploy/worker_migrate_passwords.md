# Reports portal — password hash migration plan (T5)

## Current state

`tools/deploy/worker.js` stores client passwords as raw SHA-256.
No salt, no iterations.  A KV dump is rainbow-table-able in minutes
for anything under 10-char password + common patterns.

```js
// Current (weak)
async function hashPassword(password) {
  const data = new TextEncoder().encode(password);
  const hash = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(hash)].map(b => b.toString(16).padStart(2, "0")).join("");
}
```

## Target

**PBKDF2-SHA256, 100 000 iterations, per-client 16-byte random salt.**
Stored as `pbkdf2$100000$<salthex>$<dkhex>` — prefix makes it trivially
distinguishable from legacy bare-SHA256 hashes.

```js
// Target
async function hashPassword(password, saltHex /* optional */) {
  const salt = saltHex
    ? Uint8Array.from(saltHex.match(/../g).map(b => parseInt(b, 16)))
    : crypto.getRandomValues(new Uint8Array(16));
  const enc = new TextEncoder().encode(password);
  const key = await crypto.subtle.importKey("raw", enc, "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt, iterations: 100000 },
    key, 256
  );
  const toHex = buf => [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, "0")).join("");
  return `pbkdf2$100000$${toHex(salt.buffer)}$${toHex(bits)}`;
}

async function verifyPassword(password, stored) {
  if (stored.startsWith("pbkdf2$")) {
    const [, iters, saltHex, expectedDk] = stored.split("$");
    const rehash = await hashPassword(password, saltHex);
    return rehash.split("$")[3] === expectedDk;
  }
  // Legacy path: compare bare SHA-256
  const legacy = await legacySha256(password);
  return legacy === stored;
}
```

## Migration path (no user-visible disruption)

1. **Ship verification-with-fallback** first.  `verifyPassword` accepts
   both legacy SHA-256 and new `pbkdf2$…` format.  Deploy; nothing
   changes for users.

2. **Transparent re-hash on successful login.**  After `verifyPassword`
   returns true on a legacy hash, re-hash with the new format and
   `PUT` back to `client:<id>` in KV.  User typed the right password;
   we upgraded storage silently.

3. **Monitor migration rate.**  Log legacy-vs-new verify counts to
   `/var/log/ledatic-migration.log` (or just console-log the counts in
   the Worker — CF Logs show them).  Expect most active clients to
   flip within 30 days.

4. **Force-reset for stragglers (optional, week 90).**  Clients still
   on legacy after 90 days haven't logged in.  Either leave them
   (dormant) or email a reset link.

## Rollback

`git revert` the worker commit → `deploy_worker.sh`.  Users on
upgraded hashes will fail login (we lost their plaintext).  Keep the
legacy-verify path in the code forever to avoid this.

## What not to do

- **Don't bcrypt / argon2 in a Worker.**  CF Worker runtime has
  `crypto.subtle` (WebCrypto) but no bcrypt/argon2 binding.  Adding a
  WASM argon2 is possible but adds ~50KB and startup time per request.
  PBKDF2 at 100k iterations is the pragmatic floor.
- **Don't reuse the salt across clients.**  Per-client random salts
  are the whole point.
- **Don't iterate below 100k.**  OWASP's current floor for PBKDF2-SHA256
  is 600k; 100k is the compromise for CF Worker CPU-time limits
  (50ms paid, 10ms free).  Verify performance before merging.

## Tests to run pre-deploy

```bash
# Hash then verify — both paths
node -e '
const subtle = require("crypto").webcrypto.subtle;
// paste hashPassword + verifyPassword here, replace crypto.subtle with subtle
(async () => {
  const h = await hashPassword("hunter2");
  console.log("new hash:", h);
  console.log("verify new:", await verifyPassword("hunter2", h));
  console.log("verify wrong:", await verifyPassword("wrong",   h));
  const legacy = "f52fbd32b2b3b86ff88ef6c490628285f482af15ddcb29541f94bcf526a3f6c7"; // SHA-256("hunter2")
  console.log("verify legacy:", await verifyPassword("hunter2", legacy));
})();
'
```
