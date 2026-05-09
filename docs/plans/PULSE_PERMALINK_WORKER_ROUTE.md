# /pulse/N permalink — Worker route to add

The viewer side (`tools/plasma/holo.html` `?pulse=N`) is wired and falls back gracefully when the routes return 404. To actually serve historical pulses, the Cloudflare Worker (in `Ledatic-Empire/ledatic-site` repo, separate from this one) needs two routes added.

## Routes needed

```
GET /entropy/frame/:N    → application/octet-stream  (393264-byte frame blob)
GET /entropy/pulse/:N    → application/json           (pulse record by id)
```

`/entropy/pulse/current` and `/entropy/frame/current` already exist. The `:N` variants serve historical pulses.

## Storage shape

The beacon publisher already writes every pulse's record to chain history; what's missing is a per-pulse-id key in R2 (or KV, but R2 is right for the 393 KB frames).

Expected R2 keys:
- `frames/<N>.bin` — same shape as `/entropy/frame/current` returns: `[u32 w][u32 h][u32 c][u32 step][8×f32 metrics][N²×CH×f32]`.
- `pulses/<N>.json` — same shape as `/entropy/pulse` returns.

If the beacon publisher already writes to a `frames/` bucket but not under `<N>` key, that's the gap to close. Otherwise the publisher needs a small patch to write a per-pulse copy alongside `current`.

## Worker handler sketch

```js
// inside the existing Worker fetch handler
const m = url.pathname.match(/^\/entropy\/(frame|pulse)\/(\d+)$/);
if (m) {
  const [, kind, id] = m;
  const ext = kind === 'frame' ? 'bin' : 'json';
  const ct  = kind === 'frame' ? 'application/octet-stream' : 'application/json';
  const obj = await env.BEACON_R2.get(`${kind}s/${id}.${ext}`);
  if (!obj) return new Response('not found', { status: 404 });
  return new Response(obj.body, {
    headers: {
      'content-type': ct,
      'cache-control': 'public, max-age=31536000, immutable',
    },
  });
}
```

`immutable` is correct because pulses are content-addressed; pulse N never changes once published.

## Retention policy

Decide before deploying:
- Keep all pulses forever (cheap with R2 — 393 KB × pulses/day × ∞).
- Or rotation: keep last 30 days of frames, all pulses.

Based on current pulse rate (~1 every 2s), 30 days of frames = ~50 GB. Acceptable.

## Frontend already handles 404 gracefully

`holo.html`'s `disablePulsePermalink()` flips the pill from blue (active) to amber (degraded) and continues with the live current frame. So shipping `/pulse/<N>` URLs in social posts is safe before the route lands — viewers degrade to live without crashing.

## Testing

Once the route is live:
```
curl -sI https://ledatic.org/entropy/frame/64200 | head -1   # → 200
curl -s  https://ledatic.org/entropy/pulse/64200 | jq .pulse_id   # → 64200
open https://ledatic.org/holo?pulse=64200                    # blue PULSE pill, frame loads
open https://ledatic.org/holo?pulse=99999999                 # amber pill, falls back
```
