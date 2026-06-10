#!/usr/bin/env bash
# site_bump_pr.sh — open a PR against Ledatic-Empire/ledatic-site that
# bumps the public version banner across 8 HTML pages from the current
# live value to a target version.
#
# What it touches:
#   - Hero eyebrow:       "Language — vX.Y.Z"
#   - Visor mini:         "vX.Y.Z // N/N"
#   - Footer:             "RAIL vX.Y.Z · N/N"
#   - index.html stat:    "Current Rail" tile
#   - "now.html" pill:    "<pill shipped>vX.Y.Z</pill>"
#   - Hero subtitle on index.html: "Rail vX.Y.Z · N tests green"
#
# The test count N/N is detected from the live page; override the value
# written with RAIL_TEST_COUNT (e.g. parse it from a fresh run:
#   RAIL_TEST_COUNT="$(./rail_native test | tail -1 | grep -oE '[0-9]+/[0-9]+')").
#
# What it does NOT touch (intentional — editorial):
#   - changelog.html release cards (each is a historical anchor)
#   - rail.html "Recent releases" cards
#   - meta descriptions / og: tags
#   The PR description includes a checkbox prompting the author to
#   add the new changelog entry by hand using CHANGELOG.md as source.
#
# Idempotent: if the target branch already exists locally OR on origin,
# print the PR URL (if any) and exit 0. Safe to invoke from drift_audit.
#
# Stash-isolates: the operator's dirty CSS/JS in the working tree are
# stashed before sed, popped after commit, so they don't sneak into
# the auto-PR.
#
# Usage:
#   ./tools/attest/site_bump_pr.sh v3.12.0        # bump to v3.12.0
#   ./tools/attest/site_bump_pr.sh v3.12.0 --dry  # preview, no push
#
# Exit codes:
#   0 — PR opened (or already open from a prior run)
#   1 — error (auth, sed, push)
#   2 — bad arguments

set -uo pipefail

if [ $# -lt 1 ]; then
  echo "usage: site_bump_pr.sh <version> [--dry]" >&2
  exit 2
fi

VERSION="$1"
DRY="${2:-}"
[ "$DRY" = "--dry" ] && DRY=1 || DRY=0

# Strict shape check — refuse anything that isn't vMAJOR.MINOR.PATCH so
# we don't accidentally write nonsense into 8 public pages.
if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "site_bump_pr: invalid version '$VERSION' (must match vN.N.N)" >&2
  exit 2
fi

SITE=${SITE:-$HOME/projects/ledatic-site}
RAIL_REPO=${RAIL_REPO:-$HOME/projects/rail}
PAGES=(index.html rail.html entropy.html fleet.html aliens.html manifesto.html plasma.html changelog.html)
BRANCH="auto/site-bump-$VERSION"

cd "$SITE"

log() { printf '[site_bump_pr %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

# 0. Authority check.
if ! gh auth status >/dev/null 2>&1; then
  log "ERROR: gh not authenticated. Run: gh auth login"
  exit 1
fi

# 1. Already-open PR for this version? Idempotent skip.
existing_pr=$(gh pr list --state open --search "head:$BRANCH" --json url,headRefName 2>/dev/null \
  | python3 -c 'import sys, json; d=json.load(sys.stdin); print(d[0]["url"] if d else "")' 2>/dev/null)
if [ -n "$existing_pr" ]; then
  log "PR already open: $existing_pr"
  echo "$existing_pr"
  exit 0
fi

# 2. Existing local branch? Either a prior run that didn't push, or
#    leftover state. Delete + recreate so we always get a clean bump.
if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  log "deleting stale local branch $BRANCH"
  git branch -D "$BRANCH" >/dev/null 2>&1 || true
fi

# 3. Stash dirty working tree so we don't pull the operator's in-flight
#    work into the bump PR.
STASHED=0
if ! git diff --quiet || ! git diff --cached --quiet; then
  log "stashing dirty working tree before bump"
  if [ "$DRY" = "0" ]; then
    git stash push -u -m "site_bump_pr-stash-$VERSION-$(date +%s)" >/dev/null
    STASHED=1
  else
    log "[DRY] would stash"
  fi
fi

# Restore-on-exit guarantee — even if sed errors, we don't leave
# the operator's work stranded.
restore_stash() {
  if [ "$STASHED" = "1" ]; then
    log "popping stash"
    git stash pop --quiet 2>/dev/null || log "WARN stash pop conflict — manual recovery: git stash list"
  fi
}
trap restore_stash EXIT

# 4. Sync main and branch off it.
log "syncing main"
if [ "$DRY" = "0" ]; then
  git checkout main >/dev/null 2>&1
  git pull --ff-only origin main >/dev/null 2>&1 || { log "ERROR: pull --ff-only failed"; exit 1; }
fi

# 5. Find the current banner version (whatever the site currently shows).
CURRENT=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' rail.html 2>/dev/null \
  | head -1)
if [ -z "$CURRENT" ]; then
  log "ERROR: could not detect current version in rail.html"
  exit 1
fi
if [ "$CURRENT" = "$VERSION" ]; then
  log "site already at $VERSION — nothing to bump"
  exit 0
fi

# 5b. Find the current test-count banner ("N/N"). The new count comes
# from RAIL_TEST_COUNT if set (see header for how to parse it from a
# fresh `./rail_native test` run), else the page's count is kept.
TESTS_CURRENT=$(grep -oE "RAIL $CURRENT &middot; [0-9]+/[0-9]+" rail.html 2>/dev/null \
  | grep -oE '[0-9]+/[0-9]+' | head -1)
if [ -z "$TESTS_CURRENT" ]; then
  log "ERROR: could not detect test-count banner ('RAIL $CURRENT &middot; N/N') in rail.html"
  exit 1
fi
TESTS_NEW=${RAIL_TEST_COUNT:-$TESTS_CURRENT}
if ! [[ "$TESTS_NEW" =~ ^[0-9]+/[0-9]+$ ]]; then
  log "ERROR: RAIL_TEST_COUNT '$TESTS_NEW' must look like N/N"
  exit 2
fi
TESTS_N_CURRENT=${TESTS_CURRENT%%/*}
TESTS_N_NEW=${TESTS_NEW%%/*}

log "bump $CURRENT -> $VERSION (tests $TESTS_CURRENT -> $TESTS_NEW) across ${#PAGES[@]} pages"

# 6. Create branch.
[ "$DRY" = "0" ] && git checkout -b "$BRANCH" >/dev/null 2>&1

# 7. Sed each page. Each pattern is the SPECIFIC banner location, not
#    a blind global replace — we don't want to retroactively edit
#    historical changelog cards.
#
# In DRY mode we sed onto copies in a tmpdir so the live tree stays
# untouched. In non-DRY mode we sed in-place on the branched tree.
SED_DIR="$SITE"
if [ "$DRY" = "1" ]; then
  SED_DIR=$(mktemp -d -t site-bump-dry-XXXXXX)
  for page in "${PAGES[@]}"; do
    [ -f "$page" ] && cp "$page" "$SED_DIR/$page"
  done
fi

sed_in_place() {
  # macOS-safe in-place: sed -i '' (empty extension).
  # Replacement is escaped: `&` in the replacement is sed's whole-match
  # backref, and our patterns include literal `&mdash;` / `&middot;`
  # HTML entities — without escaping, they get expanded to the matched
  # string and the page is silently corrupted.
  local file="$1" pattern="$2" replacement="$3"
  local esc_repl="${replacement//&/\\&}"
  sed -i '' "s|$pattern|$esc_repl|g" "$SED_DIR/$file"
}

bumped=0
for page in "${PAGES[@]}"; do
  [ -f "$SED_DIR/$page" ] || continue
  before=$(grep -c "$CURRENT" "$SED_DIR/$page" 2>/dev/null || echo 0)
  [ "$before" = "0" ] && continue

  case "$page" in
    rail.html)
      # Hero eyebrow + visor + footer
      sed_in_place "$page" "Language &mdash; $CURRENT" "Language &mdash; $VERSION"
      sed_in_place "$page" "<span class=\"visor-value\">$CURRENT" "<span class=\"visor-value\">$VERSION"
      sed_in_place "$page" "RAIL $CURRENT &middot; $TESTS_CURRENT" "RAIL $VERSION &middot; $TESTS_NEW"
      ;;
    index.html)
      # Hero subtitle + stat tile + footer
      sed_in_place "$page" "Rail $CURRENT &middot; $TESTS_N_CURRENT tests green" "Rail $VERSION &middot; $TESTS_N_NEW tests green"
      sed_in_place "$page" "<div class=\"value\">$CURRENT</div>" "<div class=\"value\">$VERSION</div>"
      sed_in_place "$page" "RAIL $CURRENT &middot; $TESTS_CURRENT" "RAIL $VERSION &middot; $TESTS_NEW"
      ;;
    *)
      # All other pages: just the footer banner
      sed_in_place "$page" "RAIL $CURRENT &middot; $TESTS_CURRENT" "RAIL $VERSION &middot; $TESTS_NEW"
      ;;
  esac

  after=$(grep -c "$VERSION" "$SED_DIR/$page" 2>/dev/null || echo 0)
  if [ "$after" -gt 0 ]; then
    bumped=$((bumped + 1))
    log "  bumped $page"
  else
    log "  WARN $page: pattern didn't match (page structure may have changed)"
  fi
done

if [ "$bumped" = "0" ]; then
  log "ERROR: no pages were bumped — pattern mismatch"
  [ "$DRY" = "1" ] && rm -rf "$SED_DIR"
  exit 1
fi

# 8. Commit.
if [ "$DRY" = "1" ]; then
  log "[DRY] would commit, push, open PR for $bumped pages"
  log "[DRY] diff (changes that would land — first 8 lines per page):"
  for page in "${PAGES[@]}"; do
    if [ -f "$SED_DIR/$page" ] && ! diff -q "$page" "$SED_DIR/$page" >/dev/null 2>&1; then
      log "  --- $page"
      diff -u "$page" "$SED_DIR/$page" | tail -n +3 | head -8 | sed 's/^/    /'
    fi
  done
  rm -rf "$SED_DIR"
  exit 0
fi

# Stage ONLY the pages we edited — never `git add .` or `git add -A`
# (secrets, binaries, and the operator's untracked pages must not ride in).
# Filter PAGES to only files that actually exist on disk. With multi-file
# pathspecs, `git add` is all-or-nothing: a single missing file aborts the
# stage with a "fatal: pathspec ... did not match" and stages NOTHING.
# That used to silently produce an empty commit, which produced an empty
# branch on origin, which made `gh pr create` fail with "no commits
# between main and bump branch" — see drift_audit log on 2026-05-10.
EXISTING_PAGES=()
for p in "${PAGES[@]}"; do
  [ -f "$p" ] && EXISTING_PAGES+=("$p")
done
if [ ${#EXISTING_PAGES[@]} -eq 0 ]; then
  log "ERROR: no PAGES files exist on disk — bump aborted"
  exit 1
fi
git add "${EXISTING_PAGES[@]}"


if ! git commit -m "$(cat <<EOF
site: bump version banner $CURRENT → $VERSION

Auto-generated by tools/attest/site_bump_pr.sh from drift_audit.sh.
$bumped of ${#PAGES[@]} pages updated.

This PR only touches the *current-version* banners (hero eyebrow,
visor, footer, stat tile, now-pipe ship pill). The changelog cards
on changelog.html and rail.html are untouched — those are editorial,
keyed to specific historical commits.

To finish: review and add the $VERSION changelog entry to:
  - changelog.html  (release card at the top)
  - rail.html       (Recent releases grid, drop the oldest)

Source: https://github.com/zemo-g/rail/blob/master/CHANGELOG.md

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"; then
  : # commit landed cleanly
else
  log "ERROR: git commit failed (likely empty index after PAGES filter — check PAGES vs filesystem)"
  exit 1
fi

log "pushing $BRANCH"
git push -u origin "$BRANCH" >/dev/null 2>&1 || { log "ERROR: push failed"; exit 1; }

# 9. Pull this version's CHANGELOG entry to seed the PR body.
changelog_entry=""
if [ -f "$RAIL_REPO/CHANGELOG.md" ]; then
  changelog_entry=$(awk -v ver="## $VERSION" '
    $0 ~ ver { in_block=1; print; next }
    in_block && /^## v/ { exit }
    in_block { print }
  ' "$RAIL_REPO/CHANGELOG.md" | head -40)
fi

# 10. Open PR.
pr_url=$(gh pr create --base main --head "$BRANCH" \
  --title "site: bump version banner to $VERSION" \
  --body "$(cat <<EOF
## What

Auto-generated by \`drift_audit.sh\` — drift detected between the latest \`zemo-g/rail\` tag (\`$VERSION\`) and the live version banner on ledatic.org (\`$CURRENT\`).

$bumped of ${#PAGES[@]} pages updated.

## What this PR does NOT do

- It does not add a new changelog card to \`changelog.html\` or \`rail.html\` — those are editorial. Use the seeded entry below to author them.
- It does not touch \`_shared/site.css\`, \`_shared/site.js\`, or any worker config.

## Tasks before merge

- [ ] Review the diff (should only be 5–8 single-line replacements per page).
- [ ] Add the \`$VERSION\` release card to \`changelog.html\` and \`rail.html\` from CHANGELOG.md.
- [ ] Deploy: \`CF_TOKEN=\$(cat "\$CF_TOKEN_FILE") ./deploy.sh\` (CF_TOKEN_FILE = path to your Cloudflare API token file)

## Seeded from CHANGELOG.md

\`\`\`
$changelog_entry
\`\`\`
EOF
)" 2>&1 | tail -1)

# Pop stash via trap.
trap - EXIT
restore_stash

log "PR opened: $pr_url"
echo "$pr_url"
exit 0
