#!/opt/homebrew/bin/python3.11
"""122B-drafted cite-then-derive pair generator with citation verification.

Each topic is a (rfc_num, section) tuple.  The script:
  1. Fetches the section text via impl/sources/rfc.py (cache-backed).
  2. Builds a RAG-style prompt that gives the 122B the actual section
     text inline, then asks it to construct a (prompt, target) pair
     that QUOTES VERBATIM from the section.
  3. POSTs to the Studio 122B via the SSH tunnel at localhost:8082.
  4. Parses JSON out of the model's reply.
  5. Verifies the pair via impl/verify_citation.py.
  6. PASS pairs append to sets/corpus_d_v0b_verified.jsonl with a stable
     id assigned in order.  FAIL pairs are logged but not kept.

The point of the RAG-feed (vs. cold drafting from training-data recall)
is to remove the model's incentive to fabricate.  The verifier still
runs as the final gate -- belt + suspenders.

Usage:
    /opt/homebrew/bin/python3.11 tools/dnra/impl/draft_and_verify.py
        [--topics N]   limit to first N topics (smoke)
        [--out PATH]   default sets/corpus_d_v0b_verified.jsonl
        [--temp T]     default 0.2
        [--max-tokens N] default 600
"""

from __future__ import annotations

import argparse
import importlib
import json
import re
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO))
from tools.dnra.impl.sources.rfc import get_section as rfc_get_section  # type: ignore[import-not-found]
from tools.dnra.impl.sources.posix import get_section as posix_get_section  # type: ignore[import-not-found]
from tools.dnra.impl.verify_citation import verify_pair  # type: ignore[import-not-found]


def fetch_for_topic(ident, section: str) -> tuple[str, str | None]:
    """Return (source_string, section_text-or-None) for the given topic.

    Polymorphic on the identifier: int -> RFC, str -> POSIX function.
    """
    if isinstance(ident, int):
        return f"RFC {ident}", rfc_get_section(ident, section)
    return "POSIX.1-2017", posix_get_section(ident, section)


def topic_label(ident, section: str) -> str:
    if isinstance(ident, int):
        return f"RFC {ident} section {section}"
    return f"POSIX function {ident} section {section}"


LLM_URL = "http://localhost:8082/v1/chat/completions"
MODEL = "mlx-community/Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq"

# (rfc_num, section, polarity) -- v0 keeps polarity=='keep' to validate
# the loop before adding the harder invert-the-obvious-answer variant.
TOPICS: list[tuple[int, str, str]] = [
    (8259, "3", "keep"),       # JSON Values
    (8259, "5", "keep"),       # JSON Arrays
    (7540, "6.5", "keep"),     # HTTP/2 SETTINGS
    (7540, "8.2", "keep"),     # HTTP/2 Server Push
    (8446, "4.4.2", "keep"),   # TLS 1.3 CertificateVerify
    (8446, "5.1", "keep"),     # TLS 1.3 Record layer
]


SYSTEM = (
    "You construct a single (prompt, target) training pair for a 'cite-then-derive' reasoning "
    "model. You MUST quote the load-bearing clause verbatim from the supplied section text, "
    "with the quotation enclosed in double quotes. Output strict JSON only. No commentary."
)


def _cite_phrase(ident, section: str) -> str:
    if isinstance(ident, int):
        return f"Cite: RFC {ident} section {section}"
    return f"Cite: POSIX.1-2017 {ident}() section {section}"


def build_user_msg_keep(ident, section: str, section_text: str) -> str:
    src_line = topic_label(ident, section)
    cite_phrase = _cite_phrase(ident, section)
    return (
        f"Source: {src_line}\n"
        f"Section text:\n<<<\n{section_text}\n>>>\n\n"
        "Construct ONE (prompt, target) pair satisfying ALL of these rules:\n"
        "1. prompt: a clear, single-sentence question whose answer is "
        "   determined by the section text above.\n"
        "2. target: open with Yes / No / or a short claim, then quote the "
        "   load-bearing clause VERBATIM from the section text in DOUBLE "
        f"   quotes, then derive the conclusion in one to three short "
        f"   sentences. End with '{cite_phrase}'.\n"
        "3. The verbatim quote MUST be a contiguous substring of the "
        "   section text. Do NOT insert ellipses or paraphrase inside the "
        "   quoted span.\n"
        "4. Output strict JSON of the form: "
        '{"prompt": "...", "target": "..."}\n'
        "Output JSON now."
    )


def build_user_msg_invert(ident, section: str, section_text: str) -> str:
    src_line = topic_label(ident, section)
    cite_phrase = _cite_phrase(ident, section)
    return (
        f"Source: {src_line}\n"
        f"Section text:\n<<<\n{section_text}\n>>>\n\n"
        "Construct ONE (prompt, target) pair that TRAINS THE READER TO "
        "DISTINGUISH RECOMMENDATION FROM REQUIREMENT. Specifically:\n\n"
        "1. prompt: phrase the question as if a stronger/affirmative reading "
        "   is expected (e.g. 'Does the spec REQUIRE...', 'Must implementations "
        "   always...', 'Is X mandatory...'). The phrasing should match a "
        "   common-but-incorrect lay reading of the section.\n"
        "2. target: OPEN with a corrective No / Not exactly / Not strictly. "
        "   Then quote the load-bearing clause VERBATIM in DOUBLE quotes; "
        "   the clause MUST contain the actual modal verb the section uses "
        "   (SHOULD, MAY, RECOMMENDED, etc.) -- exactly as it appears. Then "
        "   derive in 1-3 short sentences why the prompt's stronger reading "
        "   is wrong (point at the verb). End with "
        f"   '{cite_phrase}'.\n"
        "3. The quote MUST be a contiguous substring of the section text. "
        "   Do NOT paraphrase inside the quotation.\n"
        "4. If the section's strongest modal verb is itself MUST or SHALL "
        "   (i.e. the section IS a hard requirement and there is nothing "
        "   honest to invert), output the JSON {\"prompt\": \"\", \"target\": \"\"} "
        "   so the loop will reject it.\n"
        "5. Output strict JSON of the form: "
        '{"prompt": "...", "target": "..."}\n'
        "Output JSON now."
    )


def call_llm(ident, section: str, section_text: str, polarity: str,
             temp: float, max_tokens: int) -> str:
    if polarity == "invert":
        user_msg = build_user_msg_invert(ident, section, section_text)
    else:
        user_msg = build_user_msg_keep(ident, section, section_text)
    body = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": user_msg},
        ],
        "max_tokens": max_tokens,
        "temperature": temp,
    }
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        LLM_URL, data=data, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=300) as r:
        resp = json.loads(r.read())
    return resp["choices"][0]["message"]["content"]


JSON_OBJ = re.compile(r"\{[\s\S]*\}")


def parse_pair(content: str) -> dict | None:
    """Pull the first {...} block from the model output and parse it."""
    m = JSON_OBJ.search(content)
    if not m:
        return None
    try:
        obj = json.loads(m.group(0))
    except json.JSONDecodeError:
        # Some models emit trailing commas or bare control chars; try a
        # tolerant single-line eval as a fallback.
        try:
            cleaned = re.sub(r",\s*}", "}", m.group(0))
            obj = json.loads(cleaned)
        except json.JSONDecodeError:
            return None
    if not isinstance(obj, dict) or "prompt" not in obj or "target" not in obj:
        return None
    return obj


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--topics", type=int, default=None, help="Limit to first N topics (smoke). Default: all.")
    ap.add_argument("--topics-module", default=None,
                    help="Import TOPICS from this dotted module (e.g. tools.dnra.impl.topics_v0c). Default: builtin smoke list.")
    ap.add_argument("--out", default="tools/dnra/sets/corpus_d_v0b_verified.jsonl")
    ap.add_argument("--append", action="store_true", help="Append PASS pairs to --out instead of overwriting.")
    ap.add_argument("--id-prefix", default="V", help="Stable id prefix (e.g. V -> V-001).")
    ap.add_argument("--id-start", type=int, default=1, help="First sequential id.")
    ap.add_argument("--temp", type=float, default=0.2)
    ap.add_argument("--max-tokens", type=int, default=600)
    args = ap.parse_args()

    if args.topics_module:
        mod = importlib.import_module(args.topics_module)
        topics_src = mod.TOPICS  # type: ignore[attr-defined]
    else:
        topics_src = TOPICS
    topics = topics_src if args.topics is None else topics_src[: args.topics]
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    accepted_count = 0
    counters: dict[str, int] = {}
    print(f"drafting + verifying {len(topics)} topics; model={MODEL}")
    print(f"output: {out_path}\n")
    # Open the output file once and write each PASS pair as it lands,
    # so a long batch streams progress (and survives an early kill).
    out_mode = "a" if args.append else "w"
    out_fh = open(out_path, out_mode)
    try:
        sys.stdout.reconfigure(line_buffering=True)  # type: ignore[attr-defined]
    except (AttributeError, OSError):
        pass  # not a TextIO with reconfigure (rare; ignore)

    for i, (ident, section, polarity) in enumerate(topics, start=args.id_start):
        topic_id = f"{args.id_prefix}-{i:03d}"
        print(f"  [{i}/{len(topics)}] {topic_id}  {topic_label(ident, section)}  polarity={polarity}")
        source_str, section_text = fetch_for_topic(ident, section)
        if section_text is None:
            print(f"      SKIP: section fetch returned None")
            counters["SKIP_FETCH"] = counters.get("SKIP_FETCH", 0) + 1
            continue

        t0 = time.time()
        try:
            raw = call_llm(ident, section, section_text, polarity, args.temp, args.max_tokens)
        except Exception as e:
            print(f"      SKIP: LLM call failed: {e}")
            counters["SKIP_LLM"] = counters.get("SKIP_LLM", 0) + 1
            continue
        elapsed = int((time.time() - t0) * 1000)

        parsed = parse_pair(raw)
        if parsed is None:
            print(f"      SKIP: could not parse JSON pair from model output (raw head: {raw[:80]!r})")
            counters["SKIP_PARSE"] = counters.get("SKIP_PARSE", 0) + 1
            continue
        # Empty-pair sentinel for invert polarity: the model refuses when
        # the section has no honest inversion (e.g. pure MUST clauses).
        if not parsed.get("prompt") or not parsed.get("target"):
            print(f"      SKIP: model returned empty pair (no honest inversion for this section)")
            counters["SKIP_EMPTY"] = counters.get("SKIP_EMPTY", 0) + 1
            continue

        # For POSIX topics, the verifier expects the function name to live
        # inside the `section` field (e.g. "close / DESCRIPTION") so that
        # resolve_source can route to the right function page.  For RFC
        # topics the section number alone is already enough.
        if isinstance(ident, str):
            stored_section = f"{ident} / {section}"
        else:
            stored_section = section
        pair = {
            "id": topic_id,
            "source": source_str,
            "section": stored_section,
            "polarity": polarity,
            "prompt": parsed["prompt"],
            "target": parsed["target"],
        }
        verdict = verify_pair(pair)
        counters[verdict["status"]] = counters.get(verdict["status"], 0) + 1
        print(f"      gen={elapsed}ms  verdict={verdict['status']}  {verdict['notes']}")
        if verdict["status"] == "PASS":
            out_fh.write(json.dumps(pair, separators=(",", ":")) + "\n")
            out_fh.flush()
            accepted_count += 1
        # Stream first 2 results in full so the user can spot-check.
        if i <= 2:
            print(f"      --- prompt ---")
            print("      " + parsed["prompt"])
            print(f"      --- target ---")
            for line in parsed["target"].split("\n"):
                print("      " + line)
        print()

    out_fh.close()
    verb = "appended" if args.append else "wrote"
    print(f"{verb} {accepted_count} PASS pair(s) to {out_path}")

    print()
    print("==== run summary ====")
    print(f"  topics tried: {len(topics)}")
    for status, n in sorted(counters.items()):
        print(f"  {status:<12} {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
