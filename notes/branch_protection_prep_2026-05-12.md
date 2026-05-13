# Branch Protection Prep — 2026-05-12

Prep for runbook §3 (`security_deferred_runbook_2026-05-12.md`). Everything below
is **paste-ready** — Claude could not run `gh auth login` (browser OAuth) on
your behalf, but every other prerequisite is staged.

## (a) Audit verdict — Mini bare-relay hooks DIRECT-PUSH to protected refs

Read on 2026-05-12 from `ssh <user>@<host>`:

- `~/git/rail.git/hooks/post-receive` → for every ref (incl. `next`),
  runs `git push --quiet origin "$refname"`. `origin` =
  `git@github.com:zemo-g/rail.git`.
- `~/git/ledatic-site.git/hooks/post-receive` → for every ref (incl. `main`),
  runs `git push --quiet origin "$refname"`. `origin` =
  `git@github.com:Ledatic-Empire/ledatic-site.git`.

Both are **direct-push to the to-be-protected branch**. The runbook §3b/c
configs set `enforce_admins: true` + `required_pull_request_reviews` +
`allow_force_pushes: false`. With those on, GitHub will reject Mini's relay
push on every `next`/`main` update — silently turning your Studio→Mini→GitHub
push flow into "commits stop showing up on github.com and `[relay] next ->
github FAILED` accumulates in `relay.log`."

**Verdict: cannot enable protection cleanly today.** Hook surgery first.

## (b) `gh auth login` — your hands

```
gh auth login
```

Pick: `github.com` → `HTTPS` → `Y` to authenticate Git with credentials →
`Login with a web browser` → copy the one-time code → paste in browser →
authorize.

You need **both** scopes: `repo` (for `zemo-g/rail`) and `admin:org` /
`admin:repo_hook` to PUT branch protection on `Ledatic-Empire/ledatic-site`
(org-owned repo). Verify:

```
gh auth status
```

Should print your handle and a scope list including `repo` and `admin:org`. If
`admin:org` is missing, re-run `gh auth refresh -s admin:org`.

## (c) Hook surgery — proposed minimum change

Three options, ranked by minimum-disruption first.

### Option 1 (RECOMMENDED) — push to `mirror/<ref>` instead of `<ref>`

Lowest blast radius: GitHub becomes a true mirror at `mirror/next` and
`mirror/main`, while `next`/`main` on GitHub move only via PR (which you author
and self-approve from a second account, or via Studio with a PAT). The bare
relay's job becomes "snapshot every ref, no merge semantics."

Patch for `~/git/rail.git/hooks/post-receive` — replace the inner push line:

```
    if git push --quiet origin "$refname" 2>>"$LOG"; then
```

with:

```
    # Branch-protection-safe: push to mirror/<ref> on GitHub, never the
    # protected ref directly. Real merges land via gh pr create.
    case "$refname" in
      refs/heads/*)
        BRANCH=${refname#refs/heads/}
        TARGET="refs/heads/mirror/${BRANCH}"
        ;;
      *)
        TARGET="$refname"  # tags, etc. — push as-is
        ;;
    esac
    if git push --quiet --force origin "${newrev}:${TARGET}" 2>>"$LOG"; then
```

(Same change for `ledatic-site.git`'s hook — the body is byte-identical except
the LOG path and missing `auto_deploy_docs.sh` block.)

The DELETE branch needs the same `case` (delete `mirror/<ref>` on GitHub when
the local ref is deleted). Sketch:

```
      if git push --quiet origin --delete "${TARGET}" 2>>"$LOG"; then
```

**Risk acknowledged**: anyone who had `git pull origin next` on GitHub now
needs `git pull origin mirror/next` (or just keep pulling from Mini). For a
solo-dev workflow this is invisible. For the docs auto-deploy hook
(`auto_deploy_docs.sh`), the hook keys on the local ref name, not the GitHub
ref name, so it keeps working.

### Option 2 — keep direct push, exempt the deploy account via `restrictions`

If you don't want a `mirror/` namespace, GitHub's protection API supports a
`restrictions` block listing user/team/app names allowed to bypass the PR
requirement. The runbook's payload sets `restrictions: null`. You can change
that to:

```json
"restrictions": { "users": ["zemo-g"], "teams": [], "apps": [] }
```

(Or whatever username the SSH key on Mini authenticates as.) `enforce_admins:
true` still blocks force-pushes for everyone including the bypass list, so
`allow_force_pushes` would need to stay `false` and your Mini hook stays
fast-forward only — which it already is for normal pushes.

**Risk**: you've hollowed out the protection. Anyone with that account's PAT
can push directly. The audit's intent (no direct push to default branch) is
half-defeated. Use only if Option 1 is unworkable.

### Option 3 — replace push with `gh pr create` in the hook

Hook does `git push origin "refs/heads/auto/${BRANCH}-$(date +%s)"` and then
`gh pr create --base "$BRANCH" --head "auto/${BRANCH}-..." --fill`. PRs queue
up; you self-approve in batches. Heaviest workflow change; rejected unless you
specifically want PR-per-push.

### My pick

**Option 1.** Smallest hook diff, no auth changes on Mini, branch protection
keeps its full teeth. Cost is a one-line mental remap ("github.com/zemo-g/rail
truth lives on `mirror/next`, not `next`, until I PR it across").

## (d) The two PUT commands — paste-ready

Copy verbatim from runbook §3b/§3c:

### `zemo-g/rail`, default branch `next`:

```
gh api -X PUT /repos/zemo-g/rail/branches/next/protection \
  -H "Accept: application/vnd.github+json" \
  --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false,
  "required_conversation_resolution": true
}
JSON
```

### `Ledatic-Empire/ledatic-site`, default branch `main`:

```
gh api -X PUT /repos/Ledatic-Empire/ledatic-site/branches/main/protection \
  -H "Accept: application/vnd.github+json" \
  --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false,
  "required_conversation_resolution": true
}
JSON
```

## (e) Three-line verification

```
gh api /repos/zemo-g/rail/branches/next/protection            | jq '.enforce_admins.enabled, .required_pull_request_reviews.dismiss_stale_reviews, .allow_force_pushes.enabled'
gh api /repos/Ledatic-Empire/ledatic-site/branches/main/protection | jq '.enforce_admins.enabled, .required_pull_request_reviews.dismiss_stale_reviews, .allow_force_pushes.enabled'
```

Each call must print exactly:

```
true
true
false
```

If you see anything else, the PUT didn't take — re-check `gh auth status`
scopes and re-run the PUT.

## Recommended sequence (your hands)

1. **Decide Option 1 vs 2 vs 3** above. (My recommendation: 1.)
2. **Edit Mini hooks** per the chosen option:
   - `ssh <user>@<host>`
   - Back up: `cp ~/git/rail.git/hooks/post-receive{,.pre-protection}`
   - Same for `ledatic-site.git`.
   - Apply the patch.
   - Smoke-test: from Studio, `git push origin next` (small no-op commit) and
     check Mini's `~/git/rail.git/relay.log` says
     `[relay] refs/heads/next -> github OK` AND that the GitHub web UI shows
     the new commit on `mirror/next` (Option 1) or `next` (Option 2).
3. **`gh auth login`** (step b above), confirm scopes.
4. **Pre-protection**: if Swarm Agent 4's H10 force-push is still pending, do
   it NOW before turning protection on. (Runbook §3b sequencing note.)
5. **Run the two PUT commands** (step d).
6. **Run the three-line verification** (step e).
7. **Functional smoke**: from Studio, `git push origin next` again. Should
   succeed (mirror branch under Option 1, exempted account under Option 2). If
   it fails, your hook patch and protection disagree — back out protection
   with `gh api -X DELETE /repos/zemo-g/rail/branches/next/protection` and
   debug.

## What Claude pre-staged (this session)

- Confirmed both hooks direct-push (audit verdict above).
- Confirmed `origin` URLs on both bare relays (`zemo-g/rail`,
  `Ledatic-Empire/ledatic-site`).
- Did NOT modify any hook on Mini.
- Did NOT run `gh auth login` or any `gh api -X PUT`.
