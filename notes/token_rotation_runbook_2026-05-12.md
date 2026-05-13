# Token Rotation Runbook (2026-05-12)

Companion to `security_deferred_runbook_2026-05-12.md` §5. Covers every secret currently load-bearing on Studio + Mini + Worker. **This is documentation; do not rotate during a run** — every section ends with a blast-radius callout.

## Recommended order

1. **Telegram bot token** — already rotated 2026-05-12; this section is reconfirmation only. Lowest risk, only affects training notifications.
2. **API_BEARER** — already rotated 2026-05-12; reconfirmation only. Affects ledatic.org `/admin/*` and `/api/update`.
3. **Anthropic API key** — quiet window. Breaks `self_train.rail` mid-flight.
4. **`~/.fleet/token`** — quiet window. Has its own atomic rotation script.
5. **CF_TOKEN** — quiet window. Breaks ledatic-site deploys until refreshed on Mini.
6. **GitHub PATs** — N/A on this fleet (see §6); document the absence and how to add one if needed.

**Universal pre-flight**: confirm host with `hostname` before each section. CF_TOKEN and API_BEARER live on **Mini**; `~/.fleet/token` lives on **every node**; the Anthropic key lives on **Studio** (and any other node that runs `self_train.rail`).

---

## 1. `~/.fleet/token`

**Where it lives**:
- `~/.fleet/token` on Studio, Mini, Air, Pi (mode 600, 64-hex bytes — current size 64, last touched Apr 17 23:32 on Studio).

**Who reads it**:
- `~/.fleet/fleet_agent_v3` (loaded by `~/Library/LaunchAgents/com.ledatic.fleet.plist`, label `com.ledatic.fleet`, currently PID 37830 on Studio). Reads via `load_token` at `tools/fleet/fleet_agent_v3.rail:101` — `cat ~/.fleet/token`. Compared per request against `X-Fleet-Token` header at `:110`.
- Legacy `tools/fleet/fleet_agent.rail:120` (`get_token`) — same pattern. Not loaded as an agent on Studio anymore but still present in tree.
- `tools/fleet/fleet_controller.rail:9` (`get_token`) — Mini-side controller used by ad-hoc dispatch.
- `tools/fleet/poll_nodes.rail:44` — fleet dashboard poller. Reads token, sends in `X-Fleet-Token` header to `/status` on each node.
- `tools/fleet/rotate_fleet_token.sh` reads (and rewrites) the token directly during rotation.

**Rotate procedure**: there is already a paste-ready rotator. **Run from Mini only** (it uses Mini as the orchestrator and ssh-pushes to Studio + Air + Pi, with a per-node `/health` probe and rollback).

```sh
# On Mini:
bash ~/projects/rail/tools/fleet/rotate_fleet_token.sh
# Confirm "y" at the prompt. Script:
#   1. openssl rand -hex 32  → new 64-hex token
#   2. cp ~/.fleet/token ~/.fleet/token.prerotate (per node)
#   3. write new value (per node)
#   4. curl -H "X-Fleet-Token: <new>" http://<node>:9101/health
#   5. on any failure, rollback all stamped nodes from .prerotate
```

The fleet agent re-reads `~/.fleet/token` on **every request** (no in-process cache — `load_token` is invoked from inside the request handler), so **no restart is needed**. The `KeepAlive=true` LaunchAgent stays running and immediately picks up the new value on the next inbound request.

**Verification** (one-line, run from Mini after rotation):

```sh
for h in 10.42.0.1 10.42.0.2 <peer-tailscale-ip> <witness-tailscale-ip>; do printf '%s ' "$h"; curl -sm 5 -H "X-Fleet-Token: $(cat ~/.fleet/token)" "http://$h:9101/health" || echo FAIL; done
```

Expect `{"status":"ok"...}` (or equivalent OK shape) from all four. The rotator already does this per node, but re-running it from a fresh shell confirms the new token survived disk + reader.

**Blast radius if rotated mid-flight**:
- Any in-flight `poll_nodes.rail` cycle that reads its token from `~/.fleet/token` **before** the rewrite and hits a node **after** the node's rewrite gets 401. `poll_nodes` retries on next interval, so single-cycle drop only.
- `fleet_dash_gen.rail` / dashboard pages stale for one polling interval.
- Any in-flight POST job from Mini's controller to Studio fails atomically (no partial state — agent rejects before exec).
- **No SSH impact, no compile impact, no training impact.** The fleet token gates only the `:9101` HTTP control plane.

**When**: any time. Quiet window not required because re-read is per-request. **Risk**: if the rotator's `/health` probe times out for a non-token reason (network blip, agent restart in flight), it auto-rolls back across all nodes — no half-rotated state. If you need to abort manually mid-script, hit Ctrl-C and the trap'd `rollback()` runs.

---

## 2. CF_TOKEN (Cloudflare deploy)

**Where it lives**:
- `~/Desktop/rings` on **Mini** (per memory entry `deploy_via_mini.md` and `tools/deploy_ledatic.sh:28`). Path is hardcoded in two scripts:
  - `ledatic-site/deploy.sh:4-5` — usage doc says `CF_TOKEN=$(cat ~/Desktop/rings) ./deploy.sh`.
  - `ledatic-site/worker/deploy_worker.sh:7,12` — `TOKEN=$(cat ~/Desktop/rings)`.
- Also referenced from Studio: `tools/deploy_ledatic.sh:28` (`TOKEN_PATH='~/Desktop/rings'` — tilde expanded **on Mini** during the inner ssh).

**Who reads it**:
- `ledatic-site/deploy.sh` — pushes static files to Cloudflare KV via `Authorization: Bearer $CF_TOKEN`. Required scopes: `Account:Workers KV Storage:Edit`.
- `ledatic-site/worker/deploy_worker.sh` — pushes worker.js + bindings via `PUT /workers/scripts/ledatic`. Required scopes: `Account:Workers Scripts:Edit`.
- `tools/deploy_ledatic.sh` (on Studio) — ssh's into Mini and runs `CF_TOKEN=$(cat ~/Desktop/rings) ./deploy.sh "$@"`. Studio never sees the token value.

**Rotate procedure**:

```sh
# 1. Generate new token in Cloudflare dashboard:
#    dash.cloudflare.com → Profile → API Tokens → Create Token.
#    Required scopes: Account:Workers Scripts:Edit, Account:Workers KV Storage:Edit.
#    Restrict to Account = "Ledatic" (account id 2acd6ceb3a0c57f1f2b470433d94bc87).
#    Copy the new value.

# 2. On Mini (ssh <user>@<host>):
NEW_CF_TOKEN='<paste-new-value>'
cp ~/Desktop/rings ~/Desktop/rings.prerotate
printf '%s' "$NEW_CF_TOKEN" > ~/Desktop/rings
chmod 600 ~/Desktop/rings
unset NEW_CF_TOKEN

# 3. Revoke the old token in the same Cloudflare dashboard panel.
#    (Do NOT delete ~/Desktop/rings.prerotate yet — keep until verification passes.)
```

No service to restart — every consumer reads the file fresh per invocation.

**Verification** (one-line, run from Mini):

```sh
curl -sf -H "Authorization: Bearer $(cat ~/Desktop/rings)" 'https://api.cloudflare.com/client/v4/user/tokens/verify' | python3 -c 'import sys,json; d=json.load(sys.stdin); print("OK" if d.get("success") and d["result"]["status"]=="active" else "FAIL")'
```

Expect `OK`. Then do a real round-trip:

```sh
cd ~/projects/ledatic-site && CF_TOKEN=$(cat ~/Desktop/rings) ./deploy.sh index.html
```

Expect HTTP 200 on the verify line. After the round-trip succeeds, `rm ~/Desktop/rings.prerotate`.

**Blast radius if rotated mid-flight**:
- `tools/deploy_ledatic.sh` running from Studio: the inner `ssh ... "CF_TOKEN=\$(cat ~/Desktop/rings) ./deploy.sh ..."` reads the file at the moment the ssh-side shell expands `$(cat ...)`. If the rewrite happens between ssh-connect and shell-expand, you get a partial token (race window: milliseconds). Practically: if you trigger rotation **during** an in-flight `deploy_ledatic.sh`, the deploy may upload some files with old token (already-issued requests succeed) and fail mid-batch with 401 once Cloudflare propagates the revoke (seconds-to-minutes after step 3).
- `worker/deploy_worker.sh` is even more sensitive — it also reads `~/.ledatic/entropy/beacon_token` and `~/.ledatic/api/bearer_token` and writes them as Worker secret bindings. Mid-flight rotation can leave the Worker temporarily without a refreshed binding if the metadata PUT fails.
- **Static-page serving is NOT affected.** Cloudflare KV reads use the Worker's own KV binding, not CF_TOKEN.

**When**: only when no deploy is in flight. The `daily_deploy.rail` cron may run from Studio — check `tools/deploy/daily_deploy.rail` schedule before rotating.

---

## 3. API_BEARER (ledatic.org Worker)

**Where it lives**:
- `~/.ledatic/api/bearer_token` on **Mini** (43-char). Read at deploy time only.
- `env.API_BEARER` as a Cloudflare Worker `secret_text` binding on the `ledatic` script (the live read path).

**Who reads it**:
- `worker/worker.js:432` and `:906` — `Authorization: Bearer ${env.API_BEARER}` gate on `/admin/*` and `/api/update`.
- `worker/deploy_worker.sh:30` — `API_BEARER_VAL=$(cat ~/.ledatic/api/bearer_token)`, then re-uploaded as the secret binding on every Worker deploy.
- Operator-side: any curl that hits `/admin/*` or `/api/update` reads it from wherever the operator stashes it. Currently no in-tree caller; humans paste it.

**Rotate procedure** (already rotated 2026-05-12 per audit memo; this is the procedure for **next** rotation):

```sh
# 1. On Mini (ssh <user>@<host>):
NEW_API_BEARER=$(openssl rand -base64 32 | tr -d '+/=' | head -c 43)
cp ~/.ledatic/api/bearer_token ~/.ledatic/api/bearer_token.prerotate
printf '%s' "$NEW_API_BEARER" > ~/.ledatic/api/bearer_token
chmod 600 ~/.ledatic/api/bearer_token

# 2. Push to Worker (uploads as secret_text binding):
cd ~/projects/ledatic-site && ./worker/deploy_worker.sh
# Should print {"success": true, ...}.

# 3. Stash the new value in your password manager.
unset NEW_API_BEARER

# 4. After verification (next step), rm ~/.ledatic/api/bearer_token.prerotate.
```

**Verification** (run from anywhere; replace `<new>` with the value in your password manager):

```sh
curl -sI -H "Authorization: Bearer <new>" 'https://ledatic.org/admin/health' | head -1
# Expect: HTTP/2 200  (or whatever the admin/health route returns on success).
# Without the bearer, the same URL returns 401.
```

Negative check (must fail):

```sh
curl -sI -H "Authorization: Bearer $(cat ~/.ledatic/api/bearer_token.prerotate)" 'https://ledatic.org/admin/health' | head -1
# Expect: HTTP/2 401.
```

If the negative check returns 200, the Worker upload didn't take — re-run `deploy_worker.sh` and re-check.

**Blast radius if rotated mid-flight**:
- Any operator session holding the old bearer in env / clipboard breaks immediately on the next request after the Worker deploy completes (seconds).
- Cloudflare Worker deploy is atomic (single PUT) — there is **no** half-rotated state at the edge.
- `BEACON_TOKEN` and `API_BEARER` are uploaded together by `deploy_worker.sh`. If you rotate API_BEARER and `~/.ledatic/entropy/beacon_token` happens to be missing/unreadable on Mini at that moment, the deploy fails atomically and the Worker keeps the **old** API_BEARER. Confirm `cat ~/.ledatic/entropy/beacon_token | wc -c` is non-zero before step 2.
- `/admin/*`, `/api/update`, devlog/snapshot/oversight write paths all gate on this. **Public read paths (/, /plasma, /provenance, /verify, /api/intel/waitlist) are unaffected** — they don't touch `env.API_BEARER`.

**When**: only when no operator session is in the middle of an admin write. Coordinate with yourself.

---

## 4. Telegram bot token

**Where it lives**:
- Environment variable `RAIL_TELEGRAM_TOKEN` on whatever shell launches the trainer. There is **no on-disk file** in tree — the value lives in your shell rc (`~/.zshrc` / `~/.bashrc`) or in launchd EnvironmentVariables for whatever wraps the training run. Audit-rotated 2026-05-12.
- Companion env var `RAIL_TELEGRAM_CHAT` (chat id, not a secret).

**Who reads it**:
- `tools/train/notify.sh:6` — `TOKEN="${RAIL_TELEGRAM_TOKEN:?Set RAIL_TELEGRAM_TOKEN}"`.
- `tools/train/notify.rail:15` — `token = trim (shell "echo $RAIL_TELEGRAM_TOKEN")`.
- Both POST to `https://api.telegram.org/bot${TOKEN}/sendMessage` with `chat_id` and a body string.
- Called from `tools/train/post_train.sh` (and ad-hoc by `notify.sh "msg"`).

**Rotate procedure**:

```sh
# 1. On phone: open Telegram → @BotFather → /mybots → pick your bot → API Token → Revoke current token.
#    BotFather prints a new token in the chat. Copy it.

# 2. On every host that sets RAIL_TELEGRAM_TOKEN (Studio, possibly Mini if it
#    runs trainers): edit ~/.zshrc (or wherever the export lives):
#      export RAIL_TELEGRAM_TOKEN='<new-value>'
#    Then in the current shell:
NEW_TG='<paste>'
export RAIL_TELEGRAM_TOKEN="$NEW_TG"
unset NEW_TG

# 3. New shells pick it up automatically. Existing trainer processes still
#    hold the OLD token in their environment until restart — see blast radius.
```

**Verification**:

```sh
curl -s "https://api.telegram.org/bot${RAIL_TELEGRAM_TOKEN}/getMe" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("OK", d["result"]["username"]) if d.get("ok") else print("FAIL", d)'
```

Expect `OK <bot_username>`. Then a real round-trip:

```sh
bash ~/projects/rail/tools/train/notify.sh "rotation test $(date +%s)"
```

Expect a message in the Telegram chat.

**Blast radius if rotated mid-flight**:
- BotFather token revoke is **immediate** at Telegram's edge. Any in-flight trainer holding the old token in its already-loaded environment will **silently fail** notify calls (HTTP 404 from Telegram). The trainer continues; you just stop seeing notifications.
- No deploy / serving / fleet impact.
- `RAIL_TELEGRAM_CHAT` is unchanged.

**When**: any time. Lowest blast radius of any token in this runbook.

---

## 5. Anthropic API key

**Where it lives**:
- File at `~/.fleet/anthropic_key` (mode 600). Per `stdlib/anthropic_client.rail:16`: "Rail's `shell()` doesn't inherit env vars. Pass the API key via a file." Path is **not hardcoded in stdlib** — caller passes a `key_path` argument.
- Concrete callers in tree (grep `anthropic_key`):
  - `tools/tls/anthropic_live_test.rail:5` — uses literal `~/.fleet/anthropic_key` (Mini username path; would need adjust on Studio where it'd be `~/.fleet/anthropic_key`).
  - `README.md:88` — example uses `/Users/me/.fleet/anthropic_key`.
- The corpus dumps under `training/corpus_*.txt` reference the path string but those are training data, not consumers.

**Who reads it**:
- `stdlib/anthropic_client.rail:65` — `let key = a_trim_line (read_file key_path)`. Sent as `x-api-key: <key>` header to `api.anthropic.com:443` over verified TLS 1.3 (post-2026-05-12 fix; the `_unsafe_noverify` variant exists at `:81` for debug only).
- Indirect consumers: `tools/train/self_train.rail` and anything else that calls `anthropic_chat` (search `grep -rn anthropic_chat tools/`).

**Rotate procedure**:

```sh
# 1. https://console.anthropic.com → Settings → API Keys → Create Key.
#    Give it a name like "rail-self-train-2026-05-12". Copy the value.

# 2. On Studio (and any node that runs trainers using anthropic_chat):
NEW_ANTHROPIC='<paste-sk-ant-...>'
[ -f ~/.fleet/anthropic_key ] && cp ~/.fleet/anthropic_key ~/.fleet/anthropic_key.prerotate
printf '%s\n' "$NEW_ANTHROPIC" > ~/.fleet/anthropic_key
chmod 600 ~/.fleet/anthropic_key
unset NEW_ANTHROPIC

# 3. Console → API Keys → revoke the old key.

# 4. After verification, rm ~/.fleet/anthropic_key.prerotate.
```

**Verification**:

```sh
cd ~/projects/rail && ./rail_native run tools/tls/anthropic_live_test.rail
# Expect: "hello from pure rail" (or close — model may riff slightly).
# If it returns "" or HTTP non-200, the new key didn't take.
```

Note: `anthropic_live_test.rail` hardcodes the Mini path `~/.fleet/anthropic_key`. On Studio, edit the path in that file to `~/.fleet/anthropic_key` for the test, or invoke `anthropic_chat` from a one-liner with the correct path.

**Blast radius if rotated mid-flight**:
- Any in-flight `self_train.rail` segment that's currently waiting on an HTTP response from `api.anthropic.com` with the old key: that request completes (Anthropic still honors in-flight requests for a brief window, but post-revoke they 401). The next call in the loop reads the file fresh (`read_file key_path` is per-call, not cached) and uses the new value.
- If the old key revoke happens **before** the file rewrite, every in-flight call fails 401 until the file is rewritten. Race window is whatever it takes you to type two commands. Mitigation: write the new file **first**, then revoke the old key in the console.
- No fleet / deploy / Worker impact.

**When**: between trainer segments, ideally during a checkpoint pause. Self_train auto-resumes from checkpoint, so a brief 401 streak is recoverable but ugly in logs.

---

## 6. GitHub PATs

**Where it lives**: **nowhere on this fleet today.** Grep across `~/projects/rail/tools/`, `~/projects/ledatic-site/`, `~/.config/`, and `~/.zshrc` for `GITHUB_TOKEN`, `GH_TOKEN`, `gh_token` returns zero callers (only doc/text mentions). The only matches are:
- `tools/deploy_ledatic.sh` references `TOKEN` for **Cloudflare** (covered in §2), not GitHub.
- `tools/compile.rail`, `CHANGELOG.md`, plasma scripts mention `GITHUB_TOKEN` only in comments / generated text.
- `gh auth status` returns "not logged into any GitHub hosts" (per `security_deferred_runbook_2026-05-12.md` §3).

**Who reads it**: nobody on Studio today. Mini's `~/git/{rail,ledatic-site}.git/hooks/post-receive` push to GitHub via SSH (key at `~/.ssh/id_ed25519`, not a PAT). Confirm:

```sh
ssh <user>@<host> 'cat ~/git/rail.git/hooks/post-receive ~/git/ledatic-site.git/hooks/post-receive'
```

Expect `git push` invocations using the `git@github.com:` SSH remote, no token in env.

**Rotate procedure**: **not applicable** until you `gh auth login` (per security_deferred_runbook §3). When you do:
- The OAuth token gh writes to `~/.config/gh/hosts.yml` is the rotatable artifact. To rotate: `gh auth refresh` (interactive) or `gh auth logout && gh auth login` (full re-auth).
- The SSH key at `~/.ssh/id_ed25519` is not a PAT. Rotation procedure for SSH keys is out-of-scope for this runbook.

**Verification** (post-`gh auth login`):

```sh
gh auth status
# Expect: ✓ Logged in to github.com as <user> (oauth_token), with scopes 'repo, admin:org'.
gh api user | python3 -c 'import sys,json; print(json.load(sys.stdin)["login"])'
```

**Blast radius if rotated mid-flight**:
- Today: zero — no PAT in use.
- Post-`gh auth login`: rotating the OAuth token via `gh auth refresh` invalidates any concurrent `gh api ...` call from another shell. Bare `git push` over SSH is unaffected (uses key, not token).

**When**: only after §3 of the security_deferred_runbook lands. Until then, nothing to rotate.

---

## Cross-cutting hygiene

After **any** rotation:

1. **Search for the old value in files you might have grepped during the rotation**:
   ```sh
   grep -rn '<first-8-chars-of-old-token>' ~/.zsh_history ~/.bash_history /tmp/ 2>/dev/null
   ```
   If the old value appears in shell history, scrub the matching lines.

2. **Confirm prerotate backups are gone**:
   ```sh
   ls -la ~/.fleet/token.prerotate ~/Desktop/rings.prerotate ~/.ledatic/api/bearer_token.prerotate ~/.fleet/anthropic_key.prerotate 2>/dev/null
   ```
   Expect zero output once verification has passed for each token. Audit memo says clean up after 7d at the latest.

3. **Update `notes/security_audit_2026-05-12.md` deferred section** — strike rotated items, leave the corresponding "credentials already rotated; remaining risk is reputational" note in place for API_BEARER + Telegram (the public-history scrub is a **separate** deferred item — see security_deferred_runbook §3 for branch protection sequencing and audit memo H10a/H10b).

4. **Do NOT commit any of these files**. `.gitignore` should already cover `~/.fleet/`, `~/.ledatic/`, `~/Desktop/rings`. They live outside the repo by design — confirm before any `git add -A`.
