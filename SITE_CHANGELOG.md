# Site Changelog

Changes to **ledatic.org** — the website, not the language.
Rail's own release log is in [CHANGELOG.md](./CHANGELOG.md).

## 2026-04-19 — Atom feed, /changelog page, honest copy pass

First pass at making the site itself legible to feed readers and
repeat visitors.

### Atom feed

`/feed.xml` — Atom 1.0 feed rebuilt nightly from `CHANGELOG.md`.
`type="html"` paragraphs so readers render structured content
instead of one big line. `<link rel="alternate">` auto-discovery
from the home page `<head>`.  Every entry deep-links into
`/changelog#vX.Y.Z`. An XSL stylesheet styles the feed in a browser
viewer; feed readers ignore it and get raw Atom.

### /changelog page

Full HTML render of `CHANGELOG.md` at `/changelog` with:
- Sticky left-nav listing every version with its date
- `:target` highlights the linked release with a blue border
- Dark theme matching the home page
- Top-nav "Changelog" link on every page

### Copy pass

- `<title>` now reads *A language that deleted its own compiler*
  (pulled the OG hook into the primary title).
- Rail version in the "Technical" section now pulls from
  `CHANGELOG.md` instead of `ASSET_VERSION.txt` (that was a CSS/JS
  cache-bust tag — readers were confusing the two numbers).
- Hero copy: *a programming language* + *a self-flying drone*
  (singular). Matches reality: one language, one drone.
- Rust-vs-Rail bar chart: caption clarifies that Rust was the
  one-time bootstrap compiler, deleted once Rail self-hosted.
- "AI that Teaches Itself" card reframed past-tense: the flywheel
  ran for 20 levels and harvested 1.6 K+ compiler-verified examples.
  (Previously frozen at "1,636 verified lessons so far" when the
  loop had stopped running.)
- Entropy ticker: "every ~2 seconds" — matches the bash daemon on
  Mini that actually pulses the beacon.
- Logo is now `<a href='/'>` so clicking returns home.  CSS bumped
  to keep the link's bright color against the nav's dim anchor rule.

### Dropdown fix

The top-right hamburger dropdown was reading as transparent even
with a solid background color set — `backdrop-filter:blur(16px)` on
the parent `<nav>` forced children into the same compositing layer,
and the blur bled through. Moved the dropdown outside `<nav>` to
`position:fixed` at viewport level, gave it its own `isolation:
isolate`, and made each link background explicitly opaque.

### Daily deploy wiring

`tools/deploy/daily_deploy.rail` now regenerates all six surfaces
nightly: main site, `/system`, `/playground`, `/plasma`,
`/changelog`, `/feed.xml`. `com.ledatic.site-deploy` LaunchAgent
fires it at 06:00 UTC.
