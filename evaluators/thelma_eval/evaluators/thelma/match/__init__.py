"""THELMA Match modules: essentiality, coverage, groundedness, similarity."""

import re
from shared.llm_client import LLMClient
from evaluators.thelma.prompts import ESSENTIALITY_PROMPT, GROUNDEDNESS_PROMPT, COVERAGE_PROMPT


def _parse_binary(text: str) -> int:
    """Parse LLM output to 0 or 1."""
    match = re.search(r"<output>\s*(.*?)\s*</output>", text, re.DOTALL)
    content = match.group(1).strip().lower() if match else text.strip().lower()
    if content in ("1", "essential", "yes", "supported", "true"):
        return 1
    return 0


def match_essentiality(fact: str, query: str, llm: LLMClient) -> int:
    """m_sp / m_rp: Is this fact essential to answer the query? Returns 1 or 0."""
    prompt = ESSENTIALITY_PROMPT.format(query=query, response=fact)
    resp = llm.invoke(prompt)
    return _parse_binary(resp.text)


def match_groundedness(claim: str, source: str, llm: LLMClient) -> int:
    """m_gr: Is this claim supported by the source? Returns 1 or 0."""
    prompt = GROUNDEDNESS_PROMPT.format(source=source, claim=claim)
    resp = llm.invoke(prompt)
    return _parse_binary(resp.text)


def match_coverage(question: str, text: str, llm: LLMClient) -> int:
    """m_sqcov / m_rqcov: Is this sub-question answered by the text? Returns 1 or 0."""
    prompt = COVERAGE_PROMPT.format(question=question, text=text)
    resp = llm.invoke(prompt)
    return _parse_binary(resp.text)


def match_similarity(text_a: str, text_b: str, embed_fn) -> float:
    """m_sd: Cosine similarity between two texts. Returns float 0-1 (clamped)."""
    import numpy as np
    emb_a = np.array(embed_fn(text_a))
    emb_b = np.array(embed_fn(text_b))
    norm_a = np.linalg.norm(emb_a)
    norm_b = np.linalg.norm(emb_b)
    if norm_a == 0 or norm_b == 0:
        return 0.0
    sim = float(np.dot(emb_a, emb_b) / (norm_a * norm_b))
    return max(0.0, min(1.0, sim))
