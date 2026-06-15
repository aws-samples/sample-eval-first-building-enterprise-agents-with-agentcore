"""GSR calculation and RCOF aggregation."""

from __future__ import annotations

from collections import Counter
from shared.models import Goal, RCOFCode


def compute_gsr(goals: list[Goal]) -> float:
    """Goal Success Rate = successful goals / total goals × 100%."""
    if not goals:
        return 0.0
    successful = sum(1 for g in goals if g.quality == "success")
    return (successful / len(goals)) * 100.0


def compute_multi_turn_gsr(goals: list[Goal]) -> float:
    """GSR for goals spanning 2+ turns only."""
    multi = [g for g in goals if len(g.turns) >= 2]
    return compute_gsr(multi)


def compute_rcof_distribution(goals: list[Goal]) -> dict[str, int]:
    """Count failure root causes across all failed goals."""
    counter = Counter()
    for g in goals:
        if g.quality == "failure" and g.rcof:
            counter[f"{g.rcof.name}: {g.rcof.value}"] += 1
    return dict(counter.most_common())


def build_summary(goals: list[Goal]) -> dict:
    """Build complete GSR/RCOF summary."""
    multi_turn = [g for g in goals if len(g.turns) >= 2]
    return {
        "total_goals": len(goals),
        "successful_goals": sum(1 for g in goals if g.quality == "success"),
        "failed_goals": sum(1 for g in goals if g.quality == "failure"),
        "gsr": round(compute_gsr(goals), 1),
        "multi_turn_goals": len(multi_turn),
        "multi_turn_gsr": round(compute_gsr(multi_turn), 1),
        "rcof_distribution": compute_rcof_distribution(goals),
    }
