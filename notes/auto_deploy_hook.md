# Rail docs auto-deploy hook

Shipped 2026-05-12 on branch `feat/f-docs-auto-deploy`.

**What it does:** when a push to the rail bare repo lands on an allowlisted
branch (default `next`) AND changes files under `docs/site/`, the bare repo's
post-receive hook builds the docs HTML from the pushed tree and deploys
`rail/docs/*.html` + `rail/docs/examples/*.html` to Cloudflare KV. The site at
https://ledatic.org/rail/docs/ then reflects the change without a manual step.

## Topology

```
Studio  git push origin next
        |
        v (ssh)
Mini    ~/git/rail.git  (bare)
        hooks/post-receive
        |  1. mirror each ref to GitHub  (pre-existing)
        |  2. for each ref, invoke hooks/auto_deploy_docs.sh
        |       a. gate: ref must be allowlisted
        |       b. gate: docs/site/ must have changed
        |       c. git archive NEWREV docs | tar -x -C $TMP
        |       d. SRC=$TMP/docs/site OUT=~/projects/ledatic-site/rail/docs \
        |            ~/projects/ledatic-site/tools/build_rail_docs.sh
        |       e. cd ~/projects/ledatic-site && CF_TOKEN=$(cat ~/Desktop/rings) \
        |            DEPLOY_SKIP_PHYSICS_GATE=1 \
        |            ./deploy.sh rail/docs/<file>.html  (per file)
        |       f. smoke: curl /rail/docs/  ->  ~/log/rail-docs-deploy.log
        v
Cloudflare KV  ->  Worker  ->  https://ledatic.org/rail/docs/
```

## Files installed on Mini (NOT in the rail repo — bare-repo-side)

| Path                                                       | Purpose                                                  |
|------------------------------------------------------------|----------------------------------------------------------|
| `~/git/rail.git/hooks/post-receive`                        | Extended hook: mirror-to-GitHub + auto-deploy invocation |
| `~/git/rail.git/hooks/post-receive.bak.<ts>`               | Original mirror-only hook (rollback target)              |
| `~/git/rail.git/hooks/auto_deploy_docs.sh`                 | The deploy worker, called per ref                        |
| `~/git/rail.git/docs-deploy-branches`                      | Optional allowlist (one branch per line, `#` comments)   |
| `~/projects/ledatic-site/tools/build_rail_docs.sh`         | md->html builder, parameterized via SRC/OUT env vars     |
| `~/log/rail-docs-deploy.log`                               | Append-only deploy log (UTC timestamps)                  |

The Studio-side builder at `/Users/user/projects/ledatic-site/tools/build_rail_docs.sh`
is unchanged. Mini's copy is functionally identical but reads `SRC` / `OUT` from
env so the same script serves both manual (Studio) and auto (Mini) flows.

## Allowlist

Default: only `refs/heads/next` triggers the deploy. To add more branches
(or restrict the smoke window), append one short branch name per line to
`~/git/rail.git/docs-deploy-branches` on Mini. Leading `#` comments allowed.
Empty file is harmless. The file is checked on every push.

## Disable / rollback

- **Soft disable**: `chmod -x ~/git/rail.git/hooks/auto_deploy_docs.sh` on Mini.
  The post-receive hook tests `-x` before invoking, so the mirror keeps working
  and no deploy fires.
- **Full rollback**: restore the saved pre-existing hook:
  ```
  ssh ledaticempire@mini.tb 'cp ~/git/rail.git/hooks/post-receive.bak.* \
    ~/git/rail.git/hooks/post-receive'
  ```
- **Restrict allowlist**: edit / truncate `~/git/rail.git/docs-deploy-branches`.

## Failure modes (all log to `~/log/rail-docs-deploy.log` and exit 0)

The hook never breaks `git push`. Every failure path is logged and swallowed:

- Token file unreadable -> `FAIL: CF_TOKEN file unreadable`
- `git archive` fails -> `FAIL: git archive`
- Builder missing / nonzero -> `FAIL: build_rail_docs.sh exited nonzero`
- Individual `deploy.sh` calls -> counted under `N ok / N fail`
- Smoke curl -> recorded with HTTP code (no gating on result)

## Known scope limits / deferred

- **Stdlib regeneration is NOT automated.** `docs/site/stdlib.md` is generated
  on Studio via `./rail_native run tools/docs/gen_stdlib_ref.rail` (per
  `docs_deploy_rail` memory). Running rail_native inside a git hook on Mini
  is out of scope. Workflow: regenerate stdlib.md on Studio, commit it, push
  to `next` -> auto-deploy picks it up.
- **Worker source / KV namespace IDs not touched.** Per task constraint, the
  Worker's trailing-slash patch (already live) is what makes `/rail/docs/`
  resolve. No edge config changed.
- **Physics gate skipped for auto-deploys.** `deploy.sh` normally refuses to
  upload if the entropy beacon is stale; the hook sets
  `DEPLOY_SKIP_PHYSICS_GATE=1` because it runs unattended. Manual deploys
  still respect the gate.
- **No cache purge.** The Mini CF_TOKEN lacks `Zone:Cache:Purge` scope (per
  `plasma_viewer_deploy` memory). HTML pages have a short edge TTL so changes
  show up within minutes; no cache-bust query string is added.
- **No build for `tools/docs/gen_stdlib_ref.rail`-style triggers.** Auto-deploy
  only fires on changes to `docs/site/`; pushing only stdlib source edits will
  NOT regenerate stdlib.md (intentional — see above).

## Smoke / verification recipe

After landing this feature on `next`, run a trivial doc edit + push and check:

```bash
ssh ledaticempire@mini.tb 'tail -30 ~/log/rail-docs-deploy.log'
curl -s -o /dev/null -w "%{http_code}\n" https://ledatic.org/rail/docs/
```

A successful run shows `=== docs-deploy complete: N ok / 0 fail ===` and HTTP 200.
