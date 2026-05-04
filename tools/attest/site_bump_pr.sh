#!/usr/bin/env bash
# site_bump_pr.sh — open a PR against Ledatic-Empire/ledatic-site that
# bumps the public version banner across 8 HTML pages from the current
# live value to a target version.
#
# What it touches:
#   - Hero eyebrow:       "Language — vX.Y.Z"
#   - Visor mini:         "vX.Y.Z // 137/137"
#   - Footer:             "RAIL vX.Y.Z · 137/137"
#   - index.html stat:    "Current Rail" tile
#   - "now.html" pill:    "<pill shipped>vX.Y.Z</pill>"
#   - Hero subtitle on index.html: "Rail vX.Y.Z · 137 tests green"
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
# Stash-isolates: Reilly's dirty CSS/JS in the working tree are
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

SITE=${SITE:-/Users/ledaticempire/projects/ledatic-site}
RAIL_REPO=${RAIL_REPO:-/Users/ledaticempire/projects/rail-https}
PAGES=(index.html rail.html entropy.html fleet.html manifesto.html plasma.html now.html changelog.html)
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

# 3. Stash dirty working tree so we don't pull Reilly's in-flight work
#    into the bump PR. (feedback_stash_isolate_hunks)
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
# Reilly's work stranded.
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
CURRENT=$(grep -oE 'v3\.[0-9]+\.[0-9]+' rail.html 2>/dev/null \
  | head -1)
if [ -z "$CURRENT" ]; then
  log "ERROR: could not detect current version in rail.html"
  exit 1
fi
if [ "$CURRENT" = "$VERSION" ]; then
  log "site already at $VERSION — nothing to bump"
  exit 0
fi

log "bump $CURRENT -> $VERSION across ${#PAGES[@]} pages"

# 6. Create branch.
[ "$DRY" = "0" ] && git checkout -b "$BRANCH" >/dev/null 2>&1

# 7. Sed each page. Each pattern is the SPECIFIC banner location, not
#    a blind global replace — we don't want to retroactively edit
#    historical changelog cards.
sed_in_place() {
  # macOS-safe in-place: sed -i '' (empty extension)
  local file="$1" pattern="$2" replacement="$3"
  sed -i '' "s|$pattern|$replacement|g" "$file"
}

bumped=0
for page in "${PAGES[@]}"; do
  [ -f "$page" ] || continue
  before=$(grep -c "$CURRENT" "$page" 2>/dev/null || echo 0)
  [ "$before" = "0" ] && continue

  case "$page" in
    rail.html)
      # Hero eyebrow + visor + footer
      sed_in_place "$page" "Language &mdash; $CURRENT" "Language &mdash; $VERSION"
      sed_in_place "$page" "<span class=\"visor-value\">$CURRENT" "<span class=\"visor-value\">$VERSION"
      sed_in_place "$page" "RAIL $CURRENT &middot; 137/137" "RAIL $VERSION &middot; 137/137"
      ;;
    index.html)
      # Hero subtitle + stat tile + footer
      sed_in_place "$page" "Rail $CURRENT &middot; 137 tests green" "Rail $VERSION &middot; 137 tests green"
      sed_in_place "$page" "<div class=\"value\">$CURRENT</div>" "<div class=\"value\">$VERSION</div>"
      sed_in_place "$page" "RAIL $CURRENT &middot; 137/137" "RAIL $VERSION &middot; 137/137"
      ;;
    now.html)
      # Now-pipe ship-date pill (single most-recent line)
      sed_in_place "$page" "<span class=\"pill shipped\">$CURRENT</span>" "<span class=\"pill shipped\">$VERSION</span>"
      sed_in_place "$page" "RAIL $CURRENT &middot; 137/137" "RAIL $VERSION &middot; 137/137"
      ;;
    *)
      # All other pages: just the footer banner
      sed_in_place "$page" "RAIL $CURRENT &middot; 137/137" "RAIL $VERSION &middot; 137/137"
      ;;
  esac

  after=$(grep -c "$VERSION" "$page" 2>/dev/null || echo 0)
  if [ "$after" -gt 0 ]; then
    bumped=$((bumped + 1))
    log "  bumped $page"
  else
    log "  WARN $page: pattern didn't match (page structure may have changed)"
  fi
done

if [ "$bumped" = "0" ]; then
  log "ERROR: no pages were bumped — pattern mismatch"
  exit 1
fi

# 8. Commit.
if [ "$DRY" = "1" ]; then
  log "[DRY] would commit, push, open PR for $bumped pages"
  log "[DRY] git diff (stat) — bumped pages only:"
  git diff --stat "${PAGES[@]}" 2>&1 | sed 's/^/  /'
  exit 0
fi

# Stage ONLY the pages we edited — never `git add .` (memory: never use
# `git add -A` because of secrets/binaries/Reilly's-untracked-pages).
git add "${PAGES[@]}" >/dev/null 2>&1

git commit -m "$(cat <<EOF
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
)" >/dev/null

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
- [ ] Deploy: \`CF_TOKEN=\$(cat ~/Desktop/rings) ./deploy.sh\`

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
