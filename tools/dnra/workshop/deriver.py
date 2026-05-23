"""Derivation backend v0 -- HTTP client to the Studio 122B (or any
OpenAI-compatible /v1/chat/completions endpoint).

Two call modes:

  derive_cited(prompt, retrieved)   -- the model receives the retrieved
                                       section text inline (RAG) and is
                                       asked to quote verbatim + derive
                                       + emit a Cite line whose source
                                       matches retrieved["source"]/section.

  derive_uncited(prompt)            -- the model receives no source text
                                       and is asked to answer in plain
                                       prose without a Cite line. Used
                                       when the classifier says
                                       needs_cite=False.

Both go through the same LLM endpoint; the difference is in the
system + user prompts.  Default endpoint is the SSH-tunneled Studio
122B at localhost:8082; override with --endpoint / --model.
"""

from __future__ import annotations
import json
import urllib.request

LLM_URL_DEFAULT = "http://localhost:8082/v1/chat/completions"
MODEL_DEFAULT = "mlx-community/Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq"


SYSTEM_CITED = (
    "You are a Deductive panelist.  You will receive a user question "
    "AND the verbatim text of one section of an authoritative source.  "
    "Answer the question by (a) opening with Yes / No / or a short claim, "
    "(b) quoting the load-bearing clause from the supplied section text "
    "VERBATIM (in double quotes), (c) deriving the conclusion in 1-3 short "
    "sentences, and (d) ending with a single 'Cite:' line whose source and "
    "section match the supplied section's header.  The quoted clause MUST "
    "be a contiguous substring of the supplied text.  Do not paraphrase "
    "inside the quotation.  Do not cite anything else."
)

SYSTEM_UNCITED = (
    "You are a Deductive panelist.  Answer in plain prose.  Be concise "
    "and direct (2-4 sentences).  Do NOT include a 'Cite:' line.  If you "
    "are uncertain or lack a verified source for any factual claim, say "
    "so explicitly instead of inventing one."
)


def _post(url: str, body: dict, timeout: int = 180) -> dict:
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def derive_cited(
    prompt: str,
    retrieved: dict,
    *,
    endpoint: str = LLM_URL_DEFAULT,
    model: str = MODEL_DEFAULT,
    max_tokens: int = 400,
    temperature: float = 0.2,
) -> str:
    user_msg = (
        f"Question: {prompt}\n\n"
        f"Source: {retrieved['source']} section {retrieved['section']}\n"
        f"Section text:\n<<<\n{retrieved['text']}\n>>>\n\n"
        f"Construct your answer per the system instructions.  The Cite "
        f"line must read exactly 'Cite: {retrieved['source']} section "
        f"{retrieved['section']}'."
    )
    resp = _post(endpoint, {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_CITED},
            {"role": "user", "content": user_msg},
        ],
        "max_tokens": max_tokens,
        "temperature": temperature,
    })
    return resp["choices"][0]["message"]["content"]


def derive_uncited(
    prompt: str,
    *,
    endpoint: str = LLM_URL_DEFAULT,
    model: str = MODEL_DEFAULT,
    max_tokens: int = 400,
    temperature: float = 0.3,
) -> str:
    resp = _post(endpoint, {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_UNCITED},
            {"role": "user", "content": prompt},
        ],
        "max_tokens": max_tokens,
        "temperature": temperature,
    })
    return resp["choices"][0]["message"]["content"]
