#!/usr/bin/env bash
# Local mirror of the "Pattern scan" in .github/workflows/leak-guard.yml.
#
# Run this before pushing so the leak guard never fails you in CI. It reads the
# patterns AND the path excludes straight out of the guard yaml, so it can never
# drift from what CI actually enforces -- the yaml stays the single source of
# truth. It also mirrors the guard's self-integrity step.
#
#   exit 0 = clean (CI leak guard would pass)
#   exit 1 = would fail CI -- offending lines printed
#   exit 2 = setup error (not a repo / guard yaml unreadable)
#
# Enable as a pre-push hook, once per clone:
#   git config core.hooksPath .githooks
set -uo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "leak-check: not inside a git repo"; exit 2; }
cd "$root"
yml=.github/workflows/leak-guard.yml
[ -f "$yml" ] || { echo "leak-check: $yml missing -- do not remove the guard"; exit 1; }

rc=0

# --- self-integrity (mirror of the guard's first step) ---
grep -qE '^/docs/plans/' .gitignore 2>/dev/null \
  || { echo "leak-check: .gitignore lost its '/docs/plans/' keep-private entry"; rc=1; }
tracked_plans=$(git ls-files 'docs/plans/' 2>/dev/null || true)
[ -n "$tracked_plans" ] && { echo "leak-check: internal docs/plans/ files are tracked (must stay gitignored):"; echo "$tracked_plans"; rc=1; }

# --- pull the live patterns + path excludes out of the guard (no drift) ---
patterns=$(sed -nE "s/^[[:space:]]*patterns='(.*)'[[:space:]]*\$/\1/p" "$yml" | head -1)
[ -z "$patterns" ] && { echo "leak-check: could not read patterns from $yml (format changed?)"; exit 2; }
excludes=()
while IFS= read -r ex; do [ -n "$ex" ] && excludes+=("$ex"); done \
  < <(grep -oE "':\(exclude\)[^']*'" "$yml" | tr -d "'")

# --- the scan (identical to CI: -InE, same excludes, leak-guard-allow escape) ---
hits=$(git grep -InE "$patterns" -- "${excludes[@]}" 2>/dev/null | grep -v 'leak-guard-allow' || true)
if [ -n "$hits" ]; then
  echo "leak-check: BLOCKED -- these lines would fail the CI leak guard:"
  echo "$hits"
  echo
  echo "  Fix one of: scrub the value, move the file under a gitignored path,"
  echo "  or append the allow-marker to the line if it is genuinely intentional."
  rc=1
fi

[ "$rc" -eq 0 ] && echo "leak-check: clean"
exit "$rc"
