"""THELMA Decompose modules: D_text, D_qcov, D_sen."""

import re
from shared.llm_client import LLMClient
from evaluators.thelma.prompts import CLAIM_EXTRACT_PROMPT, QUERY_DECOMPOSE_PROMPT


def _parse_output_tags(text: str) -> list[str]:
    """Extract items from <output>...</output> tags."""
    match = re.search(r"<output>(.*?)</output>", text, re.DOTALL)
    if not match:
        return [line.strip("- •").strip() for line in text.strip().split("\n") if line.strip()]
    content = match.group(1).strip()
    return [line.strip("- •").strip() for line in content.split("\n") if line.strip()]


def decompose_text(text: str, llm: LLMClient) -> list[str]:
    """D_text: Decompose text into atomic claims. Used for source facts and response claims."""
    prompt = CLAIM_EXTRACT_PROMPT.format(input=text)
    resp = llm.invoke(prompt)
    return _parse_output_tags(resp.text)


def decompose_query(query: str, llm: LLMClient) -> list[str]:
    """D_qcov: Decompose query into standalone sub-questions."""
    prompt = QUERY_DECOMPOSE_PROMPT.format(input=query)
    resp = llm.invoke(prompt)
    return _parse_output_tags(resp.text)


def decompose_sentences(text: str) -> list[str]:
    """D_sen: Split text into sentences using primary terminators. Rule-based, no LLM needed."""
    sentences = re.split(r'(?<=[.!?])\s+', text.strip())
    return [s.strip() for s in sentences if s.strip()]
