#!/usr/bin/env bash
#
# gen_release_ledger.sh -- generate docs/RELEASE_LEDGER.md
#
# Joins every git tag against its signed release record and emits one
# markdown table covering all of them, with computed (not asserted)
# honesty labels.
#
# Usage:
#   bash tools/attest/gen_release_ledger.sh                            # ledger markdown to stdout
#   bash tools/attest/gen_release_ledger.sh > docs/RELEASE_LEDGER.md   # regenerate the committed copy
#   bash tools/attest/gen_release_ledger.sh --check                    # regenerate + diff vs committed
#                                                                      #   exit 0 if identical, 1 with diff
#                                                                      #   if stale (receipt R20)
#
# Data sources (all read-only):
#   - git tag / git for-each-ref (tag names + creation dates)
#   - git log (commit dates, for the 48h label window)
#   - git show <ref>:tools/compile.rail (to confirm each verify one-liner
#     actually extracts the attested bytes before printing it)
#   - releases/<name>/index.json (commit, artifact sha256s, pulse_ids)
#   - releases/<name>/*.attestation.json (witnessed timestamps)
#
# Timestamp choice (documented per spec): witnessed_at is taken from
# beacon.timestamp_utc inside the artifact's attestation JSON when present,
# else from the top-level created_at (unix). In the current tree every
# attestation carries both; beacon.timestamp_utc is preferred because it is
# the beacon's own UTC record of the pulse the signature anchors to (the two
# differ by at most seconds).
#
# Label math: release-day if witnessed_at <= tag-commit date + 48h,
# backfilled if later, no-attestation if the tag has no releases/<tag>/
# directory or no index.json in it.
#
# Requires: bash, git, python3 (stdlib only). No network, no writes outside
# /tmp. ASCII output only.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

generate() {
python3 - <<'PYEOF'
import hashlib, json, os, re, subprocess, sys
from datetime import datetime, timezone

WINDOW_S = 48 * 3600
WITNESS = "witness-fleet0"

def die(msg):
    sys.stderr.write("gen_release_ledger: %s\n" % msg)
    sys.exit(2)

def git(*args):
    r = subprocess.run(("git",) + args, capture_output=True)
    if r.returncode != 0:
        die("git %s failed: %s" % (" ".join(args), r.stderr.decode("utf-8", "replace").strip()))
    return r.stdout.decode("utf-8")

def git_show_bytes(spec):
    r = subprocess.run(("git", "show", spec), capture_output=True)
    return r.stdout if r.returncode == 0 else None

def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as e:
        die("unparseable JSON %s (%s)" % (path, e))

def vkey(s):
    # version-ish sort key, locale-independent
    return [(0, int(p), "") if p.isdigit() else (1, 0, p)
            for p in re.split(r"(\d+)", s) if p]

def witnessed(att):
    # preferred: beacon.timestamp_utc; fallback: created_at (unix)
    ts = att.get("beacon", {}).get("timestamp_utc")
    if ts:
        u = int(datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
                .replace(tzinfo=timezone.utc).timestamp())
        return u, ts[:10]
    ca = att.get("created_at")
    if ca is not None:
        u = int(ca)
        return u, datetime.fromtimestamp(u, tz=timezone.utc).strftime("%Y-%m-%d")
    return None, "-"

tags = [t for t in git("tag").splitlines() if t]
tag_date = {}  # name -> (unix, short-date as recorded by the tagger)
for line in git("for-each-ref",
                "--format=%(refname:short)\t%(creatordate:unix)\t%(creatordate:short)",
                "refs/tags").splitlines():
    name, unix, short = line.split("\t")
    tag_date[name] = (int(unix), short)

if not os.path.isdir("releases"):
    die("releases/ not found (run from the repo root)")
rel_dirs = sorted(d for d in os.listdir("releases")
                  if os.path.isdir(os.path.join("releases", d)))
names = sorted(set(tags) | {d for d in rel_dirs if d != WITNESS}, key=vkey)

rows, notes = [], []
untagged, no_att, flag_disagree = [], [], []
n_release_day = n_backfilled = 0

for name in names:
    is_tag = name in tags
    idx_path = os.path.join("releases", name, "index.json")
    idx = load_json(idx_path) if os.path.isfile(idx_path) else None

    commit = idx["git"]["commit"] if idx else None
    short = idx["git"]["short"] if idx else None
    commit_cell = short or "-"
    tag_commit = None
    if is_tag:
        tag_commit = git("rev-parse", name + "^{commit}").strip()
        if commit is None:
            commit = tag_commit
            commit_cell = tag_commit[:7]
        elif commit != tag_commit:
            commit_cell = short + "*"  # explained in notes below

    if is_tag:
        tdate = tag_date[name][1]
    elif commit:
        tdate = git("log", "-1", "--format=%cd", "--date=short", commit).strip() + " (commit)"
    else:
        tdate = "-"
    # the 48h label window anchors to the TAG's commit date (spec); the
    # attested commit is the anchor only for untagged describe-name entries
    anchor = tag_commit if is_tag else commit
    commit_unix = int(git("log", "-1", "--format=%ct", anchor).strip()) if anchor else None

    csha = rsha = pulse = wdate = "-"
    label = "no-attestation"
    verify = "see docs/VERIFY.md"

    if idx:
        arts = {a["path"]: a for a in idx.get("artifacts", [])}
        ca, ra = arts.get("tools/compile.rail"), arts.get("rail_native")
        if ca: csha = ca["sha256"][:12]
        if ra: rsha = ra["sha256"][:12]
        primary = ca or ra
        if primary:
            pulse = str(primary.get("pulse_id", "-"))
            att = load_json(os.path.join("releases", name, primary["attestation"]))
            wunix, wdate = witnessed(att)
            if wunix is not None and commit_unix is not None:
                label = "release-day" if wunix <= commit_unix + WINDOW_S else "backfilled"
                if label == "release-day":
                    n_release_day += 1
                else:
                    n_backfilled += 1
                if (label == "backfilled") != bool(idx.get("backfilled", False)):
                    flag_disagree.append((name, label, bool(idx.get("backfilled", False))))
            else:
                label = "unknown"
                notes.append("`%s`: could not derive a witnessed timestamp or commit "
                             "date; label left `unknown`." % name)
        if ca:
            want = ca["sha256"]
            blob = git_show_bytes(name + ":tools/compile.rail")
            if blob is not None and hashlib.sha256(blob).hexdigest() == want:
                verify = "`V %s`" % name
            else:
                blob2 = git_show_bytes(commit + ":tools/compile.rail") if commit else None
                if blob2 is not None and hashlib.sha256(blob2).hexdigest() == want:
                    verify = "`V %s %s`" % (commit[:7], name)
                    notes.append("`%s`: the attestation binds compile.rail as of commit "
                                 "`%s`; the tag points at `%s`, whose compile.rail "
                                 "differs, so the verify one-liner extracts from the "
                                 "attested commit." % (name, commit[:7],
                                 tag_commit[:7] if is_tag else "?"))
                else:
                    verify = "attested bytes not at any known ref -- see notes"
                    notes.append("`%s`: the attested compile.rail sha256 matches neither "
                                 "the tag nor the recorded commit. Investigate before "
                                 "trusting this row." % name)

    if is_tag and idx and idx["git"]["commit"] != tag_commit:
        blob = git_show_bytes(name + ":tools/compile.rail")
        same = blob is not None and hashlib.sha256(blob).hexdigest() == \
               (arts.get("tools/compile.rail") or {}).get("sha256")
        if same:
            notes.append("`%s`: index.json records commit `%s` while the tag points at "
                         "`%s`; compile.rail is byte-identical at both, so verification "
                         "via the tag still passes." % (name, idx["git"]["short"],
                                                        tag_commit[:7]))
    if not is_tag:
        untagged.append(name)
    if is_tag and not idx:
        no_att.append(name)

    rows.append((name, tdate, commit_cell, csha, rsha, pulse, wdate, label, verify))

# the witness key's own entry, last
watt_path = os.path.join("releases", WITNESS, "fleet0.pub.pem.attestation.json")
if os.path.isfile(watt_path):
    watt = load_json(watt_path)
    _, wd = witnessed(watt)
    wpulse = str(watt.get("beacon", {}).get("pulse_id", "-"))
    rows.append((WITNESS, "-", "-", "-", "-", wpulse, wd, "trust-root (self-signed)",
                 "`./rail_native run tools/attest/verify.rail "
                 "releases/witness-fleet0/fleet0.pub.pem "
                 "releases/witness-fleet0/fleet0.pub.pem.attestation.json "
                 "releases/witness-fleet0/fleet0.pub.pem`"))
    notes.append("`witness-fleet0` is the signing key's own entry. Its attestation is "
                 "signed by the key it attests -- circular by design; the real trust "
                 "roots are this clone's git history plus the public beacon "
                 "cross-check (see docs/VERIFY.md).")

# data-driven notes for the odd entries
if "phase1-mini-handoff-2026-04-19" in names:
    notes.insert(0, "`phase1-mini-handoff-2026-04-19` is a working-state handoff "
                    "snapshot tag, not a versioned release; it is attested and "
                    "labeled by the same rules as every other tag.")
if untagged:
    notes.append("%s: untagged dev builds recorded under their `git describe` names; "
                 "no git tag exists, so the tag-date column shows the commit date."
                 % ", ".join("`%s`" % u for u in untagged))
if no_att:
    notes.append("%s: tagged before the attestation pipeline existed; a git tag with "
                 "no signed release record. The bytes are still recoverable from "
                 "history (`git show <tag>:<path>`)."
                 % ", ".join("`%s`" % t for t in no_att))
if flag_disagree:
    rd = [n for n, lab, fl in flag_disagree if lab == "release-day" and fl]
    bf = [n for n, lab, fl in flag_disagree if lab == "backfilled" and not fl]
    if rd:
        notes.append("%s: index.json records `backfilled: true` (signed via the "
                     "backfill recipe), but the witness landed within 48 hours of the "
                     "commit, so the computed timing label is release-day. Both "
                     "statements are true; the label reports timing, the flag reports "
                     "process." % ", ".join("`%s`" % n for n in rd))
    if bf:
        notes.append("%s: computed label is backfilled but index.json does not carry "
                     "`backfilled: true`." % ", ".join("`%s`" % n for n in bf))
v4 = [t for t in ("v4.0.0", "v4.0.1", "v4.1.0") if t in names]
if v4 and all(r[7] == "release-day" for r in rows if r[0] in v4):
    notes.append("%s: docs/RELEASES.md records these as backfilled in May 2026 "
                 "(signed via the backfill recipe about 35 hours after tagging), but "
                 "that lands inside the 48-hour window, so the computed timing label "
                 "is release-day." % ", ".join("`%s`" % t for t in v4))

n_tags = len(tags)
n_att_tags = sum(1 for t in tags
                 if os.path.isfile(os.path.join("releases", t, "index.json")))

out = []
out.append("<!-- generated by tools/attest/gen_release_ledger.sh - do not hand-edit; check with --check -->")
out.append("")
out.append("# Release ledger")
out.append("")
out.append("Every git tag in this repository joined against its signed release record")
out.append("under `releases/<tag>/`. Generated from `git tag`, `releases/*/index.json`,")
out.append("and the per-artifact attestation JSONs. Regenerate with")
out.append("`bash tools/attest/gen_release_ledger.sh > docs/RELEASE_LEDGER.md`; check")
out.append("freshness with `bash tools/attest/gen_release_ledger.sh --check` (receipt R20).")
out.append("")
out.append("**Backfill semantics:** a backfilled signature proves the bytes existed")
out.append("before pulse N (May 2026) -- provenance-as-of-backfill, not release-day")
out.append("witness.")
out.append("")
out.append("Labels are computed from the data, never asserted:")
out.append("")
out.append("- `release-day` -- witnessed_at is within 48 hours of the tag's commit date.")
out.append("- `backfilled` -- witnessed_at is more than 48 hours after the tag's commit date.")
out.append("- `no-attestation` -- the tag has no `releases/<tag>/` directory (or no `index.json`).")
out.append("")
out.append("Conventions: the witnessed date is `beacon.timestamp_utc` (UTC) from the")
out.append("compile.rail attestation, falling back to `created_at` if absent; the tag")
out.append("date is the tag's creation date as recorded in git. The `pulse_id` shown is")
out.append("the compile.rail artifact's beacon pulse (rail_native's own pulse lives in")
out.append("its attestation JSON, typically a few pulses earlier). sha256 columns show")
out.append("the first 12 hex chars recorded in `index.json`. The generator confirms,")
out.append("before printing any verify one-liner, that `git show` of that ref yields")
out.append("exactly the attested bytes.")
out.append("")
out.append("To verify a row offline, paste this helper once at the repo root, then run")
out.append("the row's one-liner; expected output contains `ok artifact=compile.rail`")
out.append("and `pk_fp=cac5f21a70564aeb`:")
out.append("")
out.append('    V() { r="$1"; d="${2:-$1}"; git show "$r":tools/compile.rail >"/tmp/rail_ledger_$d" && ./rail_native run tools/attest/verify.rail "/tmp/rail_ledger_$d" "releases/$d/compile.rail.attestation.json" releases/witness-fleet0/fleet0.pub.pem; }')
out.append("")
out.append("| tag | tag date | commit (short) | compile.rail sha256 (first 12) | rail_native sha256 (first 12) | pulse_id | witnessed date | label | verify one-liner |")
out.append("|---|---|---|---|---|---|---|---|---|")
for r in rows:
    out.append("| " + " | ".join(r) + " |")
out.append("")
out.append("%d git tags (%d with signed release records, %d without), %d untagged"
           % (n_tags, n_att_tags, n_tags - n_att_tags, len(untagged)))
out.append("attested builds, 1 witness-key entry. Of the %d attested records:"
           % (n_att_tags + len(untagged)))
out.append("%d labeled release-day, %d backfilled." % (n_release_day, n_backfilled))
out.append("")
out.append("## Notes on odd entries")
out.append("")
for n in notes:
    out.append("- " + n)
out.append("")
text = "\n".join(out)
if any(ord(c) > 126 for c in text):
    die("non-ASCII character in generated output")
sys.stdout.write(text)
PYEOF
}

if [ "${1:-}" = "--check" ]; then
    if [ ! -f docs/RELEASE_LEDGER.md ]; then
        echo "gen_release_ledger: docs/RELEASE_LEDGER.md does not exist; generate it first" >&2
        exit 1
    fi
    tmp="$(mktemp /tmp/rail_ledger_check.XXXXXX)" || exit 2
    if ! generate > "$tmp"; then
        rm -f "$tmp"
        echo "gen_release_ledger: generation failed" >&2
        exit 2
    fi
    if diff -u -L "docs/RELEASE_LEDGER.md (committed)" -L "regenerated" docs/RELEASE_LEDGER.md "$tmp"; then
        rm -f "$tmp"
        echo "gen_release_ledger: docs/RELEASE_LEDGER.md is up to date"
        exit 0
    else
        rm -f "$tmp"
        echo "gen_release_ledger: docs/RELEASE_LEDGER.md is STALE -- regenerate with: bash tools/attest/gen_release_ledger.sh > docs/RELEASE_LEDGER.md" >&2
        exit 1
    fi
else
    generate
fi
