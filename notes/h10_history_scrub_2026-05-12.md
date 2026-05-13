# H10a/H10b Public-History Scrub Runbook — 2026-05-12

Deferred-security item #6 from the 2026-05-12 audit. This is the recipe.
**Nothing in this document has been executed.**

## 1. What is on github

Two literals appear in pushed history. Both credentials were rotated weeks
ago; remaining risk is reputational (a passer-by greps the public repo and
finds a string-shaped-like-a-token).

| Tag  | What                       | SHA-1 fingerprint of literal               | Length |
|------|----------------------------|--------------------------------------------|--------|
| H10a | API_BEARER (Cloudflare)    | `8ac47e9943f6ff55250981a377b7b9e900c1636a` | 43 ch  |
| H10b | Telegram bot token         | `fa323a4d0437e810a4282aef08369fde1a00ab1c` | 46 ch  |

(SHA-1 is fingerprint-only; the runbook below references the literals via
the `replacements.txt` file, which lives outside git.)

### H10a — `Ledatic-Empire/ledatic-site`

| Commit  | Date       | Action                                                                    |
|---------|------------|---------------------------------------------------------------------------|
| `1334b6f` | 2026-04-?? | Initial site import — literal lands in `worker/worker.js` as in-source const |
| `b1be97b` | 2026-04-27 | Rotated to env binding (literal removed in this commit's `+` side, present in `-`) |
| `d000658` | 2026-04-28 | Site refresh; literal still in `-` side as part of context diff           |

File touched: `worker/worker.js` only (3 commits, 1 path).

### H10a — `zemo-g/rail` (also tainted)

The literal also lives in **rail's** history because the worker was hosted
in the rail repo before the 2026-04-20 extract.

| Commit  | Date       | Action                                                                  |
|---------|------------|-------------------------------------------------------------------------|
| `44e123a` | 2026-04-19 | Initial check-in of `tools/deploy/worker.js` carries the literal        |
| `7cebc94` | 2026-04-19 | (duplicate of above on a second branch — same blob)                     |
| `7dce94e` | 2026-04-20 | `extract:` deletes the file (literal in `-` diff)                       |
| `711e105` | 2026-04-20 | (duplicate of extract on another branch — same blob)                    |

File touched: `tools/deploy/worker.js` only (4 commits, 1 path; deleted before extraction).

### H10b — `zemo-g/rail`

| Commit  | Date       | Action                                                                                        |
|---------|------------|-----------------------------------------------------------------------------------------------|
| `6ab1945` | (older)    | Telegram token introduced into `tools/train/notify.sh` as `TOKEN="..."`                       |
| `5171621` | 2026-05-?? | "purge non-Rail" — moved to `tools/train/notify.rail` as `token = "..."` (still hard-coded)   |
| `19ebad8` | 2026-05-?? | Rotated: `token = trim (shell "echo $RAIL_TELEGRAM_TOKEN")` — literal removed                 |

Files touched: `tools/train/notify.sh`, `tools/train/notify.rail` (3 commits, 2 paths).

### Sanity check — HEAD trees

```
$ grep -r 'YW4poVpINEaOEsPctzf8FRPTmycXHbH7lFyjRVRqsnc' rail/ ledatic-site/ \
    | grep -v '\.git/'
rail/docs/audits/findings_2026-05-09/05_data_exposure.md  (4 hits)

$ grep -r '8393851683:AAH7X_AyUQoNiCMWvfNQI-W9vDqdxUN8amo' rail/ ledatic-site/ \
    | grep -v '\.git/'
(none)
```

The 4 hits in the audit doc are **gitignored** (`.gitignore:112` excludes
`docs/audits/`), so this is local-only and never reached github. **Both
literals are absent from every tracked file in HEAD on both repos** — the
audit's "rotated" claim holds.

## 2. Tool choice

| Tool                | Installed?      | Best fit?                                                          |
|---------------------|-----------------|--------------------------------------------------------------------|
| `git-filter-repo`   | yes (`/opt/homebrew/bin/git-filter-repo`) | YES — designed for `--replace-text`, ships with the right ergonomics |
| `bfg`               | no              | Would have been simpler ("scrub these literals") but not installed |
| `git filter-branch` | yes (built-in)  | NO — deprecated; filter-repo is the modern path                    |

**Pick: `git filter-repo --replace-text`.** Same blob-level scrub semantics
as BFG; one tool to learn; already on the box.

## 3. The scrub

### 3a. `replacements.txt`

Same file works for both repos. **Write this OUTSIDE either repo** (e.g.
`~/scrub/replacements.txt`); never commit it.

```
YW4poVpINEaOEsPctzf8FRPTmycXHbH7lFyjRVRqsnc==>***REMOVED-API-BEARER***
8393851683:AAH7X_AyUQoNiCMWvfNQI-W9vDqdxUN8amo==>***REMOVED-TG-TOKEN***
```

(`==>` is filter-repo's literal-substring → replacement separator.
Anything before the marker matches verbatim; anything after replaces it.)

### 3b. Mirror clone → scrub → force-push

Repeat for each repo. **Mirror clone is non-negotiable** — a working
clone scrubs only the checked-out branch's history.

```
# 1. Mirror clone (gets every ref: branches, tags, notes)
cd ~/scrub/
git clone --mirror git@github.com:zemo-g/rail.git rail.git
cd rail.git

# 2. Scrub. filter-repo refuses to run on a non-mirror clone unless you
# pass --force; this IS the mirror clone, so just go.
git filter-repo --replace-text ~/scrub/replacements.txt

# 3. Verify the literals are gone from every reachable commit.
git log --all -p -S 'YW4poVpINEaOEsPctzf8FRPTmycXHbH7lFyjRVRqsnc' | wc -l   # expect 0
git log --all -p -S '8393851683:AAH7X_AyUQoNiCMWvfNQI-W9vDqdxUN8amo' | wc -l # expect 0
git log --all -p -S '***REMOVED-API-BEARER***' | head -20                   # expect hits

# 4. filter-repo deletes the `origin` remote on purpose. Re-add it.
git remote add origin git@github.com:zemo-g/rail.git

# 5. Force-push every ref. THIS IS THE DESTRUCTIVE STEP.
git push --force --mirror origin
```

Then for ledatic-site, same recipe with
`git@github.com:Ledatic-Empire/ledatic-site.git` and the `--mirror` flag
keeping its `main` + `feat/security-*` branches in sync.

### 3c. Verify on github after force-push

```
gh api '/repos/zemo-g/rail/git/blobs?recursive=1' >/dev/null  # not a real endpoint, just illustration
gh search code 'YW4poVpINEaOEsPctzf8FRPTmycXHbH7lFyjRVRqsnc' --owner zemo-g
gh search code '8393851683' --owner zemo-g
gh search code 'YW4poVpINEaOEsPctzf8FRPTmycXHbH7lFyjRVRqsnc' --owner Ledatic-Empire
```

GitHub's code-search index lags the push by minutes-to-hours; expect a
delay before the searches go quiet. The git-objects are gone immediately;
the index just hasn't caught up.

### 3d. After the force-push — local clones

Every existing checkout of either repo (Studio working tree, Mini bare
relay `~/git/{rail,ledatic-site}.git`, Razer, Pi) will have stale
history. Either:

- `git fetch origin && git reset --hard origin/<branch>` on each
  (loses any uncommitted local work), or
- `git clone` fresh into a new dir.

**Mini bare relay specifically**: the post-receive hook (see
`branch_protection_prep_2026-05-12.md`) re-pushes Studio's pushes to
github. After the scrub, Mini's bare relay is itself stale — its
`refs/heads/next` still points at the old (tainted) commit. The next
`git push origin next` from Studio will fast-forward into the bare relay,
the post-receive hook will then `git push --quiet origin next` to github,
and **github will reject because the local Mini history is no longer an
ancestor of the scrubbed github history**. Fix: `git fetch --all && git
reset --hard origin/next` inside the bare relay before the first
post-scrub Studio push, or just `--force` the relay's push once.

## 4. Coordinate with branch protection (item #1 of the deferred list)

`notes/branch_protection_prep_2026-05-12.md` and
`notes/security_deferred_runbook_2026-05-12.md:84` already flag this.
The interaction:

- The protection PUT bodies set `allow_force_pushes: false` +
  `enforce_admins: true`. With those on, the `git push --force --mirror`
  in step 3b will be rejected.
- **Sequence: scrub FIRST, then protection.** If protection has already
  landed, you must:
  1. `gh api -X DELETE /repos/zemo-g/rail/branches/next/protection`
  2. (and the equivalent for ledatic-site/main)
  3. Run the scrub.
  4. Re-PUT the protection from `branch_protection_prep_2026-05-12.md` §(d).

There is no clean way to keep protection on through the scrub.
filter-repo rewrites every commit hash; force-push isn't an avoidable
implementation detail.

## 5. Blast radius

| Repo                          | Total commits (all refs) | Commits since earliest tainted | Rewrites all of them | Open PRs / forks                   |
|-------------------------------|--------------------------|--------------------------------|----------------------|------------------------------------|
| `zemo-g/rail`                 | 1403                     | 633 (since `44e123a` 2026-04-19) | yes (mirror)         | unknown — `gh` is unauth'd; **needs user verification post-OAuth** via `gh pr list -R zemo-g/rail` and `gh api /repos/zemo-g/rail/forks` |
| `Ledatic-Empire/ledatic-site` | 34                       | 30 (since `1334b6f` initial)   | yes (mirror)         | unknown — same — `gh pr list -R Ledatic-Empire/ledatic-site`, `gh api /repos/Ledatic-Empire/ledatic-site/forks` |

What gets invalidated:

- **Every open PR**: the head SHAs no longer exist on the base. PRs go
  into a confused state — github sometimes auto-closes them, sometimes
  shows "compare across forks" errors. Rebase or re-open after the scrub.
- **Every fork**: forks still hold the old object graph. Anyone with a
  fork has the literal in their fork's history. github's
  `?after=<sha>` URLs into deleted commits will 404.
- **Every clone, anywhere**: needs `git fetch + git reset --hard` (or
  re-clone). Mini bare relay specifically (see §3d).
- **Tags**: filter-repo rewrites tag targets; tag *names* survive but
  point at new SHAs. Anything pinned by SHA breaks.
- **Issue/commit links** in github comments, ledatic.org docs, this
  repo's own CHANGELOG.md / memory entries — anything quoting an old
  SHA — becomes a 404. Worst case, audit memory entries.

Open-PR/fork count for both repos is not knowable from this Studio
session because `gh auth status` reports "not logged in." User must run
`gh auth login` (already documented in
`branch_protection_prep_2026-05-12.md` §b) and then the four `gh`
commands above before the scrub, so post-scrub damage is bounded.

## 6. Cost summary

| Item                      | Estimate                                                    |
|---------------------------|-------------------------------------------------------------|
| Wall time (both repos)    | ~10 min: 3 min mirror-clone + 1 min filter-repo + 1 min push, ×2 |
| Mirror count to update    | rail: Studio + Mini bare-relay + (any) Razer/Pi clones; ledatic-site: Studio + Mini bare-relay |
| Forks affected            | unknown until OAuth — 0 if it's solo, otherwise N×whatever  |
| Open PRs invalidated      | unknown until OAuth                                         |
| Branch protection downtime | 0 if scrub before protection lands; ~2 min if scrub after (DELETE → scrub → PUT) |
| Reversibility             | none — the original SHAs are recoverable only from a clone someone forgot to delete; for security purposes, that's the *opposite* of what you want |

## 7. Honest verdict — is this worth doing?

**Skip it.** Here is the case:

1. **Both credentials are already rotated.** A bad actor reading the
   literal off public history today learns a string that authenticates to
   nothing.
2. **The Telegram token is two layers behind**: notify.sh literal →
   notify.rail literal → env-var. The literal in history is at minimum two
   rotations stale. Same for API_BEARER (in-source const → env binding).
3. **Reputation cost of "we leaked tokens once" is already paid.** The
   audit doc itself is public-facing in spirit (lives in a repo that
   anyone can clone the predecessor of). Scrubbing now does not
   un-publish what's already been crawled by whoever cares
   (search engines, archive.org, GHTorrent, BigQuery's github_repos
   dataset — all of which retained snapshots).
4. **Force-push has real cost**: every fork, clone, PR, and SHA-link
   breaks. Mini bare-relay needs surgery. Coordination with branch
   protection (item #1) adds sequencing fragility.
5. **The audit memo's own framing**: "Credentials already rotated;
   remaining risk is reputational." Reputational risk from a leaked
   *and rotated* token in a young public repo with a small audience is
   approximately zero. The audit ranked this as a deferred item for a
   reason.

**When to revisit**: if/when (a) the repo gains a public profile that
makes "tokens in history" a credibility issue (e.g., a security-product
launch, a press cycle), or (b) external auditors require a clean blame.
Today, neither holds.

**Hold this runbook in `notes/`** so it's a 10-minute exercise the day
the verdict flips. Don't execute today.

## 8. What this session pre-staged

- Confirmed both literals **absent from HEAD** on both repos (sanity
  check — audit's rotation claim holds).
- Confirmed audit doc that reproduces the API_BEARER literal lives at
  `docs/audits/findings_2026-05-09/05_data_exposure.md` and is
  **gitignored** (`.gitignore:112`), so it has never been pushed.
- Confirmed `git-filter-repo` is installed; BFG is not.
- Did not run any git command that mutates history.
- Did not push, force or otherwise, to either repo.
- Did not touch the `origin/history-scrub-prep-2026-05-12` branch (it
  exists on origin — content-wise it's just security-c-fleet-v0 work,
  not actually a scrub branch — name appears reserved for this work).
