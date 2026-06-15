"""THELMA metric interplay diagnosis (Table 2 from paper)."""

from shared.models import THELMAScores, THELMADiagnosis

# Thresholds for low/high classification
LOW = 0.5
HIGH = 0.7

PATTERNS = [
    {
        "check": lambda s: s.response_self_distinctness < LOW and s.response_precision >= HIGH,
        "pattern": "SD↓ RP↑",
        "interpretation": "Lengthier responses with relevant but repetitive information, low user readability",
        "component": "Prompt or Generator",
    },
    {
        "check": lambda s: s.source_query_coverage < LOW and s.response_query_coverage < LOW,
        "pattern": "SQC↓ RQC↓",
        "interpretation": "Inaccurate retrieval OR missing information in source corpora",
        "component": "Retriever or Source text",
    },
    {
        "check": lambda s: s.source_precision_chunk < LOW and s.source_query_coverage >= HIGH,
        "pattern": "SP↓ SQC↑",
        "interpretation": "All query components addressed, but some retrieved sources only loosely relevant",
        "component": "Retriever",
    },
    {
        "check": lambda s: s.response_query_coverage < LOW and s.source_query_coverage >= HIGH,
        "pattern": "RQC↓ SQC↑",
        "interpretation": "Information required to answer is present in source but not used in response",
        "component": "Prompt or Generator",
    },
    {
        "check": lambda s: s.response_precision < LOW and s.source_precision_chunk >= HIGH,
        "pattern": "RP↓ SP1↑",
        "interpretation": "Response contains extraneous information but majority of retrieved sources are essential",
        "component": "Prompt or Source chunking",
    },
    {
        "check": lambda s: s.source_query_coverage < LOW and s.response_query_coverage >= HIGH and s.groundedness < LOW,
        "pattern": "SQC↓ RQC↑ GR↓",
        "interpretation": "Generator responding to queries not addressed in source, causing ungroundedness",
        "component": "Prompt",
    },
]


def diagnose(scores: THELMAScores) -> list[THELMADiagnosis]:
    """Return all matching diagnostic patterns for the given scores."""
    results = []
    for p in PATTERNS:
        if p["check"](scores):
            results.append(THELMADiagnosis(
                pattern=p["pattern"],
                interpretation=p["interpretation"],
                component_to_improve=p["component"],
            ))
    return results
