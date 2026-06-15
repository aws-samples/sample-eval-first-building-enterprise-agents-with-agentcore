"""THELMA metrics: compute all 6 scores for a (query, sources, response) triplet."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed

from shared.llm_client import LLMClient
from shared.models import THELMAScores
from evaluators.thelma.decompose import decompose_text, decompose_query, decompose_sentences
from evaluators.thelma.match import match_essentiality, match_groundedness, match_coverage, match_similarity


def _safe_avg(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def compute_source_precision_chunk(sources: list[str], query: str, llm: LLMClient) -> float:
    """SP1: Each source chunk assessed as whole — is it essential?"""
    if not sources:
        return 0.0
    scores = [match_essentiality(s, query, llm) for s in sources]
    return _safe_avg(scores)


def compute_source_precision_fact(sources: list[str], query: str, llm: LLMClient) -> float:
    """SP2: Decompose sources into facts, assess each fact's essentiality."""
    all_facts = []
    for s in sources:
        all_facts.extend(decompose_text(s, llm))
    if not all_facts:
        return 0.0
    scores = [match_essentiality(f, query, llm) for f in all_facts]
    return _safe_avg(scores)


def compute_source_query_coverage(sources: list[str], query: str, llm: LLMClient) -> float:
    """SQC: For each sub-question, is it answered by any source?"""
    sub_questions = decompose_query(query, llm)
    if not sub_questions:
        return 0.0
    scores = []
    for q in sub_questions:
        # Max over all sources for this sub-question
        source_scores = [match_coverage(q, s, llm) for s in sources] if sources else [0]
        scores.append(max(source_scores))
    return _safe_avg(scores)


def compute_response_precision(response: str, query: str, llm: LLMClient) -> float:
    """RP: Decompose response into claims, assess each claim's essentiality."""
    claims = decompose_text(response, llm)
    if not claims:
        return 0.0
    scores = [match_essentiality(c, query, llm) for c in claims]
    return _safe_avg(scores)


def compute_response_query_coverage(response: str, query: str, llm: LLMClient) -> float:
    """RQC: For each sub-question, is it answered by the response?"""
    sub_questions = decompose_query(query, llm)
    if not sub_questions:
        return 0.0
    scores = [match_coverage(q, response, llm) for q in sub_questions]
    return _safe_avg(scores)


def compute_response_self_distinctness(response: str, embed_fn) -> float:
    """SD: Average distinctness across all sentence pairs."""
    sentences = decompose_sentences(response)
    if len(sentences) < 2:
        return 1.0  # Single sentence is perfectly distinct
    pair_scores = []
    for i in range(len(sentences)):
        for j in range(i + 1, len(sentences)):
            sim = match_similarity(sentences[i], sentences[j], embed_fn)
            pair_scores.append(1.0 - sim)
    return _safe_avg(pair_scores)


def compute_groundedness(response: str, sources: list[str], llm: LLMClient) -> float:
    """GR: Decompose response into claims, check each against combined sources."""
    claims = decompose_text(response, llm)
    if not claims:
        return 0.0
    combined_source = "\n\n".join(sources)
    scores = [match_groundedness(c, combined_source, llm) for c in claims]
    return _safe_avg(scores)


def evaluate_turn(
    query: str,
    sources: list[str],
    response: str,
    llm: LLMClient,
    embed_fn=None,
) -> THELMAScores:
    """Compute all 6 THELMA metrics for a single turn."""
    return THELMAScores(
        source_precision_chunk=compute_source_precision_chunk(sources, query, llm),
        source_precision_fact=compute_source_precision_fact(sources, query, llm),
        source_query_coverage=compute_source_query_coverage(sources, query, llm),
        response_precision=compute_response_precision(response, query, llm),
        response_query_coverage=compute_response_query_coverage(response, query, llm),
        response_self_distinctness=compute_response_self_distinctness(response, embed_fn) if embed_fn else 0.0,
        groundedness=compute_groundedness(response, sources, llm),
    )


def evaluate_turn_detailed(
    query: str,
    sources: list[str],
    response: str,
    llm: LLMClient,
    embed_fn=None,
    on_status=None,
    skip_sp2: bool = False,
) -> tuple[THELMAScores, dict]:
    """Compute all 6 THELMA metrics with full intermediate evidence.

    Returns (scores, evidence) where evidence contains the decomposed units
    and per-unit match results that explain each score.
    on_status: optional callback(message: str) for progress updates.
    skip_sp2: skip fact-level source precision (expensive) to speed up evaluation.
    """
    _status = on_status or (lambda msg: None)
    evidence: dict = {}

    # Phase 1: Decompositions (sequential — need results for phase 2)
    _status("Decomposing response into claims...")
    response_claims = decompose_text(response, llm)
    _status(f"Found {len(response_claims)} claims. Decomposing query into sub-questions...")
    sub_questions = decompose_query(query, llm)
    sentences = decompose_sentences(response)
    source_facts = []
    if not skip_sp2:
        _status(f"Found {len(sub_questions)} sub-questions. Extracting facts from {len(sources)} sources...")
        for s in sources:
            source_facts.extend(decompose_text(s, llm))
    combined_source = "\n\n".join(sources)

    total_matches = (len(sources) + len(source_facts) + len(sub_questions) * len(sources)
                     + len(response_claims) + len(sub_questions) + len(response_claims))
    _status(f"Running {total_matches} match calls in parallel (SP, SQC, RP, RQC, GR)...")

    # Phase 2: All match calls in parallel
    futures = {}
    with ThreadPoolExecutor(max_workers=8) as pool:
        # SP1
        for i, s in enumerate(sources):
            futures[pool.submit(match_essentiality, s, query, llm)] = ("SP1", i, s[:80])
        # SP2
        if not skip_sp2:
            for i, f in enumerate(source_facts):
                futures[pool.submit(match_essentiality, f, query, llm)] = ("SP2", i, f)
        # SQC
        for qi, q in enumerate(sub_questions):
            for si, s in enumerate(sources):
                futures[pool.submit(match_coverage, q, s, llm)] = ("SQC", qi, si, q)
        # RP
        for i, c in enumerate(response_claims):
            futures[pool.submit(match_essentiality, c, query, llm)] = ("RP", i, c)
        # RQC
        for i, q in enumerate(sub_questions):
            futures[pool.submit(match_coverage, q, response, llm)] = ("RQC", i, q)
        # GR
        for i, c in enumerate(response_claims):
            futures[pool.submit(match_groundedness, c, combined_source, llm)] = ("GR", i, c)

        results = {}
        done_count = 0
        for fut in as_completed(futures):
            key = futures[fut]
            results[key] = fut.result()
            done_count += 1
            if done_count % 5 == 0 or done_count == len(futures):
                _status(f"Matching... {done_count}/{len(futures)} calls done")

    _status("Assembling scores...")

    # Assemble SP1
    sp1_per = [(s[:80], results[("SP1", i, s[:80])]) for i, s in enumerate(sources)]
    sp1 = _safe_avg([v for _, v in sp1_per]) if sp1_per else 0.0
    evidence["SP1"] = {"items": [{"text": t, "essential": bool(v)} for t, v in sp1_per]}

    # Assemble SP2
    sp2_per = [(f, results[("SP2", i, f)]) for i, f in enumerate(source_facts)]
    sp2 = _safe_avg([v for _, v in sp2_per])
    evidence["SP2"] = {"items": [{"text": t, "essential": bool(v)} for t, v in sp2_per]}

    # Assemble SQC
    sqc_per = []
    for qi, q in enumerate(sub_questions):
        per_source = [results[("SQC", qi, si, q)] for si in range(len(sources))] if sources else [0]
        sqc_per.append((q, bool(max(per_source))))
    sqc = _safe_avg([int(v) for _, v in sqc_per])
    evidence["SQC"] = {"items": [{"sub_question": q, "covered": c} for q, c in sqc_per]}

    # Assemble RP
    rp_per = [(c, results[("RP", i, c)]) for i, c in enumerate(response_claims)]
    rp = _safe_avg([v for _, v in rp_per])
    evidence["RP"] = {"items": [{"claim": t, "essential": bool(v)} for t, v in rp_per]}

    # Assemble RQC
    rqc_per = [(q, results[("RQC", i, q)]) for i, q in enumerate(sub_questions)]
    rqc = _safe_avg([v for _, v in rqc_per])
    evidence["RQC"] = {"items": [{"sub_question": q, "answered": bool(v)} for q, v in rqc_per]}

    # SD: self-distinctness (embedding only, no LLM)
    sd_pairs = []
    if len(sentences) >= 2:
        for i in range(len(sentences)):
            for j in range(i + 1, len(sentences)):
                sim = match_similarity(sentences[i], sentences[j], embed_fn) if embed_fn else 0.0
                sd_pairs.append((sentences[i][:60], sentences[j][:60], round(1.0 - sim, 3)))
    sd = _safe_avg([d for _, _, d in sd_pairs]) if sd_pairs else 1.0
    evidence["SD"] = {"items": [{"sent_a": a, "sent_b": b, "distinctness": d} for a, b, d in sd_pairs]}

    # Assemble GR
    gr_per = [(c, results[("GR", i, c)]) for i, c in enumerate(response_claims)]
    gr = _safe_avg([v for _, v in gr_per])
    evidence["GR"] = {"items": [{"claim": t, "grounded": bool(v)} for t, v in gr_per]}

    scores = THELMAScores(
        source_precision_chunk=sp1,
        source_precision_fact=sp2,
        source_query_coverage=sqc,
        response_precision=rp,
        response_query_coverage=rqc,
        response_self_distinctness=sd,
        groundedness=gr,
    )
    return scores, evidence
